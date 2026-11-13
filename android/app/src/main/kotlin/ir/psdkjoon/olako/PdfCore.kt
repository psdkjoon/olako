package ir.psdkjoon.olako

import java.io.ByteArrayOutputStream
import java.util.zip.Inflater

class Dict() : LinkedHashMap<String, Any?>() {
    constructor(other: Map<String, Any?>) : this() {
        putAll(other)
    }
}

class PdfName(val value: String) {
    override fun equals(other: Any?): Boolean = other is PdfName && other.value == value

    override fun hashCode(): Int = value.hashCode()
}

class PdfRef(val id: Int)

class PdfStr(val bytes: ByteArray)

class PdfStream(val dict: Dict, val data: ByteArray, val offset: Int, val length: Int)

open class PdfException(message: String) : Exception(message)

class EncryptedException : PdfException("encrypted")

private class Keyword(val text: String)

private object Eof

private object EndArray

private object EndDict

class Lexer(private val d: ByteArray, var pos: Int = 0, private val refs: Boolean = true) {
    companion object {
        fun isSpace(c: Int): Boolean = c == 0 || c == 9 || c == 10 || c == 12 || c == 13 || c == 32

        fun isDelimiter(c: Int): Boolean =
            c == 40 || c == 41 || c == 60 || c == 62 || c == 91 || c == 93 || c == 123 || c == 125 || c == 47 || c == 37
    }

    val eof: Any get() = Eof

    fun atEnd(): Boolean {
        skipSpace()
        return pos >= d.size
    }

    fun skipSpace() {
        while (pos < d.size) {
            val c = d[pos].toInt() and 0xFF
            if (isSpace(c)) {
                pos++
            } else if (c == 37) {
                while (pos < d.size && d[pos].toInt() != 10 && d[pos].toInt() != 13) pos++
            } else {
                break
            }
        }
    }

    fun startsWith(word: String): Boolean {
        if (pos + word.length > d.size) return false
        for (i in word.indices) {
            if (d[pos + i].toInt() != word[i].code) return false
        }
        return true
    }

    fun readKeyword(): String? {
        skipSpace()
        val start = pos
        while (pos < d.size) {
            val c = d[pos].toInt() and 0xFF
            if (isSpace(c) || isDelimiter(c)) break
            pos++
        }
        if (pos == start) return null
        return String(d, start, pos - start, Charsets.ISO_8859_1)
    }

    fun readInt(): Int? {
        skipSpace()
        val save = pos
        var p = pos
        var negative = false
        if (p < d.size && (d[p].toInt() == 43 || d[p].toInt() == 45)) {
            negative = d[p].toInt() == 45
            p++
        }
        val start = p
        var value = 0L
        while (p < d.size && d[p].toInt() in 48..57) {
            value = value * 10 + (d[p].toInt() - 48)
            if (value > Int.MAX_VALUE) {
                pos = save
                return null
            }
            p++
        }
        if (p == start) {
            pos = save
            return null
        }
        pos = p
        return (if (negative) -value else value).toInt()
    }

    fun read(): Any? {
        skipSpace()
        if (pos >= d.size) return Eof
        val c = d[pos].toInt() and 0xFF
        when (c) {
            47 -> return name()
            40 -> return literal()
            60 -> {
                if (pos + 1 < d.size && d[pos + 1].toInt() == 60) {
                    pos += 2
                    return dict()
                }
                return hex()
            }
            62 -> {
                if (pos + 1 < d.size && d[pos + 1].toInt() == 62) {
                    pos += 2
                    return EndDict
                }
                pos++
                return Keyword(">")
            }
            91 -> {
                pos++
                return array()
            }
            93 -> {
                pos++
                return EndArray
            }
            123, 125, 41 -> {
                pos++
                return Keyword(c.toChar().toString())
            }
        }
        val start = pos
        while (pos < d.size) {
            val ch = d[pos].toInt() and 0xFF
            if (isSpace(ch) || isDelimiter(ch)) break
            pos++
        }
        if (pos == start) {
            pos++
            return Keyword("?")
        }
        val text = String(d, start, pos - start, Charsets.ISO_8859_1)
        val first = text[0]
        if (first == '+' || first == '-' || first == '.' || first in '0'..'9') {
            val number = number(text)
            if (number != null) {
                if (refs && number is Int && number >= 0) {
                    val ref = tryRef(number)
                    if (ref != null) return ref
                }
                return number
            }
        }
        return when (text) {
            "true" -> true
            "false" -> false
            "null" -> null
            else -> Keyword(text)
        }
    }

