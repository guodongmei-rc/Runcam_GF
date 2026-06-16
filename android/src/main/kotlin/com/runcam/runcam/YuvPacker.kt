package com.runcam.runcam

import android.media.Image

/**
 * YUV_420_888 平面重排为紧凑数据(处理 rowStride 填充 / pixelStride>1 的半平面)。
 * 独立工具模块, 不依赖任何 UI / 解码状态。
 */
object YuvPacker {

    /** 紧凑三平面: Y = width*height, U/V = ((width+1)/2)*((height+1)/2)。 */
    class Frame(
        val y: ByteArray,
        val u: ByteArray,
        val v: ByteArray,
        val width: Int,
        val height: Int,
    )

    fun pack(image: Image): Frame {
        val w = image.width
        val h = image.height
        val cw = (w + 1) / 2
        val ch = (h + 1) / 2
        val y = packPlane(image.planes[0], w, h)
        val u = packPlane(image.planes[1], cw, ch)
        val v = packPlane(image.planes[2], cw, ch)
        return Frame(y, u, v, w, h)
    }

    private fun packPlane(plane: Image.Plane, w: Int, h: Int): ByteArray {
        val buf = plane.buffer.duplicate()
        val rowStride = plane.rowStride
        val pixelStride = plane.pixelStride
        val out = ByteArray(w * h)
        val rowBuf = ByteArray(rowStride)
        var o = 0
        for (r in 0 until h) {
            val pos = r * rowStride
            if (pos >= buf.limit()) {
                break
            }
            buf.position(pos)
            val n = minOf(rowStride, buf.limit() - pos)
            buf.get(rowBuf, 0, n)
            if (pixelStride == 1) {
                System.arraycopy(rowBuf, 0, out, o, minOf(w, n))
            } else {
                var c = 0
                var p = 0
                while (c < w && p < n) {
                    out[o + c] = rowBuf[p]
                    c++
                    p += pixelStride
                }
            }
            o += w
        }
        return out
    }
}
