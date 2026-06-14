import SwiftUI
import MaxMailCore

/// On-device NLP summary block shown in the detail pane.
struct NLPInsightsView: View {
    let nlp: EmailNLP

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                Text("On-device insights")
                    .font(.headline)
                Spacer()
                if let lang = nlp.language {
                    Text(lang.uppercased())
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15),
                                    in: Capsule())
                        .help("Detected language")
                }
            }

            HStack(spacing: 10) {
                MoodBadge(mood: nlp.mood, sentiment: nlp.sentiment)
                Text(moodLabel(nlp.mood))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if !nlp.entities.isEmpty {
                Text("Entities").font(.caption).foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(nlp.entities, id: \.self) { e in
                        EntityChip(entity: e)
                    }
                }
            }

            if !nlp.keywords.isEmpty {
                Text("Keywords").font(.caption).foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(nlp.keywords, id: \.self) { kw in
                        Text(kw)
                            .font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func moodLabel(_ m: EmailNLP.Mood) -> String {
        switch m {
        case .veryPositive: return "Very positive"
        case .positive:     return "Positive"
        case .neutral:      return "Neutral"
        case .negative:     return "Negative"
        case .veryNegative: return "Very negative"
        }
    }
}

private struct MoodBadge: View {
    let mood: EmailNLP.Mood
    let sentiment: Double

    var body: some View {
        Image(systemName: icon)
            .font(.title3)
            .foregroundStyle(color)
            .help(String(format: "Sentiment %.2f", sentiment))
    }

    private var icon: String {
        switch mood {
        case .veryPositive: return "face.smiling.inverse"
        case .positive:     return "face.smiling"
        case .neutral:      return "face.dashed"
        case .negative:     return "face.dashed.fill"
        case .veryNegative: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch mood {
        case .veryPositive: return .green
        case .positive:     return .mint
        case .neutral:      return .gray
        case .negative:     return .orange
        case .veryNegative: return .red
        }
    }
}

private struct EntityChip: View {
    let entity: EmailEntity

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(entity.text)
                .font(.caption)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(background, in: Capsule())
    }

    private var icon: String {
        switch entity.kind {
        case .person:       return "person.fill"
        case .organization: return "building.2.fill"
        case .place:        return "mappin.and.ellipse"
        case .other:        return "tag.fill"
        }
    }

    private var background: Color {
        switch entity.kind {
        case .person:       return Color.blue.opacity(0.15)
        case .organization: return Color.purple.opacity(0.15)
        case .place:        return Color.green.opacity(0.15)
        case .other:        return Color.secondary.opacity(0.12)
        }
    }
}

/// Wraps chip rows when they overflow the available width. Minimal
/// implementation — fine for tag clouds, not a general flow engine.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var totalHeight: CGFloat = 0
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if lineWidth + s.width > maxW {
                totalHeight += lineHeight + spacing
                lineWidth = s.width + spacing
                lineHeight = s.height
            } else {
                lineWidth += s.width + spacing
                lineHeight = max(lineHeight, s.height)
            }
        }
        totalHeight += lineHeight
        return CGSize(width: maxW.isFinite ? maxW : lineWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0
        let maxX = bounds.maxX
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x + s.width > maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            lineHeight = max(lineHeight, s.height)
        }
    }
}
