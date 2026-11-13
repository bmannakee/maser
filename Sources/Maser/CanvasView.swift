// The canvas: the review agent's diagrams, beside its conversation in the Agent tab.
//
// The canvas shows one diagram at a time, labeled as the agent's with the commit it describes, with the agent's
// elements listed under it: each one's change mark, citation, and anything the grounding check found. Choosing an
// element opens its lines. The SVG is shown in a web view with page JavaScript off, a content security policy that
// allows no network, and every navigation refused (RC-28). A diagram can also open in a window of its own.

import MaserCore
import SwiftUI
import WebKit

/// The diagram canvas for one PR's conversation.
struct CanvasView: View {
    @Bindable var agent: AgentSession
    /// The head commit the review shows, to say when a diagram describes an older one.
    let head: String?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let drawn = agent.shownDiagram {
            let diagrams = agent.transcript.diagrams
            let index = diagrams.firstIndex { $0.id == drawn.id } ?? 0
            let older = head.map { $0 != drawn.commit } ?? false
            let label =
                "Drawn by the agent at \(drawn.commit.prefix(7))\(older ? ", an older commit" : ""). Check it against the diff."
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(drawn.diagram.title).font(.headline).shownText("canvas-title", drawn.diagram.title)
                        Text(label)
                            .font(.caption)
                            .foregroundStyle(older ? Color.Brand.beamInk : .secondary)
                            .shownText("canvas-label", label)
                    }
                    Spacer()
                    Button("Older", systemImage: "chevron.left") { agent.selectDiagram(offset: -1) }
                        .disabled(index == 0)
                    Text("\(index + 1) of \(diagrams.count)").monospacedDigit().foregroundStyle(.secondary)
                    Button("Newer", systemImage: "chevron.right") { agent.selectDiagram(offset: 1) }
                        .disabled(index == diagrams.count - 1)
                    Button("Open in Window", systemImage: "macwindow") { openWindow(value: drawn) }
                }
                .labelStyle(.iconOnly)
                .padding(8)
                if drawn.isUnsourced {
                    Label(
                        "Unsourced: no element cites lines, so none of it was checked against the code.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .shownText("canvas-unsourced", "unsourced")
                }
                SVGView(svg: drawn.svg)
                    .frame(minHeight: 200)
                Divider()
                DiagramElementList(agent: agent, drawn: drawn)
                    .frame(maxHeight: 220)
            }
            .sheet(item: $agent.openedCitation) { CitationView(citation: $0) }
        } else {
            ContentUnavailableView(
                "No diagrams yet", systemImage: "point.3.connected.trianglepath.dotted",
                description: Text("Ask the agent to draw something, such as the state machine this PR changes."))
        }
    }
}

/// The agent's elements for a diagram, with what the grounding check found; choosing one opens its lines.
private struct DiagramElementList: View {
    let agent: AgentSession
    let drawn: AgentDiagram

    var body: some View {
        let findings = Dictionary(drawn.findings.map { ($0.id, $0.problems) }, uniquingKeysWith: { first, _ in first })
        let flaggedCount = drawn.flagged.count
        ScrollViewReader { proxy in
            List {
                Section {
                    ForEach(Array(drawn.diagram.elements.enumerated()), id: \.offset) { index, element in
                        let problems = findings[element.id] ?? []
                        Button {
                            agent.selectedElement = index
                            agent.openCitation(of: element)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(element.id).font(.callout.monospaced()).bold()
                                    if let change = element.change, change != .unchanged {
                                        Text(change.rawValue)
                                            .font(.caption)
                                            .padding(.horizontal, 4)
                                            .background(Self.color(change).opacity(0.2), in: Capsule())
                                    }
                                    Text(element.citation ?? "no source").font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                                ForEach(problems, id: \.self) { problem in
                                    Label("\(element.id) \(problem)", systemImage: "flag.fill")
                                        .font(.caption)
                                        .foregroundStyle(Color.Brand.delInk)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(agent.selectedElement == index ? Color.Brand.ruby.opacity(0.15) : nil)
                        .id(index)
                    }
                } header: {
                    let summary =
                        flaggedCount == 0
                        ? "\(drawn.diagram.elements.count) elements; nothing flagged"
                        : "\(drawn.diagram.elements.count) elements; \(flaggedCount) flagged"
                    Text(summary).shownText("canvas-flags", summary)
                }
            }
            .listStyle(.plain)
            .onChange(of: agent.selectedElement) { _, index in
                if let index { proxy.scrollTo(index) }
            }
        }
    }

    /// The color for a change mark, matching the diagram's.
    ///
    /// - Parameter change: The mark.
    /// - Returns: Green, amber, red, or gray.
    static func color(_ change: Diagram.Change) -> Color {
        switch change {
        case .added: .green
        case .changed: .orange
        case .removed: .red
        case .unchanged: .gray
        }
    }
}

/// Lines an element cites outside the diff, read-only from the checkout, with the cited ones highlighted.
private struct CitationView: View {
    let citation: OpenedCitation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let lines = citation.text.split(separator: "\n", omittingEmptySubsequences: false)
        let first = max(1, citation.lines.lowerBound - 10)
        let last = min(lines.count, citation.lines.upperBound + 10)
        let title = "\(citation.path):\(citation.lines.lowerBound)-\(citation.lines.upperBound)"
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline.monospaced()).shownText("citation-title", title)
                Spacer()
                Text("From the agent's checkout; not in the diff").foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(first...max(first, last), id: \.self) { number in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(number)").foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                            Text(lines.indices.contains(number - 1) ? String(lines[number - 1]) : "")
                        }
                        .font(.body.monospaced())
                        .background(citation.lines.contains(number) ? Color.Brand.ruby.opacity(0.15) : .clear)
                    }
                }
                .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(minWidth: 640, minHeight: 360)
    }
}

/// A diagram in a window of its own, for room to read it.
struct DiagramWindow: View {
    let drawn: AgentDiagram

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Drawn by the agent at \(drawn.commit.prefix(7)). Check it against the diff.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
            SVGView(svg: drawn.svg)
        }
        .navigationTitle(drawn.diagram.title)
        .frame(minWidth: 480, minHeight: 360)
    }
}

/// Shows an SVG with no script, no network and no navigation; pinch or ⌘+ to zoom.
struct SVGView: NSViewRepresentable {
    let svg: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.allowsMagnification = true
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != svg else { return }
        context.coordinator.loaded = svg
        context.coordinator.allowNextLoad = true
        view.loadHTMLString(Self.page(svg), baseURL: nil)
    }

    /// The page holding the SVG, with a policy that allows no network and no script.
    ///
    /// - Parameter svg: The SVG.
    /// - Returns: The HTML.
    static func page(_ svg: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:">
        <style>
        /* Pele's light theme on a white card, in light and dark mode alike, so its colors stay readable. */
        :root { color-scheme: light; }
        body { margin: 12px; display: flex; justify-content: center; background: #ffffff; border-radius: 8px; }
        svg { max-width: 100%; height: auto; }
        </style></head><body>\(svg)</body></html>
        """
    }

    /// Refuses every navigation but Maser's own loads.
    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        /// The SVG last loaded.
        var loaded: String?
        /// Whether the next navigation is Maser's own `loadHTMLString`.
        var allowNextLoad = false

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            let allow = allowNextLoad && navigationAction.navigationType == .other
            allowNextLoad = false
            decisionHandler(allow ? .allow : .cancel)
        }
    }
}
