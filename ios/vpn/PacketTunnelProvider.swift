//
//  PacketTunnelProvider.swift
//  vpn
//
//  Created by Abbit on 15.10.2023.
//

import OSLog
import NetworkExtension
import OutlineAppleLib
import Tun2socks

let kActionStart = "start"
let kActionRestart = "restart"
let kActionStop = "stop"
let kActionGetTunnelId = "getTunnelId"
let kMessageKeyAction = "action"
let kMessageKeyTunnelId = "tunnelId"
let kMessageKeyConfig = "config"
let kMessageKeyErrorCode = "errorCode"
let kMessageKeyHost = "host"
let kMessageKeyPort = "port"
let kMessageKeyOnDemand = "is-on-demand"
let kDefaultPathKey = "defaultPath"

public enum ErrorCode: Int {
  case noError = 0
  case undefined = 1
  case vpnPermissionNotGranted = 2
  case invalidServerCredentials = 3
  case udpRelayNotEnabled = 4
  case serverUnreachable = 5
  case vpnStartFailure = 6
  case illegalServerConfiguration = 7
  case shadowsocksStartFailure = 8
  case configureSystemProxyFailure = 9
  case noAdminPermissions = 10
  case unsupportedRoutingTable = 11
  case systemMisconfigured = 12
}

let log = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "vpn")

class PacketTunnelProvider: NEPacketTunnelProvider, Tun2socksTunWriterProtocol {
  var hostNetworkAddress: String? // IP address of the host in the active network.
  var tunnel: Tun2socksTunnelProtocol?
  var startCompletion: ((NSNumber) -> Void)?
  var stopCompletion: ((NSNumber) -> Void)?
  var tunnelConfig: OutlineTunnel?
  var tunnelStore: OutlineTunnelStore?
  var packetQueue: DispatchQueue?
  
  override init() {
    super.init()
    let appGroup = "group.com.anonymous.rn-outline"
    tunnelStore = OutlineTunnelStore.init(appGroup: appGroup)
    packetQueue = DispatchQueue(label: "com.anonymous.rn-outline.packetqueue", qos: .default, attributes: .concurrent)
  }
  
  // MARK: NEPacketTunnelProvider methods
  
  override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
    log.info("Starting tunnel")
    if options == nil {
      log.warning("Received a connect request from preferences")
      let msg = NSLocalizedString(
        "vpn-connect",
        tableName: "Outline",
        bundle: Bundle.main,
        value: "Please use the Outline app to connect.",
        comment: "Message shown in a system dialog when the user attempts to connect from settings")
      displayMessage(msg) { success in
        completionHandler(NSError(domain: NEVPNErrorDomain, code: NEVPNError.Code.configurationDisabled.rawValue, userInfo: nil))
        exit(0)
      }
      return
    }
    guard let tunnelConfig = retrieveTunnelConfig(options) else {
      log.error("Failed to retrieve the tunnel config.")
      completionHandler(NSError(domain: NEVPNErrorDomain, code: NEVPNError.Code.configurationUnknown.rawValue, userInfo: nil))
      return
    }
    self.tunnelConfig = tunnelConfig
    
    // Compute the IP address of the host in the active network.
    self.hostNetworkAddress = getNetworkIpAddress(tunnelConfig.config["host"]!)
    if self.hostNetworkAddress == nil {
      execAppCallbackForAction(kActionStart, errorCode: ErrorCode.illegalServerConfiguration)
      completionHandler(NSError(domain: NEVPNErrorDomain, code: NEVPNError.Code.configurationReadWriteFailed.rawValue, userInfo: nil))
      return
    }
    let isOnDemand = options?[kMessageKeyOnDemand] != nil
    // Bypass connectivity checks for auto-connect. If the tunnel configuration is no longer
    // valid, the connectivity checks will fail. The system will keep calling this method due to
    // On Demand being enabled (the VPN process does not have permission to change it), rendering the
    // network unusable with no indication to the user. By bypassing the checks, the network would
    // still be unusable, but at least the user will have a visual indication that Outline is the
    // culprit and can explicitly disconnect.
    var errorCode: Int = ErrorCode.noError.rawValue
    if !isOnDemand {
      guard let client = getClient() else {
        completionHandler(NSError(domain: NEVPNErrorDomain, code: NEVPNError.Code.configurationInvalid.rawValue, userInfo: nil))
        return
      }
      ShadowsocksCheckConnectivity(client, &errorCode, nil)
    }
    if errorCode != ErrorCode.noError.rawValue && errorCode != ErrorCode.udpRelayNotEnabled.rawValue {
      execAppCallbackForAction(kActionStart, errorCode: ErrorCode.noError)
      completionHandler(NSError(domain: NEVPNErrorDomain, code: NEVPNError.Code.connectionFailed.rawValue, userInfo: nil))
      return
    }
    
