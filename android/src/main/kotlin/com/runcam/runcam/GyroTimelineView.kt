package com.runcam.runcam

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.drawable.GradientDrawable
import android.view.MotionEvent
import android.view.View

/**
 * 陀螺数据时间轴(对齐 iOS GyroTimelineView): 整段视频三轴角速度波形(X 红/Y 绿/Z 蓝) +
 * 播放游标 + autosync 同步点竖线/数值。点击或拖动回调 [onSeek](进度 0–1)。
 *
 * 数据由 [GyroflowNative.nativeGyroTimeline] 提供(交错 xyz, °/s)。
 */
class GyroTimelineView(context: Context) : View(context) {

    private var samples: DoubleArray? = null   // gyro:[x0,y0,z0,...] 或 四元数:[x0,y0,z0,w0,...]
    private var sampleCount = 0
    private var componentCount = 3             // 3=gyro 三轴, 4=四元数(DJI/Xtra 等无原始角速度的源)
    private var maxAbs = 1.0
    @Volatile private var progress = 0.0
    private var videoDurationMs = 0.0
    private var syncPoints: List<Pair<Double, Double>> = emptyList() // (midMs, offMs)

    var onSeek: ((Double) -> Unit)? = null

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 9f * resources.displayMetrics.density }
    private val d = resources.displayMetrics.density

    init {
        background = GradientDrawable().apply {
            setColor(Color.argb(217, 0, 0, 0)) // 黑 0.85
            cornerRadius = 4f * d
        }
        isClickable = true
    }

    fun setData(data: DoubleArray?) = setData(data, 3)

    /// components: 3=gyro 三轴角速度, 4=四元数(x,y,z,w)。交错布局,长度需 = sampleCount*components。
    fun setData(data: DoubleArray?, components: Int) {
        val comp = if (components == 4) 4 else 3
        if (data == null || data.size < comp * 2) {
            samples = null
            sampleCount = 0
            componentCount = 3
        } else {
            samples = data
            componentCount = comp
            sampleCount = data.size / comp
            var mx = 0.0
            for (v in data) {
                val a = kotlin.math.abs(v)
                if (a > mx) mx = a
            }
            maxAbs = if (mx > 1e-6) mx else 1.0
        }
        invalidate()
    }

    // 可能从解码线程调用 → 用 postInvalidate(线程安全)。
    fun setProgress(p: Double) {
        val np = p.coerceIn(0.0, 1.0)
        if (kotlin.math.abs(np - progress) < 1e-6) return
        progress = np
        postInvalidate()
    }

    fun setVideoDurationMs(ms: Double) {
        videoDurationMs = ms
    }

    fun setSyncPoints(points: List<Pair<Double, Double>>) {
        syncPoints = points
        invalidate()
    }

    fun clear() {
        setData(null)
        syncPoints = emptyList()
        progress = 0.0
        invalidate()
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.action) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_MOVE, MotionEvent.ACTION_UP -> {
                val w = width.toFloat()
                if (w >= 1f) {
                    val frac = (event.x / w).coerceIn(0f, 1f).toDouble()
                    setProgress(frac)
                    onSeek?.invoke(frac)
                }
                return true
            }
        }
        return super.onTouchEvent(event)
    }

    override fun onDraw(canvas: Canvas) {
        val w = width.toFloat()
        val h = height.toFloat()
        if (w <= 0f || h <= 0f) return
        val midY = h * 0.5f

        // 中线(0 °/s 基准)
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = 1f * d
        paint.color = Color.argb(51, 255, 255, 255)
        canvas.drawLine(0f, midY, w, midY, paint)

        val data = samples
        if (data != null && sampleCount > 1) {
            val halfH = midY * 0.92f
            val colors = intArrayOf(
                Color.argb(242, 255, 90, 90),   // X 红
                Color.argb(242, 90, 242, 115),  // Y 绿
                Color.argb(242, 102, 166, 255), // Z 蓝
                Color.argb(242, 255, 191, 77),  // W 橙(四元数模式)
            )
            for (axis in 0 until componentCount) {
                paint.color = colors[axis]
                paint.strokeWidth = 1f * d
                paint.strokeJoin = Paint.Join.ROUND
                var prevX = 0f
                var prevY = 0f
                for (i in 0 until sampleCount) {
                    val v = data[i * componentCount + axis]
                    val px = i.toFloat() / (sampleCount - 1) * w
                    val py = midY - (v / maxAbs).toFloat() * halfH
                    if (i > 0) {
                        canvas.drawLine(prevX, prevY, px, py, paint)
                    }
                    prevX = px
                    prevY = py
                }
            }
        } else {
            textPaint.color = Color.argb(128, 255, 255, 255)
            val msg = "无陀螺仪数据"
            val tw = textPaint.measureText(msg)
            canvas.drawText(msg, (w - tw) / 2f, midY + textPaint.textSize / 2f, textPaint)
        }

        // 同步点: 竖线 + 下方数值
        if (syncPoints.isNotEmpty()) {
            val textRowH = textPaint.textSize + 2f * d
            paint.style = Paint.Style.STROKE
            paint.strokeWidth = 1.5f * d
            val lineColor = Color.argb(217, 51, 242, 128)
            textPaint.color = Color.argb(255, 51, 242, 128)
            syncPoints.forEachIndexed { i, (midMs, offMs) ->
                val sx = if (videoDurationMs > 1.0) {
                    (midMs / videoDurationMs).coerceIn(0.0, 1.0).toFloat() * w
                } else if (syncPoints.size > 1) {
                    i.toFloat() / (syncPoints.size - 1) * w
                } else {
                    w * 0.5f
                }
                paint.color = lineColor
                canvas.drawLine(sx, 0f, sx, h - textRowH, paint)
                val txt = String.format("%.2f 毫秒", offMs)
                val tw = textPaint.measureText(txt)
                var tx = sx - tw / 2f
                if (tx < 2f) tx = 2f
                if (tx + tw > w - 2f) tx = w - 2f - tw
                canvas.drawText(txt, tx, h - textRowH + textPaint.textSize, textPaint)
            }
        }

        // 播放游标(主题色)
        val playX = progress.toFloat() * w
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = 1.5f * d
        paint.color = GyroflowTheme.ACCENT
        canvas.drawLine(playX, 0f, playX, h, paint)
    }
}
