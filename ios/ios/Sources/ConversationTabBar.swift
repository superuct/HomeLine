import SwiftUI
import UIKit

struct ConversationTabBar: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.background(TabBarTransitionObserver().frame(width: 0, height: 0))
        } else {
            content.toolbar(.hidden, for: .tabBar)
        }
    }
}

@available(iOS 18.0, *)
private struct TabBarTransitionObserver: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Observer { Observer() }
    func updateUIViewController(_ controller: Observer, context: Context) {}

    final class Observer: UIViewController {
        override func loadView() { view = UIView(); view.backgroundColor = .clear; view.isUserInteractionEnabled = false }
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            setHidden(true, animated: animated)
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            // A cancelled interactive pop can replay appearance callbacks.
            // The visible conversation always owns a hidden tab bar.
            tabBarController?.setTabBarHidden(true, animated: false)
        }
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            // A sheet or the system call screen must not restore the tab bar.
            guard let navigation = navigationController,
                  let destination = transitionCoordinator?.viewController(forKey: .to),
                  navigation.viewControllers.contains(where: { $0 === destination }),
                  !isDescendant(of: destination) else { return }
            setHidden(false, animated: animated)
        }
        private func isDescendant(of controller: UIViewController) -> Bool {
            var ancestor: UIViewController? = self
            while let current = ancestor {
                if current === controller { return true }
                ancestor = current.parent
            }
            return false
        }
        private func setHidden(_ hidden: Bool, animated: Bool) {
            guard let tabs = tabBarController else { return }
            tabs.setTabBarHidden(hidden, animated: animated && !UIAccessibility.isReduceMotionEnabled)
            transitionCoordinator?.animate(alongsideTransition: nil) { [weak self, weak tabs] context in
                guard let self, let tabs,
                      let destination = context.viewController(forKey: context.isCancelled ? .from : .to) else { return }
                // Resolve the final page instead of inverting each callback's
                // request: both callbacks can belong to the same cancelled pop.
                let staysInConversation = self.isDescendant(of: destination)
                tabs.setTabBarHidden(staysInConversation, animated: false)
                #if DEBUG
                self.recordTransitionForUITest(cancelled: context.isCancelled, hidden: staysInConversation)
                #endif
            }
        }
        #if DEBUG
        private func recordTransitionForUITest(cancelled: Bool, hidden: Bool) {
            guard ProcessInfo.processInfo.environment["HOMELINE_TEST_MODE"] == "1",
                  let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            let file = directory.appendingPathComponent("conversation-navigation.json")
            let previous = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let values: [String: Any] = ["cancelledTransitions": (previous?["cancelledTransitions"] as? Int ?? 0) + (cancelled ? 1 : 0),
                                        "lastCancelled": cancelled, "tabBarHidden": hidden]
            if let data = try? JSONSerialization.data(withJSONObject: values) { try? data.write(to: file, options: .atomic) }
        }
        #endif
    }
}