    private fun number(text: String): Any? {
        var plain = true
        for (i in text.indices) {
            val ch = text[i]
            if (!(ch in '0'..'9' || (i == 0 && (ch == '+' || ch == '-')))) {
                plain = false
                break
            }
        }
        if (plain) {
            val asLong = text.toLongOrNull() ?: return null
            return if (asLong in Int.MIN_VALUE..Int.MAX_VALUE) asLong.toInt() else asLong.toDouble()
        }
        val cleaned = text.replace("--", "-")
        return cleaned.toDoubleOrNull()
    }

    private fun tryRef(id: Int): PdfRef? {
        val save = pos
        var p = pos
        while (p < d.size && isSpace(d[p].toInt() and 0xFF)) p++
        val genStart = p
        while (p < d.size && d[p].toInt() in 48..57) p++
        if (p == genStart || p - genStart > 5) return null
        while (p < d.size && isSpace(d[p].toInt() and 0xFF)) p++
        if (p < d.size && d[p].toInt() == 82) {
            val after = p + 1
            if (after >= d.size || isSpace(d[after].toInt() and 0xFF) || isDelimiter(d[after].toInt() and 0xFF)) {
                pos = after
                return PdfRef(id)
            }
        }
        pos = save
        return null
    }

    private fun hexValue(c: Int): Int = when (c) {
        in 48..57 -> c - 48
        in 65..70 -> c - 55
        in 97..102 -> c - 87
        else -> -1
    }

    private fun name(): PdfName {
        pos++
        val out = StringBuilder()
        while (pos < d.size) {
            val c = d[pos].toInt() and 0xFF
            if (isSpace(c) || isDelimiter(c)) break
            if (c == 35 && pos + 2 < d.size) {
                val high = hexValue(d[pos + 1].toInt() and 0xFF)
                val low = hexValue(d[pos + 2].toInt() and 0xFF)
                if (high >= 0 && low >= 0) {
                    out.append((high * 16 + low).toChar())
                    pos += 3
                    continue
                }
            }
            out.append(c.toChar())
            pos++
        }
        return PdfName(out.toString())
    }

    private fun literal(): PdfStr {
        pos++
        val out = ByteArrayOutputStream()
        var depth = 1
        while (pos < d.size) {
            val c = d[pos].toInt() and 0xFF
            pos++
            when {
                c == 92 -> {
                    if (pos >= d.size) break
                    val e = d[pos].toInt() and 0xFF
                    pos++
                    when (e) {
                        110 -> out.write(10)
                        114 -> out.write(13)
                        116 -> out.write(9)
                        98 -> out.write(8)
                        102 -> out.write(12)
                        13 -> if (pos < d.size && d[pos].toInt() == 10) pos++
                        10 -> {}
                        in 48..55 -> {
                            var value = e - 48
                            var count = 1
                            while (count < 3 && pos < d.size && d[pos].toInt() in 48..55) {
                                value = value * 8 + (d[pos].toInt() - 48)
                                pos++
                                count++
                            }
                            out.write(value and 0xFF)
                        }
                        else -> out.write(e)
                    }
                }
                c == 40 -> {
                    depth++
                    out.write(c)
                }
                c == 41 -> {
                    depth--
                    if (depth == 0) return PdfStr(out.toByteArray())
                    out.write(c)
                }
                else -> out.write(c)
            }
        }
        return PdfStr(out.toByteArray())
    }

    private fun hex(): PdfStr {
        pos++
        val out = ByteArrayOutputStream()
        var high = -1
        while (pos < d.size) {
            val c = d[pos].toInt() and 0xFF
            pos++
            if (c == 62) break
            val v = hexValue(c)
            if (v < 0) continue
            if (high < 0) {
                high = v
            } else {
                out.write(high * 16 + v)
                high = -1
            }
        }
        if (high >= 0) out.write(high * 16)
        return PdfStr(out.toByteArray())
    }

