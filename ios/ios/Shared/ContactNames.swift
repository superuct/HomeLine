import Contacts

enum ContactNames {
    static func key(_ number: String) -> String {
        var value = number.filter { $0.isASCII && ($0.isNumber || $0 == "+") }
        if value.hasPrefix("0086") { value = String(value.dropFirst(4)) }
        else if value.hasPrefix("+86") { value = String(value.dropFirst(3)) }
        return value
    }

    static func name(for number: String) -> String? {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status != .notDetermined, status != .denied, status != .restricted else { return nil }
        let keys = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName), CNContactPhoneNumbersKey as CNKeyDescriptor]
        let predicate = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: number))
        guard let contacts = try? CNContactStore().unifiedContacts(matching: predicate, keysToFetch: keys) else { return nil }
        return contacts.first(where: { $0.phoneNumbers.contains { key($0.value.stringValue) == key(number) } })
            .flatMap { CNContactFormatter.string(from: $0, style: .fullName) }
    }

    static func callLabel(_ number: String) -> String? {
        name(for: number).map { $0 + " · " + number }
    }
}
