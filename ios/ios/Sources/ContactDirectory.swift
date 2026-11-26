import Contacts
import Combine
import Foundation

@MainActor
final class ContactDirectory: ObservableObject {
    static let shared = ContactDirectory()
    @Published private(set) var names: [String: String] = [:]
    func name(for number: String) -> String? { names[ContactNames.key(number)] }
    func refresh() async {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status != .notDetermined, status != .denied, status != .restricted else { names = [:]; return }
        let result = await Task.detached(priority: .utility) {
            var values: [String: String] = [:]
            let keys = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName), CNContactPhoneNumbersKey as CNKeyDescriptor]
            try? CNContactStore().enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, _ in
                guard let name = CNContactFormatter.string(from: contact, style: .fullName), !name.isEmpty else { return }
                for phone in contact.phoneNumbers {
                    let key = ContactNames.key(phone.value.stringValue)
                    if !key.isEmpty && values[key] == nil { values[key] = name }
                }
            }
            return values
        }.value
        if !Task.isCancelled { names = result }
    }
}
