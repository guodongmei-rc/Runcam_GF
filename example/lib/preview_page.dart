import 'package:flutter/material.dart';
import 'edit/edit_controller.dart';
import 'edit/gyroflow_theme.dart';
import 'edit/preview_backend.dart';
import 'edit/preview_view.dart';
import 'edit/panels/stabilize_panel.dart';

/// 阶段3 切片1:Flutter 编辑页(上预览 + 下 Stabilize 面板,预览后端可一键切)。
class PreviewPage extends StatefulWidget {
  const PreviewPage({super.key});
  @override
  State<PreviewPage> createState() => _PreviewPageState();
}

class _PreviewPageState extends State<PreviewPage>
    with SingleTickerProviderStateMixin {
  final EditController _c = EditController();
  late final AnimationController _ticker = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  );

  @override
  void initState() {
    super.initState();
    // Texture 后端需持续帧驱动 Flutter 合成到 60Hz(textureFrameAvailable 单独不足)。
    _ticker.repeat();
    _c.addListener(_onChange);
  }

  void _onChange() => setState(() {});

  @override
  void dispose() {
    _c.removeListener(_onChange);
    _ticker.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: gyroflowTheme(),
      child: Builder(builder: _buildScaffold),
    );
  }

  Widget _buildScaffold(BuildContext context) {
    return Scaffold(
      backgroundColor: GfColors.bg,
      appBar: AppBar(
        title: const Text('编辑页 (dev)'),
        actions: [
          TextButton(
            onPressed: _c.uri == null || _c.busy ? null : _c.switchBackend,
            child: Text('切到 ${_c.backend.other.label}',
                style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(6),
            child: Text(_c.status, textAlign: TextAlign.center),
          ),
          // 预览区:用 AnimatedBuilder(_ticker) 包一层,Texture 后端才会被持续重绘到 60Hz。
          Expanded(
            flex: 3,
            child: AnimatedBuilder(
              animation: _ticker,
              builder: (_, _) => PreviewView(controller: _c),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              ElevatedButton(onPressed: _c.openAndStart, child: const Text('选视频')),
              ElevatedButton(
                onPressed: _c.uri == null ? null : _c.togglePlay,
                child: Text(_c.playing ? '暂停' : '播放'),
              ),
            ],
          ),
          // 参数区:Stabilize 面板。
          Expanded(
            flex: 4,
            child: _c.uri == null
                ? const Center(child: Text('选视频后可调参'))
                : StabilizePanel(model: _c.params),
          ),
        ],
      ),
    );
  }
}
