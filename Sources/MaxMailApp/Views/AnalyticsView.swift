import SwiftUI
import Charts
import MaxMailCore

/// Analytics dashboard. Aggregates over `message_nlp` to show sentiment
/// timeline, sentiment distribution, top entities, and top keywords for
/// the currently selected account.
struct AnalyticsView: View {
    @Environment(MailViewModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    progressBlock
                    if model.analyticsTimeline.count >= 2 {
                        timelineBlock
                    }
                    distributionBlock
                    if !model.analyticsKeywords.isEmpty {
                        keywordsBlock
                    }
                    if !model.analyticsEntities.isEmpty {
                        entitiesBlock
                    }
                    if !model.analyticsSenders.isEmpty {
                        sendersBlock
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 720, minHeight: 580)
        .task { await model.refreshAnalytics() }
        .sheet(isPresented: Binding(
            get: { model.showSenderDetail },
            set: { model.showSenderDetail = $0 }
        )) {
            if let s = model.selectedSender {
                SenderDetailView(
                    address: s.address,
                    stat: s,
                    recentMessages: model.selectedSenderMessages
                )
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Insights")
                .font(.title2).bold()
            Spacer()
            if let acc = model.selectedAccount {
                Text(acc.name)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding()
    }

    @ViewBuilder private var progressBlock: some View {
        let p = model.analyticsProgress
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "cpu")
                Text("Analysis progress")
                    .font(.headline)
                Spacer()
                Text("\(p.analyzed) of \(p.total)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: p.percentComplete)
            HStack(spacing: 12) {
                if model.isBackgroundAnalyzing {
                    Button("Stop") {
                        Task { await model.stopAnalysis() }
                    }
                } else {
                    Button(p.analyzed == p.total ? "Re-analyze" : "Analyze all") {
                        Task { await model.startAnalysis() }
                    }
                    .disabled(p.total == 0)
                }
                Text(p.analyzed == p.total
                     ? "Up to date."
                     : "Run on-device NLP across every remaining message in this account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private var timelineBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sentiment by month").font(.headline)
            Chart(model.analyticsTimeline) { row in
                LineMark(
                    x: .value("Month", row.month),
                    y: .value("Mean sentiment", row.meanSentiment)
                )
                .interpolationMethod(.catmullRom)
                .symbol(by: .value("Series", "sentiment"))
                .foregroundStyle(color(for: row.meanSentiment))
                RuleMark(y: .value("Neutral", 0))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            .chartYScale(domain: -1...1)
            .frame(height: 220)
        }
    }

    private func color(for sentiment: Double) -> Color {
        if sentiment > 0.2 { return .green }
        if sentiment < -0.2 { return .orange }
        return .gray
    }

    @ViewBuilder private var distributionBlock: some View {
        let d = model.analyticsDistribution
        VStack(alignment: .leading, spacing: 8) {
            Text("Sentiment distribution").font(.headline)
            HStack(spacing: 0) {
                DistributionBar(label: "Very–",  count: d.veryNegative, total: d.total, color: .red)
                DistributionBar(label: "Neg",    count: d.negative,     total: d.total, color: .orange)
                DistributionBar(label: "Neutral",count: d.neutral,      total: d.total, color: .gray)
                DistributionBar(label: "Pos",    count: d.positive,     total: d.total, color: .mint)
                DistributionBar(label: "Very+",  count: d.veryPositive, total: d.total, color: .green)
            }
            .frame(height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder private var keywordsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Top keywords").font(.headline)
            FlowLayout(spacing: 6) {
                ForEach(model.analyticsKeywords) { kw in
                    HStack(spacing: 6) {
                        Text(kw.keyword)
                        Text("\(kw.count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                }
            }
        }
    }

    @ViewBuilder private var entitiesBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Top entities").font(.headline)
            FlowLayout(spacing: 6) {
                ForEach(model.analyticsEntities) { e in
                    HStack(spacing: 6) {
                        Image(systemName: icon(for: e.entity.kind))
                            .font(.caption2)
                        Text(e.entity.text)
                        Text("\(e.count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(background(for: e.entity.kind), in: Capsule())
                }
            }
        }
    }

    @ViewBuilder private var sendersBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Top contacts").font(.headline)
            ForEach(model.analyticsSenders) { s in
                Button {
                    Task { await model.openSenderDetail(s) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle")
                            .font(.title3)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.address).font(.callout)
                            Text("\(s.messageCount) messages · \(s.attachmentMessageCount) with attachments")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let sent = s.meanSentiment {
                            Text(String(format: "%+.2f", sent))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(senderTint(sent))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(senderTint(sent).opacity(0.15), in: Capsule())
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
    }

    private func senderTint(_ sentiment: Double) -> Color {
        if sentiment > 0.2 { return .green }
        if sentiment < -0.2 { return .orange }
        return .secondary
    }

    private func icon(for k: EmailEntity.Kind) -> String {
        switch k {
        case .person: return "person.fill"
        case .organization: return "building.2.fill"
        case .place: return "mappin.and.ellipse"
        case .other: return "tag.fill"
        }
    }

    private func background(for k: EmailEntity.Kind) -> Color {
        switch k {
        case .person: return .blue.opacity(0.15)
        case .organization: return .purple.opacity(0.15)
        case .place: return .green.opacity(0.15)
        case .other: return .secondary.opacity(0.12)
        }
    }
}

private struct DistributionBar: View {
    let label: String
    let count: Int
    let total: Int
    let color: Color

    var body: some View {
        let widthFraction = total > 0 ? CGFloat(count) / CGFloat(total) : 0
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(color.opacity(0.85))
                if widthFraction > 0.08 {
                    HStack(spacing: 4) {
                        Text(label).font(.caption2.weight(.semibold))
                        Text("\(count)").font(.caption2)
                    }
                    .foregroundStyle(.white)
                    .padding(.leading, 6)
                }
            }
            .frame(width: max(geo.size.width * widthFraction, 2))
        }
    }
}
