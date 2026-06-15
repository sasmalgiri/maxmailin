import SwiftUI
import MaxMailCore

/// Minimal JMAP credentials sheet. Persists to UserDefaults via
/// JMAPConfigStore — adequate for development / single-machine use.
/// A Keychain-backed version is the obvious next move.
struct JMAPSettingsView: View {
    @Environment(MailViewModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = "Personal"
    @State private var sessionURL = "https://api.fastmail.com/.well-known/jmap"
    @State private var senderEmail = ""
    @State private var bearerToken = ""
    @State private var isTesting = false
    @State private var testResult: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Connect a JMAP account")
                    .font(.title2).bold()
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            Form {
                Section("Account") {
                    TextField("Display name", text: $displayName)
                    TextField("Sender email", text: $senderEmail)
                        .textContentType(.emailAddress)
                }
                Section("JMAP") {
                    TextField("Session URL", text: $sessionURL)
                    SecureField("Bearer token", text: $bearerToken)
                    Text("The token is held in the system Keychain. macOS may prompt you the first time the app reads it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            if let r = testResult {
                Label(r, systemImage: r.hasPrefix("OK") ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(r.hasPrefix("OK") ? Color.green : Color.orange)
            }

            HStack {
                Button("Test connection") {
                    Task { await testConnection() }
                }
                .disabled(isTesting || sessionURL.isEmpty || bearerToken.isEmpty)
                Spacer()
                Button("Save") {
                    JMAPConfigStore.upsert(JMAPConfigStore.StoredConfig(
                        displayName: displayName,
                        sessionURL: sessionURL,
                        bearerToken: bearerToken,
                        senderEmail: senderEmail
                    ))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(displayName.isEmpty || sessionURL.isEmpty || bearerToken.isEmpty || senderEmail.isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 380)
        .onAppear {
            if let existing = JMAPConfigStore.first() {
                displayName = existing.displayName
                sessionURL = existing.sessionURL
                bearerToken = existing.bearerToken
                senderEmail = existing.senderEmail
            }
        }
    }

    private func testConnection() async {
        isTesting = true
        defer { isTesting = false }
        guard let url = URL(string: sessionURL) else {
            testResult = "Bad session URL"
            return
        }
        let cfg = JMAPConfig(sessionURL: url, credential: .bearer(bearerToken))
        let client = JMAPClient(config: cfg)
        do {
            let session = try await client.discover()
            testResult = "OK — signed in as \(session.username)"
        } catch {
            testResult = "Error: \(error.localizedDescription)"
        }
    }
}
