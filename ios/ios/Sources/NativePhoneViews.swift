import AVFoundation
import SwiftUI
import QuickLook

struct NativeListFilter<Value>: View where Value: RawRepresentable & CaseIterable & Hashable, Value.RawValue == String {
    let title: String
    @Binding var selection: Value

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(Array(Value.allCases), id: \.self) { option in
                Text(option.rawValue).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .frame(idealWidth: Value.allCases.count == 2 ? 156 : 184)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityIdentifier(title)
    }
}

struct ContactAvatar: View {
    var size: CGFloat = 48
    var body: some View {
        Image(systemName: "person.fill").font(.system(size: size * 0.5))
            .foregroundStyle(.white).frame(width: size, height: size)
            .background(LinearGradient(colors: [Color(.systemGray3), Color(.systemGray)], startPoint: .top, endPoint: .bottom), in: Circle())
            .accessibilityHidden(true)
    }
}

func conversationDate(_ value: String) -> String {
    guard let date = smsDate(value) else { return "" }
    return compactPhoneDate(date)
}

func compactPhoneDate(_ date: Date) -> String {
    if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
    if Calendar.current.isDateInYesterday(date) { return "昨天" }
    return date.formatted(date: .numeric, time: .omitted)
}

struct MessageComposer: View {
    @Binding var text: String
    var sending: Bool
    var disabled = false
    var send: () -> Void

    private var canSend: Bool {
        !sending && !disabled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("信息", text: $text, axis: .vertical).lineLimit(1...5)
                .padding(.leading, 14).padding(.vertical, 10)
                .accessibilityLabel("信息内容")
                .accessibilityIdentifier("message-composer")
            Button(action: send) {
                Image(systemName: "arrow.up").font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white).frame(width: 30, height: 30)
                    .background(canSend ? Color.green : Color(.systemGray3), in: Circle())
                    .padding(5)
            }.disabled(!canSend)
                .accessibilityLabel("发送信息")
        }
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(.separator), lineWidth: 0.5))
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
}

struct MessageSendIssue: View {
    let message: String
    var unconfirmedText: String?

    var body: some View {
        VStack(spacing: 4) {
            Text(message).font(.footnote).foregroundStyle(.red)
            if let unconfirmedText {
                Button("复制未确认的信息") { UIPasteboard.general.string = unconfirmedText }
                    .font(.footnote)
            }
        }
    }
}

struct MessageSendingBubble: View {
    let text: String
    var submitted = false
    var body: some View {
        HStack {
            Spacer(minLength: 56)
            VStack(alignment: .trailing, spacing: 6) {
                Text(text).font(.body).padding(.horizontal, 14).padding(.vertical, 10)
                    .foregroundStyle(.white).background(.green.opacity(0.85), in: RoundedRectangle(cornerRadius: 20))
                HStack(spacing: 5) {
                    Text(submitted ? "已提交" : "正在发送…").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }.accessibilityElement(children: .combine)
            .accessibilityIdentifier("message-sending")
    }
}

struct PhoneKeypad: View {
    var dark = false
    var press: (String) -> Void
    private let digits = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "0", "#"]
    private let letters = ["", "ABC", "DEF", "GHI", "JKL", "MNO", "PQRS", "TUV", "WXYZ", "", "+", ""]
    @ViewBuilder var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 8) { keys }
        } else { keys }
    }
    private var keys: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 22), count: 3), spacing: 14) {
            ForEach(digits.indices, id: \.self) { index in
                let digit = digits[index]
                let key = Button { press(digit) } label: {
                    VStack(spacing: 0) {
                        Text(digit).font(.system(size: 34, weight: .regular))
                        Text(letters[index].isEmpty ? " " : letters[index]).font(.system(size: 10, weight: .semibold)).tracking(2)
                    }
                    .frame(width: 80, height: 80)
                    .modifier(DialGlassSurface(dark: dark))
                }
                .buttonStyle(DialKeyPressStyle()).foregroundStyle(dark ? .white : .primary)
                .accessibilityLabel(digit).accessibilityHint(digit == "0" && !dark ? "长按输入加号" : "")
                if digit == "0" && !dark {
                    key.contextMenu { Button("输入 +") { press("+") } }
                } else { key }
            }
        }.frame(maxWidth: 320)
    }
}

