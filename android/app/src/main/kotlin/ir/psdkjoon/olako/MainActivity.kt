package ir.psdkjoon.olako

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

open class MainActivity : FlutterActivity() {
    override fun provideFlutterEngine(context: Context): FlutterEngine? {
        return EngineHolder.ensure(context)
    }

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        Hosts.claim(this)
        super.onCreate(savedInstanceState)
        EngineHolder.activity = this
        if (savedInstanceState == null) {
            Thread { FileService.trimTemporaryFiles(applicationContext) }.start()
            handleIncoming(intent)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIncoming(intent)
    }

    override fun onPostResume() {
        super.onPostResume()
        EngineHolder.activity = this
        EngineHolder.installIfWaiting()
    }

    private var taskLabel: String? = null
    private var taskColor = 0

    @Suppress("DEPRECATION")
    override fun setTaskDescription(taskDescription: ActivityManager.TaskDescription?) {
        if (taskDescription != null) {
            taskLabel = taskDescription.label
            taskColor = taskDescription.primaryColor
        }
        super.setTaskDescription(withIcon(taskLabel, taskColor))
    }

    fun refreshTaskDescription() {
        super.setTaskDescription(withIcon(taskLabel, taskColor))
    }

    @Suppress("DEPRECATION")
    private fun withIcon(label: String?, color: Int): ActivityManager.TaskDescription {
        val icon = LauncherIcon.currentIconRes(this)
        return if (android.os.Build.VERSION.SDK_INT >= 33) {
            ActivityManager.TaskDescription.Builder()
                .setLabel(label)
                .setIcon(icon)
                .setPrimaryColor(color)
                .build()
        } else {
            ActivityManager.TaskDescription(label, icon, color)
        }
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        Hosts.onActivityResult(this, requestCode, resultCode, data)
    }

    override fun onDestroy() {
        if (EngineHolder.activity === this) EngineHolder.activity = null
        Hosts.release(this)
        super.onDestroy()
    }

    private fun handleIncoming(intent: Intent?) {
        if (intent == null) return
        if (DeepLinkHandler.handle(this, intent)) {
            Incoming.changed()
            return
        }
        ShareService.handle(this, intent)
    }
}
