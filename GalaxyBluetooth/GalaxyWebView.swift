import SwiftUI
import WebKit

struct GalaxyBarItem: Decodable, Identifiable, Equatable {
    let id: String
    let label: String
    let selected: Bool
    let disabled: Bool
    var icon: String { Self.icon(for: id) }
    static func icon(for id: String) -> String {
        switch id {
        case "home": return "house.fill"
        case "toggles": return "switch.2"
        case "tools": return "wrench.and.screwdriver"
        case "routes": return "film.stack"
        case "back": return "chevron.backward"
        case "search": return "magnifyingglass"
        case "theme": return "circle.lefthalf.filled"
        case "menu": return "list.bullet"
        default: return "rectangle.portrait.and.arrow.right"
        }
    }
    var primary: Bool { ["home", "toggles", "tools", "routes"].contains(id) }
}

enum GalaxyToolbar {
    static let orderKey = "galaxy.app.toolbarOrder"
    static let defaults = ["home", "toggles", "tools", "routes", "search", "theme", "menu"]
    static let labels = ["home": "Home", "toggles": "Toggles", "tools": "Tools", "routes": "Routes",
                         "search": "Search", "theme": "Theme", "menu": "Galaxy menu"]

    static func order(_ stored: String) -> [String] {
        var seen = Set<String>()
        return (stored.split(separator: ",").map(String.init) + defaults).filter {
            defaults.contains($0) && seen.insert($0).inserted
        }
    }

    static func visible(_ stored: String, items: [GalaxyBarItem]) -> [GalaxyBarItem] {
        Array(order(stored).compactMap { id in items.first { $0.id == id } }.prefix(4))
    }
}

struct StartupPage: Codable, Identifiable {
    let id: String
    let name: String
    static let primary = [Self(id: "/", name: "Home"), Self(id: "/settings", name: "Toggles"),
                          Self(id: "/tools", name: "Tools"), Self(id: "/recordings", name: "Routes")]
    static let cacheKey = "galaxy.app.startupCatalog"
    static var cached: [StartupPage] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let pages = try? JSONDecoder().decode([StartupPage].self, from: data) else { return primary }
        return pages
    }
    static func valid(_ id: String) -> Bool {
        id == "/" || (id.utf8.count <= 256 && id.range(of: #"^(/|toggle:|section:)[a-zA-Z0-9_-]+(/[a-zA-Z0-9_-]+)*$"#, options: .regularExpression) != nil)
    }
    static func url(_ base: URL, for id: String) -> URL {
        guard valid(id), var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
        if id.hasPrefix("/") { parts.fragment = id }
        else {
            parts.fragment = "/settings"
            parts.queryItems = (parts.queryItems ?? []) + [URLQueryItem(name: "startupPage", value: id)]
        }
        return parts.url ?? base
    }
}

struct GalaxyDownloadedFile: Identifiable {
    let id = UUID()
    let url: URL
}

@MainActor
final class GalaxyPageDiagnostics: ObservableObject {
    @Published fileprivate var downloadedFile: GalaxyDownloadedFile?
    @Published var downloadError: String?
    private var exportDirectory: URL?

    fileprivate func offerDownload(_ url: URL) {
        exportDirectory = url.deletingLastPathComponent()
        downloadedFile = GalaxyDownloadedFile(url: url)
        record("Download ready to save or share")
    }
    func cleanUpDownload() {
        if let directory = exportDirectory { try? FileManager.default.removeItem(at: directory) }
        exportDirectory = nil
    }
    func downloadFailed(_ error: Error) {
        let value = error as NSError
        record("Download failed: \(value.domain) \(value.code)")
        downloadError = "The file couldn’t be downloaded. Please try again."
    }

    var recover: ((Bool) -> Void)?
    @Published var darkAppearance: Bool?
    @Published var landscapeEditor = false
    @Published var barItems: [GalaxyBarItem] = []
    @Published var deviceStatus = ""
    fileprivate weak var barWebView: WKWebView?
    var pendingStartupPage: String?
    func startupPages() async -> [StartupPage] {
        guard let web = barWebView, let value = try? await web.callAsyncJavaScript(
            "return await window.__galaxyStartupPages?.()", arguments: [:], in: nil, contentWorld: .page),
              let rows = value as? [[String: String]], !rows.isEmpty else { return StartupPage.cached }
        var pages = StartupPage.primary
        for row in rows {
            guard let id = row["id"], let name = row["name"], StartupPage.valid(id), !name.isEmpty,
                  !pages.contains(where: { $0.id == id }) else { continue }
            pages.append(StartupPage(id: id, name: name))
        }
        if let data = try? JSONEncoder().encode(pages) { UserDefaults.standard.set(data, forKey: StartupPage.cacheKey) }
        return pages
    }

    func takeStartupURL(_ base: URL) -> URL? {
        guard let id = pendingStartupPage else { return nil }
        pendingStartupPage = nil
        return StartupPage.url(base, for: id)
    }

    func activate(_ item: GalaxyBarItem) {
        guard barItems.contains(item), !item.disabled else { return }
        if item.id == "theme", let dark = darkAppearance {
            UserDefaults.standard.set((dark ? AppAppearance.light : AppAppearance.dark).rawValue, forKey: AppAppearance.key)
            return
        }
        barWebView?.callAsyncJavaScript("window.__galaxyBarSelect?.(id)", arguments: ["id": item.id],
                                        in: nil, in: .page, completionHandler: nil)
    }
    @Published var copied = false
    @Published var stalled = false
    @Published var mounted = false
    @Published var reloadID = UUID()
    private(set) var started = Date()
    private(set) var events: [String] = []
    private var deadline: Task<Void, Never>?

    func record(_ event: String) {
        events.append("\(ISO8601DateFormatter().string(from: Date())) \(event.prefix(300))")
        if events.count > 400 { events.removeFirst(events.count - 400) }
    }
    func begin() {
        deadline?.cancel()
        barItems = []
        deviceStatus = ""
        started = Date(); mounted = false; stalled = false; landscapeEditor = false
        record("Page loading")
        deadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 12_000_000_000) } catch { return }
            guard let self, !self.mounted else { return }
            self.record("No rendered Galaxy content after 12 seconds")
            self.stalled = true
        }
    }
    func rendered() {
        mounted = true; stalled = false; deadline?.cancel()
        record("Galaxy content rendered")
    }
    func fail(_ event: String) { record(event); mounted = false; stalled = true; deadline?.cancel() }
    func retry() { reloadID = UUID() }
    func report(server: LoopbackServer, connection: String) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        return """
        StarPilot BT Galaxy diagnostics
        \(ISO8601DateFormatter().string(from: Date()))
        App: \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))
        iOS: \(UIDevice.current.systemVersion)
        Connection: \(connection)
        Sentry diagnostics revision: 1 (event list, image transfer and rendering)
        Sentry phone alerts: enabled=\(SentryPush.shared.enabled); registered=\(SentryPush.shared.registered); status=\(SentryPush.shared.status)
        Galaxy content rendered: \(mounted)
        Page age: \(Int(Date().timeIntervalSince(started))) seconds
        \(server.diagnosticSummary)
        Recent page events:
        \(events.joined(separator: "\n"))
        Recent local requests (no headers, query values or bodies):
        \(server.recentRequests.joined(separator: "\n"))
        """
    }
}

