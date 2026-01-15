import Foundation

enum SummarySectionKind: CaseIterable {
    case profile
    case capitalBase
    case investorStyle
    case allocation
    case experience
    case location

    var title: String {
        switch self {
        case .profile: return "Profile"
        case .capitalBase: return "Capital Base"
        case .investorStyle: return "Investor Style"
        case .allocation: return "Allocation"
        case .experience: return "Experience"
        case .location: return "Location"
        }
    }
}

struct SummaryHighlight: Identifiable {
    let id = UUID()
    var label: String
    var value: String
}

struct SummaryRowData: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    let field: SummaryField
}

enum SummaryField: String, Identifiable {
    case profileName
    case profilePhone
    case profileEmail
    case netWorth
    case assetBreakdown
    case investorIdentity
    case capitalIntent
    case allocationComfort
    case allocationMechanics
    case fundFitAlignment
    case experienceProud
    case experienceRegret
    case contactCountry

    var id: String { rawValue }

    var title: String {
        switch self {
        case .profileName: return "Full name"
        case .profilePhone: return "Phone"
        case .profileEmail: return "Email"
        case .netWorth: return "Net worth"
        case .assetBreakdown: return "Asset breakdown"
        case .investorIdentity: return "Investor identity"
        case .capitalIntent: return "Capital intent"
        case .allocationComfort: return "Allocation comfort (12-24m)"
        case .allocationMechanics: return "Allocation mechanics depth"
        case .fundFitAlignment: return "Fund fit alignment"
        case .experienceProud: return "Proud decision"
        case .experienceRegret: return "Regret decision"
        case .contactCountry: return "Country"
        }
    }

    var discoveryKey: String {
        switch self {
        case .netWorth: return "net_worth"
        case .assetBreakdown: return "asset_breakdown"
        case .investorIdentity: return "investor_identity"
        case .capitalIntent: return "capital_intent"
        case .allocationComfort: return "allocation_comfort_12_24m"
        case .allocationMechanics: return "allocation_mechanics_depth"
        case .fundFitAlignment: return "fund_fit_alignment"
        case .experienceProud: return "experience_proud"
        case .experienceRegret: return "experience_regret"
        case .contactCountry: return "contact_country"
        case .profileName, .profilePhone, .profileEmail:
            return ""
        }
    }

    func currentValue(profile: ProfileData, discovery: [String: String]) -> String {
        switch self {
        case .profileName: return profile.fullName
        case .profilePhone: return profile.phone
        case .profileEmail: return profile.email
        default: return discovery[discoveryKey] ?? ""
        }
    }
}
