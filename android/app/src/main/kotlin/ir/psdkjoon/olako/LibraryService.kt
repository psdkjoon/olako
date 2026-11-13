package ir.psdkjoon.olako

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import java.io.File
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.atomic.AtomicInteger

object LibraryService {
    private const val REQUEST_CODE = 4711
    private const val MAX_FILES = 6000
    private const val MAX_DEPTH = 12
    private const val WORKERS = 4

    private val EXTENSIONS = setOf(
        "docx", "pptx", "xlsx", "odt", "pdf", "md", "markdown", "txt", "log", "csv", "tsv",
    )

    fun granted(context: Context): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            return Environment.isExternalStorageManager()
        }
        return context.checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) ==
            PackageManager.PERMISSION_GRANTED
    }

    fun request(activity: Activity?): Boolean {
        if (activity == null) return false
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val intent = Intent(
                    Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                    Uri.parse("package:" + activity.packageName),
                )
                try {
                    activity.startActivity(intent)
                } catch (_: Exception) {
                    activity.startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
                }
            } else {
                activity.requestPermissions(
                    arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE),
                    REQUEST_CODE,
                )
            }
            return true
        } catch (_: Exception) {
            return false
        }
    }

    fun scan(): List<Map<String, Any>> {
        val roots = LinkedHashSet<File>()
        roots.add(Environment.getExternalStorageDirectory())
        val volumes = File("/storage").listFiles()
        if (volumes != null) {
            for (volume in volumes) {
                val name = volume.name
                if (name == "emulated" || name == "self") continue
                if (volume.isDirectory && volume.canRead()) roots.add(volume)
            }
        }
        val found = ConcurrentLinkedQueue<Map<String, Any>>()
        val count = AtomicInteger(0)
        val pool = Executors.newFixedThreadPool(WORKERS)
        val jobs = ArrayList<Future<*>>()
        try {
            for (root in roots) {
                val children = try {
                    root.listFiles()
                } catch (_: Exception) {
                    null
                } ?: continue
                for (child in children) {
                    val name = child.name
                    if (name.startsWith(".")) continue
                    if (name == "Android") continue
                    jobs.add(
                        pool.submit {
                            try {
                                visit(child, 1, found, count)
                            } catch (_: Exception) {
                            }
                        },
                    )
                }
            }
            for (job in jobs) {
                try {
                    job.get()
                } catch (_: Exception) {
                }
            }
        } finally {
            pool.shutdown()
        }
        return ArrayList(found)
    }

    private fun visit(
        entry: File,
        depth: Int,
        out: ConcurrentLinkedQueue<Map<String, Any>>,
        count: AtomicInteger,
    ) {
        if (count.get() >= MAX_FILES) return
        val name = entry.name
        if (name.startsWith(".")) return
        val dot = name.lastIndexOf('.')
        if (dot > 0 && dot < name.length - 1) {
            val extension = name.substring(dot + 1).lowercase()
            if (EXTENSIONS.contains(extension)) {
                if (!entry.isFile) return
                val size = entry.length()
                if (size <= 0L) return
                count.incrementAndGet()
                out.add(
                    mapOf(
                        "path" to entry.absolutePath,
                        "name" to name,
                        "size" to size,
                        "modified" to entry.lastModified(),
                    ),
                )
                return
            }
            if (extension.length in 1..4 && extension.all { it.isLetterOrDigit() }) return
        }
        if (depth > MAX_DEPTH) return
        val children = try {
            entry.listFiles()
        } catch (_: Exception) {
            null
        } ?: return
        for (child in children) {
            if (count.get() >= MAX_FILES) return
            visit(child, depth + 1, out, count)
        }
    }
}