struct GalaxyWebView: View {
    let url: URL
    let requestKey: String
    @ObservedObject var diagnostics: GalaxyPageDiagnostics
    @AppStorage("galaxy.app.followGalaxyLanguage") private var followGalaxyLanguage = true
    var isActive = true
    var expandedView = true
    var localWiFi = false
    var bluetooth = false
    let report: () -> String
    var body: some View {
        ZStack {
            GalaxyPage(url: url, requestKey: requestKey, diagnostics: diagnostics, isActive: isActive, expandedView: expandedView, localWiFi: localWiFi, bluetooth: bluetooth, followGalaxyLanguage: followGalaxyLanguage)
                .id(url.absoluteString + diagnostics.reloadID.uuidString)
            if diagnostics.stalled {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.bubble").font(.largeTitle).foregroundStyle(.purple)
                    Text("Galaxy hasn’t loaded").font(.title2.bold())
                    Text("Copy the report so we can find what failed, or try loading the page again.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button(diagnostics.copied ? "Report copied" : "Copy error report") {
                        UIPasteboard.general.string = report(); diagnostics.copied = true
                    }.buttonStyle(.borderedProminent).tint(.purple)
                    Button("Retry Galaxy") { diagnostics.copied = false; diagnostics.recover?(false) }.buttonStyle(.bordered)
                }.padding(28).frame(maxWidth: 420)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20)).padding(20)
            }
        }
        .sheet(item: $diagnostics.downloadedFile, onDismiss: diagnostics.cleanUpDownload) { file in
            GalaxyFileShareSheet(url: file.url) { diagnostics.downloadedFile = nil }
        }
        .alert("Couldn’t download file", isPresented: Binding(
            get: { diagnostics.downloadError != nil },
            set: { if !$0 { diagnostics.downloadError = nil } }
        )) {
            Button("OK", role: .cancel) { diagnostics.downloadError = nil }
        } message: { Text(diagnostics.downloadError ?? "") }
    }
}

