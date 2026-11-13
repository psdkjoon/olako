package ir.psdkjoon.olako

import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.OutputStream
import java.security.MessageDigest
import java.util.Locale
import java.util.zip.Deflater

class DecodedImage(
    val width: Int,
    val height: Int,
    val jpeg: ByteArray?,
    val rgb: ByteArray?,
    val alpha: ByteArray?,
)

interface ImageAdapter {
    fun load(path: String?, bytes: ByteArray?): DecodedImage?
}

class PdfOut {
    val items = ArrayList<Any?>()

    fun reserve(): Int {
        items.add(null)
        return items.size
    }

    fun add(value: Any?): PdfRef {
        items.add(value)
        return PdfRef(items.size)
    }

    fun set(id: Int, value: Any?) {
        items[id - 1] = value
    }
}

private class CountingStream(private val inner: OutputStream) : OutputStream() {
    var count = 0L
        private set

    override fun write(b: Int) {
        inner.write(b)
        count++
    }

    override fun write(b: ByteArray, off: Int, len: Int) {
        inner.write(b, off, len)
        count += len
    }

    override fun flush() = inner.flush()

    override fun close() = inner.close()
}

object PdfWriter {
    fun number(value: Double): String {
        if (value.isNaN() || value.isInfinite()) return "0"
        if (value == Math.rint(value) && Math.abs(value) < 1e12) return value.toLong().toString()
        var text = String.format(Locale.ROOT, "%.4f", value)
        if (text.contains('.')) text = text.trimEnd('0').trimEnd('.')
        return if (text == "-0") "0" else text
    }

    private fun latin(text: String): ByteArray = text.toByteArray(Charsets.ISO_8859_1)

    private fun writeName(os: OutputStream, name: String) {
        val sb = StringBuilder("/")
        for (ch in name) {
            val c = ch.code and 0xFF
            if (c < 33 || c > 126 || Lexer.isDelimiter(c) || c == 35) {
                sb.append('#').append(String.format("%02X", c))
            } else {
                sb.append(ch)
            }
        }
        os.write(latin(sb.toString()))
    }

    fun write(os: OutputStream, value: Any?) {
        when (value) {
            null -> os.write(latin("null"))
            is Boolean -> os.write(latin(if (value) "true" else "false"))
            is Int -> os.write(latin(value.toString()))
            is Long -> os.write(latin(value.toString()))
            is Number -> os.write(latin(number(value.toDouble())))
            is PdfName -> writeName(os, value.value)
            is PdfRef -> os.write(latin("${value.id} 0 R"))
            is PdfStr -> {
                val sb = StringBuilder("<")
                for (b in value.bytes) sb.append(String.format("%02X", b.toInt() and 0xFF))
                sb.append('>')
                os.write(latin(sb.toString()))
            }
            is Dict -> {
                os.write(latin("<<"))
                for ((k, v) in value) {
                    if (v == null) continue
                    writeName(os, k)
                    os.write(32)
                    write(os, v)
                    os.write(32)
                }
                os.write(latin(">>"))
            }
            is List<*> -> {
                os.write(91)
                for ((i, v) in value.withIndex()) {
                    if (i > 0) os.write(32)
                    write(os, v)
                }
                os.write(93)
            }
            is PdfStream -> {
                val d = Dict(value.dict)
                d["Length"] = value.length
                write(os, d)
                os.write(latin("\nstream\n"))
                os.write(value.data, value.offset, value.length)
                os.write(latin("\nendstream"))
            }
            is String -> write(os, PdfStr(value.toByteArray(Charsets.ISO_8859_1)))
            else -> os.write(latin("null"))
        }
    }

