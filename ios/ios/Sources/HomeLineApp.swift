import SwiftUI

@MainActor
private final class HomeLineDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = SMSNotifications.shared
        RemotePush.shared.start()
        return true
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) { RemotePush.shared.gotAlert(token) }
}

@main
struct HomeLineApp: App {
    @UIApplicationDelegateAdaptor(HomeLineDelegate.self) private var delegate
    @StateObject private var model = PhoneModel.shared
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let screen = ProcessInfo.processInfo.environment["HOMELINE_UI_PREVIEW"] {
                NativeInterfacePreview(screen: screen)
            } else { appContent }
            #else
            appContent
            #endif
        }
        .backgroundTask(.appRefresh(SMSNotifications.taskID)) {
            await SMSNotifications.shared.schedule()
            await model.refresh()
        }
    }
    private var appContent: some View {
        RootView().environmentObject(model).tint(.blue)
            .onChange(of: phase) { _, phase in
                if phase == .active {
                    if model.authenticated && !model.voice.hasCore { model.connectVoice() }
                    RemotePush.shared.start(); model.voice.foreground()
                    Task {
                        await SMSNotifications.shared.requestPermissionIfNeeded()
                        await model.refresh()
                    }
                }
                else if phase == .background { model.voice.background(); SMSNotifications.shared.schedule() }
            }
            .task(id: phase) {
                guard phase == .active else { return }
                while !Task.isCancelled {
                    RemotePush.shared.sync()
                    await model.refresh()
                    #if DEBUG
                    await SMSNotifications.shared.checkPermission()
                    #endif
                    do { try await Task.sleep(for: .seconds(10)) } catch { break }
                }
            }
    }
}
