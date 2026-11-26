import SwiftUI

enum InboxFilter: String, CaseIterable { case all = "全部", unread = "未读", codes = "验证码" }

struct VerificationInbox: View {
    @EnvironmentObject private var model: PhoneModel
    @ObservedObject private var directory = ContactDirectory.shared
    let search: String
    private var scan: SMSScanResult? { model.verificationScan }
    @State private var excluded = Set<String>()
    private var issue: String? { model.verificationError }
    @State private var revision = 0
    @State private var pending: SMSDeletion?
    private var visible: [SMSItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return (scan?.items ?? []).filter { query.isEmpty || $0.contact.peer.localizedCaseInsensitiveContains(query)
            || directory.name(for: $0.contact.peer)?.localizedCaseInsensitiveContains(query) == true
            || $0.message.text.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        List {
            if let issue { Text(issue).foregroundStyle(.red) }
            if let scan {
                let selected = visible.filter { !excluded.contains($0.id) }
                if scan.limited { Text("已达到 NAS 的查询范围，仅显示已检索到的信息。").font(.footnote) }
                if visible.isEmpty {
                    ContentUnavailableView("没有匹配的验证码", systemImage: "number.square")
                } else {
                    Button(role: .destructive) {
                        pending = SMSDeletion(items: selected, scope: model.smsScope)
                    } label: { Label("删除所选验证码（\(selected.count)）", systemImage: "trash") }
                    .disabled(selected.isEmpty || model.deletingSMS)
                    ForEach(visible) { item in
                        Button {
                            if !excluded.insert(item.id).inserted { excluded.remove(item.id) }
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: excluded.contains(item.id) ? "circle" : "checkmark.circle.fill").foregroundStyle(.blue)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(directory.name(for: item.contact.peer) ?? item.contact.peer).font(.headline)
                                    Text(item.message.text).font(.subheadline)
                                    Text(displayTime(item.message.timestamp)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.buttonStyle(.plain).accessibilityAddTraits(excluded.contains(item.id) ? [] : .isSelected)
                    }
                }
            } else if issue == nil { ProgressView("正在查找验证码…") }
            if model.verificationLoading && scan != nil { ProgressView("正在更新验证码…") }
            if model.deletingSMS { ProgressView("正在删除…") }
            else { Button("重新查找", systemImage: "arrow.clockwise") { revision += 1 } }
        }
        .refreshable { revision += 1 }
        .task(id: revision) {
            excluded = []
            model.preloadVerification(force: revision > 0)
        }
        .smsDeleteDialog($pending) { items in
            if let error = await model.deleteMessages(items.items, scope: items.scope) { model.error = error }
            revision += 1
        }
    }
}

extension View {
    func smsDeleteDialog(_ selection: Binding<SMSDeletion?>, perform: @escaping (SMSDeletion) async -> Void) -> some View {
        confirmationDialog("从 NAS 删除 \(selection.wrappedValue?.items.count ?? 0) 条信息？",
            isPresented: Binding(get: { selection.wrappedValue != nil }, set: { if !$0 { selection.wrappedValue = nil } }),
            titleVisibility: .visible, presenting: selection.wrappedValue) { snapshot in
                Button("删除 \(snapshot.items.count) 条信息", role: .destructive) { Task { await perform(snapshot) } }
                Button("取消", role: .cancel) {}
            } message: { _ in Text("删除后无法恢复。") }
    }
}
