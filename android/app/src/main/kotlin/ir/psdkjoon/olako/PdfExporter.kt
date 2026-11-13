package ir.psdkjoon.olako

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.DashPathEffect
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.pdf.PdfDocument
import android.os.Build
import android.text.Layout
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.StaticLayout
import android.text.TextDirectionHeuristic
import android.text.TextDirectionHeuristics
import android.text.TextPaint
import android.text.style.BackgroundColorSpan
import android.text.style.ForegroundColorSpan
import android.text.style.MetricAffectingSpan
import android.text.style.StrikethroughSpan
import android.text.style.UnderlineSpan
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import kotlin.math.max
import kotlin.math.min

private fun Map<*, *>.str(k: String): String = (this[k] as? String) ?: ""

private fun Map<*, *>.int(k: String, d: Int = 0): Int = (this[k] as? Number)?.toInt() ?: d

private fun Map<*, *>.dbl(k: String, d: Double = 0.0): Double = (this[k] as? Number)?.toDouble() ?: d

private fun Map<*, *>.flag(k: String): Boolean = (this[k] as? Boolean) ?: false

private fun Map<*, *>.nodes(k: String): List<Map<*, *>> =
    (this[k] as? List<*>)?.filterIsInstance<Map<*, *>>() ?: emptyList()

private fun Map<*, *>.argb(k: String): Int? = (this[k] as? Number)?.toLong()?.toInt()

class Opts(private val m: Map<*, *>) {
    fun str(k: String, d: String): String = (m[k] as? String) ?: d

    fun num(k: String, d: Double): Double = (m[k] as? Number)?.toDouble() ?: d

    fun f(k: String, d: Double): Float = num(k, d).toFloat()

    fun int(k: String, d: Int): Int = (m[k] as? Number)?.toInt() ?: d

    fun bool(k: String, d: Boolean): Boolean = (m[k] as? Boolean) ?: d

    fun color(k: String, d: Long): Int = ((m[k] as? Number)?.toLong() ?: d).toInt()
}

class Family(
    private val regular: Typeface,
    private val bold: Typeface?,
    private val italic: Typeface?,
    private val boldItalic: Typeface?,
    private val system: Boolean,
) {
    fun apply(paint: TextPaint, wantBold: Boolean, wantItalic: Boolean) {
        if (system) {
            val want = (if (wantBold) Typeface.BOLD else 0) or (if (wantItalic) Typeface.ITALIC else 0)
            val tf = Typeface.create(regular, want)
            val fake = want and tf.style.inv()
            if ((fake and Typeface.BOLD) != 0) paint.isFakeBoldText = true
            if ((fake and Typeface.ITALIC) != 0) paint.textSkewX = -0.25f
            paint.typeface = tf
            return
        }
        var tf = regular
        var gotBold = false
        var gotItalic = false
        if (wantBold && wantItalic && boldItalic != null) {
            tf = boldItalic
            gotBold = true
            gotItalic = true
        } else if (wantBold && bold != null) {
            tf = bold
            gotBold = true
        } else if (wantItalic && italic != null) {
            tf = italic
            gotItalic = true
        }
        if (wantBold && !gotBold) paint.isFakeBoldText = true
        if (wantItalic && !gotItalic) paint.textSkewX = -0.25f
        paint.typeface = tf
    }

    companion object {
        fun system(base: Typeface): Family = Family(base, null, null, null, true)
    }
}

class RunSpan(
    private val base: Family,
    private val bold: Boolean,
    private val italic: Boolean,
    private val size: Float,
    private val sup: Boolean,
    private val sub: Boolean,
) : MetricAffectingSpan() {
    override fun updateDrawState(paint: TextPaint) {
        apply(paint)
    }

    override fun updateMeasureState(paint: TextPaint) {
        apply(paint)
    }

    private fun apply(paint: TextPaint) {
        base.apply(paint, bold, italic)
        if (size > 0f) paint.textSize = size
        if (sup) paint.baselineShift += (paint.ascent() / 2f).toInt()
        if (sub) paint.baselineShift -= (paint.ascent() / 2f).toInt()
    }
}

private class Look(
    val size: Float,
    val color: Int,
    val bold: Boolean,
    val italic: Boolean,
    val face: Family,
    val mult: Float,
)

private class Ctx(val inset: Float, val bars: List<Float>, val quote: Boolean)

private class Img(val bitmap: Bitmap, val width: Int, val height: Int)

private class Entry(val level: Int, val text: String, val piece: Piece)

object PdfExporter {
    fun export(args: Map<*, *>): Map<String, Any?> {
        return try {
            PdfExport(args).run()
        } catch (e: Throwable) {
            mapOf("error" to (e.message ?: e.toString()))
        }
    }
}

private class PdfExport(private val args: Map<*, *>) {
    private val o = Opts((args["options"] as? Map<*, *>) ?: emptyMap<String, Any?>())
    private val title = (args["title"] as? String) ?: ""
    private val outPath = (args["path"] as? String) ?: ""
    private val dateText = (args["date"] as? String) ?: ""
    private val blocksIn: List<Map<*, *>> =
        (args["blocks"] as? List<*>)?.filterIsInstance<Map<*, *>>() ?: emptyList()

    private val direction = o.str("direction", "auto")
    private val docRtl = when (direction) {
        "rtl" -> true
        "ltr" -> false
        else -> (args["rtl"] as? Boolean) ?: false
    }
    private val dirMode = when (direction) {
        "rtl" -> 1
        "ltr" -> 0
        else -> -1
    }
    private val persian = o.str("digits", "latin") == "persian"