private struct DialGlassSurface: ViewModifier {
    var dark = false
    var tint: Color? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(tint ?? (dark ? Color(.systemGray) : Color(.systemGray5)), in: Circle())
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(tint).interactive(!reduceMotion), in: Circle())
        } else {
            content.background(.ultraThinMaterial, in: Circle())
                .background((tint ?? .clear).opacity(0.65), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(dark ? 0.2 : 0.55), lineWidth: 0.7))
        }
    }
}

private struct DialKeyPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .opacity(isEnabled ? 1 : 0.35)
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

private struct CallGlassSurface: ViewModifier {
    var selected = false
    var tint: Color? = nil
    var interactive = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var glassTint: Color { tint ?? (selected ? .white.opacity(0.85) : .white.opacity(0.12)) }
    private var edge: some View {
        Circle().strokeBorder(LinearGradient(colors: [.white.opacity(selected ? 0.8 : 0.5), .white.opacity(0.06), .white.opacity(0.25)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            .allowsHitTesting(false)
    }
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(tint ?? (selected ? .white : Color(.systemGray4)), in: Circle())
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(glassTint).interactive(interactive && !reduceMotion), in: Circle())
                .overlay(edge)
        } else {
            content.background(.ultraThinMaterial, in: Circle())
                .background(glassTint, in: Circle()).overlay(edge)
        }
    }
}

