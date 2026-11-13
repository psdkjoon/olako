package ir.psdkjoon.olako

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

object DocumentChannel {
    private const val CHANNEL = "olako/documents"

    private val PICK_TYPES = listOf("*/*")

    private lateinit var appContext: Context
    private lateinit var channel: MethodChannel

    private val worker = Executors.newSingleThreadExecutor()
    private val pdfWorker = Executors.newSingleThreadExecutor()
    private val editWorker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    fun register(engine: FlutterEngine, context: Context) {
        appContext = context.applicationContext
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result -> handle(call, result) }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pick" -> pick(call.argument<List<String>>("types"), call.argument<Boolean>("multiple") ?: false, result)
            "storageGranted" -> result.success(LibraryService.granted(appContext))
            "requestStorage" -> result.success(LibraryService.request(EngineHolder.activity))
            "scan" -> scan(result)
            "pdfOpen" -> pdfOpen(call.argument<String>("path"), result)
            "pdfRender" -> pdfRender(
                call.argument<Int>("id"),
                call.argument<Int>("page"),
                call.argument<Int>("width"),
                result,
            )
            "pdfClose" -> {
                val id = call.argument<Int>("id") ?: -1
                pdfWorker.execute { PdfService.close(id) }
                result.success(null)
            }
            "copy" -> copy(call.argument<String>("uri"), result)
            "share" -> result.success(
                ShareService.shareFiles(
                    appContext,
                    listOfNotNull(call.argument<String>("path")),
                    call.argument<String>("mime"),
                ),
            )
            "exportPdf" -> exportPdf(call.arguments as? Map<*, *>, result)
            "editPdf" -> editPdf(call.arguments as? Map<*, *>, result)
            "shareMany" -> result.success(
                ShareService.shareFiles(
                    appContext,
                    (call.argument<List<String>>("paths") ?: emptyList()),
                    call.argument<String>("mime"),
                ),
            )
            "saveDownload" -> saveDownload(call.argument<String>("path"), call.argument<String>("name"), result)
            else -> result.notImplemented()
        }
    }

    private fun pick(types: List<String>?, multiple: Boolean, result: MethodChannel.Result) {
        val wanted = if (types.isNullOrEmpty()) PICK_TYPES else types
        val started = FileService.pickFile(EngineHolder.activity, wanted, multiple) { files ->
            result.success(if (multiple) files else files.firstOrNull())
        }
        if (!started) result.success(if (multiple) emptyList<String>() else null)
    }

    private fun pdfOpen(path: String?, result: MethodChannel.Result) {
        if (path == null) {
            result.success(mapOf("error" to "no path"))
            return
        }
        pdfWorker.execute {
            val opened = PdfService.open(path)
            main.post { result.success(opened) }
        }
    }

    private fun pdfRender(id: Int?, page: Int?, width: Int?, result: MethodChannel.Result) {
        if (id == null || page == null || width == null) {
            result.success(null)
            return
        }
        pdfWorker.execute {
            val bytes = PdfService.render(id, page, width)
            main.post { result.success(bytes) }
        }
    }

    private fun scan(result: MethodChannel.Result) {
        worker.execute {
            val files = try {
                LibraryService.scan()
            } catch (_: Exception) {
                emptyList()
            }
            main.post { result.success(files) }
        }
    }

    private fun exportPdf(args: Map<*, *>?, result: MethodChannel.Result) {
        if (args == null) {
            result.success(mapOf("error" to "no arguments"))
            return
        }
        worker.execute {
            val name = FileService.safeName(args["name"] as? String, "document.pdf")
            val directory = File(File(appContext.cacheDir, "exports"), System.nanoTime().toString())
            directory.mkdirs()
            val target = File(directory, name)
            val request = HashMap<Any?, Any?>(args)
            request["path"] = target.absolutePath
            val outcome = PdfExporter.export(request)
            main.post { result.success(outcome) }
        }
    }

    private fun editPdf(args: Map<*, *>?, result: MethodChannel.Result) {
        val jobs = args?.get("jobs") as? List<*>
        if (jobs == null) {
            result.success(listOf(mapOf("error" to "no jobs")))
            return
        }
        editWorker.execute {
            val root = File(File(appContext.cacheDir, "exports"), System.nanoTime().toString())
            val prepared = ArrayList<Any?>()
            val names = ArrayList<String>()
            for ((i, raw) in jobs.withIndex()) {
                val job = raw as? Map<*, *>
                if (job == null) {
                    prepared.add(null)
                    names.add("")
                    continue
                }
                val name = FileService.safeName(job["name"] as? String, "document.pdf")
                val directory = File(root, i.toString())
                directory.mkdirs()
                val copy = HashMap<Any?, Any?>(job)
                copy["output"] = File(directory, name).absolutePath
                prepared.add(copy)
                names.add(name)
            }
            val outcome = try {
                PdfEdit.run(mapOf("jobs" to prepared), AndroidImages)
            } catch (e: Throwable) {
                listOf(mapOf("error" to (e.message ?: "failed")))
            }
            val reply = outcome.mapIndexed { i, r ->
                val m = HashMap<String, Any?>(r)
                if (i < names.size) m["name"] = names[i]
                m
            }
            main.post { result.success(reply) }
        }
    }

    private fun saveDownload(path: String?, name: String?, result: MethodChannel.Result) {
        if (path == null) {
            result.success(false)
            return
        }
        worker.execute {
            val file = File(path)
            val saved = if (file.isFile) {
                FileService.saveToDownloads(appContext, file, FileService.safeName(name, file.name), "application/pdf", true) != null
            } else {
                false
            }
            main.post { result.success(saved) }
        }
    }

    private fun copy(uriText: String?, result: MethodChannel.Result) {
        if (uriText == null) {
            result.success(null)
            return
        }
        worker.execute {
            val path = try {
                FileService.copyToCache(appContext, Uri.parse(uriText), "received")
            } catch (_: Exception) {
                null
            }
            main.post { result.success(path) }
        }
    }
}