    private val bodyFace = family(o.str("font", "sans"))
    private val headFace = if (o.str("headingFont", "same") == "same") bodyFace else family(o.str("headingFont", "same"))
    private val codeFace = family(o.str("codeFont", "mono"))

    private val baseSize = o.f("fontSize", 11.0)
    private val lineMult = o.f("lineHeight", 1.45)
    private val paraSpace = o.f("paragraphSpacing", 8.0)
    private val itemSpace = o.f("listSpacing", 3.0)
    private val listIndent = o.f("listIndent", 20.0)
    private val textColor = o.color("textColor", 0xFF1B1B1F)
    private val headColor = o.color("headingColor", 0xFF111111)
    private val linkColor = o.color("linkColor", 0xFF1A5FB4)
    private val linkUnderline = o.bool("linkUnderline", true)
    private val hyphenate = o.bool("hyphenate", false)
    private val minLines = max(1, o.int("minLines", 2))

    private val sizeMm: Pair<Double, Double> = when (o.str("pageSize", "a4")) {
        "a3" -> 297.0 to 420.0
        "a5" -> 148.0 to 210.0
        "a6" -> 105.0 to 148.0
        "b5" -> 176.0 to 250.0
        "letter" -> 215.9 to 279.4
        "legal" -> 215.9 to 355.6
        "custom" -> max(30.0, o.num("customW", 210.0)) to max(30.0, o.num("customH", 297.0))
        else -> 210.0 to 297.0
    }
    private val landscape = o.str("orientation", "portrait") == "landscape"
    private val pageW = mm(if (landscape) max(sizeMm.first, sizeMm.second) else min(sizeMm.first, sizeMm.second))
    private val pageH = mm(if (landscape) min(sizeMm.first, sizeMm.second) else max(sizeMm.first, sizeMm.second))
    private val mTop = mm(o.num("marginTop", 22.0))
    private val mBottom = mm(o.num("marginBottom", 22.0))
    private val mInner = mm(o.num("marginInner", 22.0))
    private val mOuter = mm(o.num("marginOuter", 18.0))
    private val mirror = o.bool("mirror", false)
    private val cw = max(100f, pageW - mInner - mOuter)
    private val ch = max(100f, pageH - mTop - mBottom)
    private val pageColor = o.color("pageColor", 0xFFFFFFFF)

    private val cover = o.bool("cover", false)
    private val startPage = o.int("startPage", 1)
    private val skipFirst = o.bool("skipFirstPage", false)
    private val numberFormat = o.str("pageNumberFormat", "arabic")
    private val sectionLevel = max(1, o.int("sectionLevel", 1))

    private val bitmaps = ArrayList<Bitmap>()
    private val body = ArrayList<Piece>()
    private val entries = ArrayList<Entry>()
    private val counters = IntArray(6)

    private fun mm(v: Double): Float = (v * 72.0 / 25.4).toFloat()

    private fun loadFile(dir: File, name: String): Typeface? {
        for (extension in listOf("ttf", "otf", "ttc")) {
            val file = File(dir, "$name.$extension")
            if (!file.isFile) continue
            try {
                return Typeface.createFromFile(file)
            } catch (_: Exception) {
            }
        }
        return null
    }

    private fun family(spec: String): Family {
        if (spec.startsWith("dir:")) {
            val dir = File(spec.substring(4))
            val regular = loadFile(dir, "regular")
            if (regular != null) {
                return Family(regular, loadFile(dir, "bold"), loadFile(dir, "italic"), loadFile(dir, "bolditalic"), false)
            }
        }
        return Family.system(
            when (spec) {
                "serif" -> Typeface.SERIF
                "mono" -> Typeface.MONOSPACE
                else -> Typeface.SANS_SERIF
            },
        )
    }

    private fun digits(s: String): String {
        if (!persian) return s
        val sb = StringBuilder(s.length)
        for (d in s) {
            sb.append(if (d in '0'..'9') '۰' + (d - '0') else d)
        }
        return sb.toString()
    }

    private fun roman(n: Int): String {
        if (n <= 0) return n.toString()
        var v = n
        val vals = intArrayOf(1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1)
        val syms = arrayOf("m", "cm", "d", "cd", "c", "xc", "l", "xl", "x", "ix", "v", "iv", "i")
        val sb = StringBuilder()
        for (i in vals.indices) {
            while (v >= vals[i]) {
                sb.append(syms[i])
                v -= vals[i]
            }
        }
        return sb.toString()
    }

    private fun alpha(n: Int): String {
        if (n <= 0) return n.toString()
        var v = n
        val sb = StringBuilder()
        while (v > 0) {
            v--
            sb.insert(0, 'a' + (v % 26))
            v /= 26
        }
        return sb.toString()
    }

    private fun formatNumber(n: Int): String = when (numberFormat) {
        "roman" -> roman(n)
        "romanUpper" -> roman(n).uppercase()
        "alpha" -> alpha(n)
        else -> digits(n.toString())
    }

    private fun firstStrongRtl(text: CharSequence, fallback: Boolean): Boolean {
        var i = 0
        while (i < text.length) {
            val cp = Character.codePointAt(text, i)
            val d = Character.getDirectionality(cp)
            if (d == Character.DIRECTIONALITY_LEFT_TO_RIGHT) return false
            if (d == Character.DIRECTIONALITY_RIGHT_TO_LEFT || d == Character.DIRECTIONALITY_RIGHT_TO_LEFT_ARABIC) return true
            i += Character.charCount(cp)
        }
        return fallback
    }

