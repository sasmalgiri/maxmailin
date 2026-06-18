import SwiftUI

/// Full-bleed overlay shown while the app is biometrically locked.
/// Blocks every other interaction until BiometricLock.authenticate
/// succeeds. Pressing the button (or hitting space / return) triggers
/// the system prompt.
struct LockScreenView: View {
    @Environment(MailViewModel.self) private var model
    @State private var isAuthing = false
    @State private var failedOnce = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.thinMaterial)
                .ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: icon)
                    .resizable().scaledToFit()
                    .frame(width: 64, height: 64)
                    .foregroundStyle(.tint)
                Text("maxmailin is locked")
                    .font(.title2.weight(.semibold))
                Text("Your mail and credentials stay locally encrypted in the macOS Keychain. Authenticate to view the inbox.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Button {
                    Task { await unlock() }
                } label: {
                    HStack(spacing: 8) {
                        if isAuthing { ProgressView().controlSize(.small) }
                        Text("Unlock")
                    }
                    .frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(isAuthing)
                if failedOnce {
                    Text("Authentication failed or was cancelled. Try again.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding()
        }
        .task {
            // Trigger the prompt automatically on first appearance so the
            // user doesn't have to click. Subsequent failures require an
            // explicit button press to retry.
            if !isAuthing && !failedOnce {
                await unlock()
            }
        }
    }

    private var icon: String {
        switch BiometricLock.availability() {
        case .touchID:         return "touchid"
        case .faceID:          return "faceid"
        case .watch:           return "applewatch"
        case .devicePassword:  return "key"
        case .unavailable:     return "lock"
        }
    }

    private func unlock() async {
        isAuthing = true
        defer { isAuthing = false }
        let ok = await BiometricLock.authenticate(reason: "Unlock maxmailin")
        if ok {
            failedOnce = false
            model.isLocked = false
        } else {
            failedOnce = true
        }
    }
}
