import 'package:flutter/material.dart';
import 'edit/edit_controller.dart';
import 'edit/gyro_widgets.dart';
import 'edit/gyroflow_theme.dart';
import 'edit/preview_backend.dart';
import 'edit/preview_view.dart';
import 'edit/panels/input_panel.dart';
import 'edit/panels/stabilize_panel.dart';

/// 阶段3 切片1:Flutter 编辑页(布局/样式对齐原生 gyroflow:全屏深色 + 大橙按钮 + 底部 Tab)。
/// 本切片只实现「参数」Tab 的 Stabilize 面板;输入/导出为后续切片占位。
class PreviewPage extends StatefulWidget {
  const PreviewPage({super.key});
  @override
  State<PreviewPage> createState() => _PreviewPageState();
}

class _PreviewPageState extends State<PreviewPage>
    with SingleTickerProviderStateMixin {
  final EditController _c = EditController();
  int _tab = 0; // 0=输入 1=参数 2=导出(对齐原生默认「输入」)
  late final AnimationController _ticker = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  );

  @override
  void initState() {
    super.initState();
    _ticker.repeat(); // Texture 后端需持续帧驱动 Flutter 合成到 60Hz
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
    return Theme(data: gyroflowTheme(), child: Builder(builder: _buildBody));
  }

  Widget _buildBody(BuildContext context) {
    return Scaffold(
      backgroundColor: GfColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            // 顶栏:关闭 + 后端状态 + 一键切后端(dev)。
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.close, color: GfColors.text),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                Expanded(
                  child: Text(_c.status,
                      style: const TextStyle(
                          color: GfColors.textSecondary, fontSize: 12)),
                ),
                TextButton(
                  onPressed: _c.uri == null || _c.busy ? null : _c.switchBackend,
                  child: Text('切到 ${_c.backend.other.label}',
                      style: const TextStyle(color: GfColors.accent)),
                ),
                const SizedBox(width: 4),
              ],
            ),
            // 预览区。
            Expanded(
              flex: 3,
              child: Container(
                color: GfColors.bg,
                width: double.infinity,
                child: AnimatedBuilder(
                  animation: _ticker,
                  builder: (_, _) => PreviewView(controller: _c),
                ),
              ),
            ),
            // 大号橙色按钮行(对齐原生 暂停/开启防抖)。
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Row(
                children: [
                  Expanded(
                      child: GyroBigButton(
                          label: '选视频', onPressed: _c.busy ? null : _c.openAndStart)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: GyroBigButton(
                      label: _c.playing ? '暂停' : '播放',
                      onPressed: _c.uri == null ? null : _c.togglePlay,
                    ),
                  ),
                ],
              ),
            ),
            // 底部 Tab(输入/参数/导出)。
            GyroTabBar(
              index: _tab,
              onChanged: (i) => setState(() => _tab = i),
              tabs: const [
                (icon: Icons.videocam_outlined, label: '输入'),
                (icon: Icons.settings_outlined, label: '参数'),
                (icon: Icons.file_download_outlined, label: '导出'),
              ],
            ),
            // Tab 内容。
            Expanded(flex: 5, child: _tabContent()),
          ],
        ),
      ),
    );
  }

  Widget _tabContent() {
    switch (_tab) {
      case 0:
        return InputPanel(controller: _c);
      case 1:
        return _c.uri == null
            ? const Center(
                child: Text('选视频后可调参',
                    style: TextStyle(color: GfColors.textSecondary)))
            : StabilizePanel(model: _c.params);
      default:
        return Container(
          color: GfColors.bgPanel,
          alignment: Alignment.center,
          child: const Text('「导出」面板:后续切片',
              style: TextStyle(color: GfColors.textSecondary)),
        );
    }
  }
}
