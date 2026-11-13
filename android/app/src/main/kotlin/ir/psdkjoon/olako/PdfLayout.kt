package ir.psdkjoon.olako

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.DashPathEffect
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.text.StaticLayout
import android.text.TextPaint

abstract class Piece {
    var before = 0f
    var after = 0f
    var keepWithNext = false
    var breakBefore = false
    var headingLevel = 0
    var headingText = ""
    var rtl = false
    var insetStart = 0f
    var insetEnd = 0f
    var bars: List<Float> = emptyList()
    var barColor = 0
    var barWidth = 2.5f

    open val lines: Int get() = 1
    open val splittable: Boolean get() = false

    abstract fun heightOf(from: Int, to: Int): Float

    open fun minChunk(minLines: Int): Float = heightOf(0, lines)

    fun left(x: Float, w: Float): Float = if (rtl) x + insetEnd else x + insetStart

    fun innerWidth(w: Float): Float = w - insetStart - insetEnd

    abstract fun drawBody(c: Canvas, x: Float, y: Float, w: Float, from: Int, to: Int)

    fun draw(c: Canvas, x: Float, y: Float, w: Float, from: Int, to: Int) {
        if (bars.isNotEmpty()) {
            val paint = Paint(Paint.ANTI_ALIAS_FLAG)
            paint.color = barColor
            paint.style = Paint.Style.FILL
            val height = heightOf(from, to)
            for (offset in bars) {
                val bx = if (rtl) x + w - offset - barWidth else x + offset
                c.drawRect(bx, y, bx + barWidth, y + height, paint)
            }
        }
        drawBody(c, x, y, w, from, to)
    }

    fun fit(start: Int, available: Float): Int {
        var end = start
        while (end < lines) {
            if (heightOf(start, end + 1) > available) break
            end++
        }
        return end
    }
}

class BreakPiece : Piece() {
    override val lines: Int get() = 0

    override fun heightOf(from: Int, to: Int): Float = 0f

    override fun drawBody(c: Canvas, x: Float, y: Float, w: Float, from: Int, to: Int) {}
}

class TextPiece(
    val layout: StaticLayout,
    val padTop: Float = 0f,
    val padBottom: Float = 0f,
    val padSide: Float = 0f,
    val fill: Int = 0,
    val radius: Float = 0f,
    val marker: String = "",
    val markerPaint: TextPaint? = null,
    val markerGap: Float = 0f,
    val canSplit: Boolean = true,
    val trail: Float = 0f,
) : Piece() {
    override val lines: Int get() = layout.lineCount

    override val splittable: Boolean get() = canSplit

    override fun heightOf(from: Int, to: Int): Float {
        if (to <= from) return 0f
        val text = (layout.getLineBottom(to - 1) - layout.getLineTop(from)).toFloat()
        val top = if (from == 0) padTop else 0f
        val bottom = if (to >= lines) padBottom - trail else 0f
        return text + top + bottom
    }

    override fun minChunk(minLines: Int): Float {
        val n = if (minLines < lines) minLines else lines
        return heightOf(0, if (n < 1) 1 else n)
    }

    override fun drawBody(c: Canvas, x: Float, y: Float, w: Float, from: Int, to: Int) {
        if (to <= from) return
        val boxLeft = left(x, w)
        val boxWidth = innerWidth(w)
        val total = heightOf(from, to)
        if (fill != 0) {
            val paint = Paint(Paint.ANTI_ALIAS_FLAG)
            paint.color = fill
            paint.style = Paint.Style.FILL
            val rect = RectF(boxLeft, y, boxLeft + boxWidth, y + total)
            if (radius > 0f) c.drawRoundRect(rect, radius, radius, paint) else c.drawRect(rect, paint)
        }
        val top = if (from == 0) padTop else 0f
        val lineTop = layout.getLineTop(from).toFloat()
        val lineBottom = layout.getLineBottom(to - 1).toFloat()
        val textLeft = boxLeft + padSide
        c.save()
        c.clipRect(textLeft, y + top, textLeft + layout.width, y + top + (lineBottom - lineTop))
        c.translate(textLeft, y + top - lineTop)
        layout.draw(c)
        c.restore()
        if (from == 0 && marker.isNotEmpty() && markerPaint != null) {
            val baseline = y + top + layout.getLineBaseline(0)
            if (rtl) {
                markerPaint.textAlign = Paint.Align.LEFT
                c.drawText(marker, boxLeft + boxWidth + markerGap, baseline, markerPaint)
            } else {
                markerPaint.textAlign = Paint.Align.RIGHT
                c.drawText(marker, boxLeft - markerGap, baseline, markerPaint)
            }
        }
    }
}

