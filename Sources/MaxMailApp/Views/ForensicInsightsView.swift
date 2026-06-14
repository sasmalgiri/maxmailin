import SwiftUI
import MaxMailCore

/// Phishing risk banner + PII chip strip. Hidden when neither is present
/// so clean mail doesn't get noisy chrome.
struct ForensicInsightsView: View {
    let result: ForensicResult

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if result.phishing.level != .none {
                phishingBanner
            }
            if !result.pii.isEmpty {
                piiBlock
            }
        }
    }

    @ViewBuilder private var phishingBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "shield.lefthalf.filled.trianglebadge.exclamationmark")
                .font(.title3)
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(headline)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Text("score \(result.phishing.score)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                }
                ForEach(result.phishing.reasons, id: \.self) { reason in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").foregroundStyle(.white.opacity(0.8))
                        Text(reasonText(reason))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.95))
                    }
                }
            }
        }
        .padding(12)
        .background(bannerColor, in: RoundedRectangle(cornerRadius: 10))
    }

    private var headline: String {
        switch result.phishing.level {
        case .high:   return "High phishing risk"
        case .medium: return "Possible phishing"
        case .low:    return "Looks suspicious"
        case .none:   return ""
        }
    }

    private var bannerColor: Color {
        switch result.phishing.level {
        case .high:   return .red
        case .medium: return .orange
        case .low:    return .yellow.opacity(0.9)
        case .none:   return .clear
        }
    }

    private func reasonText(_ r: PhishingReason) -> String {
        switch r.kind {
        case .urgency:            return "Urgency language: \"\(r.detail)\""
        case .credentialHarvest:  return "Suspicious phrase: \"\(r.detail)\""
        case .brandImpersonation: return "Brand impersonation — \(r.detail)"
        case .urlRawIP:           return "URL pointing to a raw IP address"
        case .urlAtSymbol:        return "URL contains @ (redirect trick)"
        case .urlShortener:       return "Shortened URL: \(r.detail)"
        case .linkTextMismatch:   return "Anchor text disguises destination — \(r.detail)"
        }
    }

    @ViewBuilder private var piiBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "person.text.rectangle")
                Text("Sensitive data detected (\(result.piiTotal))")
                    .font(.subheadline.weight(.semibold))
            }
            FlowLayout(spacing: 6) {
                ForEach(result.pii) { finding in
                    HStack(spacing: 4) {
                        Image(systemName: icon(for: finding.kind))
                            .font(.caption2)
                        Text(finding.kind.label)
                        Text("\(finding.count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(piiBackground(for: finding.kind), in: Capsule())
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func icon(for kind: PIIFinding.Kind) -> String {
        switch kind {
        case .email:      return "envelope.fill"
        case .phone:      return "phone.fill"
        case .ssn:        return "person.text.rectangle.fill"
        case .creditCard: return "creditcard.fill"
        case .ipAddress:  return "network"
        case .iban:       return "banknote.fill"
        }
    }

    private func piiBackground(for kind: PIIFinding.Kind) -> Color {
        switch kind.severity {
        case 3:  return Color.red.opacity(0.18)
        case 2:  return Color.orange.opacity(0.18)
        default: return Color.blue.opacity(0.12)
        }
    }
}
