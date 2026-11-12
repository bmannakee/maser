// Tests for the review agent's diagrams: checking their source, reading citations, the grounding check, and
// rendering with the vendored Pele.
//
// The door controller is the one from the 2026-11-12 spike, with the PR adding its obstruction transition (lines 15
// and 16), and the diagram is the one the agent drew of it there.

import CryptoKit
import Foundation
import Testing

@testable import MaserCore

/// Tests for `Diagram`, `Citation` and `DiagramGrounding`.
@Suite struct DiagramTests {
    /// The door controller at the PR's head.
    static let door = """
        // A door controller.
        enum DoorState { case closed, opening, open, closing, locked }

        struct Door {
            var state = DoorState.closed

            mutating func handle(_ event: String) {
                switch (state, event) {
                case (.closed, "open"): state = .opening
                case (.opening, "done"): state = .open
                case (.open, "close"): state = .closing
                case (.closing, "done"): state = .closed
                case (.closed, "lock"): state = .locked
                case (.locked, "unlock"): state = .closed
                // Safety: an obstruction while closing reopens the door.
                case (.closing, "obstructed"): state = .opening
                default: break
                }
            }
        }

        """

    /// The PR's diff: it adds lines 15 and 16, and removes an old line 15.
    static let diff = DiffParser.parse(
        """
        diff --git a/Sources/Door.swift b/Sources/Door.swift
        --- a/Sources/Door.swift
        +++ b/Sources/Door.swift
        @@ -13,4 +13,5 @@ struct Door {
                 case (.closed, "lock"): state = .locked
                 case (.locked, "unlock"): state = .closed
        -        // TODO: obstruction
        +        // Safety: an obstruction while closing reopens the door.
        +        case (.closing, "obstructed"): state = .opening
                 default: break
        """)

    /// The agent's diagram of the door, from the spike.
    static let source = """
        stateDiagram-v2
            [*] --> closed
            closed --> opening: open
            opening --> open: done
            open --> closing: close
            closing --> closed: done
            closed --> locked: lock
            locked --> closed: unlock
            closing --> opening: obstructed
        """

    /// A checkout holding the door, in a new temporary folder.
    static func checkout() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "maser-diagram-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appending(path: "Sources"), withIntermediateDirectories: true)
        try door.write(to: folder.appending(path: "Sources/Door.swift"), atomically: true, encoding: .utf8)
        return folder
    }

    @Test("REQ-CNV-002: Refuses source that could act or reach out") func sourceProblems() {
        let fine = Diagram(title: "Door", format: .mermaid, source: Self.source)
        #expect(fine.sourceProblem == nil)
        for bad in [
            "flowchart LR\n  A --> B\n  click A callback", "flowchart LR\n  A --> B\n  CLICK A \"https://x.example\"",
            "flowchart LR\n  A[\"<img src=x onerror=alert(1)>\"]", "flowchart LR\n  A --> B\n  style A fill:url(https://x)",
            "%%{init: {'securityLevel': 'loose'}}%%\nflowchart LR\n  A --> B", "flowchart LR\n  A[\"<a href='x'>y</a>\"]",
            "flowchart LR\n  A[\"javascript:alert(1)\"]", "   ", String(repeating: "a", count: Diagram.maxSourceLength + 1),
        ] {
            #expect(Diagram(title: "x", format: .mermaid, source: bad).sourceProblem != nil, "\(bad.prefix(60))")
        }
        #expect(Diagram(title: "x", format: .dot, source: "digraph { a -> b }").sourceProblem?.contains("DOT") == true)
    }

    @Test("REQ-CNV-003: Reads citations, refusing paths outside the repository") func citations() {
        #expect(Citation("Sources/Door.swift:15-16") == Citation("Sources/Door.swift:15-16"))
        #expect(Citation("Sources/Door.swift:15-16")?.lines == 15...16)
        #expect(Citation("a/b.c:7")?.lines == 7...7 && Citation("a/b.c:7")?.path == "a/b.c")
        for bad in ["Door.swift", "/etc/hosts:1", "../x.swift:1", "a/../../x:1", "x:0", "x:5-3", "x:a-b", ":3", "x:1-2-3"] {
            #expect(Citation(bad) == nil, "\(bad)")
        }
    }

    @Test("REQ-CNV-001: Reads show_diagram's arguments") func decodesArguments() throws {
        let diagram = try Diagram.decode(
            toolArguments:
                #"{"title":"Door","format":"mermaid","source":"stateDiagram-v2\n  a --> b","elements":[{"id":"a","citation":"x:1","change":"added"}]}"#
        )
        #expect(diagram.title == "Door" && diagram.elements == [.init(id: "a", citation: "x:1", change: .added)])
        #expect(try Diagram.decode(toolArguments: #"{"title":"t","format":"mermaid","source":"s"}"#).elements.isEmpty)
        #expect(throws: (any Error).self) { try Diagram.decode(toolArguments: #"{"title":"t","format":"svg","source":"s"}"#) }
    }

    @Test("REQ-CNV-003, REQ-CNV-004: Checks citations against the checkout and change marks against the diff")
    func grounding() throws {
        let checkout = try Self.checkout()
        defer { try? FileManager.default.removeItem(at: checkout) }
        let diagram = Diagram(
            title: "Door", format: .mermaid, source: Self.source,
            elements: [
                .init(id: "closing", citation: "Sources/Door.swift:2", change: .unchanged),
                .init(id: "edge7", citation: "Sources/Door.swift:15-16", change: .added),
                .init(id: "edge2", citation: "Sources/Door.swift:10", change: .changed),
                .init(id: "edge6", citation: "Sources/Door.swift:16"),
                .init(id: "todo", citation: "Sources/Door.swift:15", change: .removed),
                .init(id: "edge1", citation: "Sources/Door.swift:30-31"),
                .init(id: "ghost", citation: "Sources/Window.swift:1"),
                .init(id: "outside", citation: "/etc/hosts:1"),
                .init(id: "vague", change: .changed),
            ])
        let rendered: Set<String> = ["closing", "edge1", "edge2", "edge6", "edge7", "todo", "ghost", "outside", "vague"]
        let findings = DiagramGrounding.check(diagram, checkout: checkout, files: Self.diff, renderedIDs: rendered)
        let byID = Dictionary(uniqueKeysWithValues: findings.map { ($0.id, $0.problems) })

        #expect(byID["closing"] == [] && byID["edge7"] == [] && byID["todo"] == [])
        #expect(byID["edge2"] == ["is marked changed but the PR doesn't change Sources/Door.swift:10"])
        #expect(byID["edge6"] == ["cites lines the PR changes but isn't marked as changed"])
        #expect(byID["edge1"] == ["cites lines up to 31, but Sources/Door.swift has 20"])
        #expect(byID["ghost"] == ["cites Sources/Window.swift, which isn't in the checkout"])
        #expect(byID["outside"]?.first?.contains("isn't path:start-end in the repository") == true)
        #expect(byID["vague"] == ["is marked changed but cites no lines"])

        let missing = DiagramGrounding.check(diagram, checkout: checkout, files: Self.diff, renderedIDs: ["closing"])
        #expect(missing.first { $0.id == "edge7" }?.problems.contains("isn't in the drawn diagram") == true)
    }

    @Test("REQ-CNV-003: A citation can't lead outside the checkout through a symlink") func symlinkCitation() throws {
        let checkout = try Self.checkout()
        defer { try? FileManager.default.removeItem(at: checkout) }
        try FileManager.default.createSymbolicLink(
            at: checkout.appending(path: "hosts"), withDestinationURL: URL(filePath: "/etc/hosts"))
        #expect(DiagramGrounding.lineCount(of: "hosts", in: checkout) == nil)
        #expect(DiagramGrounding.lineCount(of: "Sources/Door.swift", in: checkout) == 20)
    }
}