    connectTunnel(OutlineTunnel.getTunnelNetworkSettings(tunnelRemoteAddress: hostNetworkAddress!)) { error in
      if let error = error {
        self.execAppCallbackForAction(kActionStart, errorCode: ErrorCode.vpnPermissionNotGranted)
        completionHandler(error)
        return
      }
      let isUdpSupported = isOnDemand ? self.tunnelStore!.isUdpSupported : errorCode == ErrorCode.noError.rawValue
      if !self.startTun2Socks(isUdpSupported: isUdpSupported) {
        self.execAppCallbackForAction(kActionStart, errorCode: ErrorCode.vpnStartFailure)
        completionHandler(NSError(domain: NEVPNErrorDomain, code: NEVPNError.Code.connectionFailed.rawValue, userInfo: nil))
        return
      }
      self.listenForNetworkChanges()
      self.tunnelStore!.save(tunnelConfig)
      self.tunnelStore!.isUdpSupported = isUdpSupported
      self.tunnelStore!.status = OutlineTunnel.TunnelStatus.connected
      self.execAppCallbackForAction(kActionStart, errorCode: ErrorCode.noError)
      completionHandler(nil)
    }
  }
  
  override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
    log.info("Stopping tunnel")
    self.tunnelStore!.status = OutlineTunnel.TunnelStatus.disconnected
    self.stopListeningForNetworkChanges()
    self.tunnel!.disconnect()
    self.cancelTunnelWithError(nil)
    self.execAppCallbackForAction(kActionStop, errorCode: ErrorCode.noError)
    completionHandler()
  }
  
  // Receives messages and callbacks from the app. The callback will be executed asynchronously,
  // echoing the provided data on success and nil on error.
  // Expects |messageData| to be JSON encoded.
  override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
    guard let message = try? JSONSerialization.jsonObject(with: messageData, options: []) as? [String: Any] else {
      log.error("Failed to receive message from app")
      return
    }
    guard let completionHandler = completionHandler else {
      log.error("Missing message completion handler")
      return
    }
    guard let action = message[kMessageKeyAction] as? String else {
      log.error("Missing action key in app message")
      return completionHandler(nil)
    }
    log.info("Received app message: \(action)")
    let callbackWrapper: (NSNumber) -> Void = { errorCode in
      var tunnelId = ""
      if let tunnelConfig = self.tunnelConfig {
        tunnelId = tunnelConfig.id!
      }
      let response: [String: Any] = [
        kMessageKeyAction: action,
        kMessageKeyErrorCode: errorCode,
        kMessageKeyTunnelId: tunnelId
      ]
      completionHandler(try? JSONSerialization.data(withJSONObject: response, options: []))
    }
    if kActionStart == action || kActionRestart == action {
      self.startCompletion = callbackWrapper
      if kActionRestart == action {
        self.tunnelConfig = OutlineTunnel(id: (message[kMessageKeyTunnelId] as? String)!, config: (message[kMessageKeyConfig] as? [String: Any])!)
        self.reconnectTunnel(true)
      }
    } else if kActionStop == action {
      self.stopCompletion = callbackWrapper
    } else if kActionGetTunnelId == action {
      var response: Data?
      if let tunnelConfig = self.tunnelConfig {
        response = try? JSONSerialization.data(withJSONObject: [kMessageKeyTunnelId: tunnelConfig.id], options: [])
      }
      completionHandler(response)
    }
  }
  
  // MARK: Tun2socks
  
  func close() throws {}
  
  func write(_ packet: Data?, n: UnsafeMutablePointer<Int>?) throws {
    self.packetFlow.writePackets([packet!], withProtocols: [NSNumber(value: AF_INET)])
  }
  
  // Restarts tun2socks if |configChanged| or the host's IP address has changed in the network.
  func reconnectTunnel(_ configChanged: Bool) {
    guard let tunnelConfig = self.tunnelConfig, let hostAddress = tunnelConfig.config["host"] else {
      log.error("Failed to reconnect tunnel, missing tunnel configuration.")
      execAppCallbackForAction(kActionStart, errorCode: ErrorCode.illegalServerConfiguration)
      return
    }
    guard let activeHostNetworkAddress = getNetworkIpAddress(hostAddress.cString(using: .utf8)!) else {
      log.error("Failed to retrieve the remote host IP address in the network")
      execAppCallbackForAction(kActionStart, errorCode: ErrorCode.illegalServerConfiguration)
      return
    }
    if !configChanged && activeHostNetworkAddress == self.hostNetworkAddress {
      // Nothing changed. Connect the tunnel with the current settings.
      connectTunnel(OutlineTunnel.getTunnelNetworkSettings(tunnelRemoteAddress: self.hostNetworkAddress!)) { error in
        if let error = error {
          self.cancelTunnelWithError(error)
        }
      }
      return
    }
    log.info("Configuration or host IP address changed with the network. Reconnecting tunnel.")
    self.hostNetworkAddress = activeHostNetworkAddress
    guard let client = getClient() else {
      execAppCallbackForAction(kActionStart, errorCode: ErrorCode.illegalServerConfiguration)
      cancelTunnelWithError(NSError(domain: NEVPNErrorDomain, code: NEVPNError.Code.configurationInvalid.rawValue, userInfo: nil))
      return
    }
    var errorCodeRaw = ErrorCode.noError.rawValue
    ShadowsocksCheckConnectivity(client, &errorCodeRaw, nil)
    let errorCode = ErrorCode(rawValue: errorCodeRaw) ?? ErrorCode.undefined
    if errorCode != ErrorCode.noError && errorCode != ErrorCode.udpRelayNotEnabled {
      log.error("Connectivity checks failed. Tearing down VPN")
      execAppCallbackForAction(kActionStart, errorCode: errorCode)
      cancelTunnelWithError(NSError(domain: NEVPNErrorDomain, code: NEVPNError.Code.connectionFailed.rawValue, userInfo: nil))
      return
    }
    let isUdpSupported = errorCode == ErrorCode.noError
    guard startTun2Socks(isUdpSupported: isUdpSupported) else {
      log.error("Failed to reconnect tunnel. Tearing down VPN")
      execAppCallbackForAction(kActionStart, errorCode: ErrorCode.vpnStartFailure)
      cancelTunnelWithError(NSError(domain: NEVPNErrorDomain, code: NEVPNError.Code.connectionFailed.rawValue, userInfo: nil))
      return
    }
    connectTunnel(OutlineTunnel.getTunnelNetworkSettings(tunnelRemoteAddress: self.hostNetworkAddress!)) { error in
      if let error = error {
        self.execAppCallbackForAction(kActionStart, errorCode: ErrorCode.vpnStartFailure)
        self.cancelTunnelWithError(error)
        return
      }
      self.tunnelStore!.isUdpSupported = isUdpSupported
      self.tunnelStore!.save(self.tunnelConfig!)
      self.execAppCallbackForAction(kActionStart, errorCode: ErrorCode.noError)
    }
  }
  
  // MARK: Tunnel
  
  // Creates a OutlineTunnel from options supplied in |config|, or retrieves the last working
  // tunnel from disk. Normally the app provides a tunnel configuration. However, when the VPN
  // is started from settings or On Demand, the system launches this process without supplying a
  // configuration, so it is necessary to retrieve a previously persisted tunnel from disk.
  // To learn more about On Demand see: https://help.apple.com/deployment/ios/#/iord4804b742.
  func retrieveTunnelConfig(_ config: [String: Any]?) -> OutlineTunnel? {
    var tunnelConfig: OutlineTunnel?
    if let config = config, let tunnId = config[kMessageKeyTunnelId] as? String, config[kMessageKeyOnDemand] == nil {
      tunnelConfig = OutlineTunnel(id: tunnId, config: config)
    } else if let tunnelStore = self.tunnelStore {
      log.info("Retrieving tunnelConfig from store.")
      tunnelConfig = tunnelStore.load()
    }
    return tunnelConfig
  }
  
  // MARK: Network
  
  func getClient() -> ShadowsocksClient? {
    let config = ShadowsocksConfig()
    config.host = self.hostNetworkAddress!
    config.port = Int(self.tunnelConfig!.port!)!
    config.password = self.tunnelConfig!.password!
    config.cipherName = self.tunnelConfig!.method!
    config.prefix = self.tunnelConfig!.prefix
    var err: NSError?
    let client = ShadowsocksNewClient(config, &err)
    if err != nil {
      log.info("Failed to construct client.")
    }
    return client
  }
  
  // Calls getaddrinfo to retrieve the IP address literal as a string for |ipv4Str| in the active network.
  // This is necessary to support IPv6 DNS64/NAT64 networks. For more details see:
  // https://developer.apple.com/library/content/documentation/NetworkingInternetWeb/Conceptual/NetworkingOverview/UnderstandingandPreparingfortheIPv6Transition/UnderstandingandPreparingfortheIPv6Transition.html
  func getNetworkIpAddress(_ ipv4Str: UnsafePointer<Int8>) -> String? {
    var info: UnsafeMutablePointer<addrinfo>?
    var hints = addrinfo(ai_flags: AI_DEFAULT, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
    let error = getaddrinfo(ipv4Str, nil, &hints, &info)
    if error != 0 {
      log.error("getaddrinfo failed: \(String(cString: gai_strerror(error)))")
      return nil
    }
    var networkAddress = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    if info == nil {
      log.error("getaddrinfo returned nil")
      return nil
    }
    let success = getIpAddressString(info!.pointee.ai_addr, &networkAddress, socklen_t(Int(INET6_ADDRSTRLEN)))
    freeaddrinfo(info)
    if !success {
      log.error("inet_ntop failed with code \(errno)")
      return nil
    }
    return String(cString: networkAddress)
  }
  
  // Converts a struct sockaddr address |sa| to a string. Expects |maxbytes| to be allocated for |s|.
  // Returns whether the operation succeeded.
  func getIpAddressString(_ sa: UnsafePointer<sockaddr>, _ s: UnsafeMutablePointer<Int8>, _ maxbytes: socklen_t) -> Bool {
    guard let saPtr = UnsafeRawPointer(sa).assumingMemoryBound(to: sockaddr_storage.self).pointee.ss_family as sa_family_t? else {
      log.error("Failed to get IP address string: invalid argument")
      return false
    }
    switch saPtr {
    case sa_family_t(AF_INET):
      let addr = withUnsafePointer(to: sa) {
        $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
          $0.pointee.sin_addr
        }
      }
      guard let cString = inet_ntoa(addr) else {
        log.error("Failed to get IP address string: inet_ntoa returned nil")
        return false
      }
      guard strncpy(s, cString, Int(maxbytes)) != nil else {
        log.error("Failed to get IP address string: strncpy returned nil")
        return false
      }
    case sa_family_t(AF_INET6):
      var addr = withUnsafePointer(to: sa) {
        $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
          $0.pointee.sin6_addr
        }
      }
      guard inet_ntop(AF_INET6, &addr, s, maxbytes) != nil else {
        log.error("Failed to get IP address string: inet_ntop returned nil")
        return false
      }
    default:
      log.error("Cannot get IP address string: unknown address family")
      return false
    }
    return true
  }
  
  // Registers KVO for the `defaultPath` property to receive network connectivity changes.
  func listenForNetworkChanges() {
    stopListeningForNetworkChanges()
    addObserver(self, forKeyPath: kDefaultPathKey, options: .old, context: nil)
  }
  
  // Unregisters KVO for `defaultPath`.
  func stopListeningForNetworkChanges() {
    removeObserver(self, forKeyPath: kDefaultPathKey)
  }
  
  func connectTunnel(_ settings: NEPacketTunnelNetworkSettings?, completionHandler: @escaping (Error?) -> Void) {
    weak var weakSelf = self
    self.setTunnelNetworkSettings(settings) { error in
      if let error = error {
        log.error("Failed to set tunnel network settings: \(error.localizedDescription)")
      } else {
        log.info("Tunnel connected")
        // Passing nil settings clears the tunnel network configuration. Indicate to the system that
        // the tunnel is being re-established if this is the case.
        weakSelf?.reasserting = settings == nil
      }
      completionHandler(error)
    }
  }
  
  func startTun2Socks(isUdpSupported: Bool) -> Bool {
    let isRestart = self.tunnel != nil && self.tunnel!.isConnected()
    if isRestart {
      self.tunnel!.disconnect()
    }
    guard let client = self.getClient() else {
      return false
    }
    weak var weakSelf = self
    var err: NSError?
    self.tunnel = Tun2socksConnectShadowsocksTunnel(weakSelf, client, isUdpSupported, &err)
    if let error = err {
      log.error("Failed to start tun2socks: \(error)")
      return false
    }
    if !isRestart {
      DispatchQueue.global(qos: .background).async {
        weakSelf?.processPackets()
      }
    }
    return true
  }
  
  // Writes packets from the VPN to the tunnel.
  func processPackets() {
    weak var weakSelf = self
    var bytesWritten: Int = 0
    weakSelf?.packetFlow.readPackets { packets, protocols in
      for packet in packets {
        do {
          try weakSelf?.tunnel!.write(packet, ret0_: &bytesWritten)
        } catch let error {
          log.error("Failed to write packet to tunnel: \(error)")
          return
        }
      }
      DispatchQueue.global(qos: .background).async {
        weakSelf?.processPackets()
      }
    }
  }
  
  // MARK: App IPC
  
  // Executes a callback stored in |callbackMap| for the given |action|. |errorCode| is passed to the
  // app to indicate the operation success.
  // Callbacks are only executed once to prevent a bad access exception (EXC_BAD_ACCESS).
  func execAppCallbackForAction(_ action: String, errorCode code: ErrorCode) {
    let errorCode = NSNumber(value: code.rawValue)
    if action == kActionStart && self.startCompletion != nil {
      self.startCompletion?(errorCode)
      self.startCompletion = nil
    } else if action == kActionStop && self.stopCompletion != nil {
      self.stopCompletion?(errorCode)
      self.stopCompletion = nil
    } else {
      log.warning("No callback for action \(action)")
    }
  }
}
