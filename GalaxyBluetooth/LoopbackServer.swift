import Foundation
import CryptoKit
import Network
import Combine
import UniformTypeIdentifiers

@MainActor
final class LoopbackServer: ObservableObject {
    @Published var url: URL?
    @Published var error = ""
    private(set) var lifecycleEvents: [String] = []
    private(set) var listenerState = "stopped"
    private var availabilityTask: Task<Bool, Never>?
    private(set) var recentRequests: [String] = []
    private var recentFailures: [String] = []
    private let lifecycleFormatter = ISO8601DateFormatter()
    var diagnosticSummary: String {
        let mobile = webRoot.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path) } ?? false
        let script = webRoot.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("js/app.js").path) } ?? false
        return "Local server ready: \(url != nil)\nLocal listener state: \(listenerState)\nRecent local server events:\n\(lifecycleEvents.joined(separator: "\n"))\nAsset source: \(webRoot == nil ? "not downloaded" : "saved from comma")\nMobile HTML exists: \(mobile)\nGalaxy script exists: \(script)\nRetained failed requests (no bodies or credentials):\n\(recentFailures.joined(separator: "\n"))\nLocal server error present: \(!error.isEmpty)"
    }
    static func reportPath(_ target: String) -> String {
        let path = String(target.prefix(512)).split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        if ["/_bridge/health", "/data/runtime.json", "/api/navigation/status", "/api/navigation/action", "/api/companion/location", "/api/device/state"].contains(path) { return path }
        if ["/assets/", "/js/", "/css/", "/vendor/"].contains(where: { path.hasPrefix($0) }) { return String(path.prefix(200)) }
        if path.hasPrefix("/api/") { return "/api/" + (path.split(separator: "/").dropFirst().first.map(String.init) ?? "") + "/…" }
        return path == "/" ? "/" : "[other path]"
    }
    let localSecret = UUID().uuidString + UUID().uuidString
    private var listener: NWListener?
    private var connections: [UUID: LocalConnection] = [:]
    private var webRoot: URL?
    private let transport: any GalaxyRequestTransport
    private let probe: (URL) async -> Bool
    private var catalog: Data?
    private var catalogSHA256: String?

    init(transport: any GalaxyRequestTransport, webRoot: URL? = nil,
         probe: @escaping (URL) async -> Bool = { url in
             var request = URLRequest(url: url.appendingPathComponent("_native/health"))
             request.timeoutInterval = 2
             guard let (data, response) = try? await BoundedHTTP.load(request, limit: 256) else { return false }
             return response.statusCode == 200 && data == Data("galaxy-loopback-ready".utf8)
         }) {
        self.transport = transport
        self.probe = probe
        self.webRoot = webRoot

    }

    private static let startupSettingsScript = """
    const startupURL = new URL(location.href);
    let startupChoice = startupURL.searchParams.get('startupPage');
    if (startupChoice) {
      startupURL.searchParams.delete('startupPage');
      history.replaceState(history.state, '', startupURL);
      if (route.path === '/settings' && /^(toggle|section):[\\w/-]+$/.test(startupChoice)) {
        const mounted = SettingsPage.mounted;
        SettingsPage.mounted = async function (...args) {
          const choice = startupChoice;
          startupChoice = null;
          const originalRoute = route.view;
          if (!choice) return mounted?.apply(this, args);
          let interrupted = false;
          const cancel = () => { interrupted = true; };
          window.addEventListener('pointerdown', cancel, true);
          window.addEventListener('keydown', cancel, true);
          try { await mounted?.apply(this, args); }
          finally {
            window.removeEventListener('pointerdown', cancel, true);
            window.removeEventListener('keydown', cancel, true);
          }
          if (interrupted || route.path !== '/settings' || route.view !== originalRoute || !this.$el?.isConnected) return;
          const [kind, key] = choice.split(':');
          if (kind === 'toggle') this.open(key);
          else {
            const section = this.sections.find(item => item.id === key);
            if (section) this.selectSection(section);
          }
        };
      }
    }
    """

    private static let startupCatalogScript = """
    window.__galaxyStartupPages = async () => {
      const rows = new Map();
      const add = (id, name) => { if (id && name && !rows.has(id)) rows.set(id, {id, name}); };
      const tools = items => { for (const item of items || []) {
        add(item.path, item.name);
        tools(item.children);
      } };
      tools(startupApp.visibleTools);
      const title = key => key.split(/[\\/_-]/).filter(Boolean).map(word => word[0].toUpperCase() + word.slice(1)).join(' ');
      const settings = await import('./settings.js');
      for (const section of settings.SETTINGS_SECTIONS || []) {
        add('section:' + section.id, section.label);
        for (const key of section.pages || []) add('toggle:' + key, title(key));
      }
      const driving = await import('./driving.js').catch(() => ({}));
      for (const group of driving.DRIVING_GROUPS || []) {
        for (const item of group.items || []) add('/driving/' + item.page, item.title);
      }
      const active = startupApp.$refs.activeSettings;
      const detail = active?.state?.data;
      if (detail?.page && detail.page !== 'hub') add('toggle:' + detail.page, detail.title || title(detail.page));
      for (const row of detail?.rows || []) if (row.page) add('toggle:' + row.page, row.label || title(row.page));
      const path = route.path;
      if (path !== '/') add(path, title(path));
      return [...rows.values()];
    };
    """

    func useWebRoot(_ root: URL) {
        webRoot = root

    }

    private func record(_ event: String) {
        lifecycleEvents.append("\(lifecycleFormatter.string(from: Date())) \(event)")
        if lifecycleEvents.count > 200 { lifecycleEvents.removeFirst(lifecycleEvents.count - 200) }
    }

    // Probe real HTTP service after suspension; an old URL is not proof of readiness.
    func ensureAvailable() async -> Bool {
        if let availabilityTask { return await availabilityTask.value }
        let task = Task { @MainActor in
            self.start()
            await self.waitUntilReady()
            if let url = self.url, await self.probe(url) {
                self.record("Local HTTP health check passed")
                return true
            }
            self.record("Local HTTP health check failed; restarting listener")
            self.stop()
            self.start()
            await self.waitUntilReady()
            guard let url = self.url, await self.probe(url) else {
                self.stop()
                self.error = "Galaxy couldn’t reconnect. Try again."
                self.record("Local HTTP recovery failed")
                return false
            }
            self.record("Local HTTP recovery succeeded")
            return true
        }
        availabilityTask = task
        defer { availabilityTask = nil }
        return await task.value
    }

    private func waitUntilReady() async {
        for _ in 0..<40 {
            if url != nil || listener == nil { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func start() {
        guard listener == nil else { return }
        error = ""
        listenerState = "starting"
        record("Starting local listener")
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        self.listenerState = "ready"
                        self.error = ""
                        if let port = listener.port { self.url = URL(string: "http://127.0.0.1:\(port.rawValue)/") }
                        self.record("Local listener ready")
                    case .failed(let failure):
                        self.stop()
                        self.listenerState = "failed"
                        self.error = failure.localizedDescription
                        self.record("Local listener failed: \(failure)")
                    case .waiting:
                        self.url = nil
                        self.listenerState = "waiting"
                        self.record("Local listener waiting")
                    case .cancelled:
                        self.stop()
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                Task { @MainActor in
                    guard let self, let listener, self.listener === listener else { connection.cancel(); return }
                    self.accept(connection)
                }
            }
            listener.start(queue: .main)
        } catch { listenerState = "failed"; self.error = error.localizedDescription; record("Could not create local listener") }
    }

    func stop() {
        let oldListener = listener
        listener = nil
        oldListener?.cancel()
        listenerState = "stopped"
        record("Local listener stopped")
        url = nil
        for client in Array(connections.values) { client.close() }
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 64 else { connection.cancel(); return }
        let id = UUID()
        let client = LocalConnection(connection: connection, handle: { [weak self] request in
            guard let self else { return .error(503, "App is shutting down.") }
            return await self.handle(request)
        }, onDiagnostic: { [weak self] in self?.record($0) },
           onClose: { [weak self] in self?.connections.removeValue(forKey: id) })
        connections[id] = client
        client.start()
    }

    private func handle(_ request: LocalRequest) async -> LocalResponse {
        let start = Date()
        let response = await respond(request)
        recentRequests.append("\(ISO8601DateFormatter().string(from: Date())) \(request.method) \(Self.reportPath(request.target)) → \(response.status), \(response.body.count) bytes, \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
        if response.status >= 400, let failure = recentRequests.last {
            recentFailures.append(failure)
            if recentFailures.count > 1000 { recentFailures.removeFirst(recentFailures.count - 1000) }
        }
        if recentRequests.count > 3000 { recentRequests.removeFirst(recentRequests.count - 3000) }
        return response
    }

    static let nativeCameraPlaybackScript = #"""
    // WebKit's video element cannot attach the app's local request header.
    if (window.__galaxyNative && CameraViewer.template?.includes(':src="url"')) {
      const players = new WeakMap()
      const chunkSize = 2 * 1024 * 1024
      const segmentLimit = 512 * 1024 * 1024

      async function fetchRecording(source, signal) {
        const url = new URL(source, document.baseURI)
        if (url.origin !== location.origin || !url.pathname.startsWith('/api/recordings/media/')) {
          throw new Error('Unexpected recording URL')
        }
        const parts = []
        let offset = 0
        let total
        do {
          const end = Math.min(offset + chunkSize, total ?? segmentLimit) - 1
          const response = await fetch(url, {
            headers: {Range: 'bytes=' + offset + '-' + end}, signal, redirect: 'error', cache: 'no-store',
          })
          if (response.headers.get('Content-Type')?.split(';')[0].trim().toLowerCase() !== 'video/mp4') {
            throw new Error('Expected a recording')
          }
          const range = response.headers.get('Content-Range')
          const part = await response.blob()
          if (signal.aborted) throw new DOMException('Cancelled', 'AbortError')
          if (response.status === 200 && offset === 0 && !range && part.size > 0 && part.size <= 8 * 1024 * 1024) {
            return part
          }
          const match = /^bytes (\d+)-(\d+)\/(\d+)$/.exec(range ?? '')
          if (response.status !== 206 || !match) throw new Error('Expected a recording range')
          const [, start, last, size] = match.map(Number)
          if (!Number.isSafeInteger(size) || size <= 0 || size > segmentLimit || (total !== undefined && total !== size) ||
              start !== offset || last !== Math.min(end, size - 1) || part.size !== last - start + 1) {
            throw new Error('Incomplete recording range')
          }
          total = size
          parts.push(part)
          offset = last + 1
        } while (offset < total)
        return new Blob(parts, {type: 'video/mp4'})
      }

      function release(video) {
        const state = players.get(video)
        if (!state) return
        players.delete(video)
        state.controller.abort()
        state.notice.remove()
        if (state.objectURL) {
          video.removeAttribute('src')
          video.load()
          URL.revokeObjectURL(state.objectURL)
        }
      }

      async function open(video, {value}) {
        release(video)
        if (!value) return
        const notice = document.createElement('div')
        notice.setAttribute('role', 'status')
        notice.textContent = 'Loading camera footage…'
        video.after(notice)
        const state = {controller: new AbortController(), notice, objectURL: null}
        players.set(video, state)
        try {
          const recording = await fetchRecording(value, state.controller.signal)
          if (players.get(video) !== state) return
          state.objectURL = URL.createObjectURL(recording)
          video.src = state.objectURL
        } catch {
          if (players.get(video) === state) video.dispatchEvent(new Event('error'))
        } finally {
          notice.remove()
        }
      }

      CameraViewer.directives = {...CameraViewer.directives, recordingSrc: {
        mounted: open,
        updated(video, binding) { if (binding.value !== binding.oldValue) open(video, binding) },
        beforeUnmount: release,
      }}
      CameraViewer.template = CameraViewer.template.replace(':src="url"', 'v-recording-src="url"')
    }
    """#

    static let nativeSearchScript = #"""
    // Native Bluetooth search adapter v1. The verified upstream assets stay unchanged on disk.
    if (window.__galaxyNative) {
      const reportSearch = (phase, count) => {
        try { window.webkit?.messageHandlers?.galaxyDiagnostics?.postMessage({ kind: 'search', phase, count }) } catch (_) {}
      }
      SettingsSearchIndex.prototype.collect = async function(generation, controller) {
        const seen = new Set(INITIAL_PAGES)
        const queue = [...INITIAL_PAGES]
        let failed = 0, reportedResults = false
        reportSearch('started', 0)
        const current = () => this.generation === generation && !controller.signal.aborted
        for (let cursor = 0; cursor < queue.length && current(); cursor++) {
          const page = queue[cursor]
          const timed = new AbortController()
          let timer, abort
          try {
            const expired = new Promise((_, reject) => {
              abort = () => { timed.abort(); reject(new DOMException('Search stopped', 'AbortError')) }
              controller.signal.addEventListener('abort', abort, { once: true })
              timer = setTimeout(abort, 20000)
            })
            const read = (async () => {
              const response = await this.fetcher(`./api/settings/pages/${encodeURIComponent(page)}`,
                { credentials: 'same-origin', cache: 'no-store', signal: timed.signal })
              if (response.status === 401) { this.stop(); this.unauthorized(); return null }
              if (response.status === 503 && response.headers?.get('X-Galaxy-Disconnected') === '1') {
                return null
              }
              if (!response.ok) throw new Error('Settings unavailable')
              const data = await response.json()
              if (data?.page !== page || !Array.isArray(data.rows) || typeof data.title !== 'string') throw new Error('Invalid settings page')
              return data
            })()
            const data = await Promise.race([read, expired])
            if (!current()) return
            if (!data) { failed++; break }
            const section = PAGE_SECTIONS.get(page.split('/')[0]) || 'Toggles'
            for (const row of data.rows) {
              if (typeof row?.label !== 'string' || !row.label) continue
              if (typeof row.page === 'string' && row.page && !seen.has(row.page) && seen.size < 64) {
                seen.add(row.page); queue.push(row.page)
              }
              if (row.page || isPipCropRow(row)) continue
              this.entries.push({ page, label: row.label, title: data.title, section,
                search: searchable(row, data.title, section) })
            }
          } catch {
            if (!current()) return
            failed++
          } finally {
            clearTimeout(timer)
            if (abort) controller.signal.removeEventListener('abort', abort)
          }
          // Publish each page immediately; one slow page must not hide earlier matches.
          if (current() && this.entries.length && !reportedResults) {
            reportedResults = true; reportSearch('results', this.entries.length)
          }
          if (current()) this.publish({ status: 'loading', entries: [...this.entries], failed })
        }
        if (!current()) return
        this.status = failed ? 'partial' : 'ready'
        reportSearch(this.status, this.entries.length)
        this.publish({ status: this.status, entries: [...this.entries], failed })
      }
      const closeSearch = ToggleSearch.methods.close
      ToggleSearch.methods.close = function() { this.index.stop(); closeSearch.call(this) }
      const searchKey = ToggleSearch.methods.onKey
      ToggleSearch.methods.onKey = function(event) {
        if (event.key === 'Escape') this.index.stop()
        searchKey.call(this, event)
      }
      const chooseSearchHit = ToggleSearch.methods.choose
      ToggleSearch.methods.choose = function(hit) { this.index.stop(); chooseSearchHit.call(this, hit) }
      ToggleSearch.template = ToggleSearch.template.replace("state.status === 'partial' && !state.entries.length", "state.status === 'partial' && !results.length")
    }
    """#

    // Adapt known read deadlines when serving verified files; never alter the saved bundle.
    static func nativeReadDeadlines(_ source: String, asset: String) -> String {
        let timeout: String
        switch asset {
        case "js/snapshot-feed.js" where source.contains("export class SnapshotFeed"):
            timeout = "globalThis.__galaxyBluetooth && this.constructor.subject !== 'device state' ? 20000 : 4000"
        case "js/settings.js" where source.contains("async run(operation,"):
            timeout = "globalThis.__galaxyBluetooth && !saving ? 20000 : 4000"
        default: return source
        }
        var adapted = source.replacingOccurrences(of: "    }, 4000)", with: "    }, \(timeout))")
        if asset == "js/snapshot-feed.js" {
            adapted = adapted.replacingOccurrences(of: "interval: this.constructor.interval,", with:
                "interval: globalThis.__galaxyBluetooth && this.constructor.subject !== 'device state' ? Math.max(15000, this.constructor.interval) : this.constructor.interval,")
        }
        return adapted
    }

    private func respond(_ request: LocalRequest) async -> LocalResponse {
        guard let base = url, let port = base.port, request.headers["host"] == "127.0.0.1:\(port)" else {
            return .error(403, "Invalid local host.")
        }
        if let origin = request.headers["origin"], origin != "http://127.0.0.1:\(port)" {
            return .error(403, "Cross-origin requests are blocked.")
        }
        guard request.target.hasPrefix("/"), !request.target.hasPrefix("//"),
              let components = URLComponents(string: request.target), components.scheme == nil, components.host == nil,
              let path = components.percentEncodedPath.removingPercentEncoding,
              !path.contains("\\"), !path.contains("%"), !path.contains("//"),
              !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else {
            return .error(400, "Invalid local path.")
        }
        if path == "/_native/health", request.method == "GET" {
            return LocalResponse(status: 200, headers: ["content-type": "text/plain"], body: Data("galaxy-loopback-ready".utf8))
        }
        if path.hasPrefix("/_gateway/") { return .error(404, "Choose your connection in the native app.") }
        let dynamic = path.hasPrefix("/api/") || path == "/data/runtime.json"
        if dynamic {
            guard request.headers["x-galaxy-local"] == localSecret else { return .error(403, "Missing app request key.") }
            guard transport.connected else { return .error(503, "Your comma is disconnected. Open Connections to reconnect.", headers: ["X-Galaxy-Disconnected": "1"]) }
            do {
                let response = try await transport.request(path: request.target, method: request.method,
                                                          headers: request.headers, body: request.body)
                return LocalResponse(status: response.status, headers: response.headers, body: response.bodyData)
            } catch {
                let failure = error as NSError
                record("Request failed: \(request.method) \(Self.reportPath(request.target)); domain=\(failure.domain), code=\(failure.code)")
                return .error(502, error.localizedDescription)
            }
        }
        guard ["GET", "HEAD"].contains(request.method) else { return .error(405, "Method is not supported for Galaxy files.") }
        let assetPath = path == "/" ? "index.html" : String(path.dropFirst())
        var data: Data
        if let webRoot {
            let file = webRoot.appendingPathComponent(assetPath).standardizedFileURL
            guard file.path.hasPrefix(webRoot.standardizedFileURL.path + "/"), let saved = try? Data(contentsOf: file) else {
                return .error(404, "Galaxy asset was not found.")
            }
            data = saved
        } else {
            // No saved copy yet (an older comma that cannot share its screens): over Local Wi-Fi/LAN read the pages live from comma.
            let notYet = "Galaxy screens aren’t downloaded yet. Connect to comma over Local Wi-Fi or Tunnel once."
            guard transport.connected, SecretGoodGalaxy.validPage("/" + assetPath) else { return .error(503, notYet) }
            guard let live = try? await transport.page(path: "/" + assetPath) else { return .error(503, notYet) }
            guard live.status == 200 else { return .error(live.status, "Comma could not serve this Galaxy asset.") }
            data = live.bodyData
        }
        if ["js/snapshot-feed.js", "js/settings.js"].contains(assetPath), let source = String(data: data, encoding: .utf8) {
            let adapted = Self.nativeReadDeadlines(source, asset: assetPath)
            if adapted == source { record("Galaxy patch failed: read deadlines in \(assetPath)") }
            data = Data(adapted.utf8)
        }
        if assetPath == "js/app.js", let source = String(data: data, encoding: .utf8) {
            if source.contains("\ncreateApp({"), source.contains(".mount(\"#galaxy-app\")"),
               source.contains("import { SettingsPage"), source.contains("visibleTools()") {
                let entry = source.replacingOccurrences(of: "\ncreateApp({", with: "\n" + Self.startupSettingsScript + "\nconst startupApp = createApp({")
                data = Data((entry + "\n" + Self.startupCatalogScript).utf8)
            } else { record("Galaxy patch failed: startup page in js/app.js") }
        }
        let pathExtension = (assetPath as NSString).pathExtension
        if assetPath == "js/camera-viewer.js", let source = String(data: data, encoding: .utf8) {
            if source.contains("export const CameraViewer") {
                data.append(Data(("\n" + Self.nativeCameraPlaybackScript).utf8))
            } else { record("Galaxy patch failed: camera playback in js/camera-viewer.js") }
        }
        if assetPath == "js/toggle-search.js", let source = String(data: data, encoding: .utf8) {
            if source.contains("export class SettingsSearchIndex"), source.contains("export const ToggleSearch") {
                data.append(Data(("\n" + Self.nativeSearchScript).utf8))
                record("Native incremental toggle search enabled")
            } else { record("Galaxy patch failed: toggle search in js/toggle-search.js") }
        }
        let mime: String
        switch pathExtension {
        case "js", "mjs": mime = "text/javascript"
        case "css": mime = "text/css"
        case "html": mime = "text/html; charset=utf-8"
        case "json", "webmanifest": mime = "application/json"
        case "svg": mime = "image/svg+xml"
        default: mime = UTType(filenameExtension: pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
        return LocalResponse(status: 200, headers: ["content-type": mime], body: data)
    }
}

@MainActor
private final class LocalConnection {
    let connection: NWConnection
    let handle: @MainActor (LocalRequest) async -> LocalResponse
    let onClose: @MainActor () -> Void
    let onDiagnostic: @MainActor (String) -> Void
    private let diagnosticID = String(UUID().uuidString.prefix(8))
    private let started = ProcessInfo.processInfo.systemUptime
    private var diagnosticTarget = "headers pending"
    private var data = Data()
    private var requestTask: Task<Void, Never>?
    private var headerTimeout: Task<Void, Never>?
    private var closed = false

    init(connection: NWConnection, handle: @escaping @MainActor (LocalRequest) async -> LocalResponse,
         onDiagnostic: @escaping @MainActor (String) -> Void = { _ in },
         onClose: @escaping @MainActor () -> Void) {
        self.connection = connection
        self.handle = handle
        self.onClose = onClose
        self.onDiagnostic = onDiagnostic
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .failed = state { self?.close(reason: "network-failed") }
                if case .cancelled = state { self?.close(reason: "network-cancelled") }
            }
        }
        connection.start(queue: .main)
        headerTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if !Task.isCancelled { self?.close(reason: "header-timeout") }
        }
        receive()
    }

    fileprivate func close(reason: String = "server-close") {
        guard !closed else { return }
        if reason != "response-sent" {
            onDiagnostic("Local connection \(diagnosticID) closed: \(reason); \(diagnosticTarget); elapsed=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - started))s; cancelling request=\(requestTask != nil)")
        }
        closed = true
        headerTimeout?.cancel()
        requestTask?.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] chunk, _, ended, failure in
            Task { @MainActor in self?.consume(chunk, ended: ended, failure: failure) }
        }
    }

    private var packageTimeout = false

    private func consume(_ chunk: Data?, ended: Bool, failure: NWError?) {
        guard !closed else { return }
        data.append(chunk ?? Data())
        guard failure == nil, data.count <= LocalRequest.maxPackageBody + 16_388 else { close(reason: failure != nil ? "receive-failed" : "request-size-limit"); return }
        if !packageTimeout, let end = data.range(of: Data("\r\n\r\n".utf8)),
           let header = String(data: data[..<end.lowerBound], encoding: .utf8),
           let first = header.components(separatedBy: "\r\n").first {
            let parts = first.split(separator: " ")
            if parts.count == 3, LocalRequest.isPackageUpload(method: String(parts[0]), target: String(parts[1])) {
                packageTimeout = true
                headerTimeout?.cancel()
                headerTimeout = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(LocalRequest.packageUploadTimeout * 1_000_000_000))
                    if !Task.isCancelled { self?.close(reason: "package-timeout") }
                }
            }
        }
        do {
            guard let request = try LocalRequest.parse(data) else {
                if ended { close(reason: "incomplete-request-eof") } else { receive() }
                return
            }
            headerTimeout?.cancel()
            diagnosticTarget = request.method + " " + SecretGoodGalaxy.diagnosticPath(request.target)
            data = Data()
            // Detect browser aborts while a Bluetooth request is queued.
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] bytes, _, done, failure in
                Task { @MainActor in
                    if done || failure != nil || bytes?.isEmpty == false {
                        self?.close(reason: failure != nil ? "peer-receive-failed" : done ? "peer-eof" : "unexpected-extra-data")
                    }
                }
            }
            requestTask = Task { @MainActor in
                let response = await handle(request)
                guard !Task.isCancelled, !closed else { close(reason: "handler-cancelled"); return }
                send(response, headOnly: request.method == "HEAD")
            }
        } catch { send(.error(400, error.localizedDescription), headOnly: false) }
    }

    private func send(_ response: LocalResponse, headOnly: Bool) {
        headerTimeout?.cancel()
        connection.send(content: response.encoded(headOnly: headOnly), completion: .contentProcessed { [weak self] failure in
            Task { @MainActor in self?.close(reason: failure == nil ? "response-sent" : "response-send-failed") }
        })
    }
}
