import AuthenticationServices
import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Shows a web sign-in (Google, through Supabase) in the system sign-in sheet and returns the
/// URL it ends on.
///
/// supabase-swift has its own version of this, but its completion closure inherits the main
/// actor while ASWebAuthenticationSession calls it on a background queue, so Swift's runtime
/// isolation check stopped the app (EXC_BREAKPOINT in signInWithOAuth, seen 2026-11-10 on
/// macOS 27). Here the completion closure is made outside any actor and only resumes a
/// continuation.
enum WebSignIn {
    @MainActor private static var running: (session: ASWebAuthenticationSession, presenter: Presenter)?

    @MainActor
    static func run(_ url: URL, callbackScheme: String) async throws -> URL {
        let presenter = Presenter()
        return try await withCheckedThrowingContinuation { continuation in
            let session = makeSession(url, callbackScheme: callbackScheme, continuation: continuation)
            session.presentationContextProvider = presenter
            running = (session, presenter)
            if !session.start() {
                running = nil
                continuation.resume(throwing: ASWebAuthenticationSessionError(.presentationContextInvalid))
            }
        }
    }

    /// Not on any actor, so ASWebAuthenticationSession may call the closure from any queue.
    private nonisolated static func makeSession(
        _ url: URL, callbackScheme: String, continuation: CheckedContinuation<URL, Error>
    ) -> ASWebAuthenticationSession {
        ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callback, error in
            Task { @MainActor in running = nil }
            if let callback {
                continuation.resume(returning: callback)
            } else {
                continuation.resume(throwing: error ?? ASWebAuthenticationSessionError(.canceledLogin))
            }
        }
    }

    private final class Presenter: NSObject, ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            MainActor.assumeIsolated {
                #if canImport(UIKit)
                let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                return scenes.flatMap(\.windows).first(where: \.isKeyWindow)
                    ?? scenes.first.map { UIWindow(windowScene: $0) }
                    ?? ASPresentationAnchor()
                #else
                return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
                #endif
            }
        }
    }
}
