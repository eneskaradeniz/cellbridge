import Foundation

struct LabeledNumber: Equatable, Hashable {
    let label: String
    let value: String
}

struct Contact: Identifiable, Equatable {
    let id: String
    let name: String
    let numbers: [LabeledNumber]
}

/// The phone's contacts, as far as the app needs them: find a name by number and search. Pure: reading the address
/// book is ContactStoreProvider's job.
struct ContactBook {
    private(set) var contacts: [Contact]
    private let namesByNumber: [String: String]

    init(contacts: [Contact] = []) {
        self.contacts = contacts
        var names: [String: String] = [:]
        for contact in contacts {
            for number in contact.numbers {
                names[MessageStore.key(for: number.value)] = names[MessageStore.key(for: number.value)] ?? contact.name
            }
        }
        namesByNumber = names
    }

    /// "+90 555 111 22 33" and "0555 111 22 33" are the same person (the last ten digits decide). A sender that is not
    /// a number at all, like a bank's name, never matches a contact by accident.
    func name(for number: String) -> String? {
        guard number.contains(where: \.isNumber) else { return nil }
        return namesByNumber[MessageStore.key(for: number)]
    }

    /// Matches names without regard to case or accents, and numbers by the digits typed (three or more).
    func search(_ query: String) -> [Contact] {
        let needle = Self.fold(query)
        guard !needle.isEmpty else { return contacts }
        let digits = query.filter(\.isNumber)
        return contacts.filter { contact in
            Self.fold(contact.name).contains(needle)
                || (digits.count >= 3 && contact.numbers.contains { $0.value.filter(\.isNumber).contains(digits) })
        }
    }

    /// Grouped by first letter, A to Z; names that do not start with a letter go last under "#".
    func sections(of list: [Contact]) -> [(letter: String, contacts: [Contact])] {
        let grouped = Dictionary(grouping: list) { contact -> String in
            guard let first = Self.fold(contact.name).first, first.isLetter else { return "#" }
            return String(first).uppercased()
        }
        return grouped.keys.sorted { lhs, rhs in
            if lhs == "#" { return false }
            if rhs == "#" { return true }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }.map { letter in
            (letter, grouped[letter, default: []].sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }
    }

    /// Case and accents out, the same way on every device: the dotless Turkish ı has no accent to strip, so it is mapped
    /// by hand, and the fixed locale keeps "I" from becoming "ı" on a phone set to Turkish.
    private static func fold(_ text: String) -> String {
        text.replacingOccurrences(of: "ı", with: "i")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
