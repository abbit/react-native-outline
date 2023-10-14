package expo.modules.outlineapi

import expo.modules.kotlin.exception.CodedException

class OutlineApiExceptions {
    class FailedToStartVpnPreparationActivityException : CodedException("Failed to start VPN preparation activity")
    class FailedToDetermineIfTunnelIsActiveException : CodedException("Failed to determine if tunnel is active")
    class IllegalServerConfigurationException : CodedException("Illegal server configuration")
}