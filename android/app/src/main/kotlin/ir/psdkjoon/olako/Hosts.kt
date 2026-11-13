package ir.psdkjoon.olako

import android.app.Activity
import android.content.Intent

object Hosts {
    private val live = mutableListOf<Activity>()

    fun claim(host: Activity) {
        live.removeAll { it.isFinishing || it.isDestroyed }
        live.filter { it !== host }.forEach { it.finish() }
        live.clear()
        live.add(host)
    }

    fun release(host: Activity) {
        live.remove(host)
    }

    fun onActivityResult(host: Activity, requestCode: Int, resultCode: Int, data: Intent?) {
        FileService.onResult(host, requestCode, resultCode, data)
    }
}
