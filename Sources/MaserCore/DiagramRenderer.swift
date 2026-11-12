// Renders the review agent's Mermaid diagrams to SVG with the bundled Pele, in JavaScriptCore.
//
// Rendering happens outside any web page, so the canvas that shows the SVG can run with page JavaScript off (RC-28).
// Pele runs with links and images turned off. Source is checked with `Diagram.sourceProblem` first. The renderer also
// lists the element IDs the SVG has, for the grounding check, and adds Maser's marks: a style that colors changed
// elements and outlines flagged ones.

import Foundation
import JavaScriptCore

/// Turns Mermaid source into SVG with Pele.
///
/// Not `Sendable`: a `JSContext` belongs to the thread that uses it. Make one per actor.
public final class DiagramRenderer {
    /// A rendered diagram.
    public struct Rendering: Equatable, Sendable {
        /// The SVG, with no script and no links.
        public let svg: String
        /// The element IDs it has (`data-id`), such as a state's name or `edge0`.
        public let ids: Set<String>
    }

    /// Why a diagram couldn't be rendered.
    public struct Failure: Error, Equatable, LocalizedError {
        /// What went wrong, as Pele or Maser says it.
        public let errorDescription: String?
    }

    /// The JavaScript context holding Pele.
    private let context: JSContext
    /// Pele's `render` function.
    private let render: JSValue

    /// Loads Pele.
    ///
    /// - Parameter script: The text of `pele.global.js`.
    /// - Throws: `Failure` if the script doesn't load or has no `render`.
    public init(script: String) throws {
        guard let context = JSContext() else { throw Failure(errorDescription: "JavaScriptCore isn't available.") }
        // The global build looks for `window`; there is no page, so the context's own global object stands in.
        context.evaluateScript("var window = globalThis; var self = globalThis;")
        context.evaluateScript(script)
        if let exception = context.exception {
            throw Failure(errorDescription: "Pele didn't load: \(exception)")
        }
        guard let render = context.objectForKeyedSubscript("pele")?.objectForKeyedSubscript("render"), render.isObject else {
            throw Failure(errorDescription: "Pele has no render function.")
        }
        self.context = context
        self.render = render
    }

    /// Renders a diagram, after checking its source.
    ///
    /// - Parameter diagram: The diagram.
    /// - Returns: The SVG and its element IDs.
    /// - Throws: `Failure` with `Diagram.sourceProblem`, or with Pele's error, such as a parse error.
    public func render(_ diagram: Diagram) throws -> Rendering {
        if let problem = diagram.sourceProblem { throw Failure(errorDescription: problem) }
        context.exception = nil
        let options: [String: Any] = ["links": false, "images": false, "limit": Diagram.maxSourceLength]
        let result = render.call(withArguments: [diagram.source, options])
        if let exception = context.exception {
            throw Failure(errorDescription: exception.toString())
        }
        guard let svg = result?.objectForKeyedSubscript("svg")?.toString(), svg.hasPrefix("<svg") else {
            throw Failure(errorDescription: "Pele returned no SVG.")
        }
        return Rendering(svg: svg, ids: Self.elementIDs(in: svg))
    }

    /// The element IDs in an SVG from Pele.
    ///
    /// - Parameter svg: The SVG.
    /// - Returns: The values of its `data-id` attributes.
    static func elementIDs(in svg: String) -> Set<String> {
        Set(svg.matches(of: #/data-id="([^"]*)"/#).map { String($0.1) })
    }

    /// Adds Maser's marks to an SVG: a color for each changed element, and a dashed outline for each flagged one.
    ///
    /// IDs are used in a CSS selector, so any with characters outside letters, digits, `_`, `-`, `.` and `:` are
    /// skipped.
    ///
    /// - Parameters:
    ///   - svg: The SVG from `render(_:)`.
    ///   - changes: The change marks, by element ID.
    ///   - flagged: The IDs of elements the grounding check found problems with.
    /// - Returns: The SVG with a style element added after its opening tag.
    public static func annotate(_ svg: String, changes: [String: Diagram.Change], flagged: Set<String>) -> String {
        let safe = { (id: String) in
            !id.isEmpty && id.allSatisfy { $0.isLetter || $0.isNumber || "_-.:".contains($0) }
        }
        var rules: [String] = []
        for (id, change) in changes.sorted(by: { $0.key < $1.key }) where safe(id) {
            let color: String? =
                switch change {
                case .added: "#2da44e"
                case .changed: "#d4a72c"
                case .removed: "#cf222e"
                case .unchanged: nil
                }
            if let color {
                rules.append("[data-id=\"\(id)\"] :is(rect,ellipse,circle,polygon,path) { stroke: \(color); stroke-width: 3px; }")
            }
        }
        for id in flagged.sorted() where safe(id) {
            rules.append("[data-id=\"\(id)\"] :is(rect,ellipse,circle,polygon,path) { stroke-dasharray: 5 3; outline: none; }")
            rules.append("[data-id=\"\(id)\"] text { fill: #cf222e; }")
        }
        guard !rules.isEmpty, let end = svg.firstIndex(of: ">") else { return svg }
        let style = "<style>\(rules.joined(separator: " "))</style>"
        return String(svg[...end]) + style + String(svg[svg.index(after: end)...])
    }
}
