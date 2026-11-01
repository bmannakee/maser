import AppKit
import SwiftUI
import WebKit

/// Displays a static HTML document. The page's own JavaScript is off; clicked links open in the
/// default browser, except `maser-quote:` links, which go to `onQuote`.
///
/// Reloading new HTML keeps the scroll position. Changing `scrollToEnd` scrolls to the bottom
/// (after any reload in progress finishes).
struct HTMLView: NSViewRepresentable {
    let html: String
    let baseURL: URL
    var scrollToEnd: UUID?
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

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedHTML: String?
        var lastScrollToEnd: UUID?
        var onQuote: (String) -> Void = { _ in }

        private var isLoading = false
        private var pendingScrollToEnd = false
        private var restoreOffset: Double?

        func load(_ html: String, baseURL: URL, in view: WKWebView) {
            let isFirstLoad = loadedHTML == nil
            loadedHTML = html
            isLoading = true
            if isFirstLoad {
                view.loadHTMLString(html, baseURL: baseURL)
                return
            }
            // Remember where the reader was, then reload.
            view.evaluateJavaScript("window.scrollY") { [weak self, weak view] offset, _ in
                MainActor.assumeIsolated {
                    guard let self, let view, self.loadedHTML == html else { return }
                    self.restoreOffset = offset as? Double
                    view.loadHTMLString(html, baseURL: baseURL)
                }
            }
        }

        func scrollToEnd(in view: WKWebView) {
            if isLoading {
                pendingScrollToEnd = true
            } else {
                view.evaluateJavaScript("window.scrollTo(0, document.documentElement.scrollHeight)")
            }
        }

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
                let id = url.absoluteString.dropFirst(ConversationHTML.quoteScheme.count + 1)
                onQuote(String(id).removingPercentEncoding ?? String(id))
            } else {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
