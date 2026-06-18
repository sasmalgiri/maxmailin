import SwiftUI
import MaxMailCore

/// IMAP credentials sheet. Stores the password in the Keychain via
/// IMAPConfigStore. Gmail / iCloud / Yahoo all accept app-specific
/// passwords here; OAuth (XOAUTH2) comes in a follow-up slice.
struct IMAPSettingsView: View {
    @Environment(MailViewModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = "Gmail"
    @State private var host = "imap.gmail.com"
    @State private var port: String = "993"
    @State private var useTLS = true
    @State private var username = ""
    @State private var password = ""
    @State private var senderEmail = ""
    @State private var smtpHost = "smtp.gmail.com"
    @State private var smtpPort: String = "465"

    @State private var isTesting = false
    @State private var testResult: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Connect an IMAP account")
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
                Section("IMAP server (incoming)") {
                    TextField("Host", text: $host)
                    TextField("Port", text: $port).frame(maxWidth: 100)
                    Toggle("TLS (recommended)", isOn: $useTLS)
                }
                Section("SMTP server (outgoing)") {
                    TextField("Host", text: $smtpHost)
                    TextField("Port", text: $smtpPort).frame(maxWidth: 100)
                    Text("Port 465 is implicit-TLS SMTPS. STARTTLS on port 587 is on the roadmap; for now most providers (Gmail / iCloud / Outlook / Fastmail) accept 465.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Credentials") {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                    SecureField("App password", text: $password)
                    Text("Tokens live in the system Keychain. For Gmail / iCloud / Yahoo, generate an app-specific password in their security settings.")
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
                .disabled(isTesting || host.isEmpty || username.isEmpty || password.isEmpty)
                Spacer()
                Button("Save") {
                    IMAPConfigStore.upsert(IMAPConfigStore.StoredConfig(
                        displayName: displayName,
                        host: host,
                        port: UInt16(port) ?? 993,
                        useTLS: useTLS,
                        username: username,
                        password: password,
                        senderEmail: senderEmail,
                        smtpHost: smtpHost,
                        smtpPort: UInt16(smtpPort) ?? 465
                    ))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(displayName.isEmpty || host.isEmpty || username.isEmpty || password.isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 540, minHeight: 460)
        .onAppear {
            if let existing = IMAPConfigStore.first() {
                displayName = existing.displayName
                host = existing.host
                port = String(existing.port)
                useTLS = existing.useTLS
                username = existing.username
                password = existing.password
                senderEmail = existing.senderEmail
                smtpHost = existing.smtpHost
                smtpPort = String(existing.smtpPort)
            }
        }
    }

    private func testConnection() async {
        isTesting = true
        defer { isTesting = false }
        let client = IMAPClient(config: IMAPConfig(
            host: host,
            port: UInt16(port) ?? 993,
            useTLS: useTLS,
            username: username,
            password: password
        ))
        do {
            try await client.connect()
            try await client.login()
            let folders = try await client.listFolders()
            await client.disconnect()
            testResult = "OK — \(folders.count) folders found"
        } catch {
            testResult = "Error: \(error.localizedDescription)"
        }
    }
}