struct DialerView: View {
    @ObservedObject var voice: VoiceService
    @ObservedObject private var directory = ContactDirectory.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var number = ""
    @State private var placingCall = false
    private var motion: Animation? { reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82) }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    Spacer(minLength: 16)
                    VStack(spacing: 8) {
                    Text(number.isEmpty ? "输入号码" : number).font(.system(size: number.isEmpty ? 28 : 36, weight: .regular, design: .rounded)).lineLimit(1).minimumScaleFactor(0.45)
                        .foregroundStyle(number.isEmpty ? Color.secondary : Color.primary)
                        .contentTransition(.numericText()).animation(motion, value: number)
                        .frame(maxWidth: .infinity).frame(height: 50).contentShape(Rectangle())
                        .accessibilityLabel(number.isEmpty ? "电话号码，尚未输入" : number)
                        .contextMenu {
                            Button("粘贴号码", systemImage: "doc.on.clipboard") {
                                if let value = UIPasteboard.general.string {
                                    number = String(value.filter { "+0123456789*#".contains($0) }.prefix(32))
                                }
                            }
                        }
                    Text(directory.name(for: number) ?? " ").font(.subheadline).foregroundStyle(.secondary)
                        .frame(height: 22).contentTransition(.opacity).animation(motion, value: number)
                    }.padding(.bottom, 8)
                    if !voice.registered { Text(voice.status).font(.subheadline).foregroundStyle(.secondary) }
                    if let issue = voice.lastCallError {
                        Text(issue).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
                    }
                    PhoneKeypad { digit in if number.count < 32 { number += digit } }
                    HStack(spacing: 22) {
                        Color.clear.frame(width: 80, height: 80)
                        Button {
                            if number.isEmpty { number = voice.history.first(where: { !$0.incoming })?.number ?? "" }
                            else { placingCall = true; Task { await voice.dial(number); placingCall = false } }
                        } label: {
                            Group {
                                if placingCall { ProgressView().tint(.white) }
                                else { Image(systemName: "phone.fill").font(.system(size: 30, weight: .medium)) }
                            }.foregroundStyle(.white)
                                .frame(width: 80, height: 80)
                                .modifier(DialGlassSurface(tint: .green))
                        }.buttonStyle(DialKeyPressStyle())
                            .disabled(!voice.registered || voice.inCall || placingCall).accessibilityLabel("呼叫")
                        Button { if !number.isEmpty { number.removeLast() } } label: {
                            Image(systemName: "delete.left.fill").font(.title2).foregroundStyle(.secondary).frame(width: 80, height: 80)
                        }.buttonStyle(DialKeyPressStyle())
                            .disabled(number.isEmpty).opacity(number.isEmpty ? 0 : 1)
                            .scaleEffect(number.isEmpty && !reduceMotion ? 0.8 : 1).animation(motion, value: number.isEmpty)
                            .accessibilityLabel("删除一位")
                            .highPriorityGesture(LongPressGesture().onEnded { _ in number = "" })
                    }.padding(.top, 2)
                    Spacer(minLength: 28)
                }.frame(maxWidth: .infinity).frame(minHeight: geometry.size.height).padding(.horizontal, 24)
            }.scrollDismissesKeyboard(.interactively)
        }.navigationTitle("拨号键盘").navigationBarTitleDisplayMode(.inline)
            .background(LinearGradient(colors: [Color(.systemBackground), Color(.secondarySystemBackground).opacity(0.5)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
            .sensoryFeedback(.selection, trigger: number)
    }
}

private enum CallHistoryFilter: String, CaseIterable {
    case all = "所有"
    case missed = "未接来电"
}

struct RecentCallsView: View {
    @ObservedObject var voice: VoiceService
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.openURL) private var openURL
    @ObservedObject private var directory = ContactDirectory.shared
    @State private var showDialer = false
    @State private var filter = CallHistoryFilter.all
    @State private var selected: CallRecord?
    @State private var previewURL: URL?
    @State private var confirmDeletion = false
    @State private var systemActionError: String?
    private var records: [CallRecord] { filter == .all ? voice.history : voice.history.filter { $0.incoming && !$0.connected } }
    var body: some View {
        List {
            if records.isEmpty {
                ContentUnavailableView(filter == .missed ? "没有未接来电" : "没有最近通话", systemImage: "phone", description: Text("通过随行电话拨打和接听的记录会显示在这里。"))
            }
            ForEach(records) { record in
                Button { selected = record } label: {
                    HStack(spacing: 12) {
                        Image(systemName: record.incoming ? "phone.arrow.down.left.fill" : "phone.arrow.up.right.fill")
                            .foregroundStyle(.secondary).frame(width: 24)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(directory.name(for: record.number) ?? record.number).font(.headline).foregroundStyle(record.incoming && !record.connected ? Color.red : .primary)
                            Text(record.connected ? "已接通" : (record.incoming ? "未接来电" : "未接通")).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(compactPhoneDate(record.date)).font(.caption).foregroundStyle(.secondary)
                        Image(systemName: "info.circle").foregroundStyle(.blue)
                    }.padding(.horizontal, 16).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).listRowInsets(EdgeInsets()).accessibilityIdentifier("call-record-" + record.number)
            }
        }.listStyle(.plain).navigationTitle("最近通话")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    NativeListFilter(title: "通话筛选", selection: $filter)
                }
            }
            .safeAreaInset(edge: .bottom, alignment: .trailing) {
                Button { showDialer = true } label: {
                    Image(systemName: "circle.grid.3x3.fill").font(.title2).padding(20)
                        .foregroundStyle(.white)
                        .modifier(DialGlassSurface(tint: .blue))
                }.buttonStyle(DialKeyPressStyle())
                    .accessibilityLabel("拨号键盘").padding(.trailing, 20).padding(.bottom, 12)
            }
            .sheet(isPresented: $showDialer) {
                NavigationStack { DialerView(voice: voice).toolbar { Button("完成") { showDialer = false } } }
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible).presentationCornerRadius(32)
            }
            .onChange(of: voice.inCall) { _, active in if active { showDialer = false; selected = nil } }
            .sheet(item: $selected) { record in
                NavigationStack {
                    Form {
                        Section {
                            if let name = directory.name(for: record.number) { Text(name).font(.title2) }
                            CopyablePhoneNumber(number: record.number)
                        }
                        Section("通话时间") {
                            LabeledContent(record.incoming ? "来电时间" : "呼叫时间", value: record.date.formatted(date: .numeric, time: .standard))
                            if record.connected {
                                if let start = record.connectedAt {
                                    LabeledContent("接通时间", value: start.formatted(date: .numeric, time: .standard))
                                }
                                if let end = record.endedAt {
                                    LabeledContent("结束时间", value: end.formatted(date: .numeric, time: .standard))
                                }
                                if let duration = record.durationText { LabeledContent("通话时长", value: duration) }
                                if record.connectedAt == nil || record.endedAt == nil {
                                    Text("这条旧记录未保存完整的通话起止时间。").font(.footnote).foregroundStyle(.secondary)
                                }
                            } else {
                                LabeledContent("状态", value: record.incoming ? "未接来电" : "未接通")
                                if let end = record.endedAt { LabeledContent("结束时间", value: end.formatted(date: .numeric, time: .standard)) }
                            }
                        }
                        Section("联系") {
                            Button { selected = nil; Task { await voice.dial(record.number) } } label: { Label("呼叫", systemImage: "phone.fill") }
                                .disabled(!voice.registered || voice.inCall)
                            Button { openSystem(SystemPhoneActions.phoneURL(record.number)) } label: {
                                Label("系统电话拨打", systemImage: "phone.arrow.up.right")
                            }.disabled(SystemPhoneActions.phoneURL(record.number) == nil)
                            Button { NotificationNavigation.shared.reply(to: record.number) } label: {
                                Label("信息回复", systemImage: "message.fill")
                            }.disabled(!model.authenticated || SystemPhoneActions.number(record.number) == nil)
                            Button { openSystem(SystemPhoneActions.messageURL(record.number)) } label: {
                                Label("系统信息回复", systemImage: "bubble.left.and.bubble.right")
                            }.disabled(SystemPhoneActions.messageURL(record.number) == nil)
                        }
                        if let url = voice.history.first(where: { $0.id == record.id })?.recordingURL {
                            Section("通话录音") {
                                Button { previewURL = url } label: { Label("播放录音", systemImage: "play.circle") }
                                ShareLink(item: url) { Label("分享录音", systemImage: "square.and.arrow.up") }
                                Button("删除录音", role: .destructive) { confirmDeletion = true }
                            }
                        }
                    }.navigationTitle("通话详情").navigationBarTitleDisplayMode(.inline)
                        .toolbar { Button("完成") { selected = nil } }
                }.quickLookPreview($previewURL)
                .confirmationDialog("删除这通电话的录音？", isPresented: $confirmDeletion) {
                    Button("删除录音", role: .destructive) { voice.deleteRecording(for: record.id) }
                }
                .presentationDetents([.large])
                .alert("操作未完成", isPresented: Binding(get: { systemActionError != nil }, set: { if !$0 { systemActionError = nil } })) {
                    Button("知道了") { systemActionError = nil }
                } message: { Text(systemActionError ?? "") }
            }
            .onChange(of: selected?.id) { _, _ in systemActionError = nil }
            .task {
                #if DEBUG
                guard ProcessInfo.processInfo.environment["HOMELINE_TEST_MODE"] == "1",
                      ProcessInfo.processInfo.environment["HOMELINE_UI_PREVIEW"] == "dialer-motion" else { return }
                // Offline visual review of both directions; never places a call.
                do {
                    for _ in 0..<2 {
                        try await Task.sleep(for: .seconds(1))
                        showDialer = true
                        try await Task.sleep(for: .seconds(2))
                        showDialer = false
                        try await Task.sleep(for: .seconds(1))
                    }
                } catch { return }
                #endif
            }
    }
    private func openSystem(_ url: URL?) {
        guard let url else { return }
        openURL(url) { accepted in
            if !accepted { systemActionError = "系统未能打开对应应用，请稍后重试。" }
        }
    }
}

