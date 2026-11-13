import AppKit
import AuthenticationServices
import Foundation

/// The system browser session for OAuth. `ASWebAuthenticationSession` needs a
/// window to present from; this is the only part of the MCP client that is
/// AppKit.
@MainActor
final class MCPOAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = MCPOAuthPresenter()

    private var session: ASWebAuthenticationSession?

    func authorize(_ url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callback, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let callback {
                    continuation.resume(returning: callback)
                } else {
                    continuation.resume(throwing: MCPClientError.transport(String(localized: "Sign-in was cancelled.")))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                continuation.resume(throwing: MCPClientError.transport(String(localized: "Could not open the sign-in page.")))
            }
        }
    }

    func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSWindow()
    }
}