    private fun array(): ArrayList<Any?> {
        val list = ArrayList<Any?>()
        while (true) {
            val v = read()
            if (v === EndArray || v === Eof) break
            if (v is Keyword) continue
            list.add(v)
        }
        return list
    }

    private fun dict(): Dict {
        val out = Dict()
        while (true) {
            val key = read()
            if (key === EndDict || key === Eof) break
            if (key !is PdfName) continue
            val value = read()
            if (value === EndDict || value === Eof) break
            if (value is Keyword) continue
            out[key.value] = value
        }
        return out
    }
}

private class XEntry(val type: Int, val a: Long, val b: Int, val position: Long)

private class ObjStm(val bytes: ByteArray, val first: Int, val offsets: Map<Int, Int>)

class PageEntry(
    val dict: Dict,
    val resources: Any?,
    val mediaBox: Any?,
    val cropBox: Any?,
    val rotate: Int,
)

class PdfFile(val data: ByteArray) {
    private val xref = HashMap<Int, XEntry>()
    private val cache = HashMap<Int, Any?>()
    private val stms = HashMap<Int, ObjStm?>()
    private var base = 0
    private var rebuilt = false
    var trailer: Dict = Dict()
        private set

    init {
        base = headerOffset()
        var ok = false
        try {
            readChain()
            ok = rootOk()
        } catch (_: Exception) {
            ok = false
        }
        if (!ok) rebuild()
        if (trailer["Encrypt"] != null) throw EncryptedException()
        if (!rootOk()) throw PdfException("damaged")
    }

    private fun headerOffset(): Int {
        val limit = minOf(data.size - 5, 1024)
        for (i in 0..maxOf(0, limit)) {
            if (data[i].toInt() == 37 && data[i + 1].toInt() == 80 && data[i + 2].toInt() == 68 && data[i + 3].toInt() == 70) return i
        }
        return 0
    }

    private fun rootOk(): Boolean {
        val root = dictOf(trailer["Root"]) ?: return false
        return root["Pages"] != null
    }

    private fun lastIndexOf(word: String, from: Int): Int {
        var i = minOf(from, data.size - word.length)
        while (i >= 0) {
            var match = true
            for (k in word.indices) {
                if (data[i + k].toInt() != word[k].code) {
                    match = false
                    break
                }
            }
            if (match) return i
            i--
        }
        return -1
    }

    private fun readChain() {
        val at = lastIndexOf("startxref", data.size)
        if (at < 0) throw PdfException("no startxref")
        val lexer = Lexer(data, at + 9, false)
        var offset: Long = (lexer.readInt() ?: throw PdfException("bad startxref")).toLong()
        val seen = HashSet<Long>()
        var first = true
        while (offset > 0 && offset + base < data.size && seen.add(offset)) {
            val lx = Lexer(data, (offset + base).toInt(), false)
            lx.skipSpace()
            val section: Dict
            if (lx.startsWith("xref")) {
                lx.pos += 4
                while (true) {
                    lx.skipSpace()
                    if (lx.startsWith("trailer")) break
                    val start = lx.readInt() ?: throw PdfException("bad xref")
                    val count = lx.readInt() ?: throw PdfException("bad xref")
                    for (i in 0 until count) {
                        val off = lx.readOffset() ?: throw PdfException("bad xref entry")
                        lx.readInt()
                        val flag = lx.readKeyword() ?: throw PdfException("bad xref entry")
                        val id = start + i
                        if (xref.containsKey(id)) continue
                        xref[id] = if (flag == "n") XEntry(1, off, 0, off) else XEntry(0, 0, 0, 0)
                    }
                }
                lx.pos += 7
                val read = Lexer(data, lx.pos, true).read()
                section = read as? Dict ?: throw PdfException("bad trailer")
                val hybrid = (section["XRefStm"] as? Number)?.toLong()
                if (hybrid != null && hybrid > 0 && hybrid + base < data.size) {
                    try {
                        readXrefStream((hybrid + base).toInt())
                    } catch (_: Exception) {
                    }
                }
            } else {
                section = readXrefStream((offset + base).toInt())
            }
            if (first) {
                trailer = Dict(section)
                first = false
            } else {
                for ((k, v) in section) {
                    if (!trailer.containsKey(k) && (k == "Root" || k == "Info" || k == "Encrypt" || k == "ID")) trailer[k] = v
                }
            }
            offset = (section["Prev"] as? Number)?.toLong() ?: 0L
        }
        if (first) throw PdfException("empty xref")
    }

