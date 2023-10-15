import ExpoModulesCore
import CocoaLumberjack
import NetworkExtension

enum OutlineApiError: Error {
    case runtimeError(String)
}

struct VpnTunnelConfig : Record {
    @Field
    var host: String? = nil
    
    @Field
    var port: Int = 0
    
    @Field
    var password: String? = nil
    
    @Field
    var method: String? = nil
    
    @Field
    var prefix: String? = nil
}

private let TUNNEL_STATUS_CHANGED_EVENT_NAME = "onTunnelStatusChanged"

public class OutlineApiModule: Module {
    public func definition() -> ModuleDefinition {
        // Sets the name of the module that JavaScript code will use to refer to the module. Takes a string as an argument.
        // Can be inferred from module's class name, but it's recommended to set it explicitly for clarity.
        // The module will be accessible from `requireNativeModule('OutlineApi')` in JavaScript.
        Name("OutlineApi")
        
        OnCreate {
            DDLog.add(DDOSLogger.sharedInstance)
            OutlineVpn.shared.onVpnStatusChange(onVpnStatusChange)
        }
        
        OnDestroy {
            if let activeTunnelId = OutlineVpn.shared.activeTunnelId {
                OutlineVpn.shared.stop(activeTunnelId)
            }
        }
        
        // Defines event names that the module can send to JavaScript.
        Events(TUNNEL_STATUS_CHANGED_EVENT_NAME)
        
        // Requests user permission to connect the VPN.
        // Returns "true" if permission was previously granted, and "false" if the OS prompt will be displayed.
        // Throws an exception if cannot request the permission.
        Function("prepareVpn") {
            return true
        }
        
        
        // Starts the VPN connection.
        // Returns error code. 0 means success.
        // Throws an exception if cannot start the VPN.
        AsyncFunction("startVpn") { (tunnelId: String, config: VpnTunnelConfig, promise: Promise) in
            DDLogInfo("Starting VPN with tunnelId \(tunnelId)")
            let configJson: [String: Any] = [
                "host": config.host,
                "port": config.port,
                "password": config.password,
                "method": config.method,
                "prefix": config.prefix,
            ]
            guard containsExpectedKeys(configJson) else {
                promise.reject(OutlineApiError.runtimeError("Failed to start VPN with tunnelId \(tunnelId), errorCode \(OutlineVpn.ErrorCode.illegalServerConfiguration.rawValue)"))
                return
            }
            OutlineVpn.shared.start(tunnelId, configJson: configJson) { errorCode in
                if errorCode == OutlineVpn.ErrorCode.noError {
                    promise.resolve(OutlineVpn.ErrorCode.noError.rawValue)
                } else {
                    DDLogError("Failed to start VPN with tunnelId \(tunnelId), errorCode \(errorCode.rawValue)")
                    promise.reject(OutlineApiError.runtimeError("Failed to start VPN with tunnelId \(tunnelId), errorCode \(errorCode.rawValue)"))
                }
            }
            ///
            //            sendEvent(TUNNEL_STATUS_CHANGED_EVENT_NAME, [
            //                "tunnelId": tunnelId,
            //                "status": 0,
            //            ])
        }
        
        
        // Stops the VPN connection.
        // Returns error code. 0 means success.
        // Throws an exception if cannot stop the VPN.
        AsyncFunction("stopVpn") { (tunnelId: String) -> Int in
            DDLogInfo("Stopping VPN with tunnelId \(tunnelId)")
            OutlineVpn.shared.stop(tunnelId)
            ///
            //            sendEvent(TUNNEL_STATUS_CHANGED_EVENT_NAME, [
            //                "tunnelId": tunnelId,
            //                "status": 1,
            //            ])
            return 0
        }
        
        
        // Returns whether the VPN service is running a particular tunnel instance.
        // Throws an exception if cannot determine the status.
        AsyncFunction("isVpnActive") { (tunnelId: String) -> Bool in
            DDLogInfo("Checking if VPN is active with tunnelId \(tunnelId)")
            return OutlineVpn.shared.isActive(tunnelId)
        }
    }
    
    // MARK: Helpers
    
    // Receives NEVPNStatusDidChange notifications. Calls onTunnelStatusChange for the active
    // tunnel.
    func onVpnStatusChange(vpnStatus: NEVPNStatus, tunnelId: String) {
        var tunnelStatus: Int
        switch vpnStatus {
        case .connected:
            tunnelStatus = OutlineTunnel.TunnelStatus.connected.rawValue
        case .disconnected:
            tunnelStatus = OutlineTunnel.TunnelStatus.disconnected.rawValue
        case .reasserting:
            tunnelStatus = OutlineTunnel.TunnelStatus.reconnecting.rawValue
        default:
            return;  // Do not report transient or invalid states.
        }
        DDLogDebug("Calling onStatusChange (\(tunnelStatus)) for tunnel \(tunnelId)")
        sendEvent(TUNNEL_STATUS_CHANGED_EVENT_NAME, [
            "tunnelId": tunnelId,
            "status": tunnelStatus,
        ])
    }
    
    // Returns whether |config| contains all the expected keys
    private func containsExpectedKeys(_ configJson: [String: Any]?) -> Bool {
        return configJson?["host"] != nil && configJson?["port"] != nil &&
        configJson?["password"] != nil && configJson?["method"] != nil
    }
}