    fun save(out: PdfOut, file: File, root: PdfRef, info: PdfRef?) {
        file.parentFile?.mkdirs()
        val counter = CountingStream(BufferedOutputStream(FileOutputStream(file), 1 shl 16))
        try {
            counter.write(latin("%PDF-1.7\n%"))
            counter.write(byteArrayOf(0xE2.toByte(), 0xE3.toByte(), 0xCF.toByte(), 0xD3.toByte()))
            counter.write(10)
            val offsets = LongArray(out.items.size + 1)
            for ((i, item) in out.items.withIndex()) {
                val id = i + 1
                offsets[id] = counter.count
                counter.write(latin("$id 0 obj\n"))
                write(counter, item)
                counter.write(latin("\nendobj\n"))
            }
            val xrefAt = counter.count
            val total = out.items.size + 1
            counter.write(latin("xref\n0 $total\n"))
            counter.write(latin("0000000000 65535 f \n"))
            for (id in 1 until total) {
                counter.write(latin(String.format(Locale.ROOT, "%010d 00000 n \n", offsets[id])))
            }
            val trailer = Dict()
            trailer["Size"] = total
            trailer["Root"] = root
            if (info != null) trailer["Info"] = info
            val digest = MessageDigest.getInstance("MD5")
            digest.update(System.nanoTime().toString().toByteArray())
            digest.update(offsets.size.toString().toByteArray())
            val id = PdfStr(digest.digest())
            trailer["ID"] = arrayListOf<Any?>(id, id)
            counter.write(latin("trailer\n"))
            write(counter, trailer)
            counter.write(latin("\nstartxref\n$xrefAt\n%%EOF\n"))
            counter.flush()
        } finally {
            counter.close()
        }
    }
}

private fun flated(bytes: ByteArray): ByteArray {
    val deflater = Deflater(6)
    deflater.setInput(bytes)
    deflater.finish()
    val out = ByteArrayOutputStream(maxOf(64, bytes.size / 2))
    val buffer = ByteArray(65536)
    while (!deflater.finished()) {
        val n = deflater.deflate(buffer)
        out.write(buffer, 0, n)
    }
    deflater.end()
    return out.toByteArray()
}

private fun newStream(dict: Dict, bytes: ByteArray, compress: Boolean = true): PdfStream {
    if (compress && bytes.size > 256) {
        val packed = flated(bytes)
        if (packed.size < bytes.size) {
            dict["Filter"] = PdfName("FlateDecode")
            return PdfStream(dict, packed, 0, packed.size)
        }
    }
    return PdfStream(dict, bytes, 0, bytes.size)
}

private class Importer(val src: PdfFile, val out: PdfOut) {
    private val memo = HashMap<Int, Int>()
    private val queue = ArrayDeque<Int>()

    fun map(id: Int): PdfRef {
        memo[id]?.let { return PdfRef(it) }
        val n = out.reserve()
        memo[id] = n
        queue.addLast(id)
        return PdfRef(n)
    }

    private fun isPageNode(value: Any?): Boolean {
        val d = src.dictOf(value) ?: return false
        val type = src.nameOf(d["Type"])
        return type == "Page" || type == "Pages" || type == "Catalog"
    }

    fun copy(value: Any?): Any? {
        return when (value) {
            is PdfRef -> if (src.objectOrNull(value.id) == null) null else map(value.id)
            is Dict -> {
                val d = Dict()
                for ((k, v) in value) {
                    if ((k == "Parent" || k == "P") && v is PdfRef && isPageNode(v)) continue
                    val c = copy(v)
                    if (c != null) d[k] = c
                }
                d
            }
            is List<*> -> {
                val l = ArrayList<Any?>(value.size)
                for (v in value) l.add(copy(v))
                l
            }
            is PdfStream -> {
                val d = Dict(value.dict)
                d.remove("Length")
                PdfStream(copy(d) as Dict, value.data, value.offset, value.length)
            }
            else -> value
        }
    }

    fun drain() {
        while (queue.isNotEmpty()) {
            val id = queue.removeFirst()
            val obj = src.objectOrNull(id)
            out.set(memo[id]!!, copy(obj))
        }
    }
}

private fun colorOf(value: Any?, fallback: Int = 0xFF000000.toInt()): Int = (value as? Number)?.toInt() ?: fallback

private fun rgbOf(c: Int): String {
    val r = (c shr 16) and 0xFF
    val g = (c shr 8) and 0xFF
    val b = c and 0xFF
    return "${PdfWriter.number(r / 255.0)} ${PdfWriter.number(g / 255.0)} ${PdfWriter.number(b / 255.0)}"
}

private fun doubleOf(value: Any?, fallback: Double = 0.0): Double = (value as? Number)?.toDouble() ?: fallback

