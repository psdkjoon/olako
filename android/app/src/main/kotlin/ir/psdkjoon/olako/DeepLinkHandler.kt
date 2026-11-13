package ir.psdkjoon.olako

import android.content.Context
import android.content.Intent
import android.net.Uri

object DeepLinkHandler {
    val scheme = "olako".replace('_', '-')

    @Volatile
    private var pending: String? = null

    fun uri(host: String, path: String): Uri =
        Uri.Builder().scheme(scheme).authority(host).appendPath(path).build()

    @Suppress("UNUSED_PARAMETER")
    fun handle(context: Context, intent: Intent?): Boolean {
        if (intent == null || intent.action != Intent.ACTION_VIEW) return false
        val data = intent.data ?: return false
        if (data.scheme != scheme) return false
        pending = data.toString()
        return true
    }

    fun consume(): String? {
        val link = pending
        pending = null
        return link
    }
}
