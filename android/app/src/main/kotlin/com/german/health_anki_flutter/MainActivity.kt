package com.german.health_anki_flutter

import android.Manifest
import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var notificationPermissionResult: MethodChannel.Result? = null
    private var backgroundSyncChannel: MethodChannel? = null
    private var connectivityManager: ConnectivityManager? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private val validatedNetwork = ValidatedNetworkTransition<Network>()
    private var syncInFlight = false
    private var syncQueued = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        registerMaintainedPlugins(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, RecallContracts.studyReminderChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestPermission" -> requestNotificationPermission(result)
                    "openSettings" -> {
                        if (RecallReminderNotifications.openSettings(this)) {
                            result.success(null)
                        } else {
                            result.error(
                                "notification_settings_unavailable",
                                "Notification settings are unavailable on this device.",
                                null,
                            )
                        }
                    }
                    "apply" -> {
                        val settings = RecallContracts.reminderSettings(call.arguments)
                        if (settings == null) {
                            result.error(
                                "invalid_reminder_settings",
                                "Expected a complete, bounded reminder request.",
                                null,
                            )
                        } else {
                            RecallReminderScheduler.apply(applicationContext, settings)
                            result.success(null)
                        }
                    }
                    "cancel" -> {
                        RecallReminderScheduler.cancel(applicationContext)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(messenger, RecallContracts.widgetChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "update" -> {
                        val snapshot = RecallContracts.widgetSnapshot(call.arguments)
                        if (snapshot == null) {
                            result.error(
                                "invalid_widget_snapshot",
                                "Expected a non-negative count and valid update time.",
                                null,
                            )
                        } else {
                            RecallWidgetProvider.store(applicationContext, snapshot)
                            result.success(null)
                        }
                    }
                    "clear" -> {
                        RecallWidgetProvider.clear(applicationContext)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(messenger, RecallContracts.operationalDiagnosticsChannel)
            .setMethodCallHandler { call, result ->
                if (call.method != "mirror") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val payload = (call.arguments as? Map<*, *>)
                    ?.takeIf { it.keys == setOf("payload") }
                    ?.get("payload") as? String
                if (payload == null || !RecallOperationalDiagnostics.isCanonical(payload)) {
                    result.error(
                        "invalid_operational_diagnostics",
                        "Expected one bounded operational-event/v2 array.",
                        null,
                    )
                    return@setMethodCallHandler
                }
                try {
                    RecallOperationalDiagnostics.write(applicationContext, payload)
                    result.success(null)
                } catch (_: Exception) {
                    result.error(
                        "operational_diagnostics_write_failed",
                        "Could not update the local diagnostics mirror.",
                        null,
                    )
                }
            }

        backgroundSyncChannel = MethodChannel(messenger, RecallContracts.backgroundSyncChannel)
            .also { channel ->
                channel.setMethodCallHandler { call, result ->
                    if (call.method == "ready") {
                        registerReconnectSync()
                        result.success(null)
                    } else {
                        result.notImplemented()
                    }
                }
            }
    }

    /**
     * Recall maintains its Android plugin surface explicitly because generated
     * registration output is not source controlled. Passkey/JNI plugins are
     * deliberately absent until the product enables a verified passkey flow.
     */
    private fun registerMaintainedPlugins(flutterEngine: FlutterEngine) {
        flutterEngine.plugins.add(com.llfbandit.app_links.AppLinksPlugin())
        flutterEngine.plugins.add(com.it_nomads.fluttersecurestorage.FlutterSecureStoragePlugin())
        flutterEngine.plugins.add(io.flutter.plugins.sharedpreferences.SharedPreferencesPlugin())
        flutterEngine.plugins.add(io.flutter.plugins.urllauncher.UrlLauncherPlugin())
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        when (RecallReminderNotifications.readiness(this)) {
            RecallNotificationReadiness.READY -> {
                result.success(true)
                return
            }
            RecallNotificationReadiness.BLOCKED -> {
                result.success(false)
                return
            }
            RecallNotificationReadiness.NEEDS_RUNTIME_PERMISSION -> Unit
        }
        if (notificationPermissionResult != null) {
            result.error(
                "notification_permission_pending",
                "A notification permission request is already active.",
                null,
            )
            return
        }
        notificationPermissionResult = result
        requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            notificationPermissionRequestCode,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != notificationPermissionRequestCode) return
        val result = notificationPermissionResult ?: return
        notificationPermissionResult = null
        result.success(
            RecallReminderNotifications.readiness(this) ==
                RecallNotificationReadiness.READY,
        )
    }

    private fun registerReconnectSync() {
        if (networkCallback != null) return
        val manager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onCapabilitiesChanged(
                network: Network,
                capabilities: NetworkCapabilities,
            ) {
                runOnUiThread {
                    val shouldSync = validatedNetwork.onCapabilitiesChanged(
                        network,
                        capabilities.hasCapability(
                            NetworkCapabilities.NET_CAPABILITY_VALIDATED,
                        ),
                    )
                    if (shouldSync) requestBackgroundSync()
                }
            }

            override fun onLost(network: Network) {
                runOnUiThread {
                    validatedNetwork.onLost(network)
                }
            }
        }
        connectivityManager = manager
        networkCallback = callback
        manager.registerDefaultNetworkCallback(callback)
        val active = manager.activeNetwork
        val capabilities = active?.let(manager::getNetworkCapabilities)
        if (active != null && validatedNetwork.onCapabilitiesChanged(
                active,
                capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true,
            )
        ) {
            requestBackgroundSync()
        }
    }

    private fun requestBackgroundSync() {
        runOnUiThread {
            val channel = backgroundSyncChannel ?: return@runOnUiThread
            if (syncInFlight) {
                syncQueued = true
                return@runOnUiThread
            }
            syncInFlight = true
            channel.invokeMethod("performSync", null, object : MethodChannel.Result {
                override fun success(result: Any?) = finishBackgroundSync()
                override fun error(code: String, message: String?, details: Any?) =
                    finishBackgroundSync()
                override fun notImplemented() = finishBackgroundSync()
            })
        }
    }

    private fun finishBackgroundSync() {
        runOnUiThread {
            syncInFlight = false
            if (syncQueued) {
                syncQueued = false
                requestBackgroundSync()
            }
        }
    }

    override fun onDestroy() {
        notificationPermissionResult?.success(false)
        notificationPermissionResult = null
        val manager = connectivityManager
        val callback = networkCallback
        if (manager != null && callback != null) {
            runCatching { manager.unregisterNetworkCallback(callback) }
        }
        networkCallback = null
        connectivityManager = null
        validatedNetwork.clear()
        backgroundSyncChannel = null
        super.onDestroy()
    }

    private companion object {
        const val notificationPermissionRequestCode = 5102
    }
}
