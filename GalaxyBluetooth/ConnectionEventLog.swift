import SwiftUI
import QuartzCore
import CoreImage
import Network
import MapKit
import CoreBluetooth
import StoreKit

@MainActor
final class ConnectionEventLog: ObservableObject {
    private var storage = Array(repeating: "", count: 12000)
    // Keep failure evidence even when successful polling rolls out the main timeline.
    private var failureStorage = Array(repeating: "", count: 256)
    private var nextFailure = 0
    private var failureCount = 0
    private var totalFailures = 0
    var failureEvents: [String] {
        let start = failureCount == failureStorage.count ? nextFailure : 0
        return (0..<failureCount).map { failureStorage[(start + $0) % failureStorage.count] }
    }
    private static let failurePattern = try! NSRegularExpression(pattern:
        #"(?i:failed|rejected|blocked|terminated|timeout|timed out|disconnected|replay blocked|exhausted|no addresses|0 result\(s\)|HTTP [45][0-9]{2})"#)
    private var nextEvent = 0
    private var retained = 0
    private var sequence = 0
    private var repeats = 0
    private let uptime = ProcessInfo.processInfo.systemUptime
    var events: [String] {
        let start = retained == storage.count ? nextEvent : 0
        return (0..<retained).map { storage[(start + $0) % storage.count] }
    }
    @Published var section = "Connections"
    @Published var detail = ""
    @Published var copied = false
    private var lastEvent = ""
    private let started = Date()
    private var dropped = 0
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    // Error descriptions can contain private tunnel URLs or key material.
    private static let privateValues = try! NSRegularExpression(pattern:
        #"https?://[^\s]+|\b[0-9a-fA-F]{64}\b|(?i:bearer)\s+[^\s]+"#)
    static func redact(_ text: String) -> String {
        privateValues.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "[redacted]")
    }
    private var stateEvents: [String: String] = [:]
    nonisolated static let defaultPersistenceURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Diagnostics", isDirectory: true).appendingPathComponent("previous-session.txt")
    private let persistenceURL: URL?
    private let persistQueue = DispatchQueue(label: "connection-log-persist", qos: .utility)
    private var persistTimer: Timer?
    private var persistedSequence = -1
    private(set) var previousSession = ""
    init(persistenceURL: URL? = ConnectionEventLog.defaultPersistenceURL) {
        self.persistenceURL = persistenceURL
        if let persistenceURL, let data = try? Data(contentsOf: persistenceURL) {
            previousSession = String(decoding: data.suffix(Self.persistedBytes), as: UTF8.self)
        }
        guard persistenceURL != nil else { return }
        persistTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.persist(reason: "periodic") }
        }
    }
    static let persistedBytes = 512 * 1024
    static let persistedEvents = 2000
    func persist(reason: String) {
        guard let persistenceURL, sequence != persistedSequence else { return }
        persistedSequence = sequence
        let info = Bundle.main.infoDictionary ?? [:]
        var body = (["Retained failure events:"] + failureEvents + ["Recent connection events:"] + events.suffix(Self.persistedEvents)).joined(separator: "\n")
        let header = "App: \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?")); session started: \(formatter.string(from: started)); saved: \(formatter.string(from: Date())) (\(reason)); events recorded: \(sequence)\n"
        let limit = Self.persistedBytes - header.utf8.count
        if body.utf8.count > limit { body = "[older events shortened]\n" + String(decoding: Data(body.utf8).suffix(limit - 32), as: UTF8.self) }
        let data = Data((header + body).utf8)
        persistQueue.async {
            let directory = persistenceURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var url = directory; try? url.setResourceValues(values)
            try? data.write(to: persistenceURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
    func recordState(_ key: String, _ event: String) {
        guard stateEvents[key] != event else { return }
        if stateEvents.count >= 32 && stateEvents[key] == nil { stateEvents.removeAll(keepingCapacity: true) }
        stateEvents[key] = event
        record(event)
    }
    // No published changes or disk/network work on the connection callback path.
    func record(_ event: String) {
        let redacted = Self.redact(event)
        let bounded = redacted.count > 2000 ? String(redacted.prefix(2000)) + " [event shortened]" : redacted
        guard bounded != lastEvent else { repeats += 1; return }
        if repeats > 0 { append("Previous event repeated \(repeats) additional times"); repeats = 0 }
        lastEvent = bounded
        append(bounded)
    }
    private func append(_ event: String) {
        sequence += 1
        let elapsed = String(format: "%.3f", ProcessInfo.processInfo.systemUptime - uptime)
        storage[nextEvent] = "\(formatter.string(from: Date())) #\(sequence) +\(elapsed)s \(event)"
        if Self.failurePattern.firstMatch(in: event, range: NSRange(event.startIndex..., in: event)) != nil {
            failureStorage[nextFailure] = storage[nextEvent]
            nextFailure = (nextFailure + 1) % failureStorage.count
            failureCount = min(failureCount + 1, failureStorage.count)
            totalFailures += 1
        }
        nextEvent = (nextEvent + 1) % storage.count
        if retained == storage.count { dropped += 1 } else { retained += 1 }
    }
    func clear() {
        storage = Array(repeating: "", count: 12000)
        failureStorage = Array(repeating: "", count: 256)
        nextFailure = 0; failureCount = 0; totalFailures = 0
        nextEvent = 0; retained = 0; dropped = 0; repeats = 0
        lastEvent = ""; stateEvents.removeAll(keepingCapacity: true); detail = ""; copied = false
        previousSession = ""; persistedSequence = sequence
        if let persistenceURL { persistQueue.async { try? FileManager.default.removeItem(at: persistenceURL) } }
    }
    func report(model: AppModel, eventLimit: Int? = nil) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        return """
        StarPilot BT connection diagnostics
        Connection diagnostics revision: 6 (setup stages and route state)
        \(ISO8601DateFormatter().string(from: Date()))
        App: \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))
        Build distribution: \(model.buildDistribution)
        iOS: \(UIDevice.current.systemVersion)
        OS build: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Phone class: \(UIDevice.current.model); low power mode=\(ProcessInfo.processInfo.isLowPowerModeEnabled); thermal state=\(ProcessInfo.processInfo.thermalState.rawValue)
        Local timezone: \(TimeZone.current.identifier); UTC offset seconds=\(TimeZone.current.secondsFromGMT())
        \(model.connectionControllerDiagnostics)
        Network path: \(model.networkPathDiagnostics)
        Mode: \(model.mode.title)
        Selected route: \(model.connectionStatusLabel)
        Available transports: local Wi-Fi=\(model.lan.connected); Tunnel=\(model.tunnel.connected); Bluetooth=\(model.bluetooth.connected)
        Tunnel verified: \(model.tunnel.connected)
        Tunnel status: \(model.tunnel.status)
        Tunnel detail: \(model.tunnel.diagnosticSummary)
        Connection order: \(model.connectionPriority.map(\.title).joined(separator: " → "))
        \(model.commaSoftwareDiagnostics)
        Saved comma identity present: \(model.lan.expectedDeviceID != nil)
        LAN verified: \(model.lan.connected)
        LAN endpoint: \(model.lan.endpoint?.host ?? "none"):8082
        LAN status: \(model.lan.status)
        Phone private IPv4 interfaces: \(LANDiscovery.privateInterfaceDiagnostics())
        Bluetooth verified: \(model.bluetooth.connected)
        Bluetooth app key saved: \(!model.pairingKey.isEmpty)
        Bluetooth detail: \(model.bluetooth.diagnosticSummary)
        Log session started: \(formatter.string(from: started)); retained: \(retained); older events dropped: \(dropped); pending repeated events: \(repeats)
        Current screen: \(model.tab.rawValue)
        GPS sharing: \(model.phoneLocation.sharing); \(model.phoneLocation.diagnosticSummary)
        \(model.navigationServices.navigation.diagnosticSummary)
        Bluetooth permission: \(CBManager.authorization)
        Discovery: searching=\(model.discovery.searching); results=\(model.discovery.devices.count)
        Discovery status: \(model.discovery.status)
        Discovery detail: \(model.discovery.diagnosticSummary)
        Local Network permission: iOS does not expose a direct status; see discovery errors and LAN verification above.
        LAN pairing setup saved: \(model.hasLANPairingSetup)
        Pairing active: \(model.pairingInProgress); setup busy: \(model.connectionSetupBusy)
        Last pairing failure: \(model.pairingFailure.isEmpty ? "none" : model.pairingFailure)
        Current connection message: \(model.connectionMessage)
        Navigation enabled: \(model.navigationEnabled)
        Retained failure events (may also appear in the timeline; retained=\(failureCount); older failures dropped=\(max(0, totalFailures - failureCount))):
        \(failureEvents.suffix(eventLimit ?? failureCount).joined(separator: "\n"))
        Recent connection events:
        \(events.suffix(eventLimit ?? retained).joined(separator: "\n"))
        Previous app session (saved when the app left the foreground or every minute; survives app restarts):
        \(previousSession.isEmpty ? "none saved" : eventLimit == nil ? previousSession : "included in copied and shared reports")
        """
    }
}

