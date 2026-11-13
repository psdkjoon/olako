package ir.psdkjoon.olako

import android.os.Handler
import android.os.Looper

object Incoming {
    @Volatile
    var listener: (() -> Unit)? = null

    private val main = Handler(Looper.getMainLooper())
    private var payload: String? = null

    @Synchronized
    fun setPayload(value: String?) {
        if (value == null) return
        payload = value
        changed()
    }

    fun changed() {
        main.post { listener?.invoke() }
    }

    @Synchronized
    fun take(): Map<String, Any?>? {
        val link = DeepLinkHandler.consume()
        val shared = ShareService.consume()
        val note = payload
        payload = null
        if (link == null && shared == null && note == null) return null
        return mapOf(
            "link" to link,
            "text" to shared?.text,
            "files" to (shared?.files ?: emptyList<String>()),
            "payload" to note,
        )
    }
}