    private fun heuristic(mode: Int): TextDirectionHeuristic = when (mode) {
        1 -> TextDirectionHeuristics.RTL
        0 -> TextDirectionHeuristics.LTR
        else -> if (docRtl) TextDirectionHeuristics.FIRSTSTRONG_RTL else TextDirectionHeuristics.FIRSTSTRONG_LTR
    }

    private fun layoutOf(
        text: CharSequence,
        paint: TextPaint,
        width: Float,
        align: Int,
        dir: Int,
        mult: Float,
        hyphen: Boolean,
        simple: Boolean = false,
    ): StaticLayout {
        val alignment = when (align) {
            1 -> Layout.Alignment.ALIGN_CENTER
            2 -> Layout.Alignment.ALIGN_OPPOSITE
            else -> Layout.Alignment.ALIGN_NORMAL
        }
        val builder = StaticLayout.Builder.obtain(text, 0, text.length, paint, max(1, width.toInt()))
            .setAlignment(alignment)
            .setIncludePad(false)
            .setLineSpacing(0f, mult)
            .setBreakStrategy(if (simple) Layout.BREAK_STRATEGY_SIMPLE else Layout.BREAK_STRATEGY_HIGH_QUALITY)
            .setHyphenationFrequency(if (hyphen) Layout.HYPHENATION_FREQUENCY_NORMAL else Layout.HYPHENATION_FREQUENCY_NONE)
            .setTextDirection(heuristic(dir))
        if (align == 3 && Build.VERSION.SDK_INT >= 26) {
            builder.setJustificationMode(Layout.JUSTIFICATION_MODE_INTER_WORD)
        }
        return builder.build()
    }

    private fun trailOf(layout: StaticLayout, mult: Float): Float {
        if (layout.lineCount == 0 || mult <= 1f) return 0f
        val last = layout.lineCount - 1
        val h = (layout.getLineDescent(last) - layout.getLineAscent(last)).toFloat()
        return h - h / mult
    }

    private fun paintFor(look: Look): TextPaint {
        val paint = TextPaint(Paint.ANTI_ALIAS_FLAG)
        look.face.apply(paint, look.bold, look.italic)
        paint.textSize = look.size
        paint.color = look.color
        return paint
    }

    private fun alignIndex(name: String): Int = when (name) {
        "center" -> 1
        "end" -> 2
        "justify" -> 3
        else -> 0
    }

    private fun headingSize(level: Int): Float = when (level) {
        1 -> o.f("h1Size", 26.0)
        2 -> o.f("h2Size", 20.0)
        3 -> o.f("h3Size", 16.0)
        4 -> o.f("h4Size", 13.5)
        5 -> o.f("h5Size", 12.0)
        else -> o.f("h6Size", 11.0)
    }

    private fun inlinesText(nodes: List<Map<*, *>>): String {
        val sb = StringBuilder()
        for (n in nodes) {
            when (n.str("k")) {
                "t" -> sb.append(n.str("s"))
                "br" -> sb.append(' ')
            }
        }
        return sb.toString()
    }

    private fun blocksText(blocks: List<Map<*, *>>): String {
        val sb = StringBuilder()
        for (b in blocks) {
            when (b.str("t")) {
                "p" -> sb.append(inlinesText(b.nodes("in"))).append(' ')
                "c" -> sb.append(b.str("s")).append(' ')
                "q", "g" -> sb.append(blocksText(b.nodes("ch")))
            }
        }
        return sb.toString()
    }

