import SwiftUI

/// The steps shown while phone notifications set up; used alone and after music pairing.
struct NotificationSharingProgress: View {
    @ObservedObject var sharing: NotificationSharing
    let bluetoothConnected: Bool
    var setUpMusic: (() -> Void)? = nil

    var body: some View {
        switch sharing.phase {
        case .idle:
            EmptyView()
        case .requesting:
            ProgressView("Asking comma to get ready…")
        case .waitingForMusic:
            ProgressView("Finishing music pairing…")
        case .pairing:
            Text("When iOS asks, tap **Pair**, then allow **Share System Notifications** (or **Allow Notifications**).")
                .multilineTextAlignment(.center)
            ProgressView()
        case .done:
            Text("Notifications are shared with comma. Choose which apps appear in Galaxy → Toggles → Phone.")
                .multilineTextAlignment(.center)
            Button("Send test notification") { Task { await sharing.sendTest() } }.buttonStyle(.bordered)
            if let status = sharing.testStatus {
                Text(LocalizedStringKey(status)).font(.callout).multilineTextAlignment(.center)
            }
        case .message(let text):
            Text(LocalizedStringKey(text)).multilineTextAlignment(.center)
            if text == NotificationSharing.needsMusicMessage, let setUpMusic {
                Button("Set up phone music") { setUpMusic() }.buttonStyle(.borderedProminent).disabled(!bluetoothConnected)
            }
            Button("Try again") { sharing.start() }.buttonStyle(.bordered).disabled(!bluetoothConnected)
        }
    }
}

struct NotificationSharingSheet: View {
    @ObservedObject var sharing: NotificationSharing
    let bluetoothConnected: Bool
    var setUpMusic: (() -> Void)? = nil
    let close: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "bell.badge").font(.system(size: 40))
            Text("Phone notifications").font(.title3.weight(.semibold))
            if sharing.phase == .idle {
                Text("Show iPhone notifications on your car screen. Your comma reads them directly over Bluetooth, so this works even when the app is closed. Messages are shown for a few seconds and never stored.")
                    .multilineTextAlignment(.center)
                Text("Uses the same Bluetooth pairing as **Phone music**, so set that up first.").font(.callout).multilineTextAlignment(.center)
                if !bluetoothConnected {
                    Text("Connect to comma over Bluetooth to set this up.").font(.callout).multilineTextAlignment(.center)
                }
                Button("Set up") { sharing.start() }.buttonStyle(.borderedProminent).disabled(!bluetoothConnected)
                if sharing.sharedWithThisComma {
                    Button("Send test notification") { Task { await sharing.sendTest() } }.buttonStyle(.bordered)
                    if let status = sharing.testStatus {
                        Text(LocalizedStringKey(status)).font(.callout).multilineTextAlignment(.center)
                    }
                }
            } else {
                NotificationSharingProgress(sharing: sharing, bluetoothConnected: bluetoothConnected, setUpMusic: setUpMusic)
            }
            Button(sharing.phase == .done ? "Done" : "Close") { close() }.padding(.top, 6)
        }.padding(24).presentationDetents([.medium, .large])
    }
}