private class OverlayBuilder(
    private val box: DoubleArray,
    private val rotation: Int,
    private val out: PdfOut,
    private val images: ImageAdapter,
    private val imageCache: HashMap<String, Pair<PdfRef, DecodedImage>>,
) {
    val content = StringBuilder()
    val states = LinkedHashMap<String, Dict>()
    val xobjects = LinkedHashMap<String, PdfRef>()

    private fun n(v: Double) = PdfWriter.number(v)

    private fun matrix(): String {
        val x0 = box[0]
        val y0 = box[1]
        val x1 = box[2]
        val y1 = box[3]
        return when (rotation) {
            90 -> "0 1 1 0 ${n(x0)} ${n(y0)}"
            180 -> "-1 0 0 1 ${n(x1)} ${n(y0)}"
            270 -> "0 -1 -1 0 ${n(x1)} ${n(y1)}"
            else -> "1 0 0 -1 ${n(x0)} ${n(y1)}"
        }
    }

    private fun state(alpha: Double, multiply: Boolean): String? {
        if (alpha >= 0.999 && !multiply) return null
        val key = "${n(alpha)}${if (multiply) "m" else "n"}"
        val name = "OlGs$key".replace('.', '_')
        if (!states.containsKey(name)) {
            val d = Dict()
            d["Type"] = PdfName("ExtGState")
            d["CA"] = alpha
            d["ca"] = alpha
            if (multiply) d["BM"] = PdfName("Multiply")
            states[name] = d
        }
        return name
    }

    private fun image(spec: Map<*, *>): Pair<String, DecodedImage>? {
        val path = spec["path"] as? String
        val bytes = spec["bytes"] as? ByteArray
        val key = path ?: bytes?.let { "b${java.util.Arrays.hashCode(it)}_${it.size}" } ?: return null
        var entry = imageCache[key]
        if (entry == null) {
            val decoded = images.load(path, bytes) ?: return null
            val d = Dict()
            d["Type"] = PdfName("XObject")
            d["Subtype"] = PdfName("Image")
            d["Width"] = decoded.width
            d["Height"] = decoded.height
            d["ColorSpace"] = PdfName("DeviceRGB")
            d["BitsPerComponent"] = 8
            val stream: PdfStream
            if (decoded.jpeg != null) {
                d["Filter"] = PdfName("DCTDecode")
                stream = PdfStream(d, decoded.jpeg, 0, decoded.jpeg.size)
            } else if (decoded.rgb != null) {
                if (decoded.alpha != null) {
                    val m = Dict()
                    m["Type"] = PdfName("XObject")
                    m["Subtype"] = PdfName("Image")
                    m["Width"] = decoded.width
                    m["Height"] = decoded.height
                    m["ColorSpace"] = PdfName("DeviceGray")
                    m["BitsPerComponent"] = 8
                    d["SMask"] = out.add(newStream(m, decoded.alpha))
                }
                stream = newStream(d, decoded.rgb)
            } else {
                return null
            }
            entry = Pair(out.add(stream), decoded)
            imageCache[key] = entry
        }
        var name = xobjects.entries.firstOrNull { it.value.id == entry.first.id }?.key
        if (name == null) {
            name = "OlIm${xobjects.size + 1}"
            xobjects[name] = entry.first
        }
        return Pair(name, entry.second)
    }

    private fun style(spec: Map<*, *>, stroke: Boolean, fill: Boolean) {
        val c = spec["c"] as? Number
        val f = spec["f"] as? Number
        if (stroke && c != null) content.append(rgbOf(c.toInt())).append(" RG\n")
        if (fill && f != null) content.append(rgbOf(f.toInt())).append(" rg\n")
        if (fill && f == null && c != null) content.append(rgbOf(c.toInt())).append(" rg\n")
        content.append(n(maxOf(0.1, doubleOf(spec["sw"], 1.0)))).append(" w 1 J 1 j\n")
    }

    private fun alphaOf(spec: Map<*, *>): Double {
        val explicit = (spec["a"] as? Number)?.toDouble()
        if (explicit != null) return explicit.coerceIn(0.0, 1.0)
        val c = (spec["c"] as? Number)?.toInt() ?: (spec["f"] as? Number)?.toInt() ?: return 1.0
        return ((c ushr 24) and 0xFF) / 255.0
    }

    fun add(spec: Map<*, *>) {
        val type = spec["t"] as? String ?: return
        val multiply = spec["m"] == "mul"
        val alpha = alphaOf(spec)
        val gs = state(alpha, multiply)
        content.append("q\n")
        if (gs != null) content.append("/$gs gs\n")
        when (type) {
            "ink" -> ink(spec)
            "rect" -> rect(spec)
            "oval" -> oval(spec)
            "line" -> line(spec, false)
            "arrow" -> line(spec, true)
            "img" -> img(spec)
        }
        content.append("Q\n")
    }

    private fun ink(spec: Map<*, *>) {
        val pts = (spec["pts"] as? List<*>)?.map { doubleOf(it) } ?: return
        if (pts.size < 2) return
        style(spec, true, false)
        content.append(n(pts[0])).append(' ').append(n(pts[1])).append(" m\n")
        if (pts.size == 2) {
            content.append(n(pts[0] + 0.01)).append(' ').append(n(pts[1])).append(" l\n")
        }
        var i = 2
        while (i + 1 < pts.size) {
            content.append(n(pts[i])).append(' ').append(n(pts[i + 1])).append(" l\n")
            i += 2
        }
        content.append("S\n")
    }

    private fun paint(spec: Map<*, *>): String {
        val hasStroke = spec["c"] != null && doubleOf(spec["sw"], 1.0) > 0
        val hasFill = spec["f"] != null
        return when {
            hasStroke && hasFill -> "B"
            hasFill -> "f"
            hasStroke -> "S"
            else -> "n"
        }
    }

    private fun rect(spec: Map<*, *>) {
        style(spec, spec["c"] != null, true)
        content.append(n(doubleOf(spec["x"]))).append(' ').append(n(doubleOf(spec["y"]))).append(' ')
            .append(n(doubleOf(spec["w"]))).append(' ').append(n(doubleOf(spec["h"]))).append(" re\n")
        content.append(paint(spec)).append('\n')
    }

    private fun oval(spec: Map<*, *>) {
        style(spec, spec["c"] != null, true)
        val x = doubleOf(spec["x"])
        val y = doubleOf(spec["y"])
        val w = doubleOf(spec["w"])
        val h = doubleOf(spec["h"])
        val k = 0.5522847498
        val cx = x + w / 2
        val cy = y + h / 2
        val rx = w / 2
        val ry = h / 2
        content.append("${n(cx + rx)} ${n(cy)} m\n")
        content.append("${n(cx + rx)} ${n(cy + ry * k)} ${n(cx + rx * k)} ${n(cy + ry)} ${n(cx)} ${n(cy + ry)} c\n")
        content.append("${n(cx - rx * k)} ${n(cy + ry)} ${n(cx - rx)} ${n(cy + ry * k)} ${n(cx - rx)} ${n(cy)} c\n")
        content.append("${n(cx - rx)} ${n(cy - ry * k)} ${n(cx - rx * k)} ${n(cy - ry)} ${n(cx)} ${n(cy - ry)} c\n")
        content.append("${n(cx + rx * k)} ${n(cy - ry)} ${n(cx + rx)} ${n(cy - ry * k)} ${n(cx + rx)} ${n(cy)} c\n")
        content.append("h\n").append(paint(spec)).append('\n')
    }

    private fun line(spec: Map<*, *>, arrow: Boolean) {
        style(spec, true, true)
        val x1 = doubleOf(spec["x1"])
        val y1 = doubleOf(spec["y1"])
        val x2 = doubleOf(spec["x2"])
        val y2 = doubleOf(spec["y2"])
        val width = maxOf(0.1, doubleOf(spec["sw"], 1.0))
        var ex = x2
        var ey = y2
        val angle = Math.atan2(y2 - y1, x2 - x1)
        val head = maxOf(9.0, width * 4.5)
        if (arrow) {
            ex = x2 - Math.cos(angle) * head * 0.7
            ey = y2 - Math.sin(angle) * head * 0.7
        }
        content.append("${n(x1)} ${n(y1)} m ${n(ex)} ${n(ey)} l S\n")
        if (arrow) {
            val spread = 0.45
            val ax = x2 - Math.cos(angle - spread) * head
            val ay = y2 - Math.sin(angle - spread) * head
            val bx = x2 - Math.cos(angle + spread) * head
            val by = y2 - Math.sin(angle + spread) * head
            content.append("${n(x2)} ${n(y2)} m ${n(ax)} ${n(ay)} l ${n(bx)} ${n(by)} l h f\n")
        }
    }

    private fun img(spec: Map<*, *>) {
        val found = image(spec) ?: return
        val x = doubleOf(spec["x"])
        val y = doubleOf(spec["y"])
        val w = doubleOf(spec["w"])
        val h = doubleOf(spec["h"])
        val rot = doubleOf(spec["rot"])
        val cx = x + w / 2
        val cy = y + h / 2
        val cos = Math.cos(rot)
        val sin = Math.sin(rot)
        content.append("1 0 0 1 ${n(cx)} ${n(cy)} cm\n")
        content.append("${n6(cos)} ${n6(sin)} ${n6(-sin)} ${n6(cos)} 0 0 cm\n")
        content.append("${n(w)} 0 0 ${n(-h)} ${n(-w / 2)} ${n(h / 2)} cm\n")
        content.append("/${found.first} Do\n")
    }

    private fun n6(v: Double): String {
        var t = String.format(Locale.ROOT, "%.6f", v)
        if (t.contains('.')) t = t.trimEnd('0').trimEnd('.')
        return if (t == "-0" || t.isEmpty()) "0" else t
    }

    fun finish(): ByteArray {
        val head = "q\n${matrix()} cm\n"
        return (head + content.toString() + "Q\n").toByteArray(Charsets.ISO_8859_1)
    }

    val isEmpty: Boolean get() = content.isEmpty()
}

