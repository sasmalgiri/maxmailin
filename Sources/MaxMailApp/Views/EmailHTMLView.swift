import SwiftUI
import WebKit
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Safely renders an HTML email body in a WKWebView.
///
/// Hardening:
/// - JavaScript is disabled. Email is not an app delivery channel.
/// - All non-initial navigations are denied, so a stray <a href> can't
///   silently load a tracking pixel or remote endpoint.
/// - Loaded with `baseURL: nil`, so relative URLs and file:// access
///   cannot be used to read local resources.
struct EmailHTMLView: View {
    let html: String

    var body: some View {
        WebViewRepresentable(html: html)
            .frame(minHeight: 280)
    }
}

private struct WebViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    fileprivate func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = false
        config.defaultWebpagePreferences = prefs
        let view = WKWebView(frame: .zero, configuration: config)
        #if canImport(AppKit)
        view.setValue(false, forKey: "drawsBackground")
        #endif
        return view
    }

    fileprivate func load(_ webView: WKWebView, context: Context) {
        webView.navigationDelegate = context.coordinator
        context.coordinator.allowOneLoad()
        let wrapped = Self.wrap(html: html)
        webView.loadHTMLString(wrapped, baseURL: nil)
    }

    private static func wrap(html: String) -> String {
        // Wrap with a minimal stylesheet so the body fits the surrounding pane.
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
        <style>
          html, body { margin: 0; padding: 12px; font: -apple-system-body; line-height: 1.45; color: #1a1a1a; background: transparent; }
          @media (prefers-color-scheme: dark) { html, body { color: #f5f5f5; } a { color: #4ea1ff; } }
          img { max-width: 100%; height: auto; }
          a   { color: #1e6fdb; text-decoration: none; }
          pre, code { font-family: ui-monospace, Menlo, Consolas, monospace; background: rgba(127,127,127,0.1); padding: 1px 4px; border-radius: 3px; }
          blockquote { border-left: 3px solid #999; margin: 0 0 0 4px; padding: 2px 10px; color: #555; }
        </style></head>
        <body>\(html)</body></html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var firstLoadConsumed = false
        func allowOneLoad() { firstLoadConsumed = false }
        func webView(_ webView: WKWebView,
                     decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if !firstLoadConsumed {
                firstLoadConsumed = true
                decisionHandler(.allow)
            } else {
                // Open external links in the user's default browser; never
                // let the embedded webview navigate to remote URLs itself.
                if action.navigationType == .linkActivated,
                   let url = action.request.url {
                    open(externalURL: url)
                }
                decisionHandler(.cancel)
            }
        }

        private func open(externalURL url: URL) {
            #if canImport(AppKit)
            NSWorkspace.shared.open(url)
            #elseif canImport(UIKit)
            UIApplication.shared.open(url)
            #endif
        }
    }
}

#if canImport(AppKit)
extension WebViewRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView() }
    func updateNSView(_ webView: WKWebView, context: Context) { load(webView, context: context) }
}
#elseif canImport(UIKit)
extension WebViewRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let v = makeWebView()
        v.isOpaque = false
        v.backgroundColor = .clear
        v.scrollView.backgroundColor = .clear
        return v
    }
    func updateUIView(_ webView: WKWebView, context: Context) { load(webView, context: context) }
}
#endif
