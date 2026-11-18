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
            VStack(spacing: 8) { ProgressView(); Text("Asking comma to get ready…").multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true) }
        case .waitingForMusic:
            VStack(spacing: 8) { ProgressView(); Text("Finishing music pairing…").multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true) }
        case .relinking:
            VStack(spacing: 8) { ProgressView(); Text("Reconnecting to comma so it can see your notifications…").multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true) }
            Text("If iOS asks to allow notifications for comma, tap **Allow**. This takes a few seconds.")
                .font(.callout).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        case .pairing:
            Text("When iOS asks, tap **Pair**, then allow **Share System Notifications** (or **Allow Notifications**).")
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            ProgressView()
        case .done:
            Text("Notifications are shared with comma. Choose which apps appear in Galaxy → Toggles → Phone.")
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Button("Send test notification") { Task { await sharing.sendTest() } }.buttonStyle(.bordered)
            if let status = sharing.testStatus {
                Text(LocalizedStringKey(status)).font(.callout).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
        case .message(let text):
            Text(LocalizedStringKey(text)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
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
        ScrollView {
        VStack(spacing: 18) {
            Image(systemName: "bell.badge").font(.system(size: 40))
            Text("Phone notifications").font(.title3.weight(.semibold))
            if sharing.phase == .idle {
                if sharing.sharedWithThisComma {
                    Text("Notifications are shared with comma.").multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Show iPhone notifications on your car screen. Your comma reads them directly over Bluetooth, so this works even when the app is closed. Messages are shown for a few seconds and never stored.")
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    Text("Uses the same Bluetooth pairing as **Phone music**.").font(.callout).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                if !bluetoothConnected {
                    Text("Connect to comma over Bluetooth to set this up.").font(.callout).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                if sharing.sharedWithThisComma {
                    Button("Send test notification") { Task { await sharing.sendTest() } }.buttonStyle(.bordered)
                    if let status = sharing.testStatus {
                        Text(LocalizedStringKey(status)).font(.callout).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                NotificationSharingProgress(sharing: sharing, bluetoothConnected: bluetoothConnected, setUpMusic: setUpMusic)
            }
            Button(sharing.phase == .done ? "Done" : "Close") { close() }.buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 6)
        }.padding(24).fixedSize(horizontal: false, vertical: true)
        }.presentationDetents([.medium, .large])
            .onAppear {
                // Opening the sheet is the request: start right away instead of asking for another tap.
                if sharing.phase == .idle && !sharing.sharedWithThisComma && bluetoothConnected { sharing.start() }
            }
    }
}