object PdfEdit {
    private val markupTypes = setOf(
        "Highlight", "Underline", "StrikeOut", "Squiggly", "Text", "FreeText", "Line", "Square",
        "Circle", "Ink", "Stamp", "Polygon", "PolyLine", "Caret",
    )

    private val annotDrop = setOf("Popup", "IRT", "P", "Parent", "StructParent", "StructParents", "Dest")

    fun run(request: Map<*, *>, images: ImageAdapter): List<Map<String, Any?>> {
        val jobs = request["jobs"] as? List<*> ?: return emptyList()
        val sources = HashMap<String, Any>()
        val results = ArrayList<Map<String, Any?>>()
        for (job in jobs) {
            val map = job as? Map<*, *>
            if (map == null) {
                results.add(mapOf("error" to "bad job"))
                continue
            }
            try {
                results.add(runJob(map, images, sources))
            } catch (e: EncryptedException) {
                results.add(mapOf("error" to "encrypted"))
            } catch (e: PdfException) {
                results.add(mapOf("error" to "damaged"))
            } catch (e: Throwable) {
                results.add(mapOf("error" to (e.message ?: e.javaClass.simpleName)))
            }
        }
        return results
    }

    private fun load(path: String, cache: HashMap<String, Any>): PdfFile {
        val hit = cache[path]
        if (hit is PdfFile) return hit
        if (hit is Throwable) throw hit
        try {
            val file = PdfFile(File(path).readBytes())
            cache[path] = file
            return file
        } catch (e: Throwable) {
            cache[path] = e
            throw e
        }
    }

