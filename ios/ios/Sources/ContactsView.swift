import Contacts
import SwiftUI
import UIKit

private struct PhoneContact: Identifiable, Sendable {
    struct Number: Identifiable, Sendable {
        let id: String
        let label: String
        let display: String
        var usable: String? {
            let compact = display.components(separatedBy: CharacterSet(charactersIn: " ()- ‑（）")).joined()
            return compact.range(of: #"^\+?[0-9]{2,20}$"#, options: .regularExpression) == nil ? nil : compact
        }
        var dialable: String? {
            guard let usable else { return nil }
            if usable.hasPrefix("+86") { return String(usable.dropFirst(3)) }
            return usable.hasPrefix("+") ? "00" + usable.dropFirst() : usable
        }
    }
    let id: String
    let name: String
    let numbers: [Number]
    let sortKey: String
    var section: String { ContactAlphabet.section(for: sortKey) }

    static func read() throws -> [PhoneContact] {
        let keys: [CNKeyDescriptor] = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName), CNContactPhoneNumbersKey as CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .userDefault
        var rows: [PhoneContact] = []
        try CNContactStore().enumerateContacts(with: request) { item, _ in
            let numbers = item.phoneNumbers.map {
                Number(id: $0.identifier, label: $0.label.map { CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: $0) } ?? "电话",
                       display: $0.value.stringValue)
            }
            guard let first = numbers.first else { return }
            let name = CNContactFormatter.string(from: item, style: .fullName) ?? first.display
            rows.append(PhoneContact(id: item.identifier, name: name, numbers: numbers, sortKey: ContactAlphabet.sortKey(name)))
        }
        return rows
    }
}

struct PhoneContactsView: View {
    @ObservedObject var voice: VoiceService
    @Environment(\.scenePhase) private var phase
    @State private var status = CNContactStore.authorizationStatus(for: .contacts)
    @State private var contacts: [PhoneContact] = []
    @State private var search = ""
    @State private var revision = 0
    @State private var loading = true
    @State private var error: String?
    #if DEBUG
    private var isPreview: Bool { ProcessInfo.processInfo.environment["HOMELINE_UI_PREVIEW"] == "contacts" }
    #else
    private var isPreview: Bool { false }
    #endif

    var body: some View {
        Group {
            if status == .notDetermined || status == .denied || status == .restricted {
                ContentUnavailableView {
                    Label("使用 iPhone 通讯录", systemImage: "person.crop.circle")
                } description: { Text("选择联系人，通过随行电话拨号或发送信息。") } actions: {
                    if status == .notDetermined {
                        Button("允许访问通讯录") { Task {
                            do { _ = try await CNContactStore().requestAccess(for: .contacts) }
                            catch { self.error = error.localizedDescription }
                            revision += 1
                        } }.buttonStyle(.borderedProminent)
                    } else if status == .denied {
                        Link("打开系统设置", destination: URL(string: UIApplication.openSettingsURLString)!)
                    }
                }
            } else if loading && contacts.isEmpty {
                ProgressView("正在读取联系人…")
            } else {
                let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
                let rows = contacts.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.numbers.contains { $0.display.contains(query) || $0.usable?.contains(query) == true } }
                indexedList(rows).overlay {
                    if rows.isEmpty { ContentUnavailableView(query.isEmpty ? "没有可显示的联系人" : "没有匹配的联系人",
                        systemImage: "person.2", description: Text(error ?? (query.isEmpty ? "通讯录中带电话号码的联系人会显示在这里。" : "试试其他姓名或号码。"))) }
                }
            }
        }
        .navigationTitle("联系人").searchable(text: $search, prompt: "姓名或电话号码")
        .onChange(of: phase) { _, value in if value == .active { revision += 1 } }
        .onReceive(NotificationCenter.default.publisher(for: .CNContactStoreDidChange)) { _ in revision += 1 }
        .task(id: revision) {
            #if DEBUG
            if isPreview {
                contacts = ["Alice", "Bob", "陈先生", "David", "Emma", "方女士", "郭先生", "韩女士", "李四", "王女士", "张三", "10086"].enumerated().map { index, name in
                    PhoneContact(id: "preview-\(index)", name: name, numbers: [], sortKey: ContactAlphabet.sortKey(name))
                }
                status = .authorized; loading = false
                return
            }
            #endif
            status = CNContactStore.authorizationStatus(for: .contacts)
            guard status != .denied, status != .restricted, status != .notDetermined else { contacts = []; return }
            loading = true
            do {
                let result = try await Task.detached(priority: .userInitiated) { try PhoneContact.read() }.value
                guard !Task.isCancelled else { return }
                contacts = result; error = nil
                await ContactDirectory.shared.refresh()
            } catch {
                guard !Task.isCancelled else { return }
                contacts = []; self.error = error.localizedDescription
            }
            loading = false
        }
    }

    private func indexedList(_ rows: [PhoneContact]) -> some View {
        let groups = Dictionary(grouping: rows, by: \.section)
        let letters = groups.keys.sorted { $0 == "#" ? false : ($1 == "#" || $0 < $1) }
        return ScrollViewReader { reader in
            List {
                ForEach(letters, id: \.self) { letter in
                    Section(letter) {
                        ForEach((groups[letter] ?? []).sorted {
                            $0.sortKey == $1.sortKey ? $0.id < $1.id : $0.sortKey < $1.sortKey
                        }) { person in
                            NavigationLink { ContactDetail(person: person, voice: voice) } label: {
                                HStack(spacing: 12) {
                                    Text(String(person.name.prefix(1))).font(.headline).foregroundStyle(.indigo)
                                        .frame(width: 38, height: 38).background(.indigo.opacity(0.1), in: Circle())
                                    Text(person.name).font(.body.weight(.medium))
                                }.padding(.vertical, 3)
                            }
                        }
                    }.id(letter).modifier(ContactSectionIndex(letter: letter))
                }
            }.listStyle(.plain)
                .overlay(alignment: .trailing) {
                    if #unavailable(iOS 26.0), !letters.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(letters, id: \.self) { letter in
                                Button { reader.scrollTo(letter, anchor: .top) } label: {
                                    Text(letter).font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 16)
                                }.accessibilityLabel("跳到 \(letter) 组")
                            }
                        }.padding(.trailing, 2)
                    }
                }
        }
    }
}

private struct ContactSectionIndex: ViewModifier {
    let letter: String
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) { content.sectionIndexLabel(letter) }
        else { content }
    }
}

private struct ContactDetail: View {
    let person: PhoneContact
    @ObservedObject var voice: VoiceService
    @EnvironmentObject var model: PhoneModel
    @State private var recipient: PhoneContact.Number?
    var body: some View {
        List {
            ForEach(person.numbers) { phone in
                Section(phone.label) {
                    Text(phone.display).font(.title3).textSelection(.enabled)
                    Button { if let number = phone.dialable { Task { await voice.dial(number) } } } label: {
                        Label("呼叫", systemImage: "phone.fill")
                    }.disabled(phone.dialable == nil || !voice.registered || voice.inCall)
                    Button { recipient = phone } label: { Label("发信息", systemImage: "message.fill") }
                        .disabled(phone.usable == nil || !model.authenticated)
                }
            }
            if !voice.registered { Text(voice.status).foregroundStyle(.secondary) }
            if let issue = voice.lastCallError { Text(issue).foregroundStyle(.secondary) }
        }.navigationTitle(person.name)
        .sheet(item: $recipient) { phone in NavigationStack { ComposeView(recipient: phone.usable ?? "") } }
    }
}
