import NetworkExtension
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground
        let label = UILabel(frame: controller.view.bounds.insetBy(dx: 24, dy: 80))
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        label.numberOfLines = 0
        label.textAlignment = .center
        label.text = "RedditBox Firewall\nChecking managed per-app configuration…"
        controller.view.addSubview(label)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window

        installAndStart { result in
            DispatchQueue.main.async {
                label.text = result
            }
        }
        return true
    }

    private func installAndStart(completion: @escaping (String) -> Void) {
        NEAppProxyProviderManager.loadAllFromPreferences { managers, error in
            if let error = error {
                completion("Firewall preference load failed:\n\(error.localizedDescription)")
                return
            }
            // iOS app-proxy configurations come from configuration profiles;
            // supported per-app routing also requires MDM-managed app assignment.
            // Do not create a global VPN or overwrite a managed configuration.
            guard let manager = managers?.first(where: {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == "com.redditbox.firewall.PacketTunnel"
            }), let configuration = manager.protocolConfiguration as? NETunnelProviderProtocol,
               configuration.providerConfiguration?["scope"] as? String == "per-app",
               !(configuration.providerConfiguration?["managedBundleIdentifiers"]
                    as? [String] ?? []).isEmpty else {
                completion("Managed per-app VPN is not configured. This build needs MDM enrollment, the VPN profile and assignment of each clone. Installing the profile alone is not enough. Online launch remains blocked; offline setup is still available in SocialBox.")
                return
            }
            do {
                try manager.connection.startVPNTunnel()
                completion("Managed app proxy started. Traffic remains closed until a clone lease is authorized.")
            } catch {
                completion("Firewall start failed:\n\(error.localizedDescription)")
            }
        }
    }
}
