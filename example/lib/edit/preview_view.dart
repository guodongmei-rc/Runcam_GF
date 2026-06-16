import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'edit_controller.dart';
import 'preview_backend.dart';

/// 只负责"显示共享 stabilizer 的输出"。不引用 ParamsModel / 任何参数。
class PreviewView extends StatelessWidget {
  const PreviewView({super.key, required this.controller});
  final EditController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    if (c.uri == null) {
      return const Center(child: Text('未选视频'));
    }
    if (c.backend == PreviewBackend.texture) {
      if (c.textureId == null) {
        return const Center(child: CircularProgressIndicator());
      }
      return Center(
        child: AspectRatio(
          aspectRatio: c.aspect,
          child: Texture(textureId: c.textureId!),
        ),
      );
    }
    // PlatformView 后端
    return UiKitView(
      viewType: 'runcam_gf/preview_platformview',
      creationParams: {'uri': c.uri},
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: c.onPlatformViewCreated,
    );
  }
}
