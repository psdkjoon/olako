package ir.psdkjoon.olako

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import java.io.ByteArrayOutputStream

object AndroidImages : ImageAdapter {
    private const val MAX_SIDE = 2600

    override fun load(path: String?, bytes: ByteArray?): DecodedImage? {
        try {
            val bounds = BitmapFactory.Options()
            bounds.inJustDecodeBounds = true
            decode(path, bytes, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
            var sample = 1
            while (maxOf(bounds.outWidth, bounds.outHeight) / sample > MAX_SIDE) sample *= 2
            val options = BitmapFactory.Options()
            options.inSampleSize = sample
            var bitmap = decode(path, bytes, options) ?: return null
            val matrix = orientation(path)
            if (matrix != null) {
                val turned = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
                if (turned !== bitmap) bitmap.recycle()
                bitmap = turned
            }
            val width = bitmap.width
            val height = bitmap.height
            val photo = bounds.outMimeType == "image/jpeg" && !bitmap.hasAlpha()
            if (photo) {
                val out = ByteArrayOutputStream(width * height / 4)
                bitmap.compress(Bitmap.CompressFormat.JPEG, 90, out)
                bitmap.recycle()
                return DecodedImage(width, height, out.toByteArray(), null, null)
            }
            val pixels = IntArray(width * height)
            bitmap.getPixels(pixels, 0, width, 0, 0, width, height)
            val hasAlpha = bitmap.hasAlpha()
            bitmap.recycle()
            val rgb = ByteArray(width * height * 3)
            val alpha = if (hasAlpha) ByteArray(width * height) else null
            var transparent = false
            for (i in pixels.indices) {
                val p = pixels[i]
                rgb[i * 3] = (p shr 16).toByte()
                rgb[i * 3 + 1] = (p shr 8).toByte()
                rgb[i * 3 + 2] = p.toByte()
                if (alpha != null) {
                    val a = (p ushr 24) and 0xFF
                    alpha[i] = a.toByte()
                    if (a != 255) transparent = true
                }
            }
            return DecodedImage(width, height, null, rgb, if (transparent) alpha else null)
        } catch (_: Throwable) {
            return null
        }
    }

    private fun decode(path: String?, bytes: ByteArray?, options: BitmapFactory.Options): Bitmap? {
        if (path != null) return BitmapFactory.decodeFile(path, options)
        if (bytes != null) return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
        return null
    }

    private fun orientation(path: String?): Matrix? {
        if (path == null) return null
        val exif = try {
            ExifInterface(path)
        } catch (_: Exception) {
            return null
        }
        val matrix = Matrix()
        when (exif.getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.postScale(-1f, 1f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.postScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> {
                matrix.postRotate(90f)
                matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_TRANSVERSE -> {
                matrix.postRotate(270f)
                matrix.postScale(-1f, 1f)
            }
            else -> return null
        }
        return matrix
    }
}