class ImagePiece(
    val bitmap: Bitmap,
    val width: Float,
    val height: Float,
    val centered: Boolean,
) : Piece() {
    override fun heightOf(from: Int, to: Int): Float = height

    override fun drawBody(c: Canvas, x: Float, y: Float, w: Float, from: Int, to: Int) {
        val boxLeft = left(x, w)
        val boxWidth = innerWidth(w)
        val dx = if (centered) boxLeft + (boxWidth - width) / 2f else if (rtl) boxLeft + boxWidth - width else boxLeft
        val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
        c.drawBitmap(bitmap, null, RectF(dx, y, dx + width, y + height), paint)
    }
}

class RulePiece(val color: Int, val thickness: Float) : Piece() {
    override fun heightOf(from: Int, to: Int): Float = thickness

    override fun drawBody(c: Canvas, x: Float, y: Float, w: Float, from: Int, to: Int) {
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        paint.color = color
        paint.style = Paint.Style.FILL
        val boxLeft = left(x, w)
        c.drawRect(boxLeft, y, boxLeft + innerWidth(w), y + thickness, paint)
    }
}

class CellContent(val layouts: List<StaticLayout>, val gap: Float) {
    val height: Float
        get() {
            var total = 0f
            for ((index, layout) in layouts.withIndex()) {
                total += layout.height
                if (index < layouts.size - 1) total += gap
            }
            return total
        }
}

class CellBox(
    val content: CellContent,
    val column: Int,
    val span: Int,
    val fill: Int,
)

class RowPiece(
    val cells: List<CellBox>,
    val columns: FloatArray,
    val pad: Float,
    val header: Boolean,
    val borderColor: Int,
    val borderWidth: Float,
    val border: String,
    val headerFill: Int,
    val zebraFill: Int,
    val zebra: Boolean,
) : Piece() {
    var headerRow: RowPiece? = null

    private val rowHeight: Float

    init {
        var tallest = 0f
        for (cell in cells) {
            val h = cell.content.height
            if (h > tallest) tallest = h
        }
        rowHeight = tallest + pad * 2f
    }

    override fun heightOf(from: Int, to: Int): Float = rowHeight

    private fun columnLeft(index: Int, boxLeft: Float): Float {
        var total = boxLeft
        for (i in 0 until index) total += columns[i]
        return total
    }

    override fun drawBody(c: Canvas, x: Float, y: Float, w: Float, from: Int, to: Int) {
        val boxLeft = left(x, w)
        val tableWidth = innerWidth(w)
        val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG)
        fillPaint.style = Paint.Style.FILL
        val linePaint = Paint(Paint.ANTI_ALIAS_FLAG)
        linePaint.style = Paint.Style.STROKE
        linePaint.strokeWidth = borderWidth
        linePaint.color = borderColor
        if (header && headerFill != 0) {
            fillPaint.color = headerFill
            c.drawRect(boxLeft, y, boxLeft + tableWidth, y + rowHeight, fillPaint)
        } else if (zebra && zebraFill != 0) {
            fillPaint.color = zebraFill
            c.drawRect(boxLeft, y, boxLeft + tableWidth, y + rowHeight, fillPaint)
        }
        for (cell in cells) {
            var cellWidth = 0f
            for (i in cell.column until (cell.column + cell.span)) {
                if (i < columns.size) cellWidth += columns[i]
            }
            val cx = if (rtl) boxLeft + tableWidth - columnLeft(cell.column, 0f) - cellWidth
            else columnLeft(cell.column, boxLeft)
            if (cell.fill != 0) {
                fillPaint.color = cell.fill
                c.drawRect(cx, y, cx + cellWidth, y + rowHeight, fillPaint)
            }
            var ty = y + pad
            for (layout in cell.content.layouts) {
                c.save()
                c.translate(cx + pad, ty)
                layout.draw(c)
                c.restore()
                ty += layout.height + cell.content.gap
            }
            if (border == "grid") {
                c.drawRect(cx, y, cx + cellWidth, y + rowHeight, linePaint)
            }
        }
        if (border == "rows") {
            val path = Path()
            path.moveTo(boxLeft, y + rowHeight)
            path.lineTo(boxLeft + tableWidth, y + rowHeight)
            c.drawPath(path, linePaint)
        }
    }
}

