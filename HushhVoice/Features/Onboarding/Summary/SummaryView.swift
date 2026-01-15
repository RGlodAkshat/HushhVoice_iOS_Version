import SwiftUI

struct SummaryView: View {
    @Binding var profile: ProfileData
    var discovery: [String: String]
    var isSavingProfile: Bool
    var onUpdateProfile: (ProfileData) -> Void
    var onUpdateDiscovery: ([String: String]) -> Void
    var onConfirm: () -> Void
    var onOpenHushhTech: () -> Void

    @State private var editingField: SummaryField?
    @State private var expandedSections: Set<SummarySectionKind> = []

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 18) {
                    SummaryHeroSection(
                        name: profile.fullName,
                        netWorth: discovery["net_worth"] ?? "",
                        investorIdentity: discovery["investor_identity"] ?? "",
                        capitalIntent: discovery["capital_intent"] ?? "",
                        onJump: { kind in
                            withAnimation(.easeInOut(duration: 0.4)) {
                                proxy.scrollTo(kind, anchor: .top)
                            }
                        }
                    )

                    SummaryHighlightsRow(highlights: summaryHighlights())

                    SummaryHushhTechNote()

                    VStack(spacing: 14) {
                        ForEach(SummarySectionKind.allCases, id: \.self) { kind in
                            SummaryAccordionSection(
                                title: kind.title,
                                summary: sectionSummary(for: kind),
                                confidence: sectionConfidence(for: kind),
                                whyText: sectionWhy(for: kind),
                                rows: sectionRows(for: kind),
                                isExpanded: Binding(
                                    get: { expandedSections.contains(kind) },
                                    set: { isExpanded in
                                        if isExpanded {
                                            expandedSections.insert(kind)
                                        } else {
                                            expandedSections.remove(kind)
                                        }
                                    }
                                ),
                                onEdit: { editingField = $0 }
                            )
                            .id(kind)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 140)
            }
            .safeAreaInset(edge: .bottom) {
                SummaryStickyCTA(onConfirm: onConfirm, onOpenHushhTech: onOpenHushhTech)
            }
        }
        .sheet(item: $editingField) { field in
            SummaryFieldEditor(
                field: field,
                currentValue: field.currentValue(profile: profile, discovery: discovery),
                isSavingProfile: isSavingProfile,
                onSave: { newValue in
                    handleFieldSave(field: field, newValue: newValue)
                }
            )
        }
    }

    private func handleFieldSave(field: SummaryField, newValue: String) {
        switch field {
        case .profileName:
            profile.fullName = newValue
            onUpdateProfile(profile)
        case .profilePhone:
            profile.phone = newValue
            onUpdateProfile(profile)
        case .profileEmail:
            profile.email = newValue
            onUpdateProfile(profile)
        default:
            onUpdateDiscovery([field.discoveryKey: newValue])
        }
    }

    private func displayValue(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "—" : value
    }

    private func sectionRows(for kind: SummarySectionKind) -> [SummaryRowData] {
        switch kind {
        case .profile:
            return [
                SummaryRowData(label: "Full name", value: profile.fullName, field: .profileName),
                SummaryRowData(label: "Phone", value: profile.phone, field: .profilePhone),
                SummaryRowData(label: "Email", value: profile.email, field: .profileEmail),
            ]
        case .capitalBase:
            return [
                SummaryRowData(label: "Net worth", value: discovery["net_worth"] ?? "", field: .netWorth),
                SummaryRowData(label: "Asset breakdown", value: discovery["asset_breakdown"] ?? "", field: .assetBreakdown),
            ]
        case .investorStyle:
            return [
                SummaryRowData(label: "Identity", value: discovery["investor_identity"] ?? "", field: .investorIdentity),
                SummaryRowData(label: "Capital intent", value: discovery["capital_intent"] ?? "", field: .capitalIntent),
            ]
        case .allocation:
            return [
                SummaryRowData(label: "Comfort (12–24m)", value: discovery["allocation_comfort_12_24m"] ?? "", field: .allocationComfort),
                SummaryRowData(label: "Mechanics depth", value: discovery["allocation_mechanics_depth"] ?? "", field: .allocationMechanics),
                SummaryRowData(label: "Fund fit", value: discovery["fund_fit_alignment"] ?? "", field: .fundFitAlignment),
            ]
        case .experience:
            return [
                SummaryRowData(label: "Proud decision", value: discovery["experience_proud"] ?? "", field: .experienceProud),
                SummaryRowData(label: "Regret decision", value: discovery["experience_regret"] ?? "", field: .experienceRegret),
            ]
        case .location:
            return [
                SummaryRowData(label: "Country", value: discovery["contact_country"] ?? "", field: .contactCountry),
            ]
        }
    }

    private func sectionSummary(for kind: SummarySectionKind) -> String {
        switch kind {
        case .profile:
            let name = displayValue(profile.fullName)
            let email = displayValue(profile.email)
            return "\(name) • \(email)"
        case .capitalBase:
            let net = displayValue(discovery["net_worth"] ?? "")
            let mix = displayValue(discovery["asset_breakdown"] ?? "")
            return "\(net) • \(mix)"
        case .investorStyle:
            let identity = displayValue(discovery["investor_identity"] ?? "")
            let intent = displayValue(discovery["capital_intent"] ?? "")
            return "\(identity) • \(intent)"
        case .allocation:
            let comfort = displayValue(discovery["allocation_comfort_12_24m"] ?? "")
            let fit = displayValue(discovery["fund_fit_alignment"] ?? "")
            return "\(comfort) • \(fit)"
        case .experience:
            let proud = displayValue(discovery["experience_proud"] ?? "")
            let regret = displayValue(discovery["experience_regret"] ?? "")
            return "\(proud) • \(regret)"
        case .location:
            return displayValue(discovery["contact_country"] ?? "")
        }
    }

    private func sectionConfidence(for kind: SummarySectionKind) -> String {
        let filled = sectionRows(for: kind)
            .filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count
        let total = sectionRows(for: kind).count
        return filled == total ? "High" : "Medium"
    }

    private func sectionWhy(for kind: SummarySectionKind) -> String {
        sectionSummary(for: kind)
    }

    private func summaryHighlights() -> [SummaryHighlight] {
        let highlights = [
            SummaryHighlight(label: "Capital scale", value: compactHighlightValue(discovery["net_worth"] ?? "")),
            SummaryHighlight(label: "Risk posture", value: compactHighlightValue(discovery["investor_identity"] ?? "")),
            SummaryHighlight(label: "Time horizon", value: compactHighlightValue(discovery["capital_intent"] ?? "")),
            SummaryHighlight(label: "Allocation comfort", value: compactHighlightValue(discovery["allocation_comfort_12_24m"] ?? "")),
            SummaryHighlight(label: "Country", value: compactHighlightValue(discovery["contact_country"] ?? "")),
        ]
        return highlights.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func compactHighlightValue(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let words = trimmed.split(separator: " ")
        if words.count > 4 {
            return words.prefix(4).joined(separator: " ")
        }
        if trimmed.count > 28 {
            let prefix = trimmed.prefix(28)
            return "\(prefix)..."
        }
        return trimmed
    }
}
