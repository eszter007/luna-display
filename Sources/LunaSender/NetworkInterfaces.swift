import Foundation
import Network
import LunaProto

/// Watches which network interfaces currently have a usable path, for the
/// ☾ menu's "Network Interface" picker.
final class InterfaceMonitor {
    static let shared = InterfaceMonitor()
    private let monitor = NWPathMonitor()
    private var started = false

    /// Main-queue snapshot of the interfaces the current path could use.
    private(set) var interfaces: [NWInterface] = []
    var onChange: (() -> Void)?

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let usable = path.availableInterfaces.filter { iface in
                switch iface.type {
                case .wifi, .wiredEthernet: return true
                // A Thunderbolt bridge can enumerate as .other; VPN tunnels
                // and the like are not links a user would pin Luna to.
                case .other: return iface.name.hasPrefix("bridge") || iface.name.hasPrefix("en")
                default: return false
                }
            }
            DispatchQueue.main.async {
                self?.interfaces = usable
                self?.onChange?()
            }
        }
        monitor.start(queue: DispatchQueue(label: "luna.ifmonitor"))
    }

    func interface(named name: String) -> NWInterface? {
        interfaces.first { $0.name == name }
    }

    static func label(for interface: NWInterface) -> String {
        NetInfo.label(bsd: interface.name, type: interface.type)
    }
}
