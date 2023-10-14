package expo.modules.outlineapi

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.IntentSender
import android.content.ServiceConnection
import android.net.VpnService
import android.os.IBinder
import androidx.core.os.bundleOf
import expo.modules.kotlin.exception.Exceptions
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import expo.modules.kotlin.records.Field
import expo.modules.kotlin.records.Record
import expo.modules.outlineapi.outlineandroidlib.IVpnTunnelService
import expo.modules.outlineapi.outlineandroidlib.TunnelConfig
import expo.modules.outlineapi.outlineandroidlib.VpnServiceStarter
import expo.modules.outlineapi.outlineandroidlib.VpnTunnelService
import expo.modules.outlineapi.outlineandroidlib.VpnTunnelService.TunnelStatus
import org.json.JSONObject
import java.util.Locale
import java.util.logging.Level
import java.util.logging.Logger


private val LOG = Logger.getLogger(OutlineApiModule::class.java.name)
private const val REQUEST_CODE_PREPARE_VPN = 100

private fun interface Action {
    fun runWithPermissions(permissionsWereGranted: Boolean)
}

private fun actionIfUserGrantedPermission(block: () -> Unit) =
    Action { permissionsWereGranted ->
        if (permissionsWereGranted) {
            LOG.info("starting action execution")
            block()
        }
    }

class VpnTunnelConfig : Record {
    @Field
    val host: String? = null

    @Field
    val port: Int = 0

    @Field
    val password: String? = null

    @Field
    val method: String? = null

    @Field
    val prefix: String? = null
}

private const val TUNNEL_STATUS_CHANGED_EVENT_NAME = "onTunnelStatusChanged"

class OutlineApiModule : Module() {
    override fun definition() = ModuleDefinition {
        // Sets the name of the module that JavaScript code will use to refer to the module. Takes a string as an argument.
        // Can be inferred from module's class name, but it's recommended to set it explicitly for clarity.
        // The module will be accessible from `requireNativeModule('OutlineApi')` in JavaScript.
        Name("OutlineApi")

        OnCreate {
            val broadcastFilter = IntentFilter()
            broadcastFilter.addAction(VpnTunnelService.STATUS_BROADCAST_KEY)
            broadcastFilter.addCategory(context.packageName)
            context.registerReceiver(vpnTunnelBroadcastReceiver, broadcastFilter)
            context.bindService(
                Intent(context, VpnTunnelService::class.java),
                vpnServiceConnection,
                Context.BIND_AUTO_CREATE
            )
        }

        OnDestroy {
            context.unregisterReceiver(vpnTunnelBroadcastReceiver)
            context.unbindService(vpnServiceConnection)
        }

        OnActivityResult { _, payload ->
            awaitingAction?.takeIf { payload.requestCode == REQUEST_CODE_PREPARE_VPN }?.let {
                it.runWithPermissions(payload.resultCode == Activity.RESULT_OK)
                awaitingAction = null
                if (payload.resultCode == Activity.RESULT_OK) {
                    LOG.info("VPN permission granted (activity result).")
                } else {
                    LOG.warning("VPN permission not granted.")
                }
            }
        }

        // Defines event names that the module can send to JavaScript.
        Events(TUNNEL_STATUS_CHANGED_EVENT_NAME)

        // Requests user permission to connect the VPN.
        // Returns "true" if permission was previously granted, and "false" if the OS prompt will be displayed.
        Function("prepareVpn") {
            LOG.fine("Preparing VPN.")
            val prepareVpnIntent = VpnService.prepare(context) ?: return@Function true
            LOG.info("Prepare VPN with activity")

            // Prepare the VPN before spawning a new thread. Fall through if it's already prepared.
            try {
                awaitingAction = actionIfUserGrantedPermission {
                    // FIXME: is not being called for some reason
                    LOG.fine("permission granted!")
                }
                currentActivity.startActivityForResult(prepareVpnIntent, REQUEST_CODE_PREPARE_VPN)
                return@Function false
            } catch (e: IntentSender.SendIntentException) {
                awaitingAction = null
                LOG.severe("Failed to start activity for VPN permission")
                throw OutlineApiExceptions.FailedToStartVpnPreparationActivityException()
            }
        }

        AsyncFunction("startVpn") { tunnelId: String, config: VpnTunnelConfig ->
            startVpnTunnel(tunnelId, config)
        }

        AsyncFunction("stopVpn") { tunnelId: String ->
            LOG.info(String.format(Locale.ROOT, "Stopping VPN tunnel %s", tunnelId))
            vpnTunnelService!!.stopTunnel(tunnelId)
        }

        // Returns whether the VPN service is running a particular tunnel instance.
        AsyncFunction("isVpnActive") { tunnelId: String ->
            try {
                return@AsyncFunction vpnTunnelService!!.isTunnelActive(tunnelId)
            } catch (e: java.lang.Exception) {
                LOG.log(
                    Level.SEVERE,
                    String.format(
                        Locale.ROOT,
                        "Failed to determine if tunnel is active: %s",
                        tunnelId
                    ),
                    e
                )
                throw OutlineApiExceptions.FailedToDetermineIfTunnelIsActiveException()
            }
        }
    }

