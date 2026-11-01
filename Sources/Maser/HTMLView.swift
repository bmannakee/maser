// A SwiftUI wrapper around `WKWebView` for showing app-generated HTML.
//
// The Overview tab uses it to show the conversation page that `ConversationHTML` renders. The page is static: its own
// scripts are off, links open in the browser, and the app's `maser-quote:` links are routed back to SwiftUI.

import AppKit
import SwiftUI
import WebKit

/// Displays a static HTML document.
///
/// The page's own JavaScript is off; clicked links open in the default browser, except `maser-quote:` links, whose item
/// ID goes to `onQuote`. Reloading new HTML keeps the scroll position. Changing `scrollToEnd` scrolls to the bottom
/// (after any reload in progress finishes).
struct HTMLView: NSViewRepresentable {
    let html: String
    /// The URL relative links and images in `html` resolve against.
    let baseURL: URL
    /// A token that scrolls the page to the bottom each time it changes.
    ///
    /// The value itself means nothing, and the initial value doesn't scroll.
    var scrollToEnd: UUID?
    /// Called with the conversation item ID from a clicked `maser-quote:` link.
    var onQuote: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Only page scripts; the app's own evaluateJavaScript calls still run.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        context.coordinator.lastScrollToEnd = scrollToEnd
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onQuote = onQuote
        if coordinator.loadedHTML != html {
            coordinator.load(html, baseURL: baseURL, in: view)
        }
        if coordinator.lastScrollToEnd != scrollToEnd {
            coordinator.lastScrollToEnd = scrollToEnd
            coordinator.scrollToEnd(in: view)
        }
    }

    /// Tracks what the web view has loaded and carries scroll requests across reloads.
    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        /// The HTML most recently sent to the web view, or `nil` before the first load.
        var loadedHTML: String?
        /// The `scrollToEnd` value already acted on, so each new value scrolls once.
        var lastScrollToEnd: UUID?
        var onQuote: (String) -> Void = { _ in }

        private var isLoading = false
        /// A scroll to the bottom requested mid-load, run when the load finishes.
        private var pendingScrollToEnd = false
        /// The reader's scroll position before a reload, restored when the new page finishes loading.
        private var restoreOffset: Double?

        /// Loads new HTML, keeping the reader's scroll position if a page is already showing.
        ///
        /// - Parameters:
        ///   - html: The document to show.
        ///   - baseURL: The URL relative links resolve against.
        ///   - view: The web view to load into.
        func load(_ html: String, baseURL: URL, in view: WKWebView) {
            let isFirstLoad = loadedHTML == nil
            loadedHTML = html
            isLoading = true
            if isFirstLoad {
                view.loadHTMLString(html, baseURL: baseURL)
                return
            }
            // Remember where the reader was, then reload. If newer HTML arrived while asking, that load wins.
            view.evaluateJavaScript("window.scrollY") { [weak self, weak view] offset, _ in
                MainActor.assumeIsolated {
                    guard let self, let view, self.loadedHTML == html else { return }
                    self.restoreOffset = offset as? Double
                    view.loadHTMLString(html, baseURL: baseURL)
                }
            }
        }

        /// Scrolls to the bottom of the page now, or once the load in progress finishes.
        func scrollToEnd(in view: WKWebView) {
            if isLoading {
                pendingScrollToEnd = true
            } else {
                view.evaluateJavaScript("window.scrollTo(0, document.documentElement.scrollHeight)")
            }
        }

        // A pending scroll to the bottom takes precedence over restoring the old position.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading = false
            if pendingScrollToEnd {
                pendingScrollToEnd = false
                restoreOffset = nil
                scrollToEnd(in: webView)
            } else if let offset = restoreOffset {
                restoreOffset = nil
                webView.evaluateJavaScript("window.scrollTo(0, \(offset))")
            }
        }

        // Keeps the web view on the app's page: clicked links never navigate it. Other navigations, such as
        // `loadHTMLString`, are allowed.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            if url.scheme == ConversationHTML.quoteScheme {
                // The ID is everything after `maser-quote:`, which WebKit may have percent-encoded.
                let id = url.absoluteString.dropFirst(ConversationHTML.quoteScheme.count + 1)
                onQuote(String(id).removingPercentEncoding ?? String(id))
            } else {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