struct GalaxyFileShareSheet: UIViewControllerRepresentable {
    let url: URL
    let finished: () -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            Task { @MainActor in finished() }
        }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct GalaxyPage: UIViewRepresentable {
    @ObservedObject private var push = SentryPush.shared
    let url: URL
    let requestKey: String

    let diagnostics: GalaxyPageDiagnostics
    let isActive: Bool
    let expandedView: Bool
    let localWiFi: Bool
    let bluetooth: Bool
    let followGalaxyLanguage: Bool
    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(origin: url, requestKey: requestKey, diagnostics: diagnostics)
        coordinator.expandedView = expandedView
        coordinator.isVisible = isActive
        coordinator.localWiFi = localWiFi
        return coordinator
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        diagnostics.begin()
        config.userContentController.add(context.coordinator, name: "galaxyDiagnostics")
        let script = """
        (() => {
          if (location.origin !== '\(url.scheme!)://\(url.host!):\(url.port!)') return;
          window.__galaxyNative = true;
          window.__galaxyPushState = \(push.stateJSON);
          window.StarPilotApp = Object.assign(window.StarPilotApp || {}, {
            sentryPush: () => JSON.stringify(window.__galaxyPushState),
            setSentryPush: enabled => window.webkit.messageHandlers.galaxyDiagnostics.postMessage({kind: 'sentryPush', enabled: !!enabled})
          });
          // Galaxy writes this preference when its own language changes.
          const originalSetItem = Storage.prototype.setItem;
          Storage.prototype.setItem = function(key, value) {
            originalSetItem.apply(this, arguments);
            if (this === window.localStorage && key === 'galaxy-language') {
              try { window.webkit.messageHandlers.galaxyDiagnostics.postMessage({kind: 'language', code: String(value)}); } catch (_) {}
            }
          };
          window.__galaxyBluetooth = \(bluetooth ? "true" : "false");
          const phoneAppearance = window.matchMedia('(prefers-color-scheme: dark)');
          const syncTheme = () => {
            const theme = phoneAppearance.matches ? 'dark' : 'light';
            localStorage.setItem('galaxy-preview-theme', theme);
            document.documentElement.dataset.theme = theme;
          };
          if (document.documentElement) syncTheme();
          else document.addEventListener('DOMContentLoaded', syncTheme, {once: true});
          document.addEventListener('click', event => {
            if (event.isTrusted && event.target.closest?.('.gx-theme-toggle')) {
              const dark = document.documentElement.dataset.theme !== 'dark';
              window.webkit.messageHandlers.galaxyDiagnostics.postMessage({kind:'chooseTheme', dark});
            }
          }, true);
          phoneAppearance.addEventListener('change', () => {
            const dark = phoneAppearance.matches;
            if ((document.documentElement.dataset.theme === 'dark') !== dark) {
              document.querySelector('.gx-theme-toggle')?.click();
            }
            syncTheme();
          });
          const reportTheme = () => {
            const theme = document.documentElement?.dataset.theme;
            if (theme !== 'dark' && theme !== 'light') return;
            try { window.webkit.messageHandlers.galaxyDiagnostics.postMessage({kind: 'theme', dark: theme === 'dark'}); } catch (_) {}
          };
          const watchTheme = () => {
            if (!document.documentElement) return;
            new MutationObserver(reportTheme).observe(document.documentElement, {attributes: true, attributeFilter: ['data-theme']});
            reportTheme();
          };
          if (document.documentElement) watchTheme();
          else document.addEventListener('DOMContentLoaded', watchTheme, {once: true});
          let nativeVisible = \(isActive ? "true" : "false");
          Object.defineProperty(document, 'visibilityState', {configurable: true, get: () => nativeVisible ? 'visible' : 'hidden'});
          Object.defineProperty(document, 'hidden', {configurable: true, get: () => !nativeVisible});
          window.__galaxySetVisible = visible => {
            if (nativeVisible === !!visible) return;
            nativeVisible = !!visible;
            document.dispatchEvent(new Event('visibilitychange'));
          };
          const emit = (kind, path = '', code = 0) => {
            try { window.webkit.messageHandlers.galaxyDiagnostics.postMessage({kind, path, code}); } catch (_) {}
          };
          // Keep this native presentation independent of downloaded Galaxy assets.
          // A portrait keyboard can make the web viewport report landscape.
          // Only use the two-column editor when there is room for both panels.
          const editorScreen = matchMedia('(min-width: 700px) and (orientation: landscape) and (max-height: 600px)');
          let editorFocused = false;
          const editorCSS = document.createElement('style');
          editorCSS.textContent = `
            \(DuoLayout.isEnabled ? """
            /* Blend only the decorative backdrop; never fade the Galaxy controls. */
            html, body { background: transparent !important; }
            /* Keep controls above the system home indicator when the page extends to the bottom edge. */
            .blur-nav { bottom: env(safe-area-inset-bottom, 0px) !important; }
            #galaxy-bg {
              mask-image: linear-gradient(to bottom, transparent, black 64px, black calc(100% - 48px), transparent),
                          linear-gradient(to right, black calc(100% - 96px), transparent);
              mask-composite: intersect;
            }
            @media (orientation: landscape) {
              html.native-galaxy-pill:not(.native-layout-editor) #galaxy-app .gx-app {
                background-image: linear-gradient(to left, var(--toolbar-edge), color-mix(in srgb, var(--toolbar-edge) 60%, transparent) 48px, transparent 148px) !important;
              }
            }

            """ : """
            /* Blend only the decorative backdrop; never fade the Galaxy controls. */
            :root { --native-galaxy-edge: rgb(2.6% 2.2% 5.8%); }
            :root[data-theme="light"] { --native-galaxy-edge: rgb(89.5% 85.5% 94.5%); }
            html, body { background: var(--native-galaxy-edge) !important; }
            /* Keep controls above the system home indicator when the page extends to the bottom edge. */
            .blur-nav { bottom: env(safe-area-inset-bottom, 0px) !important; }
            #galaxy-bg {
              -webkit-mask-image: linear-gradient(to bottom, transparent, black 100px, black calc(100% - 48px), transparent);
              mask-image: linear-gradient(to bottom, transparent, black 100px, black calc(100% - 48px), transparent);
            }

            """)

            /* Keep route actions in a scrollable area between the two navigation bars. */
            @media (max-width: 767px) {
              .gx-app:has(.gx-route-workspace) {
                height: 100dvh; min-height: 0;
              }
              .gx-app:has(.gx-route-workspace) > .gx-appbar { flex: none; }
              .gx-content:has(.gx-route-workspace) {
                min-height: 0; overflow-y: auto; padding-bottom: var(--sp-3);
              }
              .gx-app:has(.gx-route-workspace) > .blur-nav {
                position: relative; left: auto; bottom: auto !important; transform: none;
                flex: none; margin: 0 auto env(safe-area-inset-bottom, 0px);
              }
            }

            /* Blend the shell itself, including Galaxy versions without a #galaxy-bg canvas. */
            html.native-galaxy-pill { --toolbar-edge: rgb(2.6% 2.2% 5.8%); }
            html.native-galaxy-pill[data-theme="light"] { --toolbar-edge: rgb(89.5% 85.5% 94.5%); }
            html.native-galaxy-pill:not(.native-layout-editor) .gx-app {
              background-color: transparent !important;
              background-image: linear-gradient(to bottom, var(--toolbar-edge), color-mix(in srgb, var(--toolbar-edge) 85%, transparent) 22px,
                color-mix(in srgb, var(--toolbar-edge) 35%, transparent) 76px, transparent 148px) !important;
            }
            html.native-galaxy-pill { --bottomnav-height: 0px; --bottomnav-clearance: env(safe-area-inset-bottom, 0px); }
            html.native-galaxy-pill .gx-app > .blur-nav { display: none !important; }
            html.native-galaxy-pill:not(.native-layout-editor) .gx-app > .gx-appbar:not(:has(.gx-searchbox.open)) { display: none !important; }
            html.native-galaxy-pill:not(.native-layout-editor) .gx-appbar:has(.gx-searchbox.open) { padding-top: 0; }
            html.native-galaxy-pill .gx-appbar:has(.gx-searchbox.open) :is(.gx-appbar__back, .gx-appbar__home, .gx-appbar__right, .gx-appbar__menu, .gx-theme-toggle) { display: none !important; }
            html.native-galaxy-pill .gx-content { padding-bottom: max(var(--sp-3), env(safe-area-inset-bottom, 0px)) !important; }
            html.native-layout-editor .blur-nav,
            html.native-layout-editor .gx-appbar__pill,
            html.native-layout-editor .gx-appbar__menu,
            html.native-layout-editor .gx-layout > .gx-page-header { display: none !important; }
            html.native-layout-editor .gx-app { animation: none; }
            html.native-layout-editor .gx-appbar {
              position: fixed; inset: max(4px, env(safe-area-inset-top)) auto auto max(8px, env(safe-area-inset-left));
              width: 44px; padding: 0; margin: 0; z-index: 20;
            }
            html.native-layout-editor .gx-appbar__back { width: 44px; height: 44px; min-width: 44px; min-height: 44px; }
            html.native-layout-editor .gx-content {
              max-width: none; padding: max(4px, env(safe-area-inset-top)) max(8px, env(safe-area-inset-right)) max(8px, env(safe-area-inset-bottom)) max(8px, env(safe-area-inset-left));
            }
            html.native-layout-editor .gx-layout { --layout-sticky-top: max(4px, env(safe-area-inset-top)); display: grid; gap: 6px; }
            html.native-layout-editor .gx-layout__savebar {
              grid-row: 1; margin-left: 52px; padding: 0 4px 0 10px; min-height: 44px; gap: 4px;
            }
            html.native-layout-editor .gx-layout__savebar .gx-btn { min-height: 44px; padding-inline: 12px; }
            html.native-layout-editor .gx-layout__targets { grid-row: 2; margin: 0; gap: 8px; }
            html.native-layout-editor .gx-layout__targets .gx-btn { min-height: 44px; padding: 4px 12px; }
            html.native-layout-editor .gx-layout__workspace { gap: 8px; grid-template-columns: minmax(0, 1.35fr) minmax(260px, 1fr); }
            html.native-layout-editor .gx-layout__preview-card { padding: 4px; gap: 4px; }
            html.native-layout-editor .gx-layout__preview-card > p.gx-note:not([role]) { display: none; }
            html.native-layout-editor .gx-layout__preview-card .gx-layout__preview {
              width: auto; max-width: 100%; max-height: calc(100svh - 200px - env(safe-area-inset-top) - env(safe-area-inset-bottom)); margin-inline: auto;
            }
            html.native-layout-editor .gx-layout__inspector {
              padding: 8px; gap: 8px; max-height: calc(100svh - 124px - env(safe-area-inset-top) - env(safe-area-inset-bottom)); overflow: auto;
            }
            html.native-layout-editor .gx-layout__sections { margin: -8px -8px 0; padding: 4px; gap: 2px; top: -8px; }
            html.native-layout-editor .gx-layout__sections .gx-btn { min-height: 44px; padding: 4px 8px; white-space: nowrap; }
          `;
          const syncEditor = () => {
            const focused = editorScreen.matches && !!document.querySelector('.gx-layout');
            if (focused === editorFocused) return;
            editorFocused = focused;
            document.documentElement.classList.toggle('native-layout-editor', focused);
            try { window.webkit.messageHandlers.galaxyDiagnostics.postMessage({kind: 'editorFocus', active: focused}); } catch (_) {}
          };
          // BEGIN GALAXY PILL
          const primaryIcons = {'bi-house-fill':'home', 'bi-toggle-on':'toggles', 'bi-tools':'tools', 'bi-camera-reels':'routes'};
          const headerSelectors = {back:'.gx-appbar__back', search:'.gx-search-toggle', theme:'.gx-theme-toggle', menu:'.gx-appbar__menu', signout:'.gx-appbar__right > button'};
          let buttons = new Map();
          let lastBar = '';
          const syncBar = () => {
            const header = document.querySelector('.gx-app > .gx-appbar');
            const nav = document.querySelector('.gx-app > nav.blur-nav');
            const next = new Map();
            let compatible = !!header && !!nav;
            for (const button of nav?.querySelectorAll('button') || []) {
              const id = Object.keys(primaryIcons).find(icon => button.querySelector('.' + icon));
              if (!id || next.has(primaryIcons[id])) { compatible = false; break; }
              next.set(primaryIcons[id], button);
            }
            compatible &&= next.size === 4;
            if (compatible) {
              for (const [id, selector] of Object.entries(headerSelectors)) {
                const button = header.querySelector(selector);
                if (button) next.set(id, button);
              }
              const supported = new Set([...next.values(), header.querySelector('.gx-appbar__home')]);
              compatible = [...header.querySelectorAll('button, a[href], input, select')].every(el => supported.has(el) || el.matches('input.gx-appbar__search'));
            }
            buttons = compatible ? next : new Map();
            const items = [...buttons].map(([id, el]) => ({id, label:(el.getAttribute('aria-label') || el.textContent || id).trim(),
              selected:el.getAttribute('aria-current') === 'page' || el.classList.contains('active'),
              disabled:el.disabled || !!el.closest('[inert]')}));
            const device = header?.querySelector('.gx-appbar__right .gx-status-pill');
            const status = device?.getAttribute('aria-label') || device?.textContent.trim() || '';
            const payload = JSON.stringify({items,status});
            if (payload === lastBar) return;
            lastBar = payload;
            if (!compatible) document.documentElement.classList.remove('native-galaxy-pill');
            window.webkit.messageHandlers.galaxyDiagnostics.postMessage({kind:'bar',items,status});
          };
          window.__galaxyBarSelect = id => {
            const el = buttons.get(id);
            if (el?.isConnected && !el.disabled && !el.closest('[inert]')) el.click();
          };
          window.__galaxyBarReady = expanded => document.documentElement.classList.toggle('native-galaxy-pill', expanded && buttons.size > 0);
          const startBar = () => {
            if (window !== window.top) return;
            let queued = false;
            const schedule = () => {
              if (!queued) { queued = true; requestAnimationFrame(() => { queued = false; syncBar(); }); }
            };
            const controls = '.gx-appbar, nav.blur-nav';
            const touchesBar = change => {
              const target = change.target.nodeType === 1 ? change.target : change.target.parentElement;
              if (target?.closest(controls) || target?.matches('.gx-app')) return true;
              return [...change.addedNodes, ...change.removedNodes].some(node =>
                node.nodeType === 1 && (node.matches(controls) || node.querySelector(controls)));
            };
            new MutationObserver(changes => { if (changes.some(touchesBar)) schedule(); }).observe(document.body, {subtree:true, childList:true, characterData:true,
              attributes:true, attributeFilter:['class','aria-current','aria-label','aria-expanded','disabled','inert']});
            syncBar();
          };
          // END GALAXY PILL
          const startEditorPresentation = () => {
            document.head.appendChild(editorCSS);
            startBar();
            new MutationObserver(syncEditor).observe(document.body, {childList: true, subtree: true});
            editorScreen.addEventListener('change', syncEditor);
            syncEditor();
          };
          document.addEventListener('DOMContentLoaded', startEditorPresentation, {once: true});
          const pathOnly = value => {
            try { return new URL(value, location.href).pathname; } catch (_) { return ''; }
          };
          window.addEventListener('error', event => {
            if (event.target && event.target !== window) {
              emit('resource', pathOnly(event.target.src || event.target.href || ''));
            } else { emit('script', pathOnly(event.filename || ''), event.lineno || 0); }
          }, true);
          window.addEventListener('unhandledrejection', () => emit('promise'));
          let rendered = false;
          const checkContent = () => {
            const root = document.querySelector('#galaxy-app');
            if (root && !root.hasAttribute('v-cloak') && root.children.length && root.innerText.trim().length) {
              if (!rendered) { rendered = true; emit('rendered'); }
            } else if (rendered) { rendered = false; emit('blank'); }
          };
          window.addEventListener('DOMContentLoaded', () => {
            checkContent(); setInterval(checkContent, 1000);
          }, {once: true});
          const key = '\(requestKey)';
          const local = (u) => new URL(u, location.href).origin === location.origin;
          const originalFetch = window.fetch.bind(window);
          // Fixed stage labels and numeric measurements only; never response bodies or tokens.
          const sentryLog = (stage, values = {}) => {
            try { window.webkit.messageHandlers.galaxyDiagnostics.postMessage({kind: 'sentry', stage, ...values}); } catch (_) {}
          };
          window.fetch = (input, init = {}) => {
            const req = new Request(input, init);
            if (!local(req.url)) return originalFetch(req);
            const headers = new Headers(req.headers);
            headers.set('X-Galaxy-Local', key);
            const sentryEvents = new URL(req.url).pathname === '/api/sentry/events';
            const sentryStarted = Date.now();
            if (sentryEvents) sentryLog('events-start');
            return originalFetch(new Request(req, { headers })).then(async response => {
              if (sentryEvents) {
                sentryLog('events-http', {http: response.status, ms: Date.now() - sentryStarted});
                response.clone().json().then(data => {
                  if (!Array.isArray(data.events)) { sentryLog('events-invalid'); return; }
                  sentryLog('events-result', {count: data.events.length,
                    images: data.events.reduce((n, event) => n + (Array.isArray(event.images) ? event.images.length : 0), 0),
                    bytes: data.storageBytes, incomplete: data.scanIncomplete === true || data.storageIncomplete === true});
                }).catch(() => sentryLog('events-invalid'));
              }
              if (response.status === 501) {
                const message = await response.clone().json().catch(() => null);
                let notice = document.getElementById('native-wifi-notice');
                if (!notice) {
                  notice = document.createElement('button'); notice.id = 'native-wifi-notice';
                  notice.setAttribute('role', 'status');
                  notice.style.cssText = 'position:fixed;top:12px;left:12px;right:12px;z-index:10000;padding:16px;border-radius:16px;background:Canvas;color:CanvasText;border:1px solid currentColor;font:inherit;';
                  notice.onclick = () => notice.remove(); document.body.appendChild(notice);
                }
                notice.textContent = typeof message?.error === 'string' ? message.error : 'Connect to comma over Wi-Fi for this feature.';
              }
              return response;
            }).catch(error => {
              if (sentryEvents) sentryLog(error.name === 'AbortError' ? 'events-cancelled' : 'events-network-failed', {ms: Date.now() - sentryStarted});
              throw error;
            });
          };
          const originalOpen = XMLHttpRequest.prototype.open;
          const originalSend = XMLHttpRequest.prototype.send;
          XMLHttpRequest.prototype.open = function(method, url, ...rest) {
            this.__galaxyLocal = local(url);
            return originalOpen.call(this, method, url, ...rest);
          };
          XMLHttpRequest.prototype.send = function(body) {
            if (this.__galaxyLocal) this.setRequestHeader('X-Galaxy-Local', key);
            return originalSend.call(this, body);
          };
          // Sentry <img> requests cannot use the fetch/XHR header hooks above.
          // Keep the loopback API protected; fetch only same-origin Sentry images
          // with the app key, then give WebKit a short-lived blob URL.
          // BEGIN AUTHENTICATED SENTRY IMAGES
          const sentryImages = new Map();
          const releaseSentryImage = (img) => {
            const state = sentryImages.get(img);
            if (!state) return;
            img.removeEventListener('load', state.loaded);
            img.removeEventListener('error', state.failed);
            sentryLog('image-released', {attempt: state.attempt});
            state.controller.abort();
            if (state.blobURL) URL.revokeObjectURL(state.blobURL);
            sentryImages.delete(img);
          };
          let sentryImageAttempt = 0;
          const loadSentryImage = (img) => {
            const source = img.getAttribute('src');
            const previous = sentryImages.get(img);
            if (previous && (source === previous.source || source === previous.blobURL)) return;
            releaseSentryImage(img);
            let url;
            try { url = new URL(source || '', location.href); } catch (_) { return; }
            if (!source || url.origin !== location.origin || !url.pathname.startsWith('/api/sentry/image/')) return;
            const state = {source, controller: new AbortController(), blobURL: null, attempt: ++sentryImageAttempt, started: Date.now()};
            state.loaded = () => {
              if (img.getAttribute('src') === state.blobURL) sentryLog('image-rendered', {attempt: state.attempt, width: img.naturalWidth, height: img.naturalHeight, ms: Date.now() - state.started});
            };
            state.failed = () => {
              if (img.getAttribute('src') === state.blobURL) sentryLog('image-decode-failed', {attempt: state.attempt});
            };
            img.addEventListener('load', state.loaded);
            img.addEventListener('error', state.failed);
            sentryImages.set(img, state);
            sentryLog('image-start', {attempt: state.attempt});
            originalFetch(url.href, {
              headers: {'X-Galaxy-Local': key}, signal: state.controller.signal,
              redirect: 'error', cache: 'no-store'
            }).then(async response => {
              sentryLog('image-http', {attempt: state.attempt, http: response.status, ms: Date.now() - state.started});
              if (!response.ok) throw new Error('Sentry image HTTP ' + response.status);
              const blob = await response.blob();
              sentryLog(blob.type.toLowerCase().startsWith('image/') && blob.size ? 'image-bytes' : 'image-invalid', {attempt: state.attempt, bytes: blob.size});
              if (!blob.type.toLowerCase().startsWith('image/') || !blob.size) throw new Error('Invalid Sentry image');
              if (sentryImages.get(img) !== state || !img.isConnected || img.getAttribute('src') !== source) return;
              state.blobURL = URL.createObjectURL(blob);
              img.setAttribute('src', state.blobURL);
            }).catch(error => {
              sentryLog(error.name === 'AbortError' ? 'image-cancelled' : 'image-failed', {attempt: state.attempt, ms: Date.now() - state.started});
              if (error.name !== 'AbortError' && sentryImages.get(img) === state) emit('resource', url.pathname);
            });
          };
          const watchSentryImages = () => {
            sentryLog('image-observer-ready');
            const scan = root => {
              if (root.matches?.('img')) loadSentryImage(root);
              root.querySelectorAll?.('img').forEach(loadSentryImage);
            };
            new MutationObserver(records => {
              for (const record of records) {
                if (record.type === 'attributes') loadSentryImage(record.target);
                else record.addedNodes.forEach(scan);
              }
              for (const img of sentryImages.keys()) if (!img.isConnected) releaseSentryImage(img);
            }).observe(document.documentElement, {subtree: true, childList: true, attributes: true, attributeFilter: ['src']});
            scan(document);
          };
          if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', watchSentryImages, {once: true});
          else watchSentryImages();
          window.addEventListener('pagehide', () => {
            for (const img of sentryImages.keys()) releaseSentryImage(img);
          });
          // END AUTHENTICATED SENTRY IMAGES
        })();
        """
        config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let webView = WKWebView(frame: .zero, configuration: config)
        diagnostics.barWebView = webView
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = DuoLayout.isEnabled ? .clear : StarPilotTheme.toolbarColor(dark: true)
        if DuoLayout.isEnabled { webView.scrollView.backgroundColor = .clear }
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.load(URLRequest(url: diagnostics.takeStartupURL(url) ?? url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        uiView.evaluateJavaScript("window.__galaxyBluetooth = \(bluetooth ? "true" : "false")", completionHandler: nil)
        if isActive, let startup = diagnostics.takeStartupURL(url) { uiView.load(URLRequest(url: startup)) }
        if context.coordinator.expandedView != expandedView {
            context.coordinator.expandedView = expandedView
            context.coordinator.syncBar(uiView)
        }
        context.coordinator.isVisible = isActive
        context.coordinator.localWiFi = localWiFi
        context.coordinator.syncVisibility(uiView)
        context.coordinator.syncPush(uiView)
        context.coordinator.syncShare(uiView)
        if followGalaxyLanguage && !context.coordinator.wasFollowingLanguage {
            uiView.evaluateJavaScript("try { let code = localStorage.getItem('galaxy-language'); if (code) window.webkit.messageHandlers.galaxyDiagnostics.postMessage({kind:'language',code}); } catch (_) {}", completionHandler: nil)
        }
        context.coordinator.wasFollowingLanguage = followGalaxyLanguage
    }
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "galaxyDiagnostics")
        uiView.navigationDelegate = nil; uiView.uiDelegate = nil
        coordinator.cancelDownloads()
        uiView.stopLoading()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKDownloadDelegate {
        var localWiFi = false
        private var replayExport: Task<Void, Never>?
        private var downloads: [ObjectIdentifier: (WKDownload, URL?)] = [:]
        var isVisible = true
        var expandedView = true
        func syncBar(_ webView: WKWebView) {
            webView.evaluateJavaScript("window.__galaxyBarReady?.(\(expandedView ? "true" : "false"))", completionHandler: nil)
        }
        var wasFollowingLanguage = false
        func syncVisibility(_ webView: WKWebView) {
            webView.evaluateJavaScript("window.__galaxySetVisible?.(\(isVisible ? "true" : "false"))", completionHandler: nil)
        }
        func syncPush(_ webView: WKWebView) {
            webView.evaluateJavaScript("window.__galaxyPushState = \(SentryPush.shared.stateJSON)", completionHandler: nil)
            if SentryPush.shared.openEvents && diagnostics.mounted && !webView.isLoading {
                webView.evaluateJavaScript("location.hash = '/cameras/events'") { _, error in
                    if error == nil { SentryPush.shared.openEvents = false }
                }
            }
        }
        func syncShare(_ webView: WKWebView) {
            guard diagnostics.mounted, !webView.isLoading, let script = ShareInbox.shared.script() else { return }
            ShareInbox.shared.sending = true
            webView.evaluateJavaScript(script) { _, error in
                ShareInbox.shared.sending = false
                guard error == nil else { return }
                ShareInbox.shared.galaxyText = nil
                AppModel.shared.tab = .galaxy
            }
        }
        let origin: URL
        let diagnostics: GalaxyPageDiagnostics
        private let requestKey: String
        init(origin: URL, requestKey: String, diagnostics: GalaxyPageDiagnostics) {
            self.origin = origin
            self.requestKey = requestKey
            self.diagnostics = diagnostics
        }
        private func isLocal(_ url: URL) -> Bool {
            url.scheme == origin.scheme && url.host == origin.host && url.port == origin.port
        }
        private func authorized(_ request: URLRequest) -> URLRequest {
            var result = request
            result.setValue(requestKey, forHTTPHeaderField: "X-Galaxy-Local")
            return result
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            let frame = message.frameInfo.securityOrigin
            guard frame.protocol == origin.scheme, frame.host == origin.host, frame.port == origin.port,
                  let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
            let path = LoopbackServer.reportPath(body["path"] as? String ?? "")
            switch kind {
            case "bar":
                guard message.frameInfo.isMainFrame, let webView = message.webView, diagnostics.barWebView === webView,
                      let items = body["items"] as? [[String: Any]], items.count <= 12,
                      let data = try? JSONSerialization.data(withJSONObject: items),
                      let bar = try? JSONDecoder().decode([GalaxyBarItem].self, from: data) else { return }
                if diagnostics.barItems != bar { diagnostics.barItems = bar }
                let status = body["status"] as? String ?? ""
                if diagnostics.deviceStatus != status { diagnostics.deviceStatus = status }
                syncBar(webView)
            case "language":
                guard message.frameInfo.isMainFrame,
                      UserDefaults.standard.object(forKey: "galaxy.app.followGalaxyLanguage") as? Bool ?? true,
                      let code = body["code"] as? String else { break }
                let supported = ["en": "en", "es": "es", "fr": "fr", "ko": "ko", "zh-CHS": "zh-Hans"]
                if let language = supported[code] { UserDefaults.standard.set(language, forKey: "galaxy.app.language") }
            case "sentryPush":
                if message.frameInfo.isMainFrame, let enabled = body["enabled"] as? Bool {
                    Task {
                        await SentryPush.shared.setEnabled(enabled)
                        if let webView = message.webView { self.syncPush(webView) }
                    }
                }
            case "chooseTheme":
                if message.frameInfo.isMainFrame, let dark = body["dark"] as? Bool {
                    UserDefaults.standard.set((dark ? AppAppearance.dark : AppAppearance.light).rawValue, forKey: AppAppearance.key)
                }
            case "theme":
                if message.frameInfo.isMainFrame, let dark = body["dark"] as? Bool {
                    diagnostics.darkAppearance = dark
                    let background = DuoLayout.isEnabled ? UIColor.clear : StarPilotTheme.toolbarColor(dark: dark)
                    message.webView?.backgroundColor = background
                    message.webView?.scrollView.backgroundColor = background
                }
            case "editorFocus":
                if message.frameInfo.isMainFrame, let active = body["active"] as? Bool {
                    diagnostics.landscapeEditor = active
                }
            case "rendered": if message.frameInfo.isMainFrame { diagnostics.rendered(); if let webView = message.webView { syncPush(webView) } }
            case "blank": if message.frameInfo.isMainFrame { diagnostics.begin() }
            case "resource": diagnostics.record("Resource failed: \(path)")
            case "sentry":
                let stages: Set<String> = ["events-start", "events-http", "events-result", "events-invalid", "events-cancelled", "events-network-failed", "image-observer-ready", "image-start", "image-http", "image-bytes", "image-invalid", "image-rendered", "image-decode-failed", "image-failed", "image-cancelled", "image-released"]
                guard let stage = body["stage"] as? String, stages.contains(stage) else { break }
                let metrics = ["attempt", "http", "ms", "count", "images", "bytes", "width", "height"].compactMap { key -> String? in
                    guard let value = body[key] as? NSNumber, value.doubleValue.isFinite,
                          value.doubleValue >= 0, value.doubleValue <= 1_000_000_000_000 else { return nil }
                    return "\(key)=\(value.int64Value)"
                }
                diagnostics.record("Sentry \(stage): \(metrics.joined(separator: "; ")); incomplete=\(body["incomplete"] as? Bool ?? false)")
            case "script": diagnostics.record("JavaScript error: \(path), line \(body["code"] as? Int ?? 0)")
            case "promise": diagnostics.record("Unhandled JavaScript promise rejection")
            case "search":
                if let phase = body["phase"] as? String, ["started", "results", "partial", "ready"].contains(phase),
                   let count = body["count"] as? Int, (0...50_000).contains(count) {
                    diagnostics.record("Toggle search \(phase): \(count) settings indexed")
                }
            default: break
            }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            syncVisibility(webView)
            diagnostics.record("HTML navigation finished; waiting for Galaxy content")
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            navigationFailed(error)
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationFailed(error) }
        private func navigationFailed(_ error: Error) {
            let value = error as NSError
            if !downloads.isEmpty, value.code == NSURLErrorCancelled || (value.domain == "WKErrorDomain" && value.code == 102) { return }
            if value.domain == NSURLErrorDomain && value.code == NSURLErrorCancelled { return }
            diagnostics.fail("Navigation failed: \(value.domain) \(value.code)")
            if isVisible, value.domain == NSURLErrorDomain,
               [NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost].contains(value.code) {
                diagnostics.recover?(true)
            }
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            diagnostics.fail("Galaxy web content process terminated")
            if isVisible { diagnostics.recover?(true) }
        }


        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if isLocal(url) {
                if action.request.httpMethod == "GET", url.path == "/api/replay/export-download" {
                    decisionHandler(.cancel)
                    saveReplay(authorized(action.request))
                } else if action.shouldPerformDownload {
                    decisionHandler(.cancel)
                    webView.startDownload(using: authorized(action.request)) { [weak self] download in
                        self?.track(download)
                    }
                } else if url.path.hasPrefix("/api/"),
                          action.request.value(forHTTPHeaderField: "X-Galaxy-Local") != requestKey {
                    decisionHandler(.cancel)
                    webView.load(authorized(action.request))
                } else {
                    decisionHandler(.allow)
                }
            } else if url.scheme == "blob" {
                let frame = action.sourceFrame.securityOrigin
                guard frame.protocol == origin.scheme, frame.host == origin.host,
                      frame.port == origin.port else { decisionHandler(.cancel); return }
                decisionHandler(action.shouldPerformDownload ? .download : .allow)
            } else if url.scheme == "about" {
                decisionHandler(.allow)
            } else {
                if action.navigationType == .linkActivated, ["https", "http"].contains(url.scheme ?? "") {
                    UIApplication.shared.open(url)
                }
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if let http = response.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                diagnostics.downloadFailed(URLError(.badServerResponse))
                decisionHandler(.cancel)
                return
            }
            let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
            decisionHandler(disposition.lowercased().hasPrefix("attachment") || !response.canShowMIMEType ? .download : .allow)
        }
        func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse,
                      newRequest request: URLRequest,
                      decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void) {
            decisionHandler(request.url.map(isLocal) == true ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            track(download)
        }
        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            track(download)
        }
        private func saveReplay(_ request: URLRequest) {
            guard replayExport == nil, downloads.isEmpty, diagnostics.downloadedFile == nil else { return }
            diagnostics.record("Replay export download started")
            replayExport = Task {
                defer { replayExport = nil }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let destination = try await Self.writeReplay(request, in: directory, chunkLimit: { self.localWiFi ? 8 * Wire.maxBody : 2 * Wire.maxBody })
                    try Task.checkCancellation()
                    diagnostics.offerDownload(destination)
                } catch {
                    try? FileManager.default.removeItem(at: directory)
                    if !Task.isCancelled { diagnostics.downloadFailed(error) }
                }
            }
        }

        private static func writeReplay(_ original: URLRequest, in directory: URL, chunkLimit: () -> Int) async throws -> URL {
            var offset = 0
            var total: Int?
            var destination: URL?
            var file: FileHandle?
            defer { try? file?.close() }
            repeat {
                try Task.checkCancellation()
                let chunkSize = chunkLimit()
                var request = original
                let end = min(total ?? Int.max, offset + chunkSize) - 1
                request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
                let (data, response) = try await BoundedHTTP.load(request, limit: chunkSize)
                guard response.mimeType == "video/mp4", !data.isEmpty else { throw URLError(.badServerResponse) }
                if response.statusCode == 200, offset == 0, response.value(forHTTPHeaderField: "Content-Range") == nil {
                    total = data.count
                } else {
                    let range = response.value(forHTTPHeaderField: "Content-Range") ?? ""
                    guard response.statusCode == 206, let rawSize = range.split(separator: "/").last,
                          let size = Int(rawSize), size > offset, size <= Int.max - 8 * Wire.maxBody,
                          total == nil || total == size,
                          data.count == min(size - offset, chunkSize),
                          range == "bytes \(offset)-\(offset + data.count - 1)/\(size)" else {
                        throw URLError(.badServerResponse)
                    }
                    total = size
                }
                if file == nil {
                    let name = response.suggestedFilename ?? ""
                    let safe = name.range(of: #"^[A-Za-z0-9_-]+\.mp4$"#, options: .regularExpression) != nil
                    let url = directory.appendingPathComponent(safe ? name : "replay.mp4")
                    guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
                    file = try FileHandle(forWritingTo: url)
                    destination = url
                }
                try file?.write(contentsOf: data)
                offset += data.count
            } while offset != total
            try file?.close()
            file = nil
            guard let destination else { throw URLError(.zeroByteResource) }
            return destination
        }

        private func track(_ download: WKDownload) {
            guard replayExport == nil, downloads.isEmpty, diagnostics.downloadedFile == nil else {
                download.cancel { _ in }
                return
            }
            downloads[ObjectIdentifier(download)] = (download, nil)
            download.delegate = self
            diagnostics.record("File download started")
        }
        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                      suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
            let id = ObjectIdentifier(download)
            guard downloads[id] != nil else { completionHandler(nil); return }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                completionHandler(nil)
                diagnostics.downloadFailed(URLError(.badServerResponse))
                return
            }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let name = (suggestedFilename as NSString).lastPathComponent
                let safeName = name.isEmpty || name == "." || name == ".." ? "toggle-backup.json" : name
                let destination = directory.appendingPathComponent(safeName)
                downloads[id] = (download, destination)
                completionHandler(destination)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                completionHandler(nil)
                diagnostics.downloadFailed(error)
            }
        }
        func downloadDidFinish(_ download: WKDownload) {
            guard let (_, destination) = downloads.removeValue(forKey: ObjectIdentifier(download)),
                  let destination else { return }
            diagnostics.offerDownload(destination)
        }
        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            if let (_, destination) = downloads.removeValue(forKey: ObjectIdentifier(download)),
               let destination {
                try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
            }
            diagnostics.downloadFailed(error)
        }
        func cancelDownloads() {
            replayExport?.cancel()
            let active = downloads.values
            downloads.removeAll()
            for (download, destination) in active {
                download.delegate = nil
                download.cancel { _ in }
                if let destination { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
            }
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if action.targetFrame == nil, let url = action.request.url, ["https", "http"].contains(url.scheme ?? "") {
                if isLocal(url) {
                    webView.load(authorized(action.request))
                } else {
                    UIApplication.shared.open(url)
                }
            }
            return nil
        }
    }
}