    private fun Lexer.readOffset(): Long? {
        skipSpace()
        var value = 0L
        var count = 0
        while (pos < data.size && data[pos].toInt() in 48..57) {
            value = value * 10 + (data[pos].toInt() - 48)
            pos++
            count++
        }
        return if (count == 0) null else value
    }

    private fun readXrefStream(position: Int): Dict {
        val parsed = parseIndirectAt(position, null) as? PdfStream ?: throw PdfException("bad xref stream")
        val dict = parsed.dict
        val widths = (dict["W"] as? List<*>)?.map { (it as? Number)?.toInt() ?: 0 } ?: throw PdfException("no W")
        if (widths.size < 3) throw PdfException("bad W")
        val size = (dict["Size"] as? Number)?.toInt() ?: 0
        val index = (dict["Index"] as? List<*>)?.map { (it as? Number)?.toInt() ?: 0 } ?: listOf(0, size)
        val bytes = decode(parsed)
        val rowSize = widths[0] + widths[1] + widths[2]
        if (rowSize <= 0) throw PdfException("bad W")
        var cursor = 0
        var i = 0
        while (i + 1 < index.size) {
            val start = index[i]
            val count = index[i + 1]
            for (n in 0 until count) {
                if (cursor + rowSize > bytes.size) break
                fun field(width: Int, def: Long): Long {
                    if (width == 0) return def
                    var v = 0L
                    for (k in 0 until width) v = (v shl 8) or (bytes[cursor + k].toLong() and 0xFF)
                    cursor += width
                    return v
                }
                val type = field(widths[0], 1)
                val a = field(widths[1], 0)
                val b = field(widths[2], 0)
                val id = start + n
                if (xref.containsKey(id)) continue
                xref[id] = when (type.toInt()) {
                    0 -> XEntry(0, 0, 0, 0)
                    1 -> XEntry(1, a, b.toInt(), a)
                    2 -> XEntry(2, a, b.toInt(), a)
                    else -> XEntry(0, 0, 0, 0)
                }
            }
            i += 2
        }
        return dict
    }

    fun decode(stream: PdfStream): ByteArray {
        val filterValue = resolve(stream.dict["Filter"] ?: stream.dict["F"])
        val filters = ArrayList<String>()
        if (filterValue is PdfName) {
            filters.add(filterValue.value)
        } else if (filterValue is List<*>) {
            for (f in filterValue) (resolve(f) as? PdfName)?.let { filters.add(it.value) }
        }
        val parmsValue = resolve(stream.dict["DecodeParms"] ?: stream.dict["DP"])
        val parms = ArrayList<Dict?>()
        if (parmsValue is List<*>) {
            for (p in parmsValue) parms.add(dictOf(p))
        } else {
            parms.add(dictOf(parmsValue))
        }
        var bytes = stream.data.copyOfRange(stream.offset, stream.offset + stream.length)
        for ((i, name) in filters.withIndex()) {
            val p = if (i < parms.size) parms[i] else null
            bytes = when (name) {
                "FlateDecode", "Fl" -> flate(bytes, p)
                "ASCIIHexDecode", "AHx" -> asciiHex(bytes)
                else -> throw PdfException("unsupported filter $name")
            }
        }
        return bytes
    }

    private fun asciiHex(input: ByteArray): ByteArray {
        val out = ByteArrayOutputStream()
        var high = -1
        for (b in input) {
            val c = b.toInt() and 0xFF
            if (c == 62) break
            val v = when (c) {
                in 48..57 -> c - 48
                in 65..70 -> c - 55
                in 97..102 -> c - 87
                else -> -1
            }
            if (v < 0) continue
            if (high < 0) {
                high = v
            } else {
                out.write(high * 16 + v)
                high = -1
            }
        }
        if (high >= 0) out.write(high * 16)
        return out.toByteArray()
    }

