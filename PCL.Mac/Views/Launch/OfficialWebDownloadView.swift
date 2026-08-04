//
//  OfficialWebDownloadView.swift
//  PCL.Mac
//

import SwiftUI
import WebKit

/// A bounded queue of CurseForge pages. It remains user-driven by default;
/// an explicitly enabled accessibility mode can open the exact official file
/// route already bound to each queued item.
struct OfficialWebDownloadView: View {
    @ObservedObject var coordinator: OfficialWebDownloadCoordinator
    @State private var selection: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if coordinator.activeItems.isEmpty {
                ProgressView("正在准备官方网页下载…")
                    .frame(minWidth: 760, minHeight: 520)
            } else {
                TabView(selection: $selection) {
                    ForEach(coordinator.activeItems) { item in
                        OfficialWebDownloadTab(item: item, coordinator: coordinator)
                            .tag(Optional(item.id))
                    }
                }
                .tabViewStyle(.automatic)
                .frame(minWidth: 760, minHeight: 520)
            }
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 640)
        .onAppear {
            selection = coordinator.activeItems.first?.id
        }
        .onChange(of: coordinator.activeItems.map(\.id)) { _, itemIDs in
            if selection == nil || !itemIDs.contains(selection ?? "") {
                selection = itemIDs.first
            }
        }
        .onDisappear {
            coordinator.sheetDismissed()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "globe")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text("在 CurseForge 官方页面确认下载")
                    .font(.headline)
                Text(coordinator.browserAutomationEnabled
                    ? "无障碍自动化已开启：将自动打开已验证文件的官方下载页。文件仍会校验后再归位。"
                    : "请在下方官方页面自行点击下载。PCL.Mac 会自动校验文件、放入实例并继续导入。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("已完成 \(coordinator.completedCount) / \(coordinator.totalCount)")
                    .font(.subheadline.weight(.medium))
                Text("待打开 \(coordinator.pendingCount) 项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("关闭后会保留已完成文件，可在导入页继续。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("稍后继续") {
                coordinator.pause()
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
    }
}

private struct OfficialWebDownloadTab: View {
    let item: OfficialWebDownloadActiveItem
    @ObservedObject var coordinator: OfficialWebDownloadCoordinator

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: item.state == .downloading ? "arrow.down.circle.fill" : "doc.zipper")
                    .foregroundStyle(Color.accentColor)
                Text(item.group.displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text(item.state.description)
                    .font(.caption)
                    .foregroundStyle(item.state.isFailed ? Color.red : Color.secondary)
                if item.state.isFailed {
                    Button("重新加载") {
                        coordinator.retry(groupID: item.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            Divider()
            OfficialWebDownloadWebView(
                pageURL: item.group.pageURL,
                browserAutomationDownloadURL: coordinator.browserAutomationEnabled
                    ? OfficialWebDownloadBrowserAutomation.downloadURL(for: item.group)
                    : nil,
                groupID: item.id,
                reloadID: item.reloadID,
                coordinator: coordinator
            )
            .id(item.reloadID)
        }
    }
}

private struct OfficialWebDownloadWebView: NSViewRepresentable {
    let pageURL: URL
    let browserAutomationDownloadURL: URL?
    let groupID: String
    let reloadID: UUID
    @ObservedObject var coordinator: OfficialWebDownloadCoordinator

    func makeCoordinator() -> Delegate {
        Delegate(
            groupID: groupID,
            expectedProjectPageURL: pageURL,
            browserAutomationDownloadURL: browserAutomationDownloadURL,
            reloadID: reloadID,
            coordinator: coordinator
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Persistent storage avoids repeatedly asking users to log in to the
        // official page after app restarts. No script is injected into it.
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        if browserAutomationDownloadURL != nil {
            context.coordinator.startBrowserAutomation(in: webView)
        } else {
            webView.load(URLRequest(url: pageURL, cachePolicy: .reloadIgnoringLocalCacheData))
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    /// WebKit calls this on its UI actor. The delegate never injects script or
    /// follows arbitrary page controls; accessibility mode has one exact,
    /// prevalidated official route for the current queue item.
    @MainActor
    final class Delegate: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        private let groupID: String
        private let expectedProjectPageURL: URL
        private let browserAutomationDownloadURL: URL?
        private let reloadID: UUID
        private weak var coordinator: OfficialWebDownloadCoordinator?
        private var activeDownload: WKDownload?
        private var attempt: OfficialWebDownloadAttempt?
        private var userDownloadAuthorization: OfficialWebDownloadUserAuthorization?
        private var browserAutomationAuthorization: OfficialWebDownloadBrowserAutomationAuthorization?
        private var pendingDownloadSourceURL: URL?

        init(
            groupID: String,
            expectedProjectPageURL: URL,
            browserAutomationDownloadURL: URL?,
            reloadID: UUID,
            coordinator: OfficialWebDownloadCoordinator
        ) {
            self.groupID = groupID
            self.expectedProjectPageURL = expectedProjectPageURL
            self.browserAutomationDownloadURL = browserAutomationDownloadURL
            self.reloadID = reloadID
            self.coordinator = coordinator
        }

        func startBrowserAutomation(in webView: WKWebView) {
            guard let browserAutomationDownloadURL else {
                webView.load(URLRequest(url: expectedProjectPageURL, cachePolicy: .reloadIgnoringLocalCacheData))
                return
            }
            browserAutomationAuthorization = .init(
                projectPageURL: expectedProjectPageURL,
                downloadURL: browserAutomationDownloadURL,
                issuedAtUptime: ProcessInfo.processInfo.systemUptime
            )
            pendingDownloadSourceURL = expectedProjectPageURL
            coordinator?.browserAutomationStarted(for: groupID, reloadID: reloadID)
            webView.load(URLRequest(url: browserAutomationDownloadURL, cachePolicy: .reloadIgnoringLocalCacheData))
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let sourceURL = navigationAction.sourceFrame.request.url
            let sourceIsExpectedProject = sourceURL.map {
                CurseForgeURLPolicy.isSameOfficialProjectPage($0, as: expectedProjectPageURL)
            } == true
            let isExplicitProjectLink = navigationAction.navigationType == .linkActivated
                && sourceIsExpectedProject
            if isExplicitProjectLink, let sourceURL {
                userDownloadAuthorization = .init(
                    projectPageURL: sourceURL,
                    originalRequestURL: navigationAction.request.url,
                    issuedAtUptime: ProcessInfo.processInfo.systemUptime
                )
                pendingDownloadSourceURL = sourceURL
            } else if navigationAction.navigationType == .linkActivated {
                userDownloadAuthorization = nil
                pendingDownloadSourceURL = nil
            }
            guard #unavailable(macOS 15.2) else {
                if !isExplicitProjectLink, sourceIsExpectedProject {
                    pendingDownloadSourceURL = sourceURL
                }
                decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
                return
            }

            if !isExplicitProjectLink, navigationAction.navigationType != .other {
                userDownloadAuthorization = nil
                pendingDownloadSourceURL = nil
            }
            if navigationAction.shouldPerformDownload {
                let hasManualAuthorization = userDownloadAuthorization?.isValid(for: expectedProjectPageURL) == true
                let hasBrowserAutomationAuthorization = browserAutomationAuthorization?.isValid(for: expectedProjectPageURL) == true
                guard hasManualAuthorization || hasBrowserAutomationAuthorization else {
                    coordinator?.pageFailed(
                        for: groupID,
                        reloadID: reloadID,
                        error: OfficialWebDownloadError.downloadFailed("此 macOS 版本无法确认下载来自当前官方项目页。")
                    )
                    decisionHandler(.cancel)
                    return
                }
                decisionHandler(.download)
            } else {
                decisionHandler(.allow)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            if navigationResponse.canShowMIMEType {
                pendingDownloadSourceURL = nil
                if let responseURL = navigationResponse.response.url,
                   !CurseForgeURLPolicy.isSameOfficialProjectPage(responseURL, as: expectedProjectPageURL) {
                    userDownloadAuthorization = nil
                }
            }
            decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            configure(download, in: webView, sourceURL: nil)
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            configure(download, in: webView, sourceURL: navigationAction.sourceFrame.request.url)
        }

        private func configure(_ download: WKDownload, in webView: WKWebView, sourceURL: URL?) {
            let initiatingSourceURL = sourceURL ?? pendingDownloadSourceURL
            pendingDownloadSourceURL = nil
            let recentUserAuthorization = userDownloadAuthorization.flatMap { authorization in
                authorization.isValid(for: expectedProjectPageURL) ? authorization : nil
            }
            let recentBrowserAutomationAuthorization = browserAutomationAuthorization.flatMap { authorization in
                authorization.isValid(for: expectedProjectPageURL) ? authorization : nil
            }
            guard download.webView === webView else {
                download.cancel { _ in }
                coordinator?.pageFailed(
                    for: groupID,
                    reloadID: reloadID,
                    error: OfficialWebDownloadError.downloadFailed("下载必须由当前 CurseForge 官方项目页发起。")
                )
                return
            }
            if #available(macOS 15.2, *) {
                let sourceIsExpectedProject = initiatingSourceURL.map {
                    CurseForgeURLPolicy.isSameOfficialProjectPage($0, as: expectedProjectPageURL)
                } == true
                guard sourceIsExpectedProject
                    || recentUserAuthorization != nil
                    || recentBrowserAutomationAuthorization != nil else {
                    download.cancel { _ in }
                    coordinator?.pageFailed(
                        for: groupID,
                        reloadID: reloadID,
                        error: OfficialWebDownloadError.downloadFailed("下载必须由当前 CurseForge 官方项目页发起。")
                    )
                    return
                }
                guard download.isUserInitiated
                    || recentUserAuthorization != nil
                    || recentBrowserAutomationAuthorization != nil else {
                    download.cancel { _ in }
                    coordinator?.pageFailed(
                        for: groupID,
                        reloadID: reloadID,
                        error: OfficialWebDownloadError.downloadFailed("只接受用户在官方页面手动触发的下载。")
                    )
                    return
                }
            } else {
                guard recentUserAuthorization != nil || recentBrowserAutomationAuthorization != nil else {
                    download.cancel { _ in }
                    coordinator?.pageFailed(
                        for: groupID,
                        reloadID: reloadID,
                        error: OfficialWebDownloadError.downloadFailed("无法确认该下载由当前官方项目页的手动链接触发。")
                    )
                    return
                }
            }
            // One manual click or one accessibility automation run authorizes
            // at most one WebKit download attempt. The expected SHA-1 remains
            // the final binding to the queued file.
            userDownloadAuthorization = nil
            browserAutomationAuthorization = nil
            guard let coordinator,
                  let attempt = coordinator.stagingDestination(for: groupID, download: download) else {
                download.cancel { _ in }
                return
            }
            self.activeDownload = download
            self.attempt = attempt
            download.delegate = self
            coordinator.downloadStarted(for: groupID, attemptID: attempt.id)
        }

        func download(
            _ download: WKDownload,
            decideDestinationUsing response: URLResponse,
            suggestedFilename: String,
            completionHandler: @escaping (URL?) -> Void
        ) {
            guard activeDownload === download, let attempt else {
                completionHandler(nil)
                return
            }
            completionHandler(attempt.stagingURL)
        }

        func downloadDidFinish(_ download: WKDownload) {
            guard activeDownload === download, let activeAttempt = attempt else { return }
            coordinator?.completeDownload(
                for: groupID,
                attemptID: activeAttempt.id,
                stagedFile: activeAttempt.stagingURL
            )
            self.activeDownload = nil
            self.attempt = nil
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            guard activeDownload === download, let activeAttempt = attempt else { return }
            coordinator?.downloadFailed(for: groupID, attemptID: activeAttempt.id, error: error)
            activeDownload = nil
            attempt = nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            pendingDownloadSourceURL = nil
            userDownloadAuthorization = nil
            browserAutomationAuthorization = nil
            coordinator?.pageFailed(for: groupID, reloadID: reloadID, error: error)
        }
    }
}
