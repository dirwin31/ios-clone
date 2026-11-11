import SwiftUI

struct NotificationSharingSheet: View {
    @ObservedObject var sharing: NotificationSharing
    let bluetoothConnected: Bool
    let close: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "bell.badge").font(.system(size: 40))
            Text("Phone notifications").font(.title3.weight(.semibold))
            switch sharing.phase {
            case .idle:
                Text("Show iPhone notifications on your car screen. Your comma reads them directly over Bluetooth, so this works even when the app is closed. Messages are shown for a few seconds and never stored.")
                    .multilineTextAlignment(.center)
                if !bluetoothConnected {
                    Text("Connect to comma over Bluetooth to set this up.").font(.callout).multilineTextAlignment(.center)
                }
                Button("Set up") { sharing.start() }.buttonStyle(.borderedProminent).disabled(!bluetoothConnected)
            case .requesting:
                ProgressView("Asking comma to get ready…")
            case .pairing:
                Text("When iOS asks, tap **Pair**, then allow **Share System Notifications** (or **Allow Notifications**).")
                    .multilineTextAlignment(.center)
                ProgressView()
            case .done:
                Text("Notifications are shared with comma. To change this later, open **Settings → Bluetooth**, tap ⓘ next to your comma and switch **Share System Notifications**. Choose which apps appear in Galaxy → StarPort → Phone notifications.")
                    .multilineTextAlignment(.center)
            case .message(let text):
                Text(LocalizedStringKey(text)).multilineTextAlignment(.center)
                Button("Try again") { sharing.start() }.buttonStyle(.bordered).disabled(!bluetoothConnected)
            }
            Button(sharing.phase == .done ? "Done" : "Close") { close() }.padding(.top, 6)
        }.padding(24).presentationDetents([.medium, .large])
    }
}
