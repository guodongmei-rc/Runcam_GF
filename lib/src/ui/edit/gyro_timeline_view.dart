import 'package:flutter/material.dart';

/// 陀螺数据波形(对齐原生 GyroTimelineView):黑底 + 多轴彩色曲线 + 播放头 + 同步点竖线。
/// 支持点击/拖动 seek;并叠加「裁剪区间」:选区外变暗 + 橙色边框 + 两侧可拖动手柄
/// (对齐桌面 Gyroflow 时间线的 trim range)。数据为交错采样 [x,y,z(,w)];归一化居中绘制。
class GyroTimelineView extends StatefulWidget {
  const GyroTimelineView({
    super.key,
    required this.samples,
    required this.axes,
    required this.progress, // 0..1 播放头位置
    this.syncPoints = const [], // 交错 [mid_ms, off_ms, ...]
    this.durationMs = 0,
    this.onSeek, // (progress 0..1)
    this.trimStart = 0.0, // 裁剪起点 0..1
    this.trimEnd = 1.0, // 裁剪终点 0..1
    this.onTrimStart, // 拖起点手柄 (frac 0..1)
    this.onTrimEnd, // 拖终点手柄 (frac 0..1)
    this.height = 84,
  });
  final List<double> samples;
  final int axes;
  final double progress;
  final List<double> syncPoints;
  final double durationMs;
  final ValueChanged<double>? onSeek;
  final double trimStart;
  final double trimEnd;
  final ValueChanged<double>? onTrimStart;
  final ValueChanged<double>? onTrimEnd;
  final double height;

  @override
  State<GyroTimelineView> createState() => _GyroTimelineViewState();
}

class _GyroTimelineViewState extends State<GyroTimelineView> {
  // 拖动目标:0=无/seek,1=起点手柄,2=终点手柄。pan 开始时按落点就近判定。
  static const _hitPx = 20.0; // 手柄命中半径(px)
  int _drag = 0;

