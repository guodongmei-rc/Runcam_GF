import 'package:flutter/material.dart';

/// 陀螺数据波形(对齐原生 GyroTimelineView):黑底 + 多轴彩色曲线 + 播放头 + 同步点竖线。
/// 支持点击/拖动 seek。数据为交错采样 [x,y,z(,w)];归一化到 ±,居中绘制。
class GyroTimelineView extends StatelessWidget {
  const GyroTimelineView({
    super.key,
    required this.samples,
    required this.axes,
    required this.progress, // 0..1 播放头位置
    this.syncPoints = const [], // 交错 [mid_ms, off_ms, ...]
    this.durationMs = 0,
    this.onSeek, // (progress 0..1)
    this.height = 84,
  });
  final List<double> samples;
  final int axes;
  final double progress;
  final List<double> syncPoints;
  final double durationMs;
  final ValueChanged<double>? onSeek;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      margin: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xD9000000), // 黑 85%(对齐原生)
        borderRadius: BorderRadius.circular(4),
      ),
      clipBehavior: Clip.hardEdge,
      child: LayoutBuilder(
        builder: (ctx, cons) {
          final w = cons.maxWidth;
          void seekAt(double dx) {
            if (onSeek != null && w > 0) onSeek!((dx / w).clamp(0.0, 1.0));
          }

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => seekAt(d.localPosition.dx),
            onPanUpdate: (d) => seekAt(d.localPosition.dx),
            child: CustomPaint(
              painter: _GyroPainter(
                samples: samples,
                axes: axes,
                progress: progress,
                syncPoints: syncPoints,
                durationMs: durationMs,
              ),
              size: Size.infinite,
            ),
          );
        },
      ),
    );
  }
}

class _GyroPainter extends CustomPainter {
  _GyroPainter({
    required this.samples,
    required this.axes,
    required this.progress,
    required this.syncPoints,
    required this.durationMs,
  });
  final List<double> samples;
  final int axes;
  final double progress;
  final List<double> syncPoints;
  final double durationMs;

  // x 红 / y 绿 / z 蓝 / w 橙(对齐原生 GyroTimelineView.m 配色)。
  static const _colors = [
    Color(0xF2FF5959),
    Color(0xF259F273),
    Color(0xF266A6FF),
    Color(0xF2FFBF4D),
  ];
  static const _syncColor = Color(0xD933F280); // 同步点绿(对齐原生 spLineColor)

  @override
  void paint(Canvas canvas, Size size) {
    final midY = size.height / 2;
    // 中线
    canvas.drawLine(Offset(0, midY), Offset(size.width, midY),
        Paint()..color = const Color(0x33FFFFFF)..strokeWidth = 1);

    final n = axes > 0 ? samples.length ~/ axes : 0;
    if (n >= 2) {
      double maxAbs = 0;
      for (final v in samples) {
        final a = v.abs();
        if (a > maxAbs) maxAbs = a;
      }
      if (maxAbs > 0) {
        final halfH = midY * 0.92;
        for (var axis = 0; axis < axes && axis < _colors.length; axis++) {
          final path = Path();
          for (var i = 0; i < n; i++) {
            final x = size.width * (i / (n - 1));
            final y = midY - (samples[i * axes + axis] / maxAbs) * halfH;
            i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
          }
          canvas.drawPath(
              path,
              Paint()
                ..color = _colors[axis]
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1.2
                ..isAntiAlias = true);
        }
      }
    }

    // 同步点(对齐原生):绿色竖线 + 线底小三角 + 底部文字带显示偏移值(2 位小数);
    // 竖线只画到文字带上方,不盖到文字上。
    if (durationMs > 0) {
      const band = 13.0; // 底部文字带高度
      final lineBottom = (size.height - band).clamp(0.0, size.height);
      final spPaint = Paint()
        ..color = _syncColor
        ..strokeWidth = 1.5;
      for (var i = 0; i + 1 < syncPoints.length; i += 2) {
        final sx = (syncPoints[i] / durationMs).clamp(0.0, 1.0) * size.width;
        final off = syncPoints[i + 1];
        // 竖线(到文字带上沿停)
        canvas.drawLine(Offset(sx, 0), Offset(sx, lineBottom), spPaint);
        // 线底小三角标记
        final tri = Path()
          ..moveTo(sx - 3, lineBottom)
          ..lineTo(sx + 3, lineBottom)
          ..lineTo(sx, lineBottom - 5)
          ..close();
        canvas.drawPath(tri, Paint()..color = _syncColor);
        // 偏移值文字(底部带,2 位小数)
        final tp = TextPainter(
          text: TextSpan(
            text: off.toStringAsFixed(2),
            style: const TextStyle(
                color: Color(0xFF6BF7A8),
                fontSize: 9,
                fontWeight: FontWeight.w600),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        var tx = sx - tp.width / 2;
        tx = tx.clamp(0.0, (size.width - tp.width).clamp(0.0, size.width));
        tp.paint(canvas, Offset(tx, lineBottom + 2));
      }
    }

    // 播放头竖线也只画到文字带上方,避免压住底部偏移文字。
    final hbBottom =
        durationMs > 0 ? (size.height - 13.0).clamp(0.0, size.height) : size.height;

    // 播放头竖线(同样不压底部文字带)
    final px = progress.clamp(0.0, 1.0) * size.width;
    canvas.drawLine(Offset(px, 0), Offset(px, hbBottom),
        Paint()..color = const Color(0xFF2196F3)..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(covariant _GyroPainter old) =>
      old.samples != samples ||
      old.progress != progress ||
      old.axes != axes ||
      old.syncPoints != syncPoints ||
      old.durationMs != durationMs;
}
