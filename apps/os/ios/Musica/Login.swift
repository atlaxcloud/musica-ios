// Musica: the one-time login. The manager.atlax.cloud page in a web view on
// the persistent data store: Atlax ID signs in there as on Safari, then the
// session cookie of manager.atlax.cloud is copied into Auth and every request
// and stream of the app carries it. Done once; it stays across launches.
import SwiftUI
import WebKit

struct LoginSheet: View {
    @EnvironmentObject private var store: MusicStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LoginWeb {
                Haptic.ok()
                store.signedIn()
                dismiss()
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Accedi con Atlax ID")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Chiudi") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct LoginWeb: UIViewRepresentable {
    let done: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    func makeUIView(context: Context) -> WKWebView {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = .default()
        let w = WKWebView(frame: .zero, configuration: c)
        w.navigationDelegate = context.coordinator
        w.uiDelegate = context.coordinator
        w.isOpaque = false
        w.backgroundColor = .black
        w.allowsBackForwardNavigationGestures = true
        // Cookies we already hold go in first, so a still-valid session skips the form.
        let jar = c.websiteDataStore.httpCookieStore
        let group = DispatchGroup()
        for ck in Auth.cookies {
            group.enter()
            jar.setCookie(ck) { group.leave() }
        }
        group.notify(queue: .main) {
            w.load(URLRequest(url: MusicAPI.base.appendingPathComponent("musica")))
        }
        return w
    }

    func updateUIView(_ w: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let done: () -> Void
        private var finished = false

        init(done: @escaping () -> Void) { self.done = done }

        /// Every page that lands back on manager.atlax.cloud: take its cookies and
        /// ask the API; a yes means the login is through.
        func webView(_ w: WKWebView, didFinish navigation: WKNavigation!) {
            guard !finished, w.url?.host == MusicAPI.host else { return }
            Task { @MainActor in
                await Auth.fromWeb()
                guard !self.finished, Auth.signedIn else { return }
                do {
                    _ = try await MusicAPI.json(MusicAPI.request("/api/musica"))
                    self.finished = true
                    self.done()
                } catch {}
            }
        }

        /// Pop-ups of the login (target=_blank, window.open) open in the same view.
        func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if a.targetFrame == nil { w.load(a.request) }
            return nil
        }
    }
}
