import SwiftUI
import MaxMailCore

/// Compose sheet. Sends through the configured JMAP account via
/// JMAPSync.sendPlainEmail. If no JMAP credentials are saved yet,
/// surfaces the missing config and offers to open Settings.
struct ComposeView: View {
    @Environment(MailViewModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var to = ""
    @State private var subject = ""
    @State private var messageBody = ""
    @State private var sentEmailID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("New message")
                    .font(.title2).bold()
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            if let cfg = JMAPConfigStore.first() {
                fields(cfg: cfg)
            } else {
                missingConfig
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 460)
    }

    @ViewBuilder private func fields(cfg: JMAPConfigStore.StoredConfig) -> some View {
        Form {
            Section {
                LabeledContent("From") {
                    Text(cfg.senderEmail).foregroundStyle(.secondary)
                }
                TextField("To (comma-separated)", text: $to)
                TextField("Subject", text: $subject)
            }
            Section("Message") {
                TextEditor(text: $messageBody)
                    .font(.body)
                    .frame(minHeight: 180)
            }
        }
        .formStyle(.grouped)

        if let id = sentEmailID {
            Label("Sent — server id \(id)", systemImage: "paperplane.fill")
                .foregroundStyle(.green)
        }

        HStack {
            if model.isSending {
                ProgressView().controlSize(.small)
                Text(model.sendStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let err = model.sendError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button("Send") {
                Task {
                    let recipients = to
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    let id = await model.sendMail(
                        from: cfg.senderEmail,
                        to: recipients,
                        subject: subject,
                        body: messageBody
                    )
                    sentEmailID = id
                    if id != nil {
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        dismiss()
                    }
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.isSending || to.isEmpty || subject.isEmpty)
        }
    }

    private var missingConfig: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("No JMAP account configured", systemImage: "person.crop.circle.badge.questionmark")
                .font(.headline)
            Text("Add credentials in Settings → JMAP to enable sending.")
                .foregroundStyle(.secondary)
            Button("Open settings…") {
                dismiss()
                Task { @MainActor in
                    model.showJMAPSettings = true
                }
            }
        }
        .padding(.vertical, 24)
    }
}
