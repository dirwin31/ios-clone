import UIKit
import SwiftUI
import UniformTypeIdentifiers

/// Share sheet entry: sends the shared place straight to comma, or saves it for the app to deliver.
final class ShareViewController: UIViewController {
    private let state = ShareState()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.25)
        let card = UIHostingController(rootView: ShareCard(state: state) { [weak self] in self?.finish() })
        card.view.backgroundColor = .clear
        addChild(card)
        view.addSubview(card.view)
        card.view.frame = view.bounds
        card.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        card.didMove(toParent: self)
        Task { await run() }
    }

    private func run() async {
        let text = await Self.sharedText(extensionContext?.inputItems as? [NSExtensionItem] ?? [])
        guard !text.isEmpty else { state.phase = .failed("Nothing to send. Share a place from Maps."); return }
        let resolved = await SharedDestination.resolve(text) { await RedirectProbe().location(of: $0) }
        let settings = ShareGroup.settings, tunnel = ShareGroup.tunnel
        let outcome = await withTaskGroup(of: DestinationSender.Outcome.self) { group in
            group.addTask { await ShareClient().send(text: resolved, settings: settings, tunnel: tunnel) }
            group.addTask { try? await Task.sleep(nanoseconds: 40_000_000_000); return .unreachable("timed out") }
            let first = await group.next() ?? .unreachable("timed out")
            group.cancelAll()
            return first
        }
        switch outcome {
        case .started(let name):
            state.phase = .done("Route to \(name) started on comma.")
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            finish()
        case .refused(let reason): state.phase = .failed(reason)
        case .needsSearch(let text):
            ShareGroup.stashSearch(text)
            state.phase = .failed("comma couldn’t find one place for this. Open StarPilot BT to choose it.")
        case .unreachable:
            ShareGroup.queue(DestinationSender.capped(resolved))
            state.phase = .saved
        }
    }

    private func finish() { extensionContext?.completeRequest(returningItems: nil) }

    /// The web link first, then any shared text that does not already contain it.
    static func sharedText(_ items: [NSExtensionItem]) async -> String {
        var link: String?, texts: [String] = [], cards: [String] = []
        for provider in items.flatMap({ $0.attachments ?? [] }) {
            if link == nil, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL, url.scheme?.hasPrefix("http") == true {
                link = url.absoluteString
            } else if provider.hasItemConformingToTypeIdentifier(UTType.vCard.identifier),
                      let data = try? await provider.loadItem(forTypeIdentifier: UTType.vCard.identifier) as? Data,
                      let card = String(data: data, encoding: .utf8) {
                cards.append(contentsOf: card.split(whereSeparator: \.isNewline).compactMap { line in
                    line.range(of: #"https?://maps\.apple\.com/\S*"#, options: .regularExpression).map { String(line[$0]) }
                })
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                texts.append(text)
            }
        }
        if link == nil, texts.isEmpty { link = cards.first }
        let parts = (link.map { [$0] } ?? []) + texts.filter { text in link.map { !text.contains($0) } ?? true }
        return DestinationSender.capped(parts.joined(separator: "\n"))
    }
}

@MainActor
final class ShareState: ObservableObject {
    enum Phase: Equatable { case sending, done(String), saved, failed(String) }
    @Published var phase = Phase.sending
}

struct ShareCard: View {
    @ObservedObject var state: ShareState
    let done: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("StarPilot").font(.headline)
            switch state.phase {
            case .sending:
                ProgressView()
                Text("Sending to comma…").foregroundStyle(.secondary)
            case .done(let message):
                Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(.green)
                Text(message).multilineTextAlignment(.center)
            case .saved:
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 36)).foregroundStyle(.blue)
                Text("Saved. The route starts when your iPhone next connects to comma.").multilineTextAlignment(.center)
                Button("Done", action: done).buttonStyle(.borderedProminent)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 36)).foregroundStyle(.orange)
                Text(message).multilineTextAlignment(.center)
                Button("Done", action: done).buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(maxWidth: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