    private fun runJob(job: Map<*, *>, images: ImageAdapter, cache: HashMap<String, Any>): Map<String, Any?> {
        val output = job["output"] as? String ?: throw PdfException("no output")
        val paths = (job["sources"] as? List<*>)?.map { it as String } ?: emptyList()
        val specs = job["pages"] as? List<*> ?: throw PdfException("no pages")
        if (specs.isEmpty()) throw PdfException("no pages")
        val out = PdfOut()
        val pagesId = out.reserve()
        val pagesRef = PdfRef(pagesId)
        val imageCache = HashMap<String, Pair<PdfRef, DecodedImage>>()
        val files = arrayOfNulls<PdfFile>(paths.size)
        val pageLists = arrayOfNulls<List<PageEntry>>(paths.size)
        val importers = arrayOfNulls<Importer>(paths.size)
        val kids = ArrayList<Any?>()
        for (raw in specs) {
            val spec = raw as? Map<*, *> ?: continue
            val s = (spec["s"] as? Number)?.toInt() ?: -1
            val delta = (((spec["r"] as? Number)?.toInt() ?: 0) % 360 + 360) % 360
            val overlays = (spec["ov"] as? List<*>)?.mapNotNull { it as? Map<*, *> } ?: emptyList()
            val page = Dict()
            page["Type"] = PdfName("Page")
            page["Parent"] = pagesRef
            var box: DoubleArray
            var baseRotate = 0
            var importer: Importer? = null
            var entry: PageEntry? = null
            var src: PdfFile? = null
            if (s >= 0 && s < paths.size) {
                if (files[s] == null) {
                    files[s] = load(paths[s], cache)
                    pageLists[s] = files[s]!!.pages()
                    importers[s] = Importer(files[s]!!, out)
                }
                src = files[s]!!
                importer = importers[s]!!
                val list = pageLists[s]!!
                val index = (spec["p"] as? Number)?.toInt() ?: 0
                if (index < 0 || index >= list.size) throw PdfException("page out of range")
                entry = list[index]
                val media = src.boxOf(entry.mediaBox) ?: doubleArrayOf(0.0, 0.0, 612.0, 792.0)
                val crop = src.boxOf(entry.cropBox)
                box = media
                if (crop != null) {
                    val l = maxOf(media[0], crop[0])
                    val b = maxOf(media[1], crop[1])
                    val r = minOf(media[2], crop[2])
                    val t = minOf(media[3], crop[3])
                    if (r - l > 1 && t - b > 1) box = doubleArrayOf(l, b, r, t)
                }
                baseRotate = entry.rotate - entry.rotate % 90
                page["MediaBox"] = arrayListOf<Any?>(media[0], media[1], media[2], media[3])
            } else {
                val w = (spec["w"] as? Number)?.toDouble() ?: 595.0
                val h = (spec["h"] as? Number)?.toDouble() ?: 842.0
                box = doubleArrayOf(0.0, 0.0, w, h)
                page["MediaBox"] = arrayListOf<Any?>(0.0, 0.0, w, h)
            }
            val builder = OverlayBuilder(box, baseRotate, out, images, imageCache)
            for (o in overlays) builder.add(o)
            val cropInsets = (spec["crop"] as? List<*>)?.map { doubleOf(it) }
            var finalBox = box
            if (cropInsets != null && cropInsets.size == 4) {
                finalBox = insetBox(box, baseRotate, cropInsets)
            }
            if (finalBox !== box || entry?.cropBox != null) {
                page["CropBox"] = arrayListOf<Any?>(finalBox[0], finalBox[1], finalBox[2], finalBox[3])
            }
            val rotate = (baseRotate + delta) % 360
            if (rotate != 0) page["Rotate"] = rotate
            if (entry != null && importer != null && src != null) {
                val resources = src.dictOf(entry.resources)
                if (resources != null) {
                    if (builder.isEmpty) {
                        page["Resources"] = importer.copy(resources)
                    } else {
                        page["Resources"] = shallowResources(src, importer, resources, builder)
                    }
                } else {
                    page["Resources"] = withOverlayResources(Dict(), builder)
                }
                val contents = ArrayList<Any?>()
                val rawContents = src.resolve(entry.dict["Contents"])
                val sourceRefs = ArrayList<Any?>()
                if (rawContents is PdfStream) {
                    val ref = entry.dict["Contents"]
                    if (ref is PdfRef) sourceRefs.add(ref)
                } else if (rawContents is List<*>) {
                    for (r in rawContents) if (r is PdfRef && src.resolve(r) is PdfStream) sourceRefs.add(r)
                }
                if (builder.isEmpty) {
                    for (r in sourceRefs) contents.add(importer.map((r as PdfRef).id))
                } else {
                    contents.add(out.add(newStream(Dict(), "q\n".toByteArray(), false)))
                    for (r in sourceRefs) contents.add(importer.map((r as PdfRef).id))
                    contents.add(out.add(newStream(Dict(), "\nQ\n".toByteArray(), false)))
                    contents.add(out.add(newStream(Dict(), builder.finish())))
                }
                if (contents.isNotEmpty()) page["Contents"] = contents
                for (key in listOf("Group", "UserUnit", "Tabs")) {
                    val v = entry.dict[key]
                    if (v != null) page[key] = importer.copy(v)
                }
                val annots = src.listOf(entry.dict["Annots"])
                if (annots != null) {
                    val kept = ArrayList<Any?>()
                    for (a in annots) {
                        val d = src.dictOf(a) ?: continue
                        val subtype = src.nameOf(d["Subtype"])
                        val keep = when {
                            subtype != null && subtype in markupTypes -> true
                            subtype == "Link" -> {
                                val action = src.dictOf(d["A"])
                                action != null && src.nameOf(action["S"]) == "URI"
                            }
                            else -> false
                        }
                        if (!keep) continue
                        val copy = Dict()
                        for ((k, v) in d) {
                            if (k in annotDrop) continue
                            val c = importer.copy(v)
                            if (c != null) copy[k] = c
                        }
                        kept.add(out.add(copy))
                    }
                    if (kept.isNotEmpty()) page["Annots"] = kept
                }
                importer.drain()
            } else {
                page["Resources"] = withOverlayResources(Dict(), builder)
                if (!builder.isEmpty) {
                    page["Contents"] = arrayListOf<Any?>(out.add(newStream(Dict(), builder.finish())))
                }
            }
            kids.add(out.add(page))
        }
        val pagesDict = Dict()
        pagesDict["Type"] = PdfName("Pages")
        pagesDict["Kids"] = kids
        pagesDict["Count"] = kids.size
        out.set(pagesId, pagesDict)
        val catalog = Dict()
        catalog["Type"] = PdfName("Catalog")
        catalog["Pages"] = pagesRef
        val catalogRef = out.add(catalog)
        val info = Dict()
        info["Producer"] = utf16("olako")
        (job["title"] as? String)?.takeIf { it.isNotEmpty() }?.let { info["Title"] = utf16(it) }
        (job["author"] as? String)?.takeIf { it.isNotEmpty() }?.let { info["Author"] = utf16(it) }
        val infoRef = out.add(info)
        PdfWriter.save(out, File(output), catalogRef, infoRef)
        return mapOf("path" to output, "pages" to kids.size)
    }

