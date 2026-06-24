import 'dart:math' as math;
import 'package:flutter/material.dart';

/// 方向指示器:坐标轴 gizmo + 原始/平滑两个相机 frustum 线框。
/// 1:1 移植自原生 GFOrientationIndicatorView.drawRect(InputTabView.m)。
/// [quats] = double[8]:[0..4]=原始姿态 (w,x,y,z),[4..8]=平滑姿态。
class OrientationIndicator extends StatelessWidget {
  const OrientationIndicator({super.key, required this.quats});
  final List<double> quats;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 96,
      child: CustomPaint(painter: _OrientationPainter(quats), size: Size.infinite),
    );
  }
}

// ---- 四元数工具(对齐 gfQuatRotate / gfQuatMul,w 在前)----

List<double> _quatRotate(List<double> q, double vx, double vy, double vz) {
  final w = q[0], x = q[1], y = q[2], z = q[3];
  final tx = 2.0 * (y * vz - z * vy);
  final ty = 2.0 * (z * vx - x * vz);
  final tz = 2.0 * (x * vy - y * vx);
  return [
    vx + w * tx + (y * tz - z * ty),
    vy + w * ty + (z * tx - x * tz),
    vz + w * tz + (x * ty - y * tx),
  ];
}

List<double> _quatMul(List<double> a, List<double> b) => [
      a[0] * b[0] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3],
      a[0] * b[1] + a[1] * b[0] + a[2] * b[3] - a[3] * b[2],
      a[0] * b[2] - a[1] * b[3] + a[2] * b[0] + a[3] * b[1],
      a[0] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[0],
    ];

class _OrientationPainter extends CustomPainter {
  _OrientationPainter(this.quats);
  final List<double> quats;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final midY = h * 0.5;
    final veclen = math.min(30.0, h * 0.35);

    final has = quats.length >= 8;
    final rawQ = has ? quats.sublist(0, 4) : const [1.0, 0.0, 0.0, 0.0];
    final smQ = has ? quats.sublist(4, 8) : const [1.0, 0.0, 0.0, 0.0];

    // 3 个 cell 的中心白点(cell 1/2/3 等分)
    final dotMain = Paint()
      ..color = Colors.white.withValues(alpha: 0.9)
      ..style = PaintingStyle.fill;
    for (var i = 0; i < 3; i++) {
      canvas.drawCircle(Offset(w / 6.0 * (i * 2 + 1), midY), 3, dotMain);
    }

    // Cell 1:RGB 三轴(按原始姿态旋转)。X 红(0,L,0) / Y 绿(-L,0,0) / Z 蓝(0,0,L)
    const axisColors = [Color(0xFFFF0000), Color(0xFF00FF00), Color(0xFF4545FF)];
    final axisVecs = [
      [0.0, veclen, 0.0],
      [-veclen, 0.0, 0.0],
      [0.0, 0.0, veclen],
    ];
    final cx1 = w / 6.0;
    for (var i = 0; i < 3; i++) {
      final tv = _quatRotate(rawQ, axisVecs[i][0], axisVecs[i][1], axisVecs[i][2]);
      final ex = cx1 + tv[0], ey = midY - tv[1];
      canvas.drawLine(
        Offset(cx1, midY),
        Offset(ex, ey),
        Paint()
          ..color = axisColors[i].withValues(alpha: 0.5)
          ..strokeWidth = 3
          ..style = PaintingStyle.stroke,
      );
      // 端点圆点透明度按 z 投影深度(对齐官方 z/(veclen*2)+0.5)
      final dotAlpha = (tv[2] / (veclen * 2.0) + 0.5).clamp(0.1, 1.0);
      canvas.drawCircle(
        Offset(ex, ey),
        4,
        Paint()
          ..color = axisColors[i].withValues(alpha: dotAlpha)
          ..style = PaintingStyle.fill,
      );
    }

    // Cell 2/3:相机 frustum 线框。中格=原始姿态,右格=平滑姿态(rawQ * conj(smQ))。
    const camVerts = [
      [-30.0, -15.0, -30.0],
      [30.0, -15.0, -30.0],
      [30.0, 15.0, -30.0],
      [-30.0, 15.0, -30.0],
      [0.0, 0.0, 0.0],
    ];
    const lines = [
      [0, 1, 2, 3, 0],
      [0, 4, 1, -1, -1],
      [2, 4, 3, -1, -1],
    ];
    final smConj = [smQ[0], -smQ[1], -smQ[2], -smQ[3]];
    final viewQ = [rawQ, _quatMul(rawQ, smConj)];

    final frustum = Paint()
      ..color = Colors.white.withValues(alpha: 0.8)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.bevel;
    for (var view = 0; view < 2; view++) {
      final ccx = w / 6.0 * (view * 2 + 3); // 中格=w/2,右格=5w/6
      for (var li = 0; li < 3; li++) {
        final path = Path();
        var started = false;
        for (var pi = 0; pi < 5; pi++) {
          final vi = lines[li][pi];
          if (vi < 0) break;
          final tv = _quatRotate(
              viewQ[view], camVerts[vi][0], camVerts[vi][1], camVerts[vi][2]);
          final px = ccx + tv[0], py = midY - tv[1];
          started ? path.lineTo(px, py) : path.moveTo(px, py);
          started = true;
        }
        canvas.drawPath(path, frustum);
      }
    }
  }

  @override
  bool shouldRepaint(_OrientationPainter old) => old.quats != quats;
}