    private fun flate(input: ByteArray, parms: Dict?): ByteArray {
        val inflater = Inflater()
        inflater.setInput(input)
        val out = ByteArrayOutputStream(input.size * 3)
        val buffer = ByteArray(65536)
        try {
            while (!inflater.finished()) {
                val n = inflater.inflate(buffer)
                if (n == 0 && (inflater.needsInput() || inflater.needsDictionary())) break
                out.write(buffer, 0, n)
            }
        } catch (_: Exception) {
        } finally {
            inflater.end()
        }
        var bytes = out.toByteArray()
        val predictor = (resolve(parms?.get("Predictor")) as? Number)?.toInt() ?: 1
        if (predictor >= 10) {
            bytes = pngPredictor(
                bytes,
                (resolve(parms?.get("Columns")) as? Number)?.toInt() ?: 1,
                (resolve(parms?.get("Colors")) as? Number)?.toInt() ?: 1,
                (resolve(parms?.get("BitsPerComponent")) as? Number)?.toInt() ?: 8,
            )
        }
        return bytes
    }

    private fun pngPredictor(data: ByteArray, columns: Int, colors: Int, bits: Int): ByteArray {
        val bpp = maxOf(1, (colors * bits + 7) / 8)
        val rowBytes = (columns * colors * bits + 7) / 8
        if (rowBytes <= 0) return data
        val stride = rowBytes + 1
        val rows = data.size / stride
        val out = ByteArray(rows * rowBytes)
        for (r in 0 until rows) {
            val filter = data[r * stride].toInt()
            val src = r * stride + 1
            val dst = r * rowBytes
            val prev = dst - rowBytes
            for (i in 0 until rowBytes) {
                val x = data[src + i].toInt() and 0xFF
                val a = if (i >= bpp) out[dst + i - bpp].toInt() and 0xFF else 0
                val b = if (r > 0) out[prev + i].toInt() and 0xFF else 0
                val c = if (i >= bpp && r > 0) out[prev + i - bpp].toInt() and 0xFF else 0
                val v = when (filter) {
                    1 -> x + a
                    2 -> x + b
                    3 -> x + ((a + b) shr 1)
                    4 -> {
                        val p = a + b - c
                        val pa = Math.abs(p - a)
                        val pb = Math.abs(p - b)
                        val pc = Math.abs(p - c)
                        x + (if (pa <= pb && pa <= pc) a else if (pb <= pc) b else c)
                    }
                    else -> x
                }
                out[dst + i] = v.toByte()
            }
        }
        return out
    }

    private fun startsAt(at: Int, word: String): Boolean {
        if (at < 0 || at + word.length > data.size) return false
        for (i in word.indices) {
            if (data[at + i].toInt() != word[i].code) return false
        }
        return true
    }

    private fun endstreamFollows(at: Int): Boolean {
        var p = at
        while (p < data.size && Lexer.isSpace(data[p].toInt() and 0xFF)) p++
        return startsAt(p, "endstream")
    }

    private fun indexOf(word: String, from: Int): Int {
        var i = from
        val last = data.size - word.length
        val first = word[0].code.toByte()
        while (i <= last) {
            if (data[i] == first && startsAt(i, word)) return i
            i++
        }
        return -1
    }

    private fun parseIndirectAt(position: Int, expected: Int?): Any? {
        if (position < 0 || position >= data.size) return null
        val lexer = Lexer(data, position, true)
        val id = lexer.readInt() ?: return null
        lexer.readInt() ?: return null
        if (lexer.readKeyword() != "obj") return null
        if (expected != null && id != expected) return null
        val value = lexer.read()
        if (value === lexer.eof) return null
        if (value is Keyword0) return null
        if (value !is Dict) return normalize(value)
        lexer.skipSpace()
        if (!lexer.startsWith("stream")) return value
        var p = lexer.pos + 6
        if (p < data.size && data[p].toInt() == 13) {
            p++
            if (p < data.size && data[p].toInt() == 10) p++
        } else if (p < data.size && data[p].toInt() == 10) {
            p++
        }
        val length = (resolveLength(value["Length"]))
        val end: Int
        if (length != null && length >= 0 && p + length <= data.size && endstreamFollows(p + length)) {
            end = p + length
        } else {
            val found = indexOf("endstream", p)
            var e = if (found < 0) data.size else found
            if (e > p && data[e - 1].toInt() == 10) e--
            if (e > p && data[e - 1].toInt() == 13) e--
            end = e
        }
        return PdfStream(value, data, p, end - p)
    }