/// Tests for `DiagramRenderer` with the vendored Pele.
@Suite struct DiagramRendererTests {
    /// The vendored `pele.global.js`.
    static let peleURL = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Vendor/pele/pele.global.js")

    /// A renderer with the vendored Pele.
    static func renderer() throws -> DiagramRenderer {
        try DiagramRenderer(script: String(contentsOf: peleURL, encoding: .utf8))
    }

    /// The vendored file is exactly the one checked against npm's integrity hash (Vendor/pele/README.md).
    @Test("REQ-CNV-002: The vendored Pele is the pinned release") func vendoredPele() throws {
        let digest = SHA256.hash(data: try Data(contentsOf: Self.peleURL)).map { String(format: "%02x", $0) }.joined()
        #expect(digest == "787ed66bb4bd56c15e224109ff5b89ed395ebfacf71fae2c0ccad1f86d6e24ef")
    }

    @Test("REQ-CNV-002, REQ-CNV-003: Renders without a page, naming states and numbering transitions") func rendersDoor()
        throws
    {
        let rendering = try Self.renderer().render(Diagram(title: "Door", format: .mermaid, source: DiagramTests.source))
        #expect(rendering.svg.hasPrefix("<svg"))
        #expect(rendering.ids.isSuperset(of: ["closed", "opening", "open", "closing", "locked"]))
        #expect(rendering.ids.isSuperset(of: Set((0...7).map { "edge\($0)" })))
        #expect(!rendering.svg.contains("<script") && !rendering.svg.contains("<a "))
    }

    @Test("REQ-CNV-002: Refuses unsafe source before Pele sees it, and reports Pele's errors") func refuses() throws {
        let renderer = try Self.renderer()
        #expect(throws: DiagramRenderer.Failure.self) {
            try renderer.render(Diagram(title: "x", format: .mermaid, source: "flowchart LR\n  A --> B\n  click A callback"))
        }
        let error = #expect(throws: DiagramRenderer.Failure.self) {
            try renderer.render(Diagram(title: "x", format: .mermaid, source: "stateDiagram-v2\n  a --> --> b"))
        }
        #expect(error?.errorDescription?.isEmpty == false)
        // After an error, the next diagram still renders.
        #expect(try renderer.render(Diagram(title: "Door", format: .mermaid, source: DiagramTests.source)).ids.contains("closed"))
    }

    @Test("REQ-CNV-004: Marks changed and flagged elements, skipping unsafe IDs") func annotates() {
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" class="pele"><g data-id="closing"></g></svg>"#
        let marked = DiagramRenderer.annotate(
            svg, changes: ["edge8": .added, "closing": .unchanged, "x\"}*{": .changed], flagged: ["edge2"])
        #expect(marked.hasPrefix(#"<svg xmlns="http://www.w3.org/2000/svg" class="pele"><style>"#))
        #expect(marked.contains(#"[data-id="edge8"] :is(rect,ellipse,circle,polygon,path) { stroke: #2da44e"#))
        #expect(marked.contains(#"[data-id="edge2"] :is(rect,ellipse,circle,polygon,path) { stroke-dasharray"#))
        #expect(!marked.contains("closing\"] :is") && !marked.contains("x\\\""))
        #expect(DiagramRenderer.annotate(svg, changes: [:], flagged: []) == svg)
    }
}