class TocPiece(
    val layout: StaticLayout,
    val numberPaint: TextPaint,
    val numberWidth: Float,
    val leader: Boolean,
    val leaderColor: Int,
) : Piece() {
    var number = ""

    override fun heightOf(from: Int, to: Int): Float = layout.height.toFloat()

    override fun drawBody(c: Canvas, x: Float, y: Float, w: Float, from: Int, to: Int) {
        val boxLeft = left(x, w)
        val boxWidth = innerWidth(w)
        val textLeft = if (rtl) boxLeft + numberWidth + GAP else boxLeft
        c.save()
        c.translate(textLeft, y)
        layout.draw(c)
        c.restore()
        val last = layout.lineCount - 1
        val baseline = y + layout.getLineBaseline(last)
        numberPaint.textAlign = if (rtl) Paint.Align.LEFT else Paint.Align.RIGHT
        c.drawText(number, if (rtl) boxLeft else boxLeft + boxWidth, baseline, numberPaint)
        if (!leader) return
        val a: Float
        val b: Float
        if (rtl) {
            a = boxLeft + numberWidth + 4f
            b = textLeft + layout.getLineLeft(last) - 6f
        } else {
            a = textLeft + layout.getLineRight(last) + 6f
            b = boxLeft + boxWidth - numberWidth - 4f
        }
        if (b - a < 10f) return
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        paint.color = leaderColor
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = 0.9f
        paint.strokeCap = Paint.Cap.ROUND
        paint.pathEffect = DashPathEffect(floatArrayOf(0.1f, 3.2f), 0f)
        val path = Path()
        path.moveTo(a, baseline - 1f)
        path.lineTo(b, baseline - 1f)
        c.drawPath(path, paint)
    }

    companion object {
        const val GAP = 8f
    }
}

class Placed(val piece: Piece, val from: Int, val to: Int, val y: Float)

class PageContent {
    val items = ArrayList<Placed>()
}

object Paginator {
    fun paginate(
        pieces: List<Piece>,
        contentH: Float,
        minLines: Int,
        headingPages: MutableMap<Piece, Int>?,
    ): List<PageContent> {
        val pages = ArrayList<PageContent>()
        var page = PageContent()
        var y = 0f
        var prevAfter = 0f
        var atTop = true

        fun newPage() {
            pages.add(page)
            page = PageContent()
            y = 0f
            prevAfter = 0f
            atTop = true
        }

        var index = 0
        while (index < pieces.size) {
            val piece = pieces[index]
            index++
            if (piece.breakBefore && !atTop) newPage()
            if (piece.lines == 0) continue
            var start = 0
            var guard = 0
            while (start < piece.lines && guard < 100000) {
                guard++
                if (piece is RowPiece && atTop && start == 0) {
                    val head = piece.headerRow
                    if (head != null && head !== piece) {
                        val hh = head.heightOf(0, 1)
                        if (hh < contentH * 0.5f) {
                            page.items.add(Placed(head, 0, 1, y))
                            y += hh
                            atTop = false
                        }
                    }
                }
                val gap = if (atTop || start > 0) 0f else maxOf(prevAfter, piece.before)
                val available = contentH - y - gap
                val end = piece.fit(start, available)
                if (end >= piece.lines) {
                    if (piece.keepWithNext && !atTop && index < pieces.size) {
                        val next = pieces[index]
                        if (next.lines > 0 && !next.breakBefore) {
                            val need = gap + piece.heightOf(start, piece.lines) +
                                maxOf(piece.after, next.before) + next.minChunk(minLines)
                            if (need > contentH - y) {
                                newPage()
                                continue
                            }
                        }
                    }
                    val h = piece.heightOf(start, piece.lines)
                    page.items.add(Placed(piece, start, piece.lines, y + gap))
                    if (start == 0 && headingPages != null && piece.headingLevel > 0) {
                        headingPages[piece] = pages.size
                    }
                    y += gap + h
                    prevAfter = piece.after
                    atTop = false
                    start = piece.lines
                    continue
                }
                if (piece.splittable && piece.lines > 1) {
                    var e = end
                    if (start == 0 && e < minLines) e = start
                    else if (piece.lines - e < minLines && piece.lines - minLines > start) e = piece.lines - minLines
                    else if (piece.lines - e < minLines) e = start
                    if (e > start) {
                        page.items.add(Placed(piece, start, e, y + gap))
                        if (start == 0 && headingPages != null && piece.headingLevel > 0) {
                            headingPages[piece] = pages.size
                        }
                        start = e
                        newPage()
                        continue
                    }
                }
                if (atTop) {
                    val e = if (end > start) end else start + 1
                    val cut = if (e > piece.lines) piece.lines else e
                    page.items.add(Placed(piece, start, cut, y + gap))
                    if (start == 0 && headingPages != null && piece.headingLevel > 0) {
                        headingPages[piece] = pages.size
                    }
                    start = cut
                    newPage()
                    continue
                }
                newPage()
            }
        }
        if (page.items.isNotEmpty() || pages.isEmpty()) pages.add(page)
        return pages
    }
}