    private fun resolveLength(value: Any?): Int? {
        if (value is Number) return value.toInt()
        if (value is PdfRef) {
            val entry = xref[value.id] ?: return null
            if (entry.type != 1) return null
            val v = parseIndirectAt((entry.a + base).toInt(), value.id)
            return (v as? Number)?.toInt()
        }
        return null
    }

    private fun normalize(value: Any?): Any? = if (value is Keyword0) null else value

    fun objectOrNull(id: Int): Any? {
        if (cache.containsKey(id)) return cache[id]
        cache[id] = null
        var value: Any? = null
        val entry = xref[id]
        if (entry != null) {
            when (entry.type) {
                1 -> {
                    value = parseIndirectAt((entry.a + base).toInt(), id)
                    if (value == null && !rebuilt) {
                        val before = rebuilt
                        rebuild()
                        cache.clear()
                        if (!before) return objectOrNull(id)
                    }
                }
                2 -> value = packed(entry.a.toInt(), id)
            }
        }
        cache[id] = value
        return value
    }

    private fun packed(holder: Int, id: Int): Any? {
        val stm = stms.getOrPut(holder) {
            val s = objectOrNull(holder) as? PdfStream ?: return@getOrPut null
            try {
                val bytes = decode(s)
                val n = (resolve(s.dict["N"]) as? Number)?.toInt() ?: 0
                val first = (resolve(s.dict["First"]) as? Number)?.toInt() ?: 0
                val lexer = Lexer(bytes, 0, false)
                val offsets = HashMap<Int, Int>()
                for (i in 0 until n) {
                    val num = lexer.readInt() ?: break
                    val off = lexer.readInt() ?: break
                    offsets[num] = off
                }
                ObjStm(bytes, first, offsets)
            } catch (_: Exception) {
                null
            }
        } ?: return null
        val off = stm.offsets[id] ?: return null
        val start = stm.first + off
        if (start < 0 || start >= stm.bytes.size) return null
        val v = Lexer(stm.bytes, start, true).read()
        return if (v === Eof) null else normalize(v)
    }

    fun resolve(value: Any?): Any? {
        var current = value
        var guard = 0
        while (current is PdfRef && guard < 32) {
            current = objectOrNull(current.id)
            guard++
        }
        return if (current is PdfRef) null else current
    }

    fun dictOf(value: Any?): Dict? {
        val r = resolve(value)
        if (r is PdfStream) return r.dict
        @Suppress("UNCHECKED_CAST")
        return r as? Dict
    }

    fun listOf(value: Any?): List<Any?>? = resolve(value) as? List<Any?>

    fun numOf(value: Any?): Double? = (resolve(value) as? Number)?.toDouble()

    fun nameOf(value: Any?): String? = (resolve(value) as? PdfName)?.value

    fun maxId(): Int = xref.keys.maxOrNull() ?: 0

    fun ids(): List<Int> = xref.keys.sorted()

