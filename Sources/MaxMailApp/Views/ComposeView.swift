import SwiftUI
import MaxMailCore

/// Compose sheet bound to MailViewModel.draft* fields so prefills (reply,
/// forward) and on-disk drafts persist across sheet open/close.
struct ComposeView: View {
    @Environment(MailViewModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var sentEmailID: String?

    var body: some View {
        @Bindable var bindable = model
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(headerTitle)
                    .font(.title2).bold()
                Spacer()
                Button("Discard") {
                    model.clearDraft()
                    dismiss()
                }
                Button("Close") {
                    model.persistDraft()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            if let cfg = JMAPConfigStore.first() {
                fields(
                    cfg: cfg,
                    to: $bindable.draftTo,
                    subject: $bindable.draftSubject,
                    body: $bindable.draftBody
                )
            } else {
                missingConfig
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 460)
        .onAppear {
            if !model.draftTo.trimmingCharacters(in: .whitespaces).isEmpty
                || !model.draftSubject.trimmingCharacters(in: .whitespaces).isEmpty
                || !model.draftBody.trimmingCharacters(in: .whitespaces).isEmpty {
                return  // already prefilled by reply/forward or kept in-memory
            }
            model.restoreDraftFromDisk()
        }
    }

    private var headerTitle: String {
        if model.draftInReplyTo != nil { return "Reply" }
        if model.draftSubject.lowercased().hasPrefix("fwd:") { return "Forward" }
        return "New message"
    }

    @ViewBuilder
    private func fields(
        cfg: JMAPConfigStore.StoredConfig,
        to: Binding<String>,
        subject: Binding<String>,
        body: Binding<String>
    ) -> some View {
        Form {
            Section {
                LabeledContent("From") {
                    Text(cfg.senderEmail).foregroundStyle(.secondary)
                }
                TextField("To (comma-separated)", text: to)
                TextField("Subject", text: subject)
            }
            Section("Message") {
                TextEditor(text: body)
                    .font(.body)
                    .frame(minHeight: 220)
            }
        }
        .formStyle(.grouped)

        if let id = sentEmailID {
            Label("Sent — server id \(id)", systemImage: "paperplane.fill")
                .foregroundStyle(.green)
        }
        if model.draftInReplyTo != nil {
            Label("Replying to a thread — In-Reply-To will be set automatically.",
                  systemImage: "arrowshape.turn.up.left")
                .font(.caption)
                .foregroundStyle(.secondary)
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
            Button("Save draft") {
                model.persistDraft()
            }
            Button("Send") {
                Task {
                    let id = await model.sendCurrentDraft()
                    sentEmailID = id
                    if id != nil {
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        dismiss()
                    }
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.isSending
                      || model.draftTo.isEmpty
                      || model.draftSubject.isEmpty)
        }
        .onChange(of: model.draftTo)      { _, _ in model.persistDraft() }
        .onChange(of: model.draftSubject) { _, _ in model.persistDraft() }
        .onChange(of: model.draftBody)    { _, _ in model.persistDraft() }
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