  bool get _trimEnabled =>
      widget.onTrimStart != null && widget.onTrimEnd != null && widget.durationMs > 0;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: widget.height,
      margin: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xD9000000), // 黑 85%(对齐原生)
        borderRadius: BorderRadius.circular(4),
      ),
      clipBehavior: Clip.hardEdge,
      child: LayoutBuilder(
        builder: (ctx, cons) {
          final w = cons.maxWidth;
          double frac(double dx) => w > 0 ? (dx / w).clamp(0.0, 1.0) : 0.0;
          void seekAt(double dx) {
            if (widget.onSeek != null && w > 0) widget.onSeek!(frac(dx));
          }

          void onDown(double dx) {
            // 优先判定是否抓到了裁剪手柄(就近),否则按 seek 处理。
            if (_trimEnabled) {
              final sx = widget.trimStart * w, ex = widget.trimEnd * w;
              final ds = (dx - sx).abs(), de = (dx - ex).abs();
              if (ds <= _hitPx && ds <= de) {
                _drag = 1;
                return;
              }
              if (de <= _hitPx) {
                _drag = 2;
                return;
              }
            }
            _drag = 0;
          }

          void onMove(double dx) {
            switch (_drag) {
              case 1:
                widget.onTrimStart!(frac(dx));
                break;
              case 2:
                widget.onTrimEnd!(frac(dx));
                break;
              default:
                seekAt(dx);
            }
          }

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => seekAt(d.localPosition.dx),
            onPanDown: (d) => onDown(d.localPosition.dx),
            onPanUpdate: (d) => onMove(d.localPosition.dx),
            onPanEnd: (_) => _drag = 0,
            onPanCancel: () => _drag = 0,
            child: CustomPaint(
              painter: _GyroPainter(
                samples: widget.samples,
                axes: widget.axes,
                progress: widget.progress,
                syncPoints: widget.syncPoints,
                durationMs: widget.durationMs,
                showTrim: _trimEnabled,
                trimStart: widget.trimStart,
                trimEnd: widget.trimEnd,
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
    required this.showTrim,
    required this.trimStart,
    required this.trimEnd,
  });
  final List<double> samples;
  final int axes;
  final double progress;
  final List<double> syncPoints;
  final double durationMs;
  final bool showTrim;
  final double trimStart;
  final double trimEnd;

  // 轴线配色对齐官方桌面 TimelineGyroChart.rs「原始数据」暗色组(情况A 三轴角速度 /
  // 情况B 四元数 xyzw 均用此组)。x 暗红 / y 暗绿 / z 暗蓝 / w 暗品红。
  static const _colors = [
    Color(0xFF8F4C4C),
    Color(0xFF4C8F4D),
    Color(0xFF4C7C8F),
    Color(0xFF8F4C8F),
  ];
  // 自动同步点亮绿(对齐官方有效同步点色 HSV(112°,0.84,0.86) ≈ #3cdb23)。
  static const _syncColor = Color(0xFF3CDB23);
  // 播放头:对齐官方 Timeline.qml 的 styleAccentColor(深色主题 #76baed)。
  static const _playheadColor = Color(0xFF76BAED);
  static const _trimColor = Color(0xFFFF8000); // 裁剪选区(橙,对齐主题色 GfColors.accent)

  @override
  void paint(Canvas canvas, Size size) {
    final midY = size.height / 2;
    // 裁剪框/播放头的底端统一到这条线:durationMs>0 时让出底部 13px 同步偏移文字带,
    // 使裁剪框底端与播放头底端对齐。
    final bottomY =
        durationMs > 0 ? (size.height - 13.0).clamp(0.0, size.height) : size.height;
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
                color: _syncColor, // 同步点偏移文字同 teal(对齐官方)
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

    // 裁剪选区(在播放头之下、波形之上):选区外压暗 + 橙色边框 + 两侧手柄。
    if (showTrim) {
      final sx = (trimStart.clamp(0.0, 1.0)) * size.width;
      final ex = (trimEnd.clamp(0.0, 1.0)) * size.width;
      final gripY = bottomY / 2; // 手柄抓点居中于裁剪框
      final dim = Paint()..color = const Color(0x80000000); // 选区外压暗 50%
      if (sx > 0) canvas.drawRect(Rect.fromLTRB(0, 0, sx, bottomY), dim);
      if (ex < size.width) {
        canvas.drawRect(Rect.fromLTRB(ex, 0, size.width, bottomY), dim);
      }
      // 选区边框(底端对齐播放头底端 bottomY)
      canvas.drawRect(
          Rect.fromLTRB(sx, 0.5, ex, bottomY - 0.5),
          Paint()
            ..color = _trimColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2);
      // 两侧手柄:竖条 + 中部圆点抓手
      final handle = Paint()..color = _trimColor;
      for (final hx in [sx, ex]) {
        canvas.drawRect(Rect.fromLTRB(hx - 2, 0, hx + 2, bottomY), handle);
        canvas.drawCircle(Offset(hx, gripY), 5, handle);
        canvas.drawCircle(
            Offset(hx, gripY), 2.2, Paint()..color = const Color(0xFF1A1A1A));
      }
    }

    // 播放头(对齐官方 Timeline.qml handle):浅蓝竖线 + 顶部「旗标头」(圆角矩形 + 下尖角)。
    // 底端 = bottomY,与裁剪框底端一致。
    final px = progress.clamp(0.0, 1.0) * size.width;
    final headPaint = Paint()..color = _playheadColor;
    const headW = 14.0, headBody = 11.0, headTip = 16.0; // 头宽 / 矩形高 / 尖角底
    // 竖线(从旗标头下沿到文字带上沿)
    canvas.drawLine(Offset(px, headTip - 2), Offset(px, bottomY),
        Paint()..color = _playheadColor..strokeWidth = 2);
    // 旗标头:圆角矩形 + 下三角尖
    final headRect = RRect.fromRectAndRadius(
        Rect.fromLTRB(px - headW / 2, 0, px + headW / 2, headBody),
        const Radius.circular(3));
    canvas.drawRRect(headRect, headPaint);
    final tip = Path()
      ..moveTo(px - headW / 2 + 1, headBody - 0.5)
      ..lineTo(px + headW / 2 - 1, headBody - 0.5)
      ..lineTo(px, headTip)
      ..close();
    canvas.drawPath(tip, headPaint);
    // 头内黑色竖向小刻痕(对齐官方 #000 notch)
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromCenter(
                center: Offset(px, headBody / 2 + 1), width: 1.5, height: 6),
            const Radius.circular(1)),
        Paint()..color = const Color(0xFF000000));
  }

  @override
  bool shouldRepaint(covariant _GyroPainter old) =>
      old.samples != samples ||
      old.progress != progress ||
      old.axes != axes ||
      old.syncPoints != syncPoints ||
      old.durationMs != durationMs ||
      old.showTrim != showTrim ||
      old.trimStart != trimStart ||
      old.trimEnd != trimEnd;
}
