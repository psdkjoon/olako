package ir.psdkjoon.olako

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.io.File

object EngineHolder {
    private lateinit var appContext: Context

    private var engine: FlutterEngine? = null
    private var themeSyncChannel: MethodChannel? = null
    private var systemChannel: MethodChannel? = null
    private var pendingInstall: File? = null

    @Volatile
    var activity: android.app.Activity? = null

    fun attach(context: Context) {
        appContext = context.applicationContext
    }

    @Synchronized
    fun ensure(context: Context): FlutterEngine {
        engine?.let { return it }
        appContext = context.applicationContext
        val created = FlutterEngine(appContext)
        setUpChannels(created)
        created.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault(),
        )
        engine = created
        return created
    }

    private fun setUpChannels(e: FlutterEngine) {
        val messenger = e.dartExecutor.binaryMessenger

        DocumentChannel.register(e, appContext)

        MethodChannel(messenger, "olako/paths").setMethodCallHandler { call, result ->
            when (call.method) {
                "resolve" -> result.success(
                    mapOf(
                        "nativeLibraryDir" to appContext.applicationInfo.nativeLibraryDir,
                        "filesDir" to appContext.filesDir.absolutePath,
                    ),
                )
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, "olako/launcher_icon").setMethodCallHandler { call, result ->
            when (call.method) {
                "configure" -> {
                    LauncherIcon.configure(
                        call.argument<String>("mode") ?: "system",
                        call.argument<String>("accent") ?: "",
                        call.argument<Number>("updatedAt")?.toLong() ?: 0L,
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        val themeSync = MethodChannel(messenger, "olako/theme_sync")
        themeSyncChannel = themeSync
        themeSync.setMethodCallHandler { call, result ->
            when (call.method) {
                "publish" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: true
                    val accent = call.argument<String>("accent") ?: ""
                    val mode = call.argument<String>("mode") ?: "system"
                    val updatedAt = call.argument<Number>("updatedAt")?.toLong() ?: 0L
                    ThemeSync.async(result) {
                        ThemeSync.toMap(ThemeSync.publish(appContext, enabled, accent, mode, updatedAt))
                    }
                }
                "pull" -> ThemeSync.async(result) {
                    ThemeSync.toMap(ThemeSync.pull(appContext))
                }
                "current" -> ThemeSync.async(result) {
                    ThemeSync.toMap(ThemeSync.current(appContext))
                }
                else -> result.notImplemented()
            }
        }

        val system = MethodChannel(messenger, "olako/system")
        systemChannel = system
        Incoming.listener = { system.invokeMethod("incoming", null) }
        system.setMethodCallHandler { call, result ->
            when (call.method) {
                "openUrl" -> openUrl(call.argument<String>("url"), result)
                "installApk" -> installApk(call.argument<String>("path"), result)
                "abi" -> result.success(Build.SUPPORTED_ABIS.firstOrNull())
                "takeIncoming" -> result.success(Incoming.take())
                "closeApp" -> {
                    closeApp()
                    result.success(null)
                }
                "keepAwake" -> {
                    keepAwake(call.argument<Boolean>("on") == true)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun closeApp() {
        val host = activity as? ViewerActivity ?: return
        host.runOnUiThread { host.finish() }
    }

    private fun keepAwake(on: Boolean) {
        val host = activity ?: return
        host.runOnUiThread {
            val flag = android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
            if (on) host.window.addFlags(flag) else host.window.clearFlags(flag)
        }
    }

    private fun openUrl(url: String?, result: MethodChannel.Result) {
        if (url == null) {
            result.error("bad_url", "No URL.", null)
            return
        }
        try {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            appContext.startActivity(intent)
            result.success(null)
        } catch (_: ActivityNotFoundException) {
            result.error("no_browser", "No app can open this link.", null)
        } catch (e: Exception) {
            result.error("open_failed", e.message ?: "Could not open this link.", null)
        }
    }

    private fun canInstall(): Boolean =
        Build.VERSION.SDK_INT < 26 ||
            appContext.packageManager.canRequestPackageInstalls()

    private fun installApk(path: String?, result: MethodChannel.Result) {
        val file = path?.let { File(it) }
        if (file == null || !file.isFile) {
            result.error("no_file", "The update file is missing.", null)
            return
        }
        try {
            if (canInstall()) {
                pendingInstall = null
                launchInstaller(file)
                result.success("installing")
            } else {
                pendingInstall = file
                appContext.startActivity(
                    Intent(
                        Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Uri.parse("package:${appContext.packageName}"),
                    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
                result.success("needs_permission")
            }
        } catch (e: Exception) {
            pendingInstall = null
            result.error("install_failed", e.message ?: "Could not start the installer.", null)
        }
    }

    fun installIfWaiting() {
        val file = pendingInstall ?: return
        pendingInstall = null
        if (!canInstall()) return
        try {
            launchInstaller(file)
        } catch (_: Exception) {
        }
    }

    private fun launchInstaller(file: File) {
        val uri = FileProvider.getUriForFile(appContext, "${appContext.packageName}.updates", file)
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        appContext.startActivity(intent)
    }

    fun requestThemeSync(done: () -> Unit) {
        val channel = if (engine != null) themeSyncChannel else null
        if (channel == null) {
            done()
            return
        }
        channel.invokeMethod(
            "refresh",
            null,
            object : MethodChannel.Result {
                override fun success(result: Any?) = done()
                override fun error(code: String, message: String?, details: Any?) = done()
                override fun notImplemented() = done()
            },
        )
    }
}
