import ExpoModulesCore

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
        AsyncFunction("startVpn") { (tunnelId: String, config: VpnTunnelConfig) -> Int in
            sendEvent(TUNNEL_STATUS_CHANGED_EVENT_NAME, [
                "tunnelId": tunnelId,
                "status": 0,
            ])
            return 0
        }
        
        
        // Stops the VPN connection.
        // Returns error code. 0 means success.
        // Throws an exception if cannot stop the VPN.
        AsyncFunction("stopVpn") { (tunnelId: String) -> Int in
            sendEvent(TUNNEL_STATUS_CHANGED_EVENT_NAME, [
                "tunnelId": tunnelId,
                "status": 1,
            ])
            return 0
        }
        
        
        // Returns whether the VPN service is running a particular tunnel instance.
        // Throws an exception if cannot determine the status.
        AsyncFunction("isVpnActive") { (tunnelId: String) -> Bool in
            return false
        }
    }
}
