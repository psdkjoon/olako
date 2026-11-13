package ir.psdkjoon.olako

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import java.io.File

object ShareService {
    data class Received(val text: String?, val files: List<String>)

    @Volatile
    private var pending: Received? = null

    private const val MAX_FILES = 50

    fun shareFiles(context: Context, paths: List<String>, mime: String? = null): Boolean {
        val staged = paths.mapNotNull { FileService.stageForSharing(context, File(it)) }
        val uris = ArrayList<Uri>(staged.mapNotNull { FileService.uriFor(context, it) })
        if (uris.isEmpty()) return false
        val types = staged.map { FileService.mimeOf(it.name) }.distinct()
        val type = mime ?: if (types.size == 1) types[0] else "*/*"
        val send = if (uris.size == 1) {
            Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_STREAM, uris[0])
        } else {
            Intent(Intent.ACTION_SEND_MULTIPLE).putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
        }
        send.setType(type).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        return chooser(context, send)
    }

    private fun chooser(context: Context, send: Intent): Boolean {
        val chooser = Intent.createChooser(send, context.getString(R.string.share))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            context.startActivity(chooser)
            true
        } catch (_: Exception) {
            false
        }
    }

    fun handle(context: Context, intent: Intent?): Boolean {
        if (intent == null) return false
        val uris = when (intent.action) {
            Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE -> streams(intent)
            Intent.ACTION_VIEW -> listOfNotNull(intent.data)
            else -> return false
        }.filter { it.scheme == "content" || it.scheme == "file" }.take(MAX_FILES)
        if (uris.isEmpty()) return false
        val app = context.applicationContext
        Thread {
            val files = uris.mapNotNull { copy(app, it) }
            if (files.isNotEmpty()) {
                pending = Received(null, files)
                Incoming.changed()
            }
        }.start()
        return true
    }

    private fun copy(context: Context, uri: Uri): String? {
        if (uri.scheme == "file") {
            val path = uri.path ?: return null
            val file = File(path)
            if (!file.isFile || !file.canRead()) return null
            return try {
                val directory = File(context.cacheDir, "received/${System.nanoTime()}").apply { mkdirs() }
                val target = File(directory, FileService.safeName(file.name))
                file.copyTo(target, overwrite = true)
                target.absolutePath
            } catch (_: Exception) {
                null
            }
        }
        return try {
            FileService.copyToCache(context, uri, "received")
        } catch (_: Exception) {
            null
        }
    }

    fun consume(): Received? {
        val received = pending
        pending = null
        return received
    }

    @Suppress("DEPRECATION")
    private fun streams(intent: Intent): List<Uri> {
        if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
            val list = if (Build.VERSION.SDK_INT >= 33) {
                intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
            }
            return list ?: emptyList()
        }
        val single = if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
        }
        return listOfNotNull(single)
    }
}
