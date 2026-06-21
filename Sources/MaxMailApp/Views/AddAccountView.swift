import SwiftUI
import MaxMailCore

/// One-field account setup: type your email → app detects provider →
/// fill the password / app-password → Connect.
///
/// Three branches drive the second step:
///   - .oauth         — TODO: real OAuth flow lives in the next slice;
///                      until then we surface a hint telling the user
///                      they need an app password (Gmail / M365 allow
///                      both) and link the provider help URL.
///   - .appPassword   — direct field, prominent help URL.
///   - .basic         — never produced by ProviderDetector today, but
///                      the path is here for future custom providers.
/// Unknown domains fall through to "Custom setup" which opens the
/// full IMAP settings view.
struct AddAccountView: View {
    @Environment(MailViewModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var emailAddress: String = ""
    @State private var displayName: String = ""
    @State private var password: String = ""
    @State private var status: String = ""
    @State private var isWorking = false

    private var profile: ProviderDetector.ProviderProfile? {
        ProviderDetector.detect(emailAddress: emailAddress)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .padding()
            Divider()
            footer
                .padding()
        }
        .frame(width: 520)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "envelope.badge.shield.half.filled")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading) {
                Text("Add account")
                    .font(.title2.bold())
                Text("Type your email — we detect the rest")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Email address", text: $emailAddress)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .onSubmit { advanceToProvider() }

            if let profile {
                providerCard(profile)
                passwordField(profile)
            } else if !emailAddress.isEmpty && emailAddress.contains("@") {
                unknownProviderHint
            }

            if !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(status.hasPrefix("OK") ? Color.green : .secondary)
            }
        }
    }

    private func providerCard(_ profile: ProviderDetector.ProviderProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: authIcon(profile.auth))
                    .foregroundStyle(.tint)
                Text(profile.displayName)
                    .font(.headline)
                Spacer()
                Text(authShortLabel(profile.auth))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.18), in: Capsule())
            }
            Text(profile.imap.host + ":\(profile.imap.port) · SMTP \(profile.smtp.host):\(profile.smtp.port)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            if profile.jmapEndpoint != nil {
                Label("JMAP available — preferred for live push",
                      systemImage: "bolt.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if let help = profile.helpURL {
                Link(authHelpLabel(profile.auth), destination: help)
                    .font(.caption)
            }
        }
        .padding()
        .background(Color.accentColor.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func passwordField(_ profile: ProviderDetector.ProviderProfile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(passwordFieldLabel(profile.auth))
                .font(.caption.weight(.semibold))
            SecureField("", text: $password)
                .textFieldStyle(.roundedBorder)
            if isOAuthProvider(profile.auth) {
                // OAuth flow lands in the next slice; until then the
                // honest path for Gmail / M365 is the user generating
                // an app-specific password (still permitted under
                // admin policy at most orgs).
                Label("OAuth sign-in is coming in the next release. Use an app password from your provider for now.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            TextField("Display name (optional — defaults to provider name)",
                      text: $displayName)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var unknownProviderHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("We don't recognise that domain", systemImage: "questionmark.circle")
                .font(.caption.weight(.semibold))
            Text("Use the manual IMAP setup to configure host, port, and TLS yourself.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Open manual IMAP setup…") {
                model.showIMAPSettings = true
                dismiss()
            }
            .controlSize(.small)
        }
        .padding()
        .background(Color.gray.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button {
                Task { await connect() }
            } label: {
                if isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Connect")
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canConnect || isWorking)
        }
    }

    // MARK: - Logic

    private var canConnect: Bool {
        profile != nil && !password.isEmpty && emailAddress.contains("@")
    }

    private func advanceToProvider() {
        // No-op stub — the form is reactive on emailAddress so the
        // provider card appears as soon as a complete address is typed.
        // Reserved for any future provider-warm-up work.
    }

    private func connect() async {
        guard let profile else { return }
        isWorking = true
        defer { isWorking = false }
        let label = displayName.isEmpty ? profile.displayName : displayName
        // Sender address is the email the user typed; username is the
        // same for every provider we currently support.
        IMAPConfigStore.upsert(IMAPConfigStore.StoredConfig(
            displayName: label,
            host: profile.imap.host,
            port: profile.imap.port,
            useTLS: profile.imap.useTLS,
            username: emailAddress,
            password: password,
            senderEmail: emailAddress,
            smtpHost: profile.smtp.host,
            smtpPort: profile.smtp.port
        ))
        status = "OK — saved \(label)"
        await model.refreshAccountsAndFolders()
        await model.loadHeaders()
        dismiss()
    }

    // MARK: - Auth helpers

    private func authIcon(_ auth: ProviderDetector.AuthMechanism) -> String {
        switch auth {
        case .oauth:       return "person.badge.key.fill"
        case .appPassword: return "key.horizontal.fill"
        case .basic:       return "key"
        }
    }

    private func authShortLabel(_ auth: ProviderDetector.AuthMechanism) -> String {
        switch auth {
        case .oauth:       return "OAuth"
        case .appPassword: return "App password"
        case .basic:       return "Password"
        }
    }

    private func authHelpLabel(_ auth: ProviderDetector.AuthMechanism) -> String {
        switch auth {
        case .oauth:       return "Provider OAuth documentation"
        case .appPassword: return "How to create an app password"
        case .basic:       return "Provider help"
        }
    }

    private func passwordFieldLabel(_ auth: ProviderDetector.AuthMechanism) -> String {
        switch auth {
        case .oauth:       return "Password (use an app password for now)"
        case .appPassword: return "App-specific password"
        case .basic:       return "Password"
        }
    }

    private func isOAuthProvider(_ auth: ProviderDetector.AuthMechanism) -> Bool {
        if case .oauth = auth { return true }
        return false
    }
}
