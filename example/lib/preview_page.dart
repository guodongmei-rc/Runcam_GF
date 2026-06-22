import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'edit/edit_controller.dart';
import 'edit/gyro_widgets.dart';
import 'edit/gyroflow_theme.dart';
import 'edit/preview_backend.dart';
import 'edit/preview_view.dart';
import 'edit/gyro_timeline_view.dart';
import 'edit/panels/input_panel.dart';
import 'edit/panels/stabilize_panel.dart';
import 'edit/panels/sync_panel.dart';
import 'edit/panels/export_panel.dart';

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
      body: Stack(
        children: [
          SafeArea(child: _bodyColumn()),
          // 加载视频蒙版(转圈)。
          if (_c.busy) _busyOverlay('加载视频中…'),
          // 自动同步蒙版「分析中…」(对齐原生 syncOverlay)。
          if (_c.autosyncRunning) _autosyncOverlay(),
          // 导出蒙版「导出中…」(对齐原生导出进度遮罩)。
          if (_c.exportRunning) _exportOverlay(),
        ],
      ),
    );
  }

  Widget _bodyColumn() {
    return Column(
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
                // PlatformView 对照后端仅 iOS 实现;安卓只 Texture(对齐设计:
                // 原生全屏页的 SurfaceView 已是参照),隐藏切换以免触发 iOS-only UiKitView。
                if (defaultTargetPlatform != TargetPlatform.android)
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
            // 陀螺数据波形(对齐原生:预览下方、按钮上方),仅载入视频后显示。
            if (_c.uri != null) ...[
              const SizedBox(height: 6),
              GyroTimelineView(
                samples: _c.gyroSamples,
                axes: _c.gyroAxes,
                progress: _gyroProgress(),
                syncPoints: _c.autosyncSyncPoints,
                durationMs: (_c.videoInfo?.durationS ?? 0) * 1000,
                onSeek: (p) => _c.seekToProgress(p),
              ),
            ],
            // 预览控制按钮行:播放 / 切换稳定概览 / 防抖 / 背景模式(对齐官方预览控制)。
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
              child: Row(
                children: [
                  _ctrlBtn(
                    icon: _c.playing ? Icons.pause : Icons.play_arrow,
                    label: _c.playing ? '暂停' : '播放',
                    active: _c.playing,
                    onTap: _c.uri == null ? null : _c.togglePlay,
                  ),
                  const SizedBox(width: 8),
                  _ctrlBtn(
                    icon: Icons.crop_free,
                    label: '稳定概览',
                    active: _c.fovOverview,
                    onTap: _c.uri == null ? null : _c.toggleFovOverview,
                  ),
                  const SizedBox(width: 8),
                  _ctrlBtn(
                    icon: Icons.auto_fix_high,
                    label: '防抖',
                    active: _c.stabEnabled,
                    onTap: _c.uri == null ? null : _c.toggleStab,
                  ),
                  const SizedBox(width: 8),
                  _ctrlBtn(
                    icon: Icons.wallpaper,
                    label: _c.backgroundModeName,
                    active: false,
                    onTap: _c.uri == null
                        ? null
                        : () {
                            _c.cycleBackgroundMode();
                            if (!_c.fovOverview) {
                              _toast('打开稳定概览才能更好的预览效果');
                            }
                          },
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
        );
  }

  // 预览控制按钮(图标+标签):激活=橙底白字,未激活=描边,禁用=灰。
  Widget _ctrlBtn(
      {required IconData icon,
      required String label,
      required bool active,
      required VoidCallback? onTap}) {
    final enabled = onTap != null;
    final fg = !enabled
        ? GfColors.textSecondary
        : (active ? Colors.white : GfColors.accent);
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active && enabled ? GfColors.accent : Colors.transparent,
            border: Border.all(
                color: enabled ? GfColors.accent : GfColors.textSecondary),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: fg),
              const SizedBox(height: 2),
              Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: fg, fontSize: 11)),
            ],
          ),
        ),
      ),
    );
  }

  // 浮动 toast(清掉旧的不堆积)。
  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(milliseconds: 1500),
        behavior: SnackBarBehavior.floating,
      ));
  }

  // 陀螺波形播放头进度(Dart 播放头 / 时长)。
  double _gyroProgress() {
    final durUs = (_c.videoInfo?.durationS ?? 0) * 1e6;
    return durUs > 0 ? (_c.playheadUs / durUs).clamp(0.0, 1.0) : 0.0;
  }

  // 模态蒙版底座:全屏半透明 + 拦截点击,内容居中。
  Widget _modalOverlay({required Color color, required Widget child}) =>
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {},
          child: ColoredBox(color: color, child: Center(child: child)),
        ),
      );

  // 加载视频转圈蒙版。
  Widget _busyOverlay(String text) => _modalOverlay(
        color: const Color(0x99000000),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: GfColors.accent),
            const SizedBox(height: 12),
            Text(text,
                style: const TextStyle(color: GfColors.text, fontSize: 14)),
          ],
        ),
      );

  // 自动同步「分析中…」蒙版(对齐桌面:百分比 + 帧数@fps + 耗时/剩余 + 取消)。
  Widget _autosyncOverlay() {
    final pct = (_c.autosyncProgressValue * 100).toStringAsFixed(2);
    final fps = _c.autosyncFps.toStringAsFixed(1);
    return _modalOverlay(
      color: const Color(0xB3000000),
      child: Container(
        width: 300,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
        decoration: BoxDecoration(
          color: GfColors.bgPanel,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 进度条
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: _c.autosyncProgressValue.clamp(0.0, 1.0),
                minHeight: 5,
                backgroundColor: GfColors.inputBg,
                color: GfColors.accent,
              ),
            ),
            const SizedBox(height: 14),
            Text('分析中 $pct%... (${_c.autosyncReady}/${_c.autosyncTotal} @ ${fps}fps)',
                style: const TextStyle(color: GfColors.text, fontSize: 14)),
            const SizedBox(height: 6),
            Text('耗时: ${_c.autosyncElapsedSec}秒, 剩余: ${_c.autosyncRemainingSec}秒',
                style:
                    const TextStyle(color: GfColors.textSecondary, fontSize: 12)),
            const SizedBox(height: 10),
            TextButton(
              onPressed: _c.cancelAutosync,
              child: const Text('取消', style: TextStyle(color: GfColors.accent)),
            ),
          ],
        ),
      ),
    );
  }

  // 导出「导出中…」蒙版(对齐原生导出进度遮罩:百分比 + 帧数@fps + 耗时/剩余 + 取消)。
  Widget _exportOverlay() {
    final pct = (_c.exportProgressValue * 100).toStringAsFixed(1);
    final fps = _c.exportFps.toStringAsFixed(1);
    return _modalOverlay(
      color: const Color(0xB3000000),
      child: Container(
        width: 300,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
        decoration: BoxDecoration(
          color: GfColors.bgPanel,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: _c.exportProgressValue.clamp(0.0, 1.0),
                minHeight: 5,
                backgroundColor: GfColors.inputBg,
                color: GfColors.accent,
              ),
            ),
            const SizedBox(height: 14),
            Text('导出中 $pct%... (${_c.exportFrame}/${_c.exportTotal} @ ${fps}fps)',
                style: const TextStyle(color: GfColors.text, fontSize: 14)),
            const SizedBox(height: 6),
            Text('耗时: ${_c.exportElapsedSec}秒, 剩余: ${_c.exportRemainingSec}秒',
                style:
                    const TextStyle(color: GfColors.textSecondary, fontSize: 12)),
            const SizedBox(height: 10),
            TextButton(
              onPressed: _c.cancelExport,
              child: const Text('取消', style: TextStyle(color: GfColors.accent)),
            ),
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
            : StabilizePanel(
                model: _c.params,
                trailing: SyncPanel(controller: _c), // 参数下方:同步模块
                loadedValues: _c.loadedParamValues, // 双击标题恢复加载值
              );
      default:
        return ExportPanel(controller: _c);
    }
  }
}