    private fun utf16(text: String): PdfStr {
        val body = text.toByteArray(Charsets.UTF_16BE)
        val bytes = ByteArray(body.size + 2)
        bytes[0] = 0xFE.toByte()
        bytes[1] = 0xFF.toByte()
        System.arraycopy(body, 0, bytes, 2, body.size)
        return PdfStr(bytes)
    }

    private fun insetBox(box: DoubleArray, rotation: Int, insets: List<Double>): DoubleArray {
        val w = box[2] - box[0]
        val h = box[3] - box[1]
        val dw = if (rotation == 90 || rotation == 270) h else w
        val dh = if (rotation == 90 || rotation == 270) w else h
        val l = insets[0].coerceIn(0.0, dw - 10)
        val t = insets[1].coerceIn(0.0, dh - 10)
        val r = insets[2].coerceIn(0.0, dw - l - 10)
        val b = insets[3].coerceIn(0.0, dh - t - 10)
        val corners = arrayOf(doubleArrayOf(l, t), doubleArrayOf(dw - r, dh - b))
        val mapped = corners.map { toUser(box, rotation, it[0], it[1]) }
        return doubleArrayOf(
            minOf(mapped[0][0], mapped[1][0]),
            minOf(mapped[0][1], mapped[1][1]),
            maxOf(mapped[0][0], mapped[1][0]),
            maxOf(mapped[0][1], mapped[1][1]),
        )
    }