    private fun rebuild() {
        rebuilt = true
        xref.clear()
        cache.clear()
        stms.clear()
        val text = String(data, Charsets.ISO_8859_1)
        val objects = Regex("(\\d{1,10})\\s+(\\d{1,5})\\s+obj\\b")
        val owners = ArrayList<IntArray>()
        for (m in objects.findAll(text)) {
            val id = m.groupValues[1].toIntOrNull() ?: continue
            val at = m.range.first
            val old = xref[id]
            if (old == null || at.toLong() >= old.position) xref[id] = XEntry(1, (at - base).toLong(), 0, at.toLong())
            owners.add(intArrayOf(at, id))
        }
        fun ownerOf(position: Int): Int? {
            var low = 0
            var high = owners.size - 1
            var best: Int? = null
            while (low <= high) {
                val mid = (low + high) ushr 1
                if (owners[mid][0] <= position) {
                    best = owners[mid][1]
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }
            return best
        }
        val candidates = ArrayList<Dict>()
        var from = 0
        while (true) {
            val at = text.indexOf("trailer", from)
            if (at < 0) break
            from = at + 7
            val v = Lexer(data, at + 7, true).read()
            if (v is Dict) candidates.add(v)
        }
        for (m in Regex("/Type\\s*/XRef").findAll(text)) {
            val id = ownerOf(m.range.first) ?: continue
            val entry = xref[id] ?: continue
            val s = parseIndirectAt((entry.a + base).toInt(), id)
            if (s is PdfStream) candidates.add(s.dict)
        }
        for (m in Regex("/Type\\s*/ObjStm").findAll(text)) {
            val id = ownerOf(m.range.first) ?: continue
            val entry = xref[id] ?: continue
            val s = parseIndirectAt((entry.a + base).toInt(), id) as? PdfStream ?: continue
            try {
                val bytes = decode(s)
                val n = (resolve(s.dict["N"]) as? Number)?.toInt() ?: 0
                val lexer = Lexer(bytes, 0, false)
                for (i in 0 until n) {
                    val num = lexer.readInt() ?: break
                    lexer.readInt() ?: break
                    val old = xref[num]
                    if (old == null || entry.position > old.position) xref[num] = XEntry(2, id.toLong(), i, entry.position)
                }
            } catch (_: Exception) {
            }
        }
        var found: Dict? = null
        for (c in candidates) {
            if (c["Root"] != null) found = c
        }
        if (found == null) {
            for (id in xref.keys.sorted()) {
                val d = dictOf(objectOrNull(id)) ?: continue
                if ((d["Type"] as? PdfName)?.value == "Catalog") {
                    found = Dict()
                    found["Root"] = PdfRef(id)
                }
            }
        }
        trailer = found ?: Dict()
        cache.clear()
        stms.clear()
    }

    private fun box(value: Any?): DoubleArray? {
        val list = listOf(value) ?: return null
        if (list.size < 4) return null
        val n = DoubleArray(4)
        for (i in 0 until 4) n[i] = numOf(list[i]) ?: return null
        return doubleArrayOf(minOf(n[0], n[2]), minOf(n[1], n[3]), maxOf(n[0], n[2]), maxOf(n[1], n[3]))
    }

    fun boxOf(value: Any?): DoubleArray? = box(value)

    fun pages(): List<PageEntry> {
        val out = ArrayList<PageEntry>()
        val root = dictOf(trailer["Root"]) ?: return out
        val seen = HashSet<Int>()
        class Frame(val node: Any?, val resources: Any?, val media: Any?, val crop: Any?, val rotate: Int)
        val stack = ArrayList<Frame>()
        stack.add(Frame(root["Pages"], null, null, null, 0))
        var guard = 0
        while (stack.isNotEmpty() && guard < 2_000_000) {
            guard++
            val frame = stack.removeAt(stack.size - 1)
            val node = frame.node
            if (node is PdfRef && !seen.add(node.id)) continue
            val d = dictOf(node) ?: continue
            val resources = d["Resources"] ?: frame.resources
            val media = d["MediaBox"] ?: frame.media
            val crop = d["CropBox"] ?: frame.crop
            val rotate = (numOf(d["Rotate"])?.toInt()) ?: frame.rotate
            val kids = listOf(d["Kids"])
            val type = nameOf(d["Type"])
            if (kids != null && type != "Page") {
                for (i in kids.indices.reversed()) stack.add(Frame(kids[i], resources, media, crop, rotate))
            } else {
                out.add(PageEntry(d, resources, media, crop, ((rotate % 360) + 360) % 360))
            }
        }
        if (out.isEmpty()) {
            for (id in ids()) {
                val d = dictOf(objectOrNull(id)) ?: continue
                if (nameOf(d["Type"]) == "Page") {
                    out.add(PageEntry(d, d["Resources"], d["MediaBox"], d["CropBox"], (((numOf(d["Rotate"])?.toInt()) ?: 0) % 360 + 360) % 360))
                }
            }
        }
        return out
    }
}

private typealias Keyword0 = Keyword
