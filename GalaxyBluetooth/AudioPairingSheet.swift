import SwiftUI

struct AudioPairingSheet: View {
    @ObservedObject var pairing: AudioPairing
    @ObservedObject var notifications: NotificationSharing
    let bluetoothConnected: Bool
    let notificationsSupported: Bool
    let close: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "music.note").accessibilityHidden(true).font(.system(size: 40))
            Text("Bluetooth music").font(.title3.weight(.semibold))
            switch pairing.phase {
            case .idle, .opening:
                VStack(spacing: 8) { ProgressView(); Text("Asking comma to open pairing…").multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true) }
            case .waiting(let name):
                Text("On your iPhone, open **Settings → Bluetooth** and select **\(name)** to pair music.")
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                ProgressView()
                Text("Already says Connected? In Control Center, check whether comma is available as an audio output.")
                    .font(.callout).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Text("Pairing music also lets comma show your iPhone notifications.").font(.callout).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            case .confirm(let code, _, _):
                Text("Check that comma and this iPhone both show").multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Text(code).font(.system(size: 34, weight: .semibold, design: .monospaced))
                HStack {
                    Button("Cancel") { pairing.respond(accepted: false) }.buttonStyle(.bordered)
                    Button("Pair") { pairing.respond(accepted: true) }.buttonStyle(.borderedProminent)
                }
            case .done:
                Text("Bluetooth music paired. In Control Center, choose comma as the audio output.").multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                notificationStep
            case .connected:
                Text("Music connected. This iPhone is already using comma as its Bluetooth audio output.").multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                notificationStep
            case .message(let text):
                Text(LocalizedStringKey(text)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            Button((pairing.phase == .done || pairing.phase == .connected) ? "Done" : "Close") { close() }.buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 6)
        }.padding(24).presentationDetents([.medium, .large])
            .onChange(of: pairing.phase) { _, phase in
                guard phase == .done || phase == .connected else { return }
                continueToNotifications()
            }
    }

    /// Music is paired: close comma's window and carry straight on to phone notifications, so there is one setup.
    private func continueToNotifications() {
        guard bluetoothConnected, notificationsSupported, notifications.phase == .idle, !notifications.sharedWithThisComma else { return }
        notifications.start()
    }

    @ViewBuilder private var notificationStep: some View {
        if notifications.phase != .idle {
            Divider()
            Label("Phone notifications", systemImage: "bell.badge").font(.headline)
            NotificationSharingProgress(sharing: notifications, bluetoothConnected: bluetoothConnected)
        }
    }
}