    private val context: Context
        get() = appContext.reactContext?.applicationContext ?: throw Exceptions.ReactContextLost()
    private val currentActivity
        get() = appContext.activityProvider?.currentActivity ?: throw Exceptions.MissingActivity()

    // AIDL interface for VpnTunnelService, which is bound for the lifetime of this class.
    // The VpnTunnelService runs in a sub process and is thread-safe.
    private var vpnTunnelService: IVpnTunnelService? = null

    // Action to run when the user grants VPN permissions.
    private var awaitingAction: Action? = null

    // Broadcasts receiver to forward VPN service broadcasts to the React Native when the tunnel status changes.
    private val vpnTunnelBroadcastReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val tunnelId = intent.getStringExtra(VpnTunnelService.MessageData.TUNNEL_ID.value)
            if (tunnelId == null) {
                LOG.warning("Tunnel status broadcast missing tunnel ID")
                return
            }
            val status = intent.getIntExtra(
                VpnTunnelService.MessageData.PAYLOAD.value, TunnelStatus.INVALID.value
            )
            LOG.fine(
                String.format(
                    Locale.ROOT, "VPN connectivity changed: %s, %d", tunnelId, status
                )
            )
            this@OutlineApiModule.sendEvent(
                TUNNEL_STATUS_CHANGED_EVENT_NAME, bundleOf(
                    "tunnelId" to tunnelId,
                    "status" to status
                )
            )
        }
    }

    // Connection to the VPN service.
    private val vpnServiceConnection: ServiceConnection = object : ServiceConnection {
        override fun onServiceConnected(className: ComponentName, binder: IBinder) {
            vpnTunnelService = IVpnTunnelService.Stub.asInterface(binder)
            LOG.info("VPN service connected")
        }

        override fun onServiceDisconnected(className: ComponentName) {
            LOG.warning("VPN service disconnected")
            // Rebind the service so the VPN automatically reconnects if the service process crashed.
            val rebind = Intent(context, VpnTunnelService::class.java)
            rebind.putExtra(VpnServiceStarter.AUTOSTART_EXTRA, true)
            context.bindService(rebind, this, Context.BIND_AUTO_CREATE)
        }
    }

    @Throws(java.lang.Exception::class)
    private fun startVpnTunnel(tunnelId: String, config: VpnTunnelConfig): Int {
        LOG.info(String.format(Locale.ROOT, "Starting VPN tunnel %s", tunnelId))
        val tunnelConfig: TunnelConfig = try {
            val json = JSONObject()
            json.put("host", config.host)
            json.put("port", config.port)
            json.put("password", config.password)
            json.put("method", config.method)
            json.put("prefix", config.prefix)
            VpnTunnelService.makeTunnelConfig(tunnelId, json)
        } catch (e: java.lang.Exception) {
            LOG.log(Level.SEVERE, "Failed to retrieve the tunnel proxy config.", e)
            throw OutlineApiExceptions.IllegalServerConfigurationException()
        }
        return vpnTunnelService!!.startTunnel(tunnelConfig)
    }
}
