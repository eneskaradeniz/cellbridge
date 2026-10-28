import Contacts
import Foundation

/// Reads the iPhone's address book (read only; nothing is sent anywhere). Contacts without a phone number are left out:
/// the app can only call or text a number.
@MainActor
final class ContactStoreProvider {
    private let store = CNContactStore()

    var status: CNAuthorizationStatus { CNContactStore.authorizationStatus(for: .contacts) }

    var isAuthorized: Bool {
        if #available(iOS 18.0, *) { return status == .authorized || status == .limited }
        return status == .authorized
    }

    func requestAccess() async -> Bool {
        (try? await store.requestAccess(for: .contacts)) ?? false
    }

    func load() async -> [Contact] {
        let store = self.store
        return await Task.detached {
            let keys: [CNKeyDescriptor] = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName), CNContactPhoneNumbersKey as CNKeyDescriptor]
            let request = CNContactFetchRequest(keysToFetch: keys)
            var contacts: [Contact] = []
            try? store.enumerateContacts(with: request) { contact, _ in
                let numbers = contact.phoneNumbers.map {
                    LabeledNumber(label: $0.label.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) } ?? "", value: $0.value.stringValue)
                }
                let name = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
                if !numbers.isEmpty && !name.isEmpty { contacts.append(Contact(id: contact.identifier, name: name, numbers: numbers)) }
            }
            return contacts
        }.value
    }
}