// A single-entry ZIP stores the full UTF-8 report without a third-party dependency.
enum DiagnosticArchive {
    private static let crcTable: [UInt32] = (0..<256).map { value in
        (0..<8).reduce(UInt32(value)) { crc, _ in
            (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb88320)
        }
    }

    static func zip(_ text: String) -> Data {
        let name = Data("diagnostics.txt".utf8)
        let contents = Data(text.utf8)
        let size = UInt32(contents.count)
        let crc = contents.reduce(UInt32.max) { crc, byte in
            (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xff)]
        } ^ UInt32.max
        var archive = Data()
        func word(_ value: UInt16) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { archive.append(contentsOf: $0) }
        }
        func long(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { archive.append(contentsOf: $0) }
        }
        func entryFields() {
            word(20) // ZIP version needed
            word(0) // flags
            word(0) // stored data
            word(0) // time
            word(33) // 1980-01-01
            long(crc)
            long(size)
            long(size)
            word(UInt16(name.count))
            word(0) // extra field length
        }

        long(0x04034b50)
        entryFields()
        archive.append(name)
        archive.append(contents)
        let directoryOffset = UInt32(archive.count)

        long(0x02014b50)
        word(20)
        entryFields()
        word(0) // comment length
        word(0) // disk number
        word(0) // internal attributes
        long(0) // external attributes
        long(0) // local header offset
        archive.append(name)
        let directorySize = UInt32(archive.count) - directoryOffset

        long(0x06054b50)
        word(0)
        word(0)
        word(1)
        word(1)
        long(directorySize)
        long(directoryOffset)
        word(0)
        return archive
    }
}

