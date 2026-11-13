package ir.psdkjoon.olako

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

object PdfService {
    private const val MAX_PIXELS = 9_000_000.0

    private var descriptor: ParcelFileDescriptor? = null
    private var renderer: PdfRenderer? = null
    private var current = 0

    @Synchronized
    fun open(path: String): Map<String, Any>? {
        release()
        try {
            val file = ParcelFileDescriptor.open(File(path), ParcelFileDescriptor.MODE_READ_ONLY)
            descriptor = file
            val pdf = PdfRenderer(file)
            renderer = pdf
            current++
            val sizes = ArrayList<Int>()
            for (index in 0 until pdf.pageCount) {
                val page = pdf.openPage(index)
                sizes.add(page.width)
                sizes.add(page.height)
                page.close()
            }
            return mapOf("id" to current, "sizes" to sizes)
        } catch (e: Exception) {
            release()
            return mapOf("error" to (e.javaClass.simpleName + ": " + (e.message ?: "")))
        } catch (e: Error) {
            release()
            return mapOf("error" to (e.javaClass.simpleName + ": " + (e.message ?: "")))
        }
    }

    @Synchronized
    fun render(id: Int, index: Int, width: Int): ByteArray? {
        val pdf = renderer ?: return null
        if (id != current || index < 0 || index >= pdf.pageCount) return null
        var page: PdfRenderer.Page? = null
        var bitmap: Bitmap? = null
        try {
            page = pdf.openPage(index)
            if (page.width <= 0 || page.height <= 0) return null
            val ratio = page.height.toDouble() / page.width
            var targetWidth = width.coerceIn(64, 4000)
            if (targetWidth * targetWidth * ratio > MAX_PIXELS) {
                targetWidth = Math.sqrt(MAX_PIXELS / ratio).toInt().coerceAtLeast(64)
            }
            val targetHeight = (targetWidth * ratio).toInt().coerceIn(1, 8000)
            bitmap = Bitmap.createBitmap(targetWidth, targetHeight, Bitmap.Config.ARGB_8888)
            bitmap.eraseColor(Color.WHITE)
            page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
            val buffer = ByteBuffer.allocate(8 + targetWidth * targetHeight * 4)
            buffer.order(ByteOrder.LITTLE_ENDIAN)
            buffer.putInt(targetWidth)
            buffer.putInt(targetHeight)
            bitmap.copyPixelsToBuffer(buffer)
            return buffer.array()
        } catch (_: Exception) {
            return null
        } catch (_: OutOfMemoryError) {
            return null
        } finally {
            try {
                page?.close()
            } catch (_: Exception) {
            }
            bitmap?.recycle()
        }
    }

    @Synchronized
    fun close(id: Int) {
        if (id == current) release()
    }

    private fun release() {
        try {
            renderer?.close()
        } catch (_: Exception) {
        }
        try {
            descriptor?.close()
        } catch (_: Exception) {
        }
        renderer = null
        descriptor = null
    }
}
