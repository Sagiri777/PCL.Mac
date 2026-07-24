//
//  BrowserLoginController.swift
//  PCL.Mac
//
//  Pops a NSWindow containing a WKWebView for login.live.com OAuth.
//

import Foundation

@MainActor
final class BrowserLoginController: ObservableObject {
    static let shared = BrowserLoginController()

    @Published var isPresented = false
    var authorizeURL: URL?

    private var continuation: CheckedContinuation<String, Error>?

    func present(url: URL) async throws -> String {
        self.authorizeURL = url
        self.isPresented = true
        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
        }
    }

    func complete(with code: String) {
        guard let cont = continuation else { return }
        continuation = nil
        isPresented = false
        authorizeURL = nil
        cont.resume(returning: code)
    }

    func fail(_ error: Error) {
        guard let cont = continuation else { return }
        continuation = nil
        isPresented = false
        authorizeURL = nil
        cont.resume(throwing: error)
    }
}
