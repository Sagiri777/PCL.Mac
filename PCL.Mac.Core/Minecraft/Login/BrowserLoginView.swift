//
//  BrowserLoginView.swift
//  PCL.Mac
//
//  NSWindow-backed WKWebView for login.live.com OAuth Authorization Code flow.
//  on macOS 14+ WKWebView 已经原生支持 WebAuthn / 通行密钥（Touch ID / 安全密钥）。
//

import SwiftUI
import WebKit

struct BrowserLoginView: View {
    @ObservedObject private var controller = BrowserLoginController.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("登录 Microsoft 账号")
                    .font(.headline)
                Spacer()
                Button("取消") {
                    controller.fail(OAuthCallbackError.userCancelled)
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if let url = controller.authorizeURL {
                MsLoginWebView(url: url) { result in
                    DispatchQueue.main.async {
                        switch result {
                        case .success(let code):
                            controller.complete(with: code)
                        case .failure(let error):
                            controller.fail(error)
                        }
                    }
                }
            } else {
                ProgressView("正在加载…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 520, minHeight: 620)
    }
}

struct MsLoginWebView: NSViewRepresentable {
    let url: URL
    let onResult: (Result<String, Error>) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        // 允许通行密钥 / WebAuthn 所需的 JS API
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        // 让系统弹出 Touch ID / 安全密钥 UI（WebAuthn）
        config.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let onResult: (Result<String, Error>) -> Void
        private var hasCompleted = false

        init(onResult: @escaping (Result<String, Error>) -> Void) {
            self.onResult = onResult
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            let urlString = url.absoluteString

            // login.microsoftonline.com 鉴权成功后 redirect 到 littleskin.cn/user/premium/callback?code=xxx
            if urlString.contains("littleskin.cn/user/premium/callback") {
                let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
                let items = comps?.queryItems ?? []

                if let errCode = items.first(where: { $0.name == "error" })?.value, !errCode.isEmpty {
                    let errDesc = items.first(where: { $0.name == "error_description" })?.value ?? ""
                    hasCompleted = true
                    decisionHandler(.cancel)
                    onResult(.failure(OAuthCallbackError.serverError("\(errCode): \(errDesc)")))
                    return
                }

                if let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty {
                    hasCompleted = true
                    decisionHandler(.cancel)
                    onResult(.success(code))
                    return
                }
            }

            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            guard !hasCompleted else { return }
            hasCompleted = true
            onResult(.failure(error))
        }
    }
}
