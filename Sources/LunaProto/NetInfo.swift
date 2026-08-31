import Foundation
import Network
import SystemConfiguration

/// Names a BSD interface the way System Settings does ("Wi-Fi",
/// "Thunderbolt Bridge", "Ethernet"), so both apps can tell the user which
/// link a connection actually uses.
public enum NetInfo {
    public static func displayName(bsd: String, type: NWInterface.InterfaceType?) -> String {
        for item in SCNetworkInterfaceCopyAll() as NSArray {
            let sc = item as! SCNetworkInterface
            if let name = SCNetworkInterfaceGetBSDName(sc) as String?, name == bsd,
               let display = SCNetworkInterfaceGetLocalizedDisplayName(sc) as String? {
                return display
            }
        }
        // SCNetworkInterfaceCopyAll misses virtual interfaces like bridges.
        if bsd.hasPrefix("bridge") { return "Thunderbolt Bridge" }
        switch type {
        case .wifi: return "Wi-Fi"
        case .wiredEthernet: return "Ethernet"
        default: return "Network"
        }
    }

    /// "Thunderbolt Bridge (bridge0)" — for menus, status lines and logs.
    public static func label(bsd: String, type: NWInterface.InterfaceType?) -> String {
        "\(displayName(bsd: bsd, type: type)) (\(bsd))"
    }
}