    private fun appendInline(sb: SpannableStringBuilder, n: Map<*, *>, look: Look) {
        when (n.str("k")) {
            "br" -> sb.append('\n')
            "t" -> {
                val text = n.str("s")
                if (text.isEmpty()) return
                val start = sb.length
                sb.append(text)
                val end = sb.length
                val code = n.flag("c")
                val linked = n.str("l").isNotEmpty()
                val sup = n.flag("sp")
                val sub = n.flag("sb")
                val explicit = n.dbl("z").toFloat()
                val size = when {
                    explicit > 0f -> explicit
                    code -> look.size * 0.9f
                    sup || sub -> look.size * 0.72f
                    else -> 0f
                }
                sb.setSpan(
                    RunSpan(
                        if (code) codeFace else look.face,
                        look.bold || n.flag("b"),
                        look.italic || n.flag("i"),
                        size,
                        sup,
                        sub,
                    ),
                    start,
                    end,
                    Spanned.SPAN_EXCLUSIVE_EXCLUSIVE,
                )
                var color = n.argb("col")
                if (color == null && linked) color = linkColor
                val codeColor = o.color("inlineCodeColor", 0)
                if (color == null && code && codeColor != 0) color = codeColor
                if (color != null) sb.setSpan(ForegroundColorSpan(color), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                var back = n.argb("bg")
                val codeBack = o.color("inlineCodeBackground", 0)
                if (back == null && code && codeBack != 0) back = codeBack
                if (back != null) sb.setSpan(BackgroundColorSpan(back), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                if (n.flag("u") || (linked && linkUnderline)) {
                    sb.setSpan(UnderlineSpan(), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                }
                if (n.flag("x")) sb.setSpan(StrikethroughSpan(), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
        }
    }

    private fun decode(bytes: ByteArray?): Img? {
        if (bytes == null || bytes.isEmpty()) return null
        val bounds = BitmapFactory.Options()
        bounds.inJustDecodeBounds = true
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        val longest = max(bounds.outWidth, bounds.outHeight)
        while (longest / sample > 2600) sample *= 2
        val opts = BitmapFactory.Options()
        opts.inSampleSize = sample
        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts) ?: return null
        bitmaps.add(bitmap)
        return Img(bitmap, bounds.outWidth, bounds.outHeight)
    }

    private fun imagePiece(n: Map<*, *>, ctx: Ctx, out: MutableList<Piece>) {
        val img = decode(n["d"] as? ByteArray) ?: return
        var w = img.width * 0.75f
        var h = img.height * 0.75f
        val wp = n.dbl("w").toFloat()
        val hp = n.dbl("h").toFloat()
        if (wp > 0f && hp > 0f) {
            w = wp
            h = hp
        } else if (wp > 0f) {
            h = h * wp / w
            w = wp
        } else if (hp > 0f) {
            w = w * hp / h
            h = hp
        }
        val maxW = (cw - ctx.inset) * o.f("imageWidth", 100.0) / 100f
        val maxH = ch * 0.92f
        var s = min(maxW / w, maxH / h)
        if (!o.bool("imageFill", false) && s > 1f) s = 1f
        w *= s
        h *= s
        val piece = ImagePiece(img.bitmap, w, h, o.str("imageAlign", "center") == "center")
        piece.rtl = docRtl
        piece.insetStart = ctx.inset
        piece.bars = ctx.bars
        piece.barColor = o.color("quoteBarColor", 0xFF9AA0A6)
        piece.before = paraSpace / 2f
        piece.after = paraSpace
        out.add(piece)
        val alt = n.str("alt")
        if (o.bool("imageCaptions", false) && alt.isNotEmpty()) {
            val look = Look(baseSize * 0.85f, o.color("mutedColor", 0xFF6B6F76), false, true, bodyFace, lineMult)
            val sb = SpannableStringBuilder(alt)
            sb.setSpan(RunSpan(bodyFace, false, true, 0f, false, false), 0, sb.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            val paint = paintFor(look)
            val layout = layoutOf(sb, paint, cw - ctx.inset, 1, dirMode, lineMult, false)
            val caption = TextPiece(layout, trail = trailOf(layout, lineMult))
            caption.rtl = firstStrongRtl(alt, docRtl)
            caption.insetStart = ctx.inset
            caption.bars = ctx.bars
            caption.barColor = piece.barColor
            caption.after = paraSpace
            out.add(caption)
        }
    }

    private fun paragraph(b: Map<*, *>, ctx: Ctx, out: MutableList<Piece>, nextIsItem: Boolean) {
        val level = b.int("h", 0)
        val listLevel = b.int("ll", -1)
        val isItem = listLevel >= 0 && level == 0
        val quoteColor = o.color("quoteColor", 0)
        val look = when {
            level > 0 -> Look(
                headingSize(level),
                headColor,
                o.bool("headingBold", true),
                false,
                headFace,
                max(1.05f, min(lineMult, 1.3f)),
            )
            else -> Look(
                baseSize,
                if (ctx.quote && quoteColor != 0) quoteColor else textColor,
                false,
                ctx.quote && o.bool("quoteItalic", false),
                bodyFace,
                lineMult,
            )
        }
        val inset = ctx.inset + (if (isItem) listIndent * (listLevel + 1) else 0f) + b.dbl("ind").toFloat()
        val inlines = b.nodes("in")
        val explicitAlign = b.int("a", 0)
        val align = when {
            level > 0 -> {
                val h = o.str("headingAlign", "start")
                if (h == "same") (if (explicitAlign != 0) explicitAlign else alignIndex(o.str("align", "start"))) else alignIndex(h)
            }
            explicitAlign != 0 -> explicitAlign
            else -> alignIndex(o.str("align", "start"))
        }
        val dir = if (dirMode >= 0) dirMode else when (b.int("r", -1)) {
            1 -> 1
            0 -> 0
            else -> -1
        }
        val background = b.argb("bg")
        var sb = SpannableStringBuilder()
        var first = true

        fun emit(last: Boolean) {
            var text: SpannableStringBuilder = sb
            sb = SpannableStringBuilder()
            while (text.isNotEmpty() && text[text.length - 1] == '\n') text = text.delete(text.length - 1, text.length)
            if (text.isBlank()) return
            var plain = text.toString()
            if (level > 0 && first && o.bool("numberHeadings", false)) {
                counters[level - 1]++
                for (i in level until 6) counters[i] = 0
                var from = 0
                while (from < level - 1 && counters[from] == 0) from++
                val sbn = StringBuilder()
                for (i in from until level) {
                    sbn.append(counters[i])
                    if (i < level - 1) sbn.append('.')
                }
                val prefix = digits(sbn.toString()) + "  "
                text.insert(0, prefix)
                plain = text.toString()
            }
            val paint = paintFor(look)
            val pieceRtl = when (dir) {
                1 -> true
                0 -> false
                else -> firstStrongRtl(plain, docRtl)
            }
            val width = cw - inset - (if (background != null) 8f else 0f)
            val hyphen = hyphenate && level == 0
            val layout = layoutOf(text, paint, width, align, dir, look.mult, hyphen)
            val markerText = if (isItem && first) digits(b.str("m")) else ""
            val markerPaint = if (markerText.isNotEmpty()) paintFor(Look(baseSize, textColor, false, false, bodyFace, 1f)) else null
            val piece = TextPiece(
                layout,
                padTop = if (background != null) 3f else 0f,
                padBottom = if (background != null) 3f else 0f,
                padSide = if (background != null) 4f else 0f,
                fill = background ?: 0,
                radius = 3f,
                marker = markerText,
                markerPaint = markerPaint,
                markerGap = 5f,
                canSplit = level == 0,
                trail = trailOf(layout, look.mult),
            )
            piece.rtl = pieceRtl
            piece.insetStart = inset
            piece.bars = ctx.bars
            piece.barColor = o.color("quoteBarColor", 0xFF9AA0A6)
            val spaceBefore = b.dbl("sb").toFloat()
            if (level > 0) {
                piece.before = max(o.f("headingBefore", 18.0), spaceBefore)
                piece.after = o.f("headingAfter", 8.0)
                piece.keepWithNext = o.bool("keepHeadingWithNext", true)
                piece.headingLevel = level
                piece.headingText = plain.trim()
                val breakLevel = o.int("breakLevel", 0)
                piece.breakBefore = first && breakLevel > 0 && level <= breakLevel
                entries.add(Entry(level, plain.trim(), piece))
            } else if (isItem) {
                piece.before = spaceBefore
                piece.after = if (last && !nextIsItem) paraSpace else itemSpace
            } else {
                piece.before = spaceBefore
                piece.after = paraSpace
            }
            out.add(piece)
            if (level > 0 && level <= o.int("headingRuleLevel", 0)) {
                piece.after = 3f
                piece.keepWithNext = true
                val rule = RulePiece(o.color("ruleColor", 0xFFC9CCD1), 0.8f)
                rule.rtl = pieceRtl
                rule.insetStart = inset
                rule.bars = ctx.bars
                rule.before = 3f
                rule.after = o.f("headingAfter", 8.0)
                rule.keepWithNext = true
                out.add(rule)
            }
            first = false
        }

        for (n in inlines) {
            if (n.str("k") == "img") {
                emit(false)
                imagePiece(n, ctx, out)
            } else {
                appendInline(sb, n, look)
            }
        }
        emit(true)
    }

    private fun code(b: Map<*, *>, ctx: Ctx, out: MutableList<Piece>) {
        var text = b.str("s").replace("\t", "    ")
        while (text.endsWith("\n")) text = text.substring(0, text.length - 1)
        if (text.isEmpty()) text = " "
        val size = o.f("codeSize", 9.5)
        val mult = o.f("codeLineHeight", 1.3)
        val look = Look(size, o.color("codeColor", 0xFF24292F), false, false, codeFace, mult)
        val paint = paintFor(look)
        val pad = o.f("codePadding", 8.0)
        val width = cw - ctx.inset - pad * 2f
        val layout = layoutOf(text, paint, width, 0, 0, mult, false, true)
        val piece = TextPiece(
            layout,
            padTop = pad,
            padBottom = pad,
            padSide = pad,
            fill = o.color("codeBackground", 0xFFF1F3F5),
            radius = o.f("codeRadius", 4.0),
            canSplit = !o.bool("keepCodeTogether", false),
            trail = trailOf(layout, mult),
        )
        piece.rtl = docRtl
        piece.insetStart = ctx.inset
        piece.bars = ctx.bars
        piece.barColor = o.color("quoteBarColor", 0xFF9AA0A6)
        piece.before = 0f
        piece.after = paraSpace
        out.add(piece)
    }

    private fun rule(b: Map<*, *>, ctx: Ctx, out: MutableList<Piece>) {
        val action = if (b.flag("pb")) "pagebreak" else o.str("ruleAction", "line")
        when (action) {
            "pagebreak" -> {
                val piece = BreakPiece()
                piece.breakBefore = true
                out.add(piece)
            }
            "ignore" -> {}
            else -> {
                val piece = RulePiece(o.color("ruleColor", 0xFFC9CCD1), o.f("ruleThickness", 0.8))
                piece.rtl = docRtl
                piece.insetStart = ctx.inset
                piece.bars = ctx.bars
                piece.barColor = o.color("quoteBarColor", 0xFF9AA0A6)
                piece.before = paraSpace
                piece.after = paraSpace
                out.add(piece)
            }
        }
    }

    private fun cellLayouts(
        blocks: List<Map<*, *>>,
        width: Float,
        align: Int,
        look: Look,
        rtl: Boolean,
        out: MutableList<StaticLayout>,
    ) {
        for (b in blocks) {
            when (b.str("t")) {
                "p" -> {
                    val sb = SpannableStringBuilder()
                    if (b.int("ll", -1) >= 0 && b.str("m").isNotEmpty()) sb.append(digits(b.str("m"))).append(' ')
                    for (n in b.nodes("in")) appendInline(sb, n, look)
                    if (sb.isNotEmpty()) {
                        val a = if (b.int("a", 0) != 0) b.int("a", 0) else align
                        out.add(layoutOf(sb, paintFor(look), width, if (a == 3) 0 else a, if (dirMode >= 0) dirMode else if (rtl) 1 else -1, look.mult, false))
                    }
                }
                "c" -> {
                    val text = b.str("s").replace("\t", "    ").trimEnd('\n')
                    if (text.isNotEmpty()) {
                        val codeLook = Look(look.size * 0.9f, look.color, false, false, codeFace, 1.15f)
                        out.add(layoutOf(text, paintFor(codeLook), width, 0, 0, 1.15f, false, true))
                    }
                }
                "q", "g" -> cellLayouts(b.nodes("ch"), width, align, look, rtl, out)
            }
        }
    }

    private fun table(b: Map<*, *>, ctx: Ctx, out: MutableList<Piece>) {
        val rows = b.nodes("rows")
        if (rows.isEmpty()) return
        var cols = 0
        for (r in rows) {
            var n = 0
            for (c in r.nodes("cells")) n += max(1, c.int("span", 1))
            cols = max(cols, n)
        }
        if (cols == 0) return
        val tableW = cw - ctx.inset
        val given = (b["w"] as? List<*>)?.mapNotNull { (it as? Number)?.toDouble() } ?: emptyList()
        val weights = DoubleArray(cols)
        if (given.size == cols && given.sum() > 0.0) {
            for (i in 0 until cols) weights[i] = max(0.05, given[i])
        } else {
            for (i in 0 until cols) weights[i] = 6.0
            for (r in rows) {
                var col = 0
                for (c in r.nodes("cells")) {
                    val span = max(1, c.int("span", 1))
                    if (span == 1 && col < cols) {
                        val len = min(40, blocksText(c.nodes("ch")).length).toDouble()
                        if (len > weights[col]) weights[col] = len
                    }
                    col += span
                }
            }
        }
        val total = weights.sum()
        val colW = FloatArray(cols) { (weights[it] / total * tableW).toFloat() }
        val pad = o.f("tablePadding", 5.0)
        val size = baseSize * o.f("tableFontScale", 0.92)
        val border = o.str("tableBorder", "grid")
        val borderColor = o.color("tableBorderColor", 0xFFB8BDC4)
        val borderWidth = o.f("tableBorderWidth", 0.6)
        val headerFill = o.color("tableHeaderBackground", 0xFFE9ECEF)
        val headerText = o.color("tableHeaderColor", 0xFF111111)
        val zebraFill = o.color("tableZebraColor", 0xFFF6F7F8)
        val zebra = o.bool("tableZebra", true)
        val repeat = o.bool("repeatTableHeader", true)
        var firstText = ""
        for (r in rows) {
            for (c in r.nodes("cells")) {
                if (firstText.isEmpty()) firstText = blocksText(c.nodes("ch")).trim()
            }
        }
        val tableRtl = firstStrongRtl(firstText, docRtl)
        var headerPiece: RowPiece? = null
        var bodyIndex = 0
        val pieces = ArrayList<RowPiece>()
        for (r in rows) {
            val header = r.flag("h")
            var col = 0
            val boxes = ArrayList<CellBox>()
            for (c in r.nodes("cells")) {
                val span = max(1, c.int("span", 1))
                if (col >= cols) break
                var wcell = 0f
                for (k in col until min(cols, col + span)) wcell += colW[k]
                val look = Look(
                    size,
                    if (header) headerText else textColor,
                    header,
                    false,
                    bodyFace,
                    max(1.1f, min(lineMult, 1.35f)),
                )
                val layouts = ArrayList<StaticLayout>()
                cellLayouts(c.nodes("ch"), wcell - pad * 2f, c.int("a", 0), look, tableRtl, layouts)
                boxes.add(CellBox(CellContent(layouts, 3f), col, span, c.argb("bg") ?: 0))
                col += span
            }
            val piece = RowPiece(
                boxes,
                colW,
                pad,
                header,
                borderColor,
                borderWidth,
                border,
                headerFill,
                zebraFill,
                zebra && !header && bodyIndex % 2 == 1,
            )
            if (!header) bodyIndex++
            piece.rtl = tableRtl
            piece.insetStart = ctx.inset
            piece.bars = ctx.bars
            piece.barColor = o.color("quoteBarColor", 0xFF9AA0A6)
            piece.keepWithNext = header
            if (header && headerPiece == null) headerPiece = piece
            if (!header && repeat) piece.headerRow = headerPiece
            pieces.add(piece)
        }
        if (pieces.isEmpty()) return
        pieces.first().before = paraSpace
        pieces.last().after = paraSpace
        out.addAll(pieces)
    }

    private fun buildBlocks(blocks: List<Map<*, *>>, ctx: Ctx, out: MutableList<Piece>) {
        for ((i, b) in blocks.withIndex()) {
            when (b.str("t")) {
                "p" -> {
                    val next = blocks.getOrNull(i + 1)
                    val nextIsItem = next != null && next.str("t") == "p" && next.int("ll", -1) >= 0 && next.int("h", 0) == 0
                    paragraph(b, ctx, out, nextIsItem)
                }
                "c" -> code(b, ctx, out)
                "q" -> {
                    val barWidth = 2.5f
                    val gap = o.f("quoteIndent", 12.0)
                    val inner = Ctx(ctx.inset + barWidth + gap, ctx.bars + (ctx.inset + 1f), true)
                    buildBlocks(b.nodes("ch"), inner, out)
                }
                "g" -> buildBlocks(b.nodes("ch"), Ctx(ctx.inset + b.int("n", 1) * listIndent, ctx.bars, ctx.quote), out)
                "r" -> rule(b, ctx, out)
                "tb" -> table(b, ctx, out)
            }
        }
    }

    private fun displayNumber(phys: Int, coverCount: Int): Int = phys - coverCount + startPage

    private fun expand(text: String, phys: Int, coverCount: Int, lastPhys: Int, section: String): String {
        if (text.isEmpty()) return text
        return text
            .replace("{title}", title)
            .replace("{page}", formatNumber(displayNumber(phys, coverCount)))
            .replace("{pages}", formatNumber(displayNumber(lastPhys, coverCount)))
            .replace("{date}", dateText)
            .replace("{section}", section)
    }

    private fun fillBackground(c: Canvas) {
        if (pageColor != -1) c.drawColor(pageColor)
    }

    private fun drawBorder(c: Canvas) {
        if (!o.bool("border", false)) return
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        paint.style = Paint.Style.STROKE
        paint.color = o.color("borderColor", 0xFF444444)
        val width = o.f("borderWidth", 1.0)
        paint.strokeWidth = width
        val style = o.str("borderStyle", "solid")
        if (style == "dashed") paint.pathEffect = DashPathEffect(floatArrayOf(7f, 4f), 0f)
        val inset = mm(o.num("borderInset", 8.0))
        c.drawRect(RectF(inset, inset, pageW - inset, pageH - inset), paint)
        if (style == "double") {
            val extra = inset + width * 3f
            c.drawRect(RectF(extra, extra, pageW - extra, pageH - extra), paint)
        }
    }

    private fun drawWatermark(c: Canvas) {
        val text = o.str("watermark", "")
        if (text.isEmpty()) return
        val paint = TextPaint(Paint.ANTI_ALIAS_FLAG)
        bodyFace.apply(paint, true, false)
        var size = o.f("watermarkSize", 72.0)
        paint.textSize = size
        val limit = Math.hypot(pageW.toDouble(), pageH.toDouble()).toFloat() * 0.8f
        val measured = paint.measureText(text)
        if (measured > limit) {
            size *= limit / measured
            paint.textSize = size
        }
        paint.color = o.color("watermarkColor", 0xFF888888)
        paint.alpha = ((o.f("watermarkOpacity", 15.0) / 100f).coerceIn(0f, 1f) * 255f).toInt()
        paint.textAlign = Paint.Align.CENTER
        c.save()
        c.rotate(-o.f("watermarkAngle", 45.0), pageW / 2f, pageH / 2f)
        c.drawText(text, pageW / 2f, pageH / 2f - (paint.ascent() + paint.descent()) / 2f, paint)
        c.restore()
    }

    private fun drawBand(c: Canvas, phys: Int, coverCount: Int, lastPhys: Int, section: String, left: Float, header: Boolean) {
        val prefix = if (header) "header" else "footer"
        val l = expand(o.str(prefix + "Left", ""), phys, coverCount, lastPhys, section)
        val m = expand(o.str(prefix + "Center", ""), phys, coverCount, lastPhys, section)
        val r = expand(o.str(prefix + "Right", ""), phys, coverCount, lastPhys, section)
        if (l.isEmpty() && m.isEmpty() && r.isEmpty()) return
        val paint = TextPaint(Paint.ANTI_ALIAS_FLAG)
        bodyFace.apply(paint, false, false)
        paint.textSize = o.f("bandSize", 9.0)
        paint.color = o.color("bandColor", 0xFF666A70)
        val dist = mm(o.num(prefix + "Distance", 10.0))
        val metrics = paint.fontMetrics
        val baseline = if (header) dist - metrics.ascent else pageH - dist - metrics.descent
        if (l.isNotEmpty()) {
            paint.textAlign = Paint.Align.LEFT
            c.drawText(l, left, baseline, paint)
        }
        if (m.isNotEmpty()) {
            paint.textAlign = Paint.Align.CENTER
            c.drawText(m, left + cw / 2f, baseline, paint)
        }
        if (r.isNotEmpty()) {
            paint.textAlign = Paint.Align.RIGHT
            c.drawText(r, left + cw, baseline, paint)
        }
        if (o.bool(prefix + "Rule", false)) {
            val line = Paint(Paint.ANTI_ALIAS_FLAG)
            line.color = o.color("ruleColor", 0xFFC9CCD1)
            line.strokeWidth = 0.7f
            val y = if (header) baseline + metrics.descent + 4f else baseline + metrics.ascent - 4f
            c.drawLine(left, y, left + cw, y, line)
        }
    }

    private fun leftMargin(phys: Int, coverCount: Int): Float {
        var innerLeft = !docRtl
        if (mirror && displayNumber(phys, coverCount) % 2 == 0) innerLeft = !innerLeft
        return if (innerLeft) mInner else mOuter
    }

    private fun drawCover(c: Canvas) {
        val back = o.color("coverBackground", 0)
        if (back != 0) c.drawColor(back) else fillBackground(c)
        val color = o.color("coverColor", 0xFF111111)
        val alignName = o.str("coverAlign", "center")
        val align = alignIndex(alignName)
        val left = if (docRtl) mOuter else mInner
        val titleText = o.str("coverTitle", "").ifEmpty { title }
        val subText = o.str("coverSubtitle", "")
        val authorText = o.str("coverAuthor", "")
        val dateLine = if (o.bool("coverDate", false)) dateText else ""
        val layouts = ArrayList<Pair<StaticLayout, Float>>()
        fun add(text: String, size: Float, bold: Boolean, alpha: Int, gapAfter: Float) {
            if (text.isEmpty()) return
            val look = Look(size, color, bold, false, if (bold) headFace else bodyFace, 1.2f)
            val paint = paintFor(look)
            paint.alpha = alpha
            layouts.add(layoutOf(text, paint, cw, align, -1, 1.2f, false) to gapAfter)
        }
        add(titleText, o.f("coverTitleSize", 34.0), true, 255, 14f)
        add(subText, o.f("coverSubtitleSize", 16.0), false, 200, 22f)
        add(authorText, 13f, false, 220, 6f)
        add(dateLine, 12f, false, 170, 0f)
        val ruleOn = o.bool("coverRule", true)
        var height = 0f
        for ((layout, gap) in layouts) height += layout.height + gap
        if (ruleOn) height += 22f
        val centerY = pageH * (o.f("coverPosition", 38.0) / 100f).coerceIn(0.05f, 0.95f)
        val top = (centerY - height / 2f).coerceIn(mTop, max(mTop, pageH - mBottom - height))
        var y = top
        for ((index, entry) in layouts.withIndex()) {
            val layout = entry.first
            c.save()
            c.translate(left, y)
            layout.draw(c)
            c.restore()
            y += layout.height + entry.second
            if (index == 0 && ruleOn) {
                val line = Paint(Paint.ANTI_ALIAS_FLAG)
                line.color = o.color("accentColor", 0xFF1A5FB4)
                line.strokeWidth = 3f
                line.strokeCap = Paint.Cap.ROUND
                val len = 64f
                val rtlSide = docRtl
                val x0 = when (alignName) {
                    "center" -> left + (cw - len) / 2f
                    "end" -> if (rtlSide) left else left + cw - len
                    else -> if (rtlSide) left + cw - len else left
                }
                c.drawLine(x0, y - 4f, x0 + len, y - 4f, line)
                y += 18f
            }
        }
    }

    fun run(): Map<String, Any?> {
        if (outPath.isEmpty()) return mapOf("error" to "no path")
        var written = 0
        try {
            buildBlocks(blocksIn, Ctx(0f, emptyList(), false), body)
            val coverCount = if (cover) 1 else 0

            val tocPieces = ArrayList<Piece>()
            val tocMap = ArrayList<Pair<TocPiece, Piece>>()
            if (o.bool("toc", false)) {
                val depth = o.int("tocDepth", 3)
                val listed = entries.filter { it.level <= depth }
                if (listed.isNotEmpty()) {
                    val titleLook = Look(headingSize(1), headColor, o.bool("headingBold", true), false, headFace, 1.2f)
                    val titleText = o.str("tocTitle", "")
                    if (titleText.isNotEmpty()) {
                        val layout = layoutOf(titleText, paintFor(titleLook), cw, 0, -1, 1.2f, false)
                        val heading = TextPiece(layout, canSplit = false, trail = trailOf(layout, 1.2f))
                        heading.rtl = firstStrongRtl(titleText, docRtl)
                        heading.after = 14f
                        heading.keepWithNext = true
                        tocPieces.add(heading)
                    }
                    var minLevel = 6
                    for (e in listed) minLevel = min(minLevel, e.level)
                    val tocSize = o.f("tocSize", 11.0)
                    for (e in listed) {
                        val indent = (e.level - minLevel) * 14f
                        val look = Look(tocSize, textColor, e.level == minLevel, false, bodyFace, 1.2f)
                        val paint = paintFor(look)
                        val numberPaint = paintFor(Look(tocSize, textColor, false, false, bodyFace, 1f))
                        val numberWidth = numberPaint.measureText(digits("0000"))
                        val layout = layoutOf(
                            e.text,
                            paint,
                            cw - indent - numberWidth - TocPiece.GAP,
                            0,
                            dirMode,
                            1.2f,
                            false,
                        )
                        val piece = TocPiece(
                            layout,
                            numberPaint,
                            numberWidth,
                            o.bool("tocLeader", true),
                            o.color("ruleColor", 0xFF9AA0A6),
                        )
                        piece.rtl = firstStrongRtl(e.text, docRtl)
                        piece.insetStart = indent
                        piece.before = if (e.level == minLevel) 5f else 0f
                        piece.after = 3f
                        tocPieces.add(piece)
                        tocMap.add(piece to e.piece)
                    }
                }
            }

            val tocPages: List<PageContent> = if (tocPieces.isEmpty()) emptyList() else Paginator.paginate(tocPieces, ch, 1, null)
            val headingPages = HashMap<Piece, Int>()
            val bodyPages = Paginator.paginate(body, ch, minLines, headingPages)
            val offset = coverCount + tocPages.size
            val lastPhys = offset + bodyPages.size - 1
            for ((piece, target) in tocMap) {
                val index = headingPages[target] ?: 0
                piece.number = formatNumber(displayNumber(offset + index, coverCount))
            }

            val doc = PdfDocument()
            try {
                var phys = 0
                if (cover) {
                    val info = PdfDocument.PageInfo.Builder(Math.round(pageW), Math.round(pageH), phys + 1).create()
                    val page = doc.startPage(info)
                    drawCover(page.canvas)
                    doc.finishPage(page)
                    phys++
                }
                var section = ""
                val all = ArrayList<PageContent>()
                all.addAll(tocPages)
                all.addAll(bodyPages)
                for ((index, content) in all.withIndex()) {
                    val isBody = index >= tocPages.size
                    if (isBody) {
                        for (placed in content.items) {
                            val piece = placed.piece
                            if (placed.from == 0 && piece.headingLevel in 1..sectionLevel) {
                                section = piece.headingText
                                break
                            }
                        }
                    }
                    val info = PdfDocument.PageInfo.Builder(Math.round(pageW), Math.round(pageH), phys + 1).create()
                    val page = doc.startPage(info)
                    val c = page.canvas
                    fillBackground(c)
                    drawBorder(c)
                    drawWatermark(c)
                    val left = leftMargin(phys, coverCount)
                    for (placed in content.items) {
                        placed.piece.draw(c, left, mTop + placed.y, cw, placed.from, placed.to)
                    }
                    val hidden = skipFirst && phys == coverCount
                    if (!hidden) {
                        drawBand(c, phys, coverCount, lastPhys, section, left, true)
                        drawBand(c, phys, coverCount, lastPhys, section, left, false)
                    }
                    doc.finishPage(page)
                    phys++
                }
                val file = File(outPath)
                file.parentFile?.mkdirs()
                BufferedOutputStream(FileOutputStream(file)).use { doc.writeTo(it) }
                written = phys
            } finally {
                doc.close()
            }
        } finally {
            for (b in bitmaps) {
                if (!b.isRecycled) b.recycle()
            }
        }
        return mapOf("path" to outPath, "pages" to written)
    }
}
