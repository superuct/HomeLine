import SwiftUI
import UIKit

struct CopyablePhoneNumber: View {
    let number: String
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(number).font(.title3)
            Text(copied ? "已复制" : "长按号码复制").font(.caption)
                .foregroundStyle(copied ? Color.green : Color.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0.45, perform: copy)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("copy-call-number")
            .accessibilityHint("长按复制号码")
            .accessibilityAction(named: "复制号码", copy)
            .task(id: copied) {
                guard copied else { return }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                copied = false
            }
    }
    private func copy() {
        guard !number.isEmpty else { return }
        UIPasteboard.general.string = number
        copied = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
