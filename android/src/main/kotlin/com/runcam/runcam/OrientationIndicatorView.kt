package com.runcam.runcam

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.view.View

/**
 * 方向指示器(对齐 iOS MotionData.qml 的 orientationIndicator Canvas)。
 *
 * 三列: ① 原始姿态的 XYZ 轴向量 ② 原始姿态相机线框 ③ 平滑后相对相机线框。
 * 用 [setQuats] 传入 [GyroflowNative.nativeQuatsAtTimestamp] 的 8 元数组
 * ([q.w,q.i,q.j,q.k, sq.w,sq.i,sq.j,sq.k]), 自身按四元数旋转矢量后正交投影绘制。
 */
class OrientationIndicatorView(context: Context) : View(context) {

    // 默认单位四元数(无旋转)
    private var quats = doubleArrayOf(1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0)

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val d = resources.displayMetrics.density

    fun setQuats(q: DoubleArray) {
        if (q.size >= 8) {
            quats = q
            invalidate()
        }
    }

    override fun onDraw(canvas: Canvas) {
        val w = width.toFloat()
        val h = height.toFloat()
        if (w <= 0f || h <= 0f) {
            return
        }
        val veclen = 30f * d
        val axisColors = intArrayOf(Color.parseColor("#ff0000"), Color.parseColor("#00ff00"), Color.parseColor("#4444ff"))
        val mainColor = Color.argb(230, 255, 255, 255) // rgba(255,255,255,0.9)

        // 相机线框顶点(类似 Blender 相机)
        val cw = 30f * d
        val ch = 15f * d
        val cl = 30f * d
        val camVerts = arrayOf(
            doubleArrayOf(-cw.toDouble(), -ch.toDouble(), -cl.toDouble()),
            doubleArrayOf(cw.toDouble(), -ch.toDouble(), -cl.toDouble()),
            doubleArrayOf(cw.toDouble(), ch.toDouble(), -cl.toDouble()),
            doubleArrayOf(-cw.toDouble(), ch.toDouble(), -cl.toDouble()),
            doubleArrayOf(0.0, 0.0, 0.0)
        )
        val lines = arrayOf(intArrayOf(0, 1, 2, 3, 0), intArrayOf(0, 4, 1), intArrayOf(2, 4, 3))

        // transforms[0]=原始; transforms[1]=原始 * 平滑.inverse()(残差)
        val org = doubleArrayOf(quats[0], quats[1], quats[2], quats[3])
        val smooth = doubleArrayOf(quats[4], quats[5], quats[6], quats[7])
        val residual = quatMul(org, quatConj(smooth))
        val transforms = arrayOf(org, residual)

        // 三列中心圆点
        paint.style = Paint.Style.FILL
        paint.color = mainColor
        paint.alpha = 230
        for (i in 0 until 3) {
            canvas.drawCircle(w / 6f * (i * 2 + 1), h / 2f, 4f * d, paint)
        }

        // 第①列: 原始姿态的三轴向量
        val vecs = arrayOf(
            doubleArrayOf(0.0, veclen.toDouble(), 0.0),
            doubleArrayOf(-veclen.toDouble(), 0.0, 0.0),
            doubleArrayOf(0.0, 0.0, veclen.toDouble())
        )
        val cx0 = w / 6f
        val cy0 = h / 2f
        for (i in 0 until 3) {
            val tv = rotate(org, vecs[i])
            paint.color = axisColors[i]
            paint.style = Paint.Style.STROKE
            paint.strokeWidth = 3f * d
            paint.alpha = 128 // 0.5
            canvas.drawLine(cx0, cy0, cx0 + tv[0].toFloat(), cy0 - tv[1].toFloat(), paint)
            // 端点圆(透明度随深度 z)
            val a = (tv[2] / (veclen * 2) + 0.5).coerceIn(0.1, 1.0)
            paint.style = Paint.Style.FILL
            paint.alpha = (a * 255).toInt()
            canvas.drawCircle(cx0 + tv[0].toFloat(), cy0 - tv[1].toFloat(), 4f * d, paint)
        }

        // 第②③列: 相机线框(view0=原始 @中列, view1=平滑残差 @右列)
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = 1.5f * d
        paint.color = mainColor
        paint.alpha = 204 // 0.8
        for (view in 0 until 2) {
            val cx = w / 6f * (view * 2 + 3)
            for (line in lines) {
                var first = true
                var px = 0f
                var py = 0f
                for (idx in line) {
                    val tv = rotate(transforms[view], camVerts[idx])
                    val x = tv[0].toFloat() + cx
                    val y = -tv[1].toFloat() + h / 2f
                    if (first) {
                        px = x
                        py = y
                        first = false
                    } else {
                        canvas.drawLine(px, py, x, y, paint)
                        px = x
                        py = y
                    }
                }
            }
        }
    }

    // 用四元数(w,i,j,k)旋转向量 v: v' = v + 2w(q×v) + 2 q×(q×v)
    private fun rotate(q: DoubleArray, v: DoubleArray): DoubleArray {
        val w = q[0]; val x = q[1]; val y = q[2]; val z = q[3]
        val vx = v[0]; val vy = v[1]; val vz = v[2]
        val tx = 2 * (y * vz - z * vy)
        val ty = 2 * (z * vx - x * vz)
        val tz = 2 * (x * vy - y * vx)
        return doubleArrayOf(
            vx + w * tx + (y * tz - z * ty),
            vy + w * ty + (z * tx - x * tz),
            vz + w * tz + (x * ty - y * tx)
        )
    }

    // 单位四元数共轭(= 逆)
    private fun quatConj(q: DoubleArray): DoubleArray = doubleArrayOf(q[0], -q[1], -q[2], -q[3])

    // Hamilton 四元数乘 a*b
    private fun quatMul(a: DoubleArray, b: DoubleArray): DoubleArray = doubleArrayOf(
        a[0] * b[0] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3],
        a[0] * b[1] + a[1] * b[0] + a[2] * b[3] - a[3] * b[2],
        a[0] * b[2] - a[1] * b[3] + a[2] * b[0] + a[3] * b[1],
        a[0] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[0]
    )
}
