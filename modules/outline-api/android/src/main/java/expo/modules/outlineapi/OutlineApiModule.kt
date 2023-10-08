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
import expo.modules.kotlin.exception.Exceptions
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import expo.modules.kotlin.records.Field
import expo.modules.kotlin.records.Record
import expo.modules.outlineapi.outlineandroidlib.IVpnTunnelService
import expo.modules.outlineapi.outlineandroidlib.TunnelConfig
import expo.modules.outlineapi.outlineandroidlib.VpnServiceStarter
import expo.modules.outlineapi.outlineandroidlib.VpnTunnelService
import expo.modules.outlineapi.outlineandroidlib.VpnTunnelService.ErrorCode
import expo.modules.outlineapi.outlineandroidlib.VpnTunnelService.TunnelStatus
import expo.modules.outlineapi.outlineandroidlib.shadowsocks.ShadowsocksConfig
import org.json.JSONObject
import java.util.Locale
import java.util.logging.Level
import java.util.logging.Logger


private val LOG = Logger.getLogger(OutlineApiModule::class.java.name)
private const val REQUEST_CODE_PREPARE_VPN = 100

private fun interface Action {
    fun runWithPermissions(permissionsWereGranted: Boolean)
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

class OutlineApiModule : Module() {
    // AIDL interface for VpnTunnelService, which is bound for the lifetime of this class.
    // The VpnTunnelService runs in a sub process and is thread-safe.
    // A race condition may occur when calling methods on this instance if the service unbinds.
    // We catch any exceptions, which should generally be transient and recoverable, and report them
    // to the WebView.
    private var vpnTunnelService: IVpnTunnelService? = null

    // Tunnel status change callback by tunnel ID.
//    private val tunnelStatusListeners: Map<String, CallbackContext> =
//        ConcurrentHashMap<String, CallbackContext>()


    // Broadcasts receiver to forward VPN service broadcasts to the WebView when the tunnel status changes.
    private val vpnTunnelBroadcastReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val tunnelId = intent.getStringExtra(VpnTunnelService.MessageData.TUNNEL_ID.value)
            if (tunnelId == null) {
                LOG.warning("Tunnel status broadcast missing tunnel ID")
                return
            }
//            val callback: CallbackContext? = outlinePlugin.tunnelStatusListeners[tunnelId]
//            val callback = null;
//            if (callback == null) {
//                LOG.warning(
//                    String.format(
//                        Locale.ROOT, "Failed to retrieve status listener for tunnel ID %s", tunnelId
//                    )
//                )
//                return
//            }
            val status = intent.getIntExtra(
                VpnTunnelService.MessageData.PAYLOAD.value, TunnelStatus.INVALID.value
            )
            LOG.fine(
                String.format(
                    Locale.ROOT, "VPN connectivity changed: %s, %d", tunnelId, status
                )
            )
//            val result = PluginResult(PluginResult.Status.OK, status)
            // Keep the tunnel status callback so it can be called multiple times.
//            result.setKeepCallback(true)
//            callback.sendPluginResult(result)
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

    private val context: Context
        get() = appContext.reactContext?.applicationContext ?: throw Exceptions.ReactContextLost();
    private val currentActivity
        get() = appContext.activityProvider?.currentActivity ?: throw Exceptions.MissingActivity()

    private var awaitingAction: Action? = null

    // Each module class must implement the definition function. The definition consists of components
    // that describes the module's functionality and behavior.
    // See https://docs.expo.dev/modules/module-api for more details about available components.
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

//        AsyncFunction("requestPermissionsAsync") { writeOnly: Boolean, promise: Promise ->
//            askForPermissionsWithPermissionsManager(
//                appContext.permissions,
//                promise,
//                *getManifestPermissions(writeOnly)
//            )
//        }
//
//        AsyncFunction("getPermissionsAsync") { writeOnly: Boolean, promise: Promise ->
//            getPermissionsWithPermissionsManager(
//                appContext.permissions,
//                promise,
//                *getManifestPermissions(writeOnly)
//            )
//        }

        // Sets constant properties on the module. Can take a dictionary or a closure that returns a dictionary.
        Constants(
            "PI" to Math.PI
        )

        // Defines event names that the module can send to JavaScript.
        Events("onChange")

        Events("statusChanged")

        // Defines a JavaScript function that always returns a Promise and whose native code
        // is by default dispatched on the different thread than the JavaScript runtime runs on.
        AsyncFunction("setValueAsync") { value: String ->
            // Send an event to JavaScript.
            sendEvent(
                "onChange", mapOf(
                    "value" to value
                )
            )
        }

        // Requests user permission to connect the VPN.
        // Returns "true" if permission was previously granted, and "false" if the OS prompt will be displayed.
        Function("prepareVpn") {
            LOG.fine("Preparing VPN.")
            val prepareVpnIntent = VpnService.prepare(context) ?: return@Function "already granted" 
            LOG.info("Prepare VPN with activity")

            // Prepare the VPN before spawning a new thread. Fall through if it's already prepared.
            try {
                awaitingAction = actionIfUserGrantedPermission {
                    LOG.fine("permission granted!")
                }
                currentActivity.startActivityForResult(prepareVpnIntent, 0)
                return@Function "ask for permission"
            } catch (e: IntentSender.SendIntentException) {
                awaitingAction = null
                LOG.severe("Failed to start activity for VPN permission")
                return@Function "failed to start activity"
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
        AsyncFunction ("isVpnActive") { tunnelId: String ->
            try {
                return@AsyncFunction vpnTunnelService!!.isTunnelActive(tunnelId)
            } catch (e: java.lang.Exception) {
                LOG.log(
                    Level.SEVERE,
                    String.format(Locale.ROOT, "Failed to determine if tunnel is active: %s", tunnelId),
                    e
                )
            }
            return@AsyncFunction false
        }
    }

    private fun actionIfUserGrantedPermission(
        block: () -> Unit
    ) = Action { permissionsWereGranted ->
        if (!permissionsWereGranted) {
            // throw PermissionsException(ERROR_USER_DID_NOT_GRANT_VPN_PERMISSIONS_MESSAGE)
            throw Exception("ERROR_USER_DID_NOT_GRANT_VPN_PERMISSIONS_MESSAGE")
        }
        block()
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
            return ErrorCode.ILLEGAL_SERVER_CONFIGURATION.value
        }
        return vpnTunnelService!!.startTunnel(tunnelConfig)
    }

//    private fun getManifestPermissions(writeOnly: Boolean): Array<String> {
//        val shouldAddMediaLocationAccess =
//            Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
//                    hasManifestPermission(context, ACCESS_MEDIA_LOCATION)
//
//        val shouldAddWriteExternalStorage =
//            Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU &&
//                    hasManifestPermission(context, WRITE_EXTERNAL_STORAGE)
//
//        val shouldAddGranularPermissions =
//            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
//                    listOf(READ_MEDIA_AUDIO, READ_MEDIA_VIDEO, READ_MEDIA_IMAGES)
//                        .all { MediaLibraryUtils.hasManifestPermission(context, it) }
//
//        return listOfNotNull(
//            WRITE_EXTERNAL_STORAGE.takeIf { shouldAddWriteExternalStorage },
//            READ_EXTERNAL_STORAGE.takeIf { !writeOnly && !shouldAddGranularPermissions },
//            ACCESS_MEDIA_LOCATION.takeIf { shouldAddMediaLocationAccess },
//            *getGranularPermissions(writeOnly, shouldAddGranularPermissions)
//        ).toTypedArray()
//    }
//
//    private fun getManifestPermissions(context: Context): Set<String> {
//        val pm: PackageManager = context.packageManager
//        return try {
//            val packageInfo = pm.getPackageInfo(context.packageName, PackageManager.GET_PERMISSIONS)
//            packageInfo.requestedPermissions?.toSet() ?: emptySet()
//        } catch (e: PackageManager.NameNotFoundException) {
//            LOG.severe("Failed to list AndroidManifest.xml permissions")
//            e.printStackTrace()
//            emptySet()
//        }
//    }
//
//    /**
//     * Checks, whenever an application represented by [context] contains specific [permission]
//     * in `AndroidManifest.xml`:
//     *
//     * ```xml
//     *  <uses-permission android:name="<<PERMISSION STRING HERE>>" />
//     *  ```
//     */
//    fun hasManifestPermission(context: Context, permission: String): Boolean =
//        getManifestPermissions(context).contains(permission)
}