    private fun toUser(box: DoubleArray, rotation: Int, dx: Double, dy: Double): DoubleArray {
        return when (rotation) {
            90 -> doubleArrayOf(box[0] + dy, box[1] + dx)
            180 -> doubleArrayOf(box[2] - dx, box[1] + dy)
            270 -> doubleArrayOf(box[2] - dy, box[3] - dx)
            else -> doubleArrayOf(box[0] + dx, box[3] - dy)
        }
    }

    private fun withOverlayResources(resources: Dict, builder: OverlayBuilder): Dict {
        if (builder.states.isNotEmpty()) {
            val gs = Dict()
            for ((k, v) in builder.states) gs[k] = v
            resources["ExtGState"] = gs
        }
        if (builder.xobjects.isNotEmpty()) {
            val xo = Dict()
            for ((k, v) in builder.xobjects) xo[k] = v
            resources["XObject"] = xo
        }
        return resources
    }

    private fun shallowResources(src: PdfFile, importer: Importer, resources: Dict, builder: OverlayBuilder): Dict {
        val result = Dict()
        for ((k, v) in resources) {
            if ((k == "ExtGState" || k == "XObject") && src.dictOf(v) != null) {
                val sub = Dict()
                for ((sk, sv) in src.dictOf(v)!!) {
                    val c = importer.copy(sv)
                    if (c != null) sub[sk] = c
                }
                result[k] = sub
            } else {
                val c = importer.copy(v)
                if (c != null) result[k] = c
            }
        }
        val gs = result["ExtGState"] as? Dict
        if (builder.states.isNotEmpty()) {
            val target = gs ?: Dict()
            for ((k, v) in builder.states) target[k] = v
            result["ExtGState"] = target
        }
        val xo = result["XObject"] as? Dict
        if (builder.xobjects.isNotEmpty()) {
            val target = xo ?: Dict()
            for ((k, v) in builder.xobjects) target[k] = v
            result["XObject"] = target
        }
        return result
    }
}
