import SwiftUI

struct SIMStatusSections: View {
    @EnvironmentObject var model: PhoneModel
    @Environment(\.dynamicTypeSize) private var dynamicType
    @ObservedObject var voice: VoiceService
    @ObservedObject private var push = RemotePush.shared
    let now: Date

    private var state: SIMStatusState {
        model.simStatus.matches(origin: model.settings.apiURL, deviceID: model.settings.deviceID) ? model.simStatus : SIMStatusState()
    }
    private var fresh: Bool { state.isFresh(at: now) }
    private var stateTint: Color {
        guard model.authenticated, state.checkedAt != nil || state.error != nil else { return .secondary }
        return fresh && state.snapshot?.online == true ? .green : .orange
    }

    var body: some View {
        Section {
            overview
            if model.authenticated {
                if let card = state.snapshot {
                    networkMetrics(card)
                    statusRow("网络注册", icon: "network", value: card.registrationText,
                              tint: fresh ? healthColor(card.registered) : .secondary)
                }
                if let error = state.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                }
                if model.settings.unified == true {
                    statusRow("来电与信息推送", icon: "bell.badge", value: push.status,
                              tint: push.providerReady ? .primary : .secondary)
                    pushDeliveryRow("信息推送", kind: "alert")
                    pushDeliveryRow("来电推送", kind: "voip")
                }
                NavigationLink {
                    TimelineView(.periodic(from: .now, by: 5)) { context in
                        Form { deviceDetails(at: context.date) }
                    }
                    .navigationTitle("设备详情")
                    .navigationBarTitleDisplayMode(.inline)
                    .refreshable { await model.refreshSIMStatus() }
                } label: {
                    Label("设备详情", systemImage: "info.circle")
                }
            }
        } header: {
            Text("SIM 卡状态")
        } footer: {
            if !model.authenticated {
                Text("登录后可查看 SIM 卡和电话服务状态。")
            } else if let checkedAt = state.checkedAt {
                Text(fresh ? "上次更新 \(checkedAt.formatted(date: .omitted, time: .standard))" :
                        "上次读取 \(checkedAt.formatted(date: .abbreviated, time: .standard))，状态可能已变化。")
            }
        }

    }

    @ViewBuilder
    private func pushDeliveryRow(_ title: String, kind: String) -> some View {
        if let delivery = push.delivery[kind] {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.medium))
                if let accepted = delivery.lastAccepted {
                    Text("Apple 最近接收 \(accepted.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let failed = delivery.lastFailed, let reason = delivery.lastError {
                    Text("上次失败 \(failed.formatted(date: .abbreviated, time: .shortened)) · \(reason)")
                        .font(.caption).foregroundStyle(delivery.needsAttention ? Color.orange : .secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func deviceDetails(at date: Date) -> some View {
        if model.authenticated, let card = state.snapshot {
            let fresh = state.isFresh(at: date)
            Section("设备与连接") {
                healthRow("模块连接", icon: "simcard", state: card.present, yes: "已连接", no: "未连接", fresh: fresh)
                healthRow("控制通道", icon: "link", state: card.controlOnline, yes: "在线", no: "离线", fresh: fresh)
                healthRow("设备服务", icon: "checkmark.shield", state: card.healthy, yes: "正常", no: "异常", fresh: fresh)
                statusRow("手机电话账号", icon: "phone", value: voice.registered ? "已连接" : "未连接",
                          tint: healthColor(voice.registered))
            }
            Section {
                statusRow("数据开关", icon: "switch.2", value: flag(card.dataEnabled, yes: "已开启", no: "已关闭"),
                          tint: card.dataEnabled == true && fresh ? .green : .secondary)
                statusRow("数据连接", icon: "arrow.up.arrow.down", value: flag(card.dataConnected, yes: "已连接", no: "未连接"),
                          tint: card.dataConnected == true && fresh ? .green : .secondary)
            } header: { Text("移动数据") } footer: {
                if !fresh { Text("设备与移动数据为上次读取的状态。") }
            }
        } else {
            ContentUnavailableView("暂无设备状态", systemImage: "simcard", description: Text("下拉刷新后再查看。"))
        }
    }

    private var overview: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "simcard.fill")
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(stateTint)
                .frame(width: 52, height: 52)
                .background(stateTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 15))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                if let card = state.snapshot {
                    Text(card.operatorName == "未知" ? "运营商未知" : card.operatorName).font(.title3.weight(.semibold))
                }
                Text(title).font(state.snapshot == nil ? .headline : .subheadline).foregroundStyle(stateTint)
                Text(model.settings.deviceID).font(.caption.monospaced()).foregroundStyle(.secondary)
            }.accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            if model.authenticated {
                Button {
                    Task { await model.refreshSIMStatus() }
                } label: {
                    Group {
                        if model.refreshingSIM { ProgressView() }
                        else { Image(systemName: "arrow.clockwise").font(.system(size: 18, weight: .medium)) }
                    }.frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(.borderless)
                    .disabled(model.refreshingSIM)
                    .accessibilityLabel(model.refreshingSIM ? "正在刷新 SIM 状态" : "刷新 SIM 状态")
            }
        }.padding(.vertical, 6)
    }

    private func networkMetrics(_ card: SIMSnapshot) -> some View {
        let signal = card.signal.map { "\($0) dBm" } ?? "未知"
        return Group {
            if dynamicType.isAccessibilitySize {
                VStack(spacing: 10) {
                    metric("网络类型", icon: "antenna.radiowaves.left.and.right", value: card.network)
                    metric("信号强度", icon: "cellularbars", value: signal)
                }
            } else {
                HStack(spacing: 10) {
                    metric("网络类型", icon: "antenna.radiowaves.left.and.right", value: card.network)
                    metric("信号强度", icon: "cellularbars", value: signal)
                }
            }
        }.padding(.vertical, 3)
    }

    private func metric(_ title: String, icon: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit())
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
            .accessibilityElement(children: .combine)
    }

    private func statusRow(_ title: String, icon: String, value: String, tint: Color) -> some View {
        LabeledContent {
            Text(value).foregroundStyle(tint).multilineTextAlignment(.trailing)
        } label: {
            Label(title, systemImage: icon)
        }
    }

    private func healthRow(_ title: String, icon: String, state: Bool?, yes: String, no: String, fresh: Bool) -> some View {
        statusRow(title, icon: icon, value: flag(state, yes: yes, no: no), tint: fresh ? healthColor(state) : .secondary)
    }
    private func healthColor(_ state: Bool?) -> Color {
        state.map { $0 ? .green : .orange } ?? .secondary
    }
    private func flag(_ value: Bool?, yes: String, no: String) -> String {
        value.map { $0 ? yes : no } ?? "未知"
    }
    private var title: String {
        if !model.authenticated { return "尚未登录" }
        if state.error != nil { return "暂时无法获取状态" }
        if state.checkedAt == nil { return "等待获取状态" }
        if !fresh { return "状态待刷新" }
        return state.snapshot?.title ?? "未发现指定设备"
    }
}
