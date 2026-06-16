import SwiftUI
import MaxMailCore

struct MessageDetailView: View {
    @Environment(MailViewModel.self) private var model

    var body: some View {
        if model.selectedMessageID == nil {
            ContentUnavailableView(
                "No message selected",
                systemImage: "envelope",
                description: Text("Pick a message in the list to read it.")
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    headerBlock
                    replyToolbar
                    if !model.currentAnomalies.isEmpty {
                        AnomalyChipsView(anomalies: model.currentAnomalies)
                    }
                    if let forensics = model.currentForensics,
                       forensics.phishing.level != .none || !forensics.pii.isEmpty {
                        ForensicInsightsView(result: forensics)
                    }
                    if let nlp = model.currentNLP {
                        NLPInsightsView(nlp: nlp)
                    }
                    Divider()
                    bodyBlock
                    if !model.currentAttachments.isEmpty {
                        Divider()
                        attachmentsBlock
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var selectedHeader: MessageHeader? {
        guard let id = model.selectedMessageID else { return nil }
        if let h = model.headers.first(where: { $0.id == id }) { return h }
        // If the user picked a search hit, synthesize a header-like view
        // from the SearchHit so we still get subject/from/date.
        if let hit = model.searchResults.first(where: { $0.id == id }) {
            return MessageHeader(
                id: hit.id, messageID: hit.messageID, folder: "",
                subject: hit.subject, fromAddress: hit.fromAddress,
                date: hit.date, sizeBytes: 0, flags: [], snippet: nil
            )
        }
        return nil
    }

    @ViewBuilder private var replyToolbar: some View {
        HStack(spacing: 8) {
            Button {
                model.startReply(replyAll: false)
            } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
            Button {
                model.startReply(replyAll: true)
            } label: {
                Label("Reply All", systemImage: "arrowshape.turn.up.left.2")
            }
            Button {
                model.startForward()
            } label: {
                Label("Forward", systemImage: "arrowshape.turn.up.right")
            }
            Spacer()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    @ViewBuilder private var headerBlock: some View {
        if let h = selectedHeader {
            VStack(alignment: .leading, spacing: 6) {
                Text(h.subject.isEmpty ? "(No subject)" : h.subject)
                    .font(.title2).bold()
                    .textSelection(.enabled)
                HStack(spacing: 12) {
                    Label(h.fromAddress, systemImage: "person.crop.circle")
                        .font(.callout)
                    Text("·")
                    Text(h.date, format: .dateTime
                            .month(.wide).day().year().hour().minute())
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var bodyBlock: some View {
        if let html = model.currentBody?.html, !html.isEmpty {
            EmailHTMLView(html: html)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let plain = model.currentBody?.plain, !plain.isEmpty {
            Text(plain)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("(no body)").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var attachmentsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Attachments (\(model.currentAttachments.count))")
                .font(.headline)
            ForEach(model.currentAttachments) { att in
                AttachmentRow(att: att)
            }
        }
    }

    private func iconForMIME(_ mime: String?) -> String {
        guard let mime = mime?.lowercased() else { return "doc" }
        if mime.hasPrefix("image/") { return "photo" }
        if mime.hasPrefix("video/") { return "film" }
        if mime.hasPrefix("audio/") { return "waveform" }
        if mime.contains("pdf")     { return "doc.richtext" }
        if mime.contains("zip")     { return "archivebox" }
        return "doc"
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct AttachmentRow: View {
    @Environment(MailViewModel.self) private var model
    let att: AttachmentRef

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.tint)
            VStack(alignment: .leading) {
                Text(att.filename)
                if let s = att.sizeBytes {
                    Text(ByteCountFormatter.string(fromByteCount: s, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let hex = att.sha256Hex {
                Text(String(hex.prefix(10)) + "…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help(hex)
            }
            #if canImport(AppKit)
            if att.hasLocalBlob {
                Button("Open") {
                    Task { await openAttachment() }
                }
                .buttonStyle(.borderless)
                Button("Save…") {
                    Task { await saveAttachment() }
                }
                .buttonStyle(.borderless)
            } else if att.externalID != nil {
                Button("Download") {
                    Task { await model.downloadAttachment(att) }
                }
                .buttonStyle(.borderless)
            }
            #endif
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var icon: String {
        let mime = (att.mimeType ?? "").lowercased()
        if mime.hasPrefix("image/") { return "photo" }
        if mime.hasPrefix("video/") { return "film" }
        if mime.hasPrefix("audio/") { return "waveform" }
        if mime.contains("pdf")     { return "doc.richtext" }
        if mime.contains("zip")     { return "archivebox" }
        return "doc"
    }

    #if canImport(AppKit)
    @MainActor
    private func openAttachment() async {
        guard let hex = att.sha256Hex,
              let store = model.store,
              let data = await store.loadAttachmentData(sha256Hex: hex)
        else { return }
        AttachmentActions.open(data: data, filename: att.filename)
    }

    @MainActor
    private func saveAttachment() async {
        guard let hex = att.sha256Hex,
              let store = model.store,
              let data = await store.loadAttachmentData(sha256Hex: hex)
        else { return }
        AttachmentActions.saveAs(data: data, suggestedName: att.filename)
    }
    #endif
}
