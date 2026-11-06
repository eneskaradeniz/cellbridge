import Contacts

/// A contact's name for a phone number, for the extensions (the app has its own book). Nil unless the app may read contacts.
enum ContactName {
    static func lookup(_ number: String) -> String? {
        guard number.contains(where: \.isNumber), CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return nil }
        let contacts = try? CNContactStore().unifiedContacts(
            matching: CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: number)),
            keysToFetch: [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]
        )
        return contacts?.first.flatMap { CNContactFormatter.string(from: $0, style: .fullName) }
    }
}
