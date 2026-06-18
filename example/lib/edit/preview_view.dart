import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:runcam_gf/runcam_gf.dart'; // ParamsModel 扩展 getter(fov)
import 'edit_controller.dart';
import 'preview_backend.dart';

/// 只负责"显示共享 stabilizer 的输出" + 预览 HUD(时间/帧号 + 缩放%)。
/// 不引用 ParamsModel / 任何参数;HUD 数据从 controller 的只读 getter 取。
class PreviewView extends StatelessWidget {
  const PreviewView({super.key, required this.controller});
  final EditController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    if (c.uri == null) {
      return const Center(child: Text('未选视频'));
    }
    // 稳定概览裁切框比例:概览 fov=base+1,输出区=中央 base/(base+1)(自适应缩放抵消)。
    final fov = c.params.fov;
    final cropFrac = (fov > 0 ? fov / (fov + 1.0) : 0.5).clamp(0.1, 1.0);
    final overview = c.fovOverview
        ? Positioned.fill(child: CustomPaint(painter: _OverviewPainter(cropFrac)))
        : null;

    final Widget preview;
    if (c.backend == PreviewBackend.texture) {
      if (c.textureId == null) {
        return const Center(child: CircularProgressIndicator());
      }
      preview = Center(
        child: AspectRatio(
          aspectRatio: c.aspect,
          child: Stack(children: [
            Texture(textureId: c.textureId!),
            ?overview, // 叠在画面边界内,精确对齐
          ]),
        ),
      );
    } else {
      // PlatformView 后端
      preview = Stack(children: [
        Positioned.fill(
          child: UiKitView(
            viewType: 'runcam_gf/preview_platformview',
            creationParams: {'uri': c.uri},
            creationParamsCodec: const StandardMessageCodec(),
            onPlatformViewCreated: c.onPlatformViewCreated,
          ),
        ),
        ?overview,
      ]);
    }
    // 画面 + 左上角 HUD(对齐桌面 Gyroflow 时间轴上方那块)。
    return Stack(
      children: [
        Positioned.fill(child: preview),
        Positioned(left: 8, top: 8, child: _Hud(controller: c)),
      ],
    );
  }
}

/// 稳定概览叠加层(对齐官方 fov_overview):画面外区域压暗蒙版 + 中央输出区白色裁切框。
class _OverviewPainter extends CustomPainter {
  _OverviewPainter(this.cropFrac);
  final double cropFrac; // 中央输出区占整幅画面的比例(宽高同比)

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: size.width * cropFrac,
      height: size.height * cropFrac,
    );
    // 框外压暗(evenOdd:外框 - 内框 = 环形区域)。
    final mask = Path()
      ..addRect(Offset.zero & size)
      ..addRect(rect)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(mask, Paint()..color = const Color(0x80000000));
    // 黑色裁切框(对齐官方)。
    canvas.drawRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.black
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_OverviewPainter old) => old.cropFrac != cropFrac;
}

/// 预览左上角 HUD:第一行「时间 (当前帧/总帧)」,第二行「缩放: xx%」。
class _Hud extends StatelessWidget {
  const _Hud({required this.controller});
  final EditController controller;

  static String _fmtTime(int us) {
    final totalSec = us ~/ 1000000;
    final h = totalSec ~/ 3600;
    final m = (totalSec % 3600) ~/ 60;
    final s = totalSec % 60;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(h)}:${two(m)}:${two(s)}';
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final total = c.totalFrames;
    final frame = total > 0 ? (c.currentFrameIndex + 1) : 0; // 1-based,对齐桌面 1/810
    final zoom = c.zoomPercent;
    final zoomStr = zoom > 0 ? '${zoom.toStringAsFixed(2)}%' : '--';
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Color(0x73000000), // ~45% 黑底
        borderRadius: BorderRadius.all(Radius.circular(4)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${_fmtTime(c.playheadUs)}  ($frame/$total)',
              style: const TextStyle(color: Colors.white, fontSize: 11),
            ),
            Text(
              '缩放: $zoomStr',
              style: const TextStyle(
                  color: Color(0xFFFFA500),
                  fontSize: 11,
                  fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}
