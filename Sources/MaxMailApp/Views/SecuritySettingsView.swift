import SwiftUI

struct SecuritySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var lockOn = BiometricLock.enabled
    @State private var relockMinutes: Int = max(1, Int(BiometricLock.relockAfterSeconds) / 60)
    @State private var availability: BiometricLock.Availability = .unavailable("")

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Security").font(.title2).bold()
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            Form {
                Section("App lock") {
                    Toggle("Require \(availabilityLabel) to open", isOn: $lockOn)
                        .onChange(of: lockOn) { _, new in
                            BiometricLock.enabled = new
                        }
                    Stepper(value: $relockMinutes, in: 1...120) {
                        Text("Re-lock after \(relockMinutes) min idle")
                    }
                    .onChange(of: relockMinutes) { _, new in
                        BiometricLock.relockAfterSeconds = TimeInterval(new * 60)
                    }
                    if case let .unavailable(reason) = availability {
                        Label(reason, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                }
                Section("What's protected") {
                    Label("Bearer tokens, IMAP / SMTP passwords",
                          systemImage: "key.fill")
                        .foregroundStyle(.secondary)
                    Text("All credentials live in the macOS Keychain. The lock here gates access to the UI itself — useful when leaving the screen unattended.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .padding()
        .frame(width: 480, height: 380)
        .onAppear { availability = BiometricLock.availability() }
    }

    private var availabilityLabel: String {
        switch availability {
        case .touchID:         return "Touch ID"
        case .faceID:          return "Face ID"
        case .watch:           return "Apple Watch"
        case .devicePassword:  return "device password"
        case .unavailable:     return "authentication"
        }
    }
}