struct DeveloperLogsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var log: ConnectionEventLog
    let back: () -> Void
    let submitReport: () -> Void
    @State private var sharedReport: GalaxyDownloadedFile?
    @State private var reportDirectory: URL?
    @State private var exportStatus = ""
    @State private var exporting = false
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color { colorScheme == .dark ? Color(red: 0.68, green: 0.48, blue: 0.96) : Color(red: 0.45, green: 0.26, blue: 0.73) }
    private var panel: Color { colorScheme == .dark ? Color(red: 0.09, green: 0.065, blue: 0.145) : Color(red: 0.88, green: 0.83, blue: 0.95) }
    private var background: Color { colorScheme == .dark ? Color(red: 0.035, green: 0.035, blue: 0.078) : Color(red: 0.93, green: 0.90, blue: 0.98) }
    private var muted: Color { colorScheme == .dark ? Color(red: 0.70, green: 0.65, blue: 0.77) : Color(red: 0.36, green: 0.29, blue: 0.46) }
    private func allReports() -> String { model.supportReport() }
    private func selectedReport() -> String {
        switch log.section {
        case "Galaxy": return ConnectionEventLog.redact(model.galaxyPage.report(server: model.server, connection: model.transport.label))
        case "Live View": return ConnectionEventLog.redact(model.diagnostics.diagnosticLog())
        default: return log.report(model: model)
        }
    }
    private func previewReport() -> String {
        log.section == "Connections" ? log.report(model: model, eventLimit: 150) : selectedReport()
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Logs & support").font(.largeTitle.bold()).frame(maxWidth: .infinity)
                    .overlay(alignment: .leading) {
                        Button(action: back) { Image(systemName: "chevron.left").font(.headline).frame(width: 44, height: 44).contentShape(Rectangle()) }
                            .buttonStyle(.plain).accessibilityLabel("Back to Settings")
                    }
                VStack(alignment: .leading, spacing: 14) {
                    Label("Need a hand?", systemImage: "bubble.left.and.exclamationmark.bubble.right.fill")
                        .font(.headline).foregroundStyle(accent)
                    Text("Report a problem through Discord to keep your logs and support replies together.")
                        .font(.subheadline).foregroundStyle(muted)
                    Button {
                        submitReport()
                    } label: {
                        Label("Report a problem on Discord", systemImage: "bubble.left.and.exclamationmark.bubble.right")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 13)
                            .foregroundStyle(.white).background(accent, in: Capsule())
                    }.buttonStyle(.plain)
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    .background(panel, in: RoundedRectangle(cornerRadius: 22))
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 14) {
                        DisclosureGroup("View diagnostic logs") {
                            VStack(alignment: .leading, spacing: 14) {
                                Picker("Report", selection: $log.section) {
                                    ForEach(["Connections", "Galaxy", "Live View"], id: \.self) { Text($0).tag($0) }
                                }.pickerStyle(.segmented)
                                HStack {
                                    Button(log.copied ? "Copied" : "Copy selected", systemImage: "doc.on.doc") {
                                        UIPasteboard.general.string = selectedReport(); log.copied = true
                                    }
                                    Spacer()
                                    Button("Refresh", systemImage: "arrow.clockwise") { log.detail = previewReport(); log.copied = false }
                                }.font(.subheadline.weight(.semibold)).foregroundStyle(accent)
                                Button("Copy all diagnostics", systemImage: "doc.on.doc") {
                                    UIPasteboard.general.string = allReports(); log.copied = true
                                }.font(.subheadline.weight(.semibold)).foregroundStyle(accent)
                                Text("Preview shows the latest 150 connection events. Copy or share includes the full retained log.")
                                .font(.caption).foregroundStyle(.secondary)
                                Text(log.detail)
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                                Button("Clear connection history") { log.clear(); log.detail = previewReport() }
                                .font(.caption).foregroundStyle(muted)
                            }
                        }.font(.subheadline).tint(muted)
                        Divider()
                        Button(exporting ? "Preparing report…" : "Export logs (.zip)") {
                            guard !exporting else { return }
                            exporting = true; exportStatus = ""
                            let report = allReports()
                            Task {
                                do {
                                    let url = try await Task.detached(priority: .utility) {
                                        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                                        do {
                                            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                                            let name = "StarPilot-diagnostics-" + ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + ".zip"
                                            let url = directory.appendingPathComponent(name)
                                            try DiagnosticArchive.zip(report).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                                            return url
                                        } catch {
                                            try? FileManager.default.removeItem(at: directory)
                                            throw error
                                        }
                                    }.value
                                    reportDirectory = url.deletingLastPathComponent()
                                    sharedReport = GalaxyDownloadedFile(url: url)
                                } catch { exportStatus = "Couldn’t prepare diagnostics. Try again or copy the report." }
                                exporting = false
                            }
                        }.buttonStyle(.plain).font(.footnote).foregroundStyle(muted)
                            .frame(minHeight: 44, alignment: .leading).disabled(exporting).accessibilityIdentifier("save-diagnostics-zip")
                        if !exportStatus.isEmpty { Text(exportStatus).font(.caption).foregroundStyle(.secondary) }
                        Text("For manual troubleshooting when needed.")
                            .font(.caption).foregroundStyle(muted)
                    }.padding(.top, 12)
                } label: {
                    Text("Troubleshooting").font(.subheadline).foregroundStyle(muted)
                }.tint(muted)
            }.padding(20)
        }.background(background.ignoresSafeArea())
            .sheet(item: $sharedReport, onDismiss: {
                if let directory = reportDirectory { try? FileManager.default.removeItem(at: directory) }
                reportDirectory = nil
            }) { file in
                GalaxyFileShareSheet(url: file.url) { sharedReport = nil }
            }
            .task {
                while !Task.isCancelled {
                    let report = previewReport()
                    if report != log.detail { log.detail = report }
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                }
            }
            .onChange(of: log.section) { _, _ in log.detail = previewReport(); log.copied = false }
    }
}