struct CallPresentation: ViewModifier {
    @ObservedObject var voice: VoiceService
    var navigationRevision: UUID = UUID()
    @State private var showControls = false
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top) {
            if voice.inCall {
                Button { showControls = true } label: {
                    HStack { Image(systemName: "phone.fill"); Text(ContactNames.callLabel(voice.activeNumber) ?? voice.activeNumber); Spacer(); Text(voice.status) }
                        .font(.subheadline).padding(12).foregroundStyle(.white).background(.green)
                }.accessibilityLabel("查看当前通话")
            }
        }
        .task(id: voice.inCall) {
            if !voice.inCall { showControls = false; return }
            guard !voice.isIncoming else { return }
            try? await Task.sleep(for: .milliseconds(350))
            if !Task.isCancelled && voice.inCall { showControls = true }
        }
        .onChange(of: navigationRevision) { _, _ in showControls = false }
        .fullScreenCover(isPresented: Binding(get: { voice.inCall && showControls }, set: { showControls = $0 })) {
            ActiveCallView(voice: voice).interactiveDismissDisabled()
        }
    }
}

struct ActiveCallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var voice: VoiceService
    @ObservedObject private var directory = ContactDirectory.shared
    @State private var showKeypad = false
    @State private var digits = ""
    @State private var confirmRecording = false
    private var motion: Animation? { reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.9) }

    var body: some View {
        ZStack(alignment: .bottom) {
            background.ignoresSafeArea()
            ViewThatFits(in: .vertical) { panel; ScrollView { panel } }
                .safeAreaInset(edge: .bottom, spacing: 0) { bottomControls }
        }
        .overlay(alignment: .topLeading) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down").font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44).modifier(DialGlassSurface(dark: true))
            }.buttonStyle(DialKeyPressStyle()).padding(.leading, 16).padding(.top, 8)
                .accessibilityLabel("收起通话")
        }
        .foregroundStyle(.white).preferredColorScheme(.dark)
        .confirmationDialog("开始通话录音？", isPresented: $confirmRecording) {
            Button("开始录音") { voice.startRecording() }
        } message: { Text("请先告知对方。录音保存在此 iPhone 的“最近通话”中。") }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).receive(on: RunLoop.main)) { _ in
            voice.refreshAudioRoute()
        }
        .task {
            await directory.refresh()
            #if DEBUG
            if ProcessInfo.processInfo.environment["HOMELINE_TEST_MODE"] == "1" {
                let screen = ProcessInfo.processInfo.environment["HOMELINE_UI_PREVIEW"]
                showKeypad = screen == "call-keypad"
            }
            #endif
        }
        .onChange(of: voice.ringing) { _, ringing in
            if ringing { showKeypad = false }
        }
    }

    private var background: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.35, green: 0.32, blue: 0.28),
                                    Color(red: 0.30, green: 0.27, blue: 0.25),
                                    Color(red: 0.17, green: 0.17, blue: 0.23)],
                           startPoint: .topTrailing, endPoint: .bottomLeading)
            RadialGradient(colors: [Color(red: 0.44, green: 0.32, blue: 0.19).opacity(0.52), .clear],
                           center: .topLeading, startRadius: 15, endRadius: 580)
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            identity.padding(.top, 52)
            Spacer(minLength: 30)
            if !voice.ringing && showKeypad {
                PhoneKeypad(dark: true) { digit in
                    voice.sendDTMF(digit)
                    digits = String((digits + digit).suffix(24))
                }.disabled(!voice.mediaReady || voice.onHold)
            } else if !voice.ringing {
                HStack(alignment: .top, spacing: 0) {
                    audioMenu
                    control(voice.recording ? "停止录音" : (voice.recordingSaved ? "录音已保存" : "通话录音"),
                            icon: voice.recording ? "stop.circle.fill" : "record.circle",
                            selected: voice.recording) {
                        if voice.recording { voice.stopRecording() } else { confirmRecording = true }
                    }.disabled(!voice.recording && (!voice.mediaReady || voice.onHold || voice.recordingSaved))
                    control("静音", icon: "mic.slash.fill", selected: voice.muted) { voice.toggleMute() }
                }.frame(maxWidth: 360)
            }
        }.frame(maxWidth: .infinity).padding(.horizontal, 24)
    }

    private var bottomControls: some View {
        Group {
            if voice.ringing {
                HStack(spacing: 64) {
                    control("拒绝", icon: "phone.down.fill", tint: .red) { voice.hangup() }
                    control("接听", icon: "phone.fill", tint: .green) { voice.answer() }
                }.frame(maxWidth: 320)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    control(voice.onHold ? "恢复通话" : "保持通话",
                            icon: voice.onHold ? "play.fill" : "pause.fill", selected: voice.onHold) {
                        voice.toggleHold()
                    }.disabled(showKeypad || !voice.supportsHold || (!voice.mediaReady && !voice.onHold))
                        .opacity(showKeypad ? 0 : 1)
                        .accessibilityHidden(showKeypad)
                    endButton
                    control(showKeypad ? "隐藏键盘" : "拨号键盘",
                            icon: showKeypad ? "chevron.down" : "circle.grid.3x3.fill") {
                        withAnimation(motion) { showKeypad.toggle() }
                    }
                }.frame(maxWidth: 360)
            }
        }.frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 24)
    }

    private var identity: some View {
        let name = directory.name(for: voice.activeNumber)
        return VStack(spacing: 7) {
            Group {
                if let date = voice.connectedAt {
                    HStack(spacing: 8) {
                        if voice.onHold { Text("已保持") }
                        Text(date, style: .timer).monospacedDigit().fixedSize()
                    }
                } else { Text(voice.ringing ? "来电" : voice.status) }
            }.font(.system(size: 22, weight: .semibold)).foregroundStyle(.white.opacity(0.66))
            Text(showKeypad && !digits.isEmpty ? digits : name ?? voice.activeNumber)
                .font(.system(size: 34, weight: .bold)).lineLimit(2).minimumScaleFactor(0.48)
                .multilineTextAlignment(.center).contentTransition(.numericText())
            if name != nil && !showKeypad {
                Text(voice.activeNumber).font(.callout).foregroundStyle(.white.opacity(0.75))
            }
            if voice.recording { Label("正在录音", systemImage: "record.circle.fill").font(.footnote).foregroundStyle(.red) }
            else if voice.recordingSaved { Text("录音已保存").font(.footnote).foregroundStyle(.white.opacity(0.65)) }
            if let error = voice.controlError { Text(error).font(.footnote).multilineTextAlignment(.center).foregroundStyle(.orange) }
        }.frame(maxWidth: .infinity)
    }

    private var endButton: some View {
        control("结束", icon: "phone.down.fill", tint: .red) { voice.hangup() }
    }

    private var audioMenu: some View {
        VStack(spacing: 8) {
            Menu {
                Picker("音频输出", selection: Binding(get: { voice.outputID ?? "" }, set: voice.selectOutput)) {
                    ForEach(voice.audioOutputs, id: \.id) { output in
                        Label(output.label, systemImage: output.icon).tag(output.id)
                    }
                }.pickerStyle(.inline)
            } label: {
                let icon = voice.audioOutputs.first { $0.id == voice.outputID }?.icon ?? "speaker.wave.3.fill"
                Image(systemName: icon).font(.system(size: 30, weight: .medium)).frame(width: 80, height: 80)
                    .foregroundStyle(voice.speakerEnabled ? Color.black : .white)
                    .modifier(CallGlassSurface(selected: voice.speakerEnabled, interactive: false))
                    .clipShape(Circle())
                    .contentShape(.interaction, Circle())
                    .contentShape(.contextMenuPreview, Circle())
            }
            .buttonStyle(.plain)
            .menuOrder(.fixed)
            .accessibilityLabel("音频")
            .accessibilityValue(voice.audioOutputs.first { $0.id == voice.outputID }?.label ?? "")
            Text("音频").font(.system(size: 15)).accessibilityHidden(true)
        }.frame(maxWidth: .infinity)
            .disabled(voice.audioOutputs.isEmpty)
            .opacity(voice.audioOutputs.isEmpty ? 0.35 : 1)
    }

    private func control(_ title: String, icon: String, selected: Bool = false, tint: Color? = nil,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            controlLabel(title, icon: icon, selected: selected, tint: tint)
        }.buttonStyle(DialKeyPressStyle()).accessibilityLabel(title)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func controlLabel(_ title: String, icon: String, selected: Bool, tint: Color? = nil) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 30, weight: .medium)).frame(width: 80, height: 80)
                .foregroundStyle(selected ? Color.black : .white)
                .modifier(CallGlassSurface(selected: selected, tint: tint))
            Text(title).font(.system(size: 15)).lineLimit(1).minimumScaleFactor(0.75)
        }.frame(maxWidth: .infinity)
    }
}
