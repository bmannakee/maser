import Foundation
import MaserCore

/// Renders a PR's description and discussion as one HTML page, using GitHub's own rendered bodies.
enum ConversationHTML {
    static func render(_ overview: PullRequestOverview) -> String {
        var items = [article(
            id: "description",
            quotable: !overview.body.isEmpty,
            header: "<b>\(escape(overview.author))</b> opened \(time(overview.createdAt))",
            bodyHTML: overview.bodyHTML.isEmpty ? #"<p class="empty">No description provided.</p>"# : overview.bodyHTML,
            url: overview.url,
            extraClass: "description"
        )]
        for item in overview.timeline {
            let header: String
            switch item.kind {
            case .comment:
                header = "<b>\(escape(item.author))</b> commented \(time(item.date))"
            case let .review(state):
                header = "\(badge(state)) <b>\(escape(item.author))</b> \(verb(state)) \(time(item.date))"
            }
            items.append(article(id: item.id, quotable: !item.body.isEmpty, header: header,
                                 bodyHTML: item.bodyHTML, url: item.url, extraClass: nil))
        }
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><style>\(css)</style></head>
        <body>\(items.joined(separator: "\n"))</body></html>
        """
    }

    /// Links with this scheme are handled by the app (see `HTMLView`) rather than opened in the browser.
    static let quoteScheme = "maser-quote"

    private static func article(id: String, quotable: Bool, header: String, bodyHTML: String, url: URL, extraClass: String?) -> String {
        let classes = ["item", extraClass, bodyHTML.isEmpty ? "compact" : nil].compactMap(\.self).joined(separator: " ")
        let body = bodyHTML.isEmpty ? "" : #"<div class="markdown-body">\#(bodyHTML)</div>"#
        let quote = quotable ? #"<a href="\#(quoteScheme):\#(escape(id))" title="Quote this in your comment">Quote reply</a>"# : ""
        return """
        <article class="\(classes)">
        <header>\(header)<span class="actions">\(quote)<a href="\(escape(url.absoluteString))" title="Open on GitHub">↗</a></span></header>
        \(body)
        </article>
        """
    }

    private static func badge(_ state: Review.State) -> String {
        switch state {
        case .approved: #"<span class="badge approved">Approved</span>"#
        case .changesRequested: #"<span class="badge changes">Changes requested</span>"#
        case .commented: #"<span class="badge commented">Reviewed</span>"#
        case .dismissed: #"<span class="badge dismissed">Dismissed</span>"#
        }
    }

    private static func verb(_ state: Review.State) -> String {
        switch state {
        case .approved: "approved"
        case .changesRequested: "requested changes"
        case .commented: "reviewed"
        case .dismissed: "reviewed (dismissed)"
        }
    }

    private static func time(_ date: Date) -> String {
        let relative = date.formatted(.relative(presentation: .named, unitsStyle: .wide))
        let absolute = date.formatted(date: .abbreviated, time: .shortened)
        return #"<time title="\#(escape(absolute))">\#(escape(relative))</time>"#
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let css = """
    :root {
      color-scheme: light dark;
      --fg: #1f2328; --muted: #59636e; --border: #d1d9e0; --subtle: #f6f8fa;
      --link: #0969da; --green: #1a7f37; --red: #d1242f; --gray: #6e7781;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --fg: #f0f6fc; --muted: #9198a1; --border: #3d444d; --subtle: #151b23;
        --link: #4493f8; --green: #238636; --red: #da3633; --gray: #656c76;
      }
    }
    body { font: 13px/1.5 -apple-system, system-ui, sans-serif; color: var(--fg); margin: 0; padding: 16px 20px 48px; }
    .item { border: 1px solid var(--border); border-radius: 8px; margin: 0 0 16px; overflow: hidden; }
    .item > header { display: flex; align-items: center; gap: 4px; background: var(--subtle); color: var(--muted);
      padding: 7px 12px; border-bottom: 1px solid var(--border); }
    .item.compact > header { border-bottom: none; }
    .item > header b { color: var(--fg); }
    .actions { margin-left: auto; display: flex; gap: 12px; }
    .actions a { text-decoration: none; color: var(--muted); }
    .actions a:hover { color: var(--link); }
    .badge { font-size: 11px; font-weight: 600; color: white; border-radius: 999px; padding: 1px 8px; margin-right: 4px; }
    .badge.approved { background: var(--green); }
    .badge.changes { background: var(--red); }
    .badge.commented, .badge.dismissed { background: var(--gray); }
    .markdown-body { padding: 12px 16px; overflow-wrap: anywhere; }
    .markdown-body > :first-child { margin-top: 0; }
    .markdown-body > :last-child { margin-bottom: 0; }
    .empty { color: var(--muted); font-style: italic; }
    a { color: var(--link); }
    h1, h2 { border-bottom: 1px solid var(--border); padding-bottom: .3em; }
    h1 { font-size: 1.6em; } h2 { font-size: 1.35em; } h3 { font-size: 1.15em; } h4 { font-size: 1em; }
    code, pre { font: 12px ui-monospace, "SF Mono", Menlo, monospace; }
    code { background: var(--subtle); padding: .15em .35em; border-radius: 4px; }
    pre { background: var(--subtle); padding: 12px; border-radius: 6px; overflow: auto; }
    pre code { background: none; padding: 0; }
    blockquote { margin: 0 0 1em; padding: 0 1em; color: var(--muted); border-left: .25em solid var(--border); }
    table { border-collapse: collapse; display: block; overflow: auto; }
    th, td { border: 1px solid var(--border); padding: 5px 12px; }
    tr:nth-child(2n) { background: var(--subtle); }
    img { max-width: 100%; }
    ul.contains-task-list { list-style: none; padding-left: 1.2em; }
    hr { border: none; border-top: 1px solid var(--border); }
    details > summary { cursor: pointer; }
    """
}
