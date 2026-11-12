import Contacts

/// Which kind of labeled field a label applies to, and the system labels offered for it.
nonisolated enum LabeledFieldKind: Sendable {
    case phone, email, url, address, relation

    var suggestedLabels: [String] {
        switch self {
        case .phone:
            [CNLabelPhoneNumberMobile, CNLabelPhoneNumberiPhone, CNLabelHome, CNLabelWork,
             CNLabelPhoneNumberMain, CNLabelPhoneNumberHomeFax, CNLabelPhoneNumberWorkFax,
             CNLabelPhoneNumberPager, CNLabelOther]
        case .email:
            [CNLabelHome, CNLabelWork, CNLabelSchool, CNLabelEmailiCloud, CNLabelOther]
        case .url:
            [CNLabelURLAddressHomePage, CNLabelHome, CNLabelWork, CNLabelSchool, CNLabelOther]
        case .address:
            [CNLabelHome, CNLabelWork, CNLabelSchool, CNLabelOther]
        case .relation:
            [CNLabelContactRelationMother, CNLabelContactRelationFather, CNLabelContactRelationParent,
             CNLabelContactRelationBrother, CNLabelContactRelationSister, CNLabelContactRelationSibling,
             CNLabelContactRelationChild, CNLabelContactRelationSon, CNLabelContactRelationDaughter,
             CNLabelContactRelationSpouse, CNLabelContactRelationPartner, CNLabelContactRelationFriend,
             CNLabelContactRelationAssistant, CNLabelContactRelationManager, CNLabelOther]
        }
    }

    /// Default label for a newly added field, picked to avoid repeating labels already in use.
    func defaultLabel(excluding used: [String?]) -> String {
        let preferred: [String] = switch self {
        case .phone: [CNLabelPhoneNumberMobile, CNLabelHome, CNLabelWork, CNLabelOther]
        case .email, .url, .address: [CNLabelHome, CNLabelWork, CNLabelOther]
        case .relation: [CNLabelContactRelationFriend, CNLabelOther]
        }
        return preferred.first { !used.contains($0) } ?? CNLabelOther
    }
}

nonisolated enum ContactLabel {
    /// Human-readable form of a system label (e.g. `_$!<Mobile>!$_` → "mobile"); custom labels pass through.
    static func localized(_ label: String?) -> String {
        guard let label, !label.isEmpty else { return String(localized: "other") }
        return CNLabeledValue<NSString>.localizedString(forLabel: label)
    }
}
