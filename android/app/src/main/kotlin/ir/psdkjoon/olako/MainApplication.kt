package ir.psdkjoon.olako

import android.app.Application
import java.io.File
import java.util.Date

class MainApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        if (ThemeSync.isSyncProcess()) return
        logCrashes()
        EngineHolder.attach(this)
        LauncherIcon.install(this)
        ThemeSync.watchInstalls(this)
    }

    private fun logCrashes() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            try {
                File(filesDir, "errors.log").appendText(
                    "--- ${Date()} [native]\n${error.stackTraceToString()}\n",
                )
            } catch (_: Exception) {
            }
            previous?.uncaughtException(thread, error)
        }
    }
}
