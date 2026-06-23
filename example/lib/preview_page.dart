import 'package:flutter/material.dart';
import 'l10n/l10n.dart';
import 'edit/edit_controller.dart';
import 'edit/gyro_widgets.dart';
import 'edit/gyroflow_theme.dart';
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

  // 点页面任意空白处:收键盘 + 收起镜头检索结果列表。
  void _dismissLensOverlay() {
    FocusScope.of(context).unfocus();
    _c.clearLensResults();
  }

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
          // 宽屏(iPad 横屏)走三栏布局,窄屏(手机/竖屏)走原 Tab 布局。
          // 包一层 GestureDetector:点页面任意空白处即收键盘 + 收起镜头检索列表(子控件照常响应)。
          SafeArea(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _dismissLensOverlay,
              child: LayoutBuilder(
                builder: (context, c) =>
                    c.maxWidth >= _kWideBreakpoint ? _wideBody() : _bodyColumn(),
              ),
            ),
          ),
          // 加载视频蒙版(转圈)。
          if (_c.busy) _busyOverlay(context.l10n.prevLoadingVideo),
          // 自动同步蒙版「分析中…」(对齐原生 syncOverlay)。
          if (_c.autosyncRunning) _autosyncOverlay(),
          // 导出蒙版「导出中…」(对齐原生导出进度遮罩)。
          if (_c.exportRunning) _exportOverlay(),
        ],
      ),
    );
  }

  // iPad 横屏等宽屏阈值:>= 此宽度切「输入 | 预览 | 参数/导出」三栏布局。
  static const double _kWideBreakpoint = 900;

  // 顶栏:返回按钮 + 居中标题「Gyroflow」。
  Widget _topBar() => Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_ios,
                color: GfColors.unselectedBottomBarColor),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          const Expanded(
            child: Center(
              child: Text(
                'Gyroflow',
                style: TextStyle(
                    color: GfColors.unselectedBottomBarColor, fontSize: 18),
              ),
            ),
          ),
          const SizedBox(width: 48), // 平衡左侧返回按钮宽度,使标题真正居中
        ],
      );

  // 预览画面内容:黑底 + 视频帧(PreviewView 内部 Center+AspectRatio 按 c.aspect 居中、
  // 在「所在区域」内按比例适配)。给固定高度容器或 Expanded 都可。
  Widget _previewContent() => Container(
        color: GfColors.bg,
        width: double.infinity,
        child: AnimatedBuilder(
          animation: _ticker,
          builder: (_, _) => PreviewView(controller: _c),
        ),
      );

  // 窄屏预览区:固定高度 =(可用宽 − 20)× 9/16(16:9 左右各留 10);宽 = 高 × 比例(AspectRatio 自动)。
  Widget _previewBox() => LayoutBuilder(
        builder: (context, constraints) {
          final previewH = (constraints.maxWidth - 20) * 9 / 16;
          return SizedBox(
            height: previewH,
            width: double.infinity,
            child: _previewContent(),
          );
        },
      );

  // 运动数据波形(预览下方、按钮上方);未载入视频返回空占位。
  Widget _gyroTimeline() {
    if (_c.uri == null) return const SizedBox.shrink();
    return GyroTimelineView(
      samples: _c.gyroSamples,
      axes: _c.gyroAxes,
      progress: _gyroProgress(),
      syncPoints: _c.autosyncSyncPoints,
      durationMs: (_c.videoInfo?.durationS ?? 0) * 1000,
      onSeek: (p) => _c.seekToProgress(p),
      // 裁剪区间:仅裁剪开关开启时显示选区/手柄(回调为 null 即隐藏)。
      trimStart: _c.trimStartFrac,
      trimEnd: _c.trimEndFrac,
      onTrimStart: _c.trimEnabled
          ? (p) => _c.setTrimStartUs((p * _durationUs).round())
          : null,
      onTrimEnd: _c.trimEnabled
          ? (p) => _c.setTrimEndUs((p * _durationUs).round())
          : null,
    );
  }

  // 预览控制按钮行:播放 / 稳定概览 / 防抖 / 背景模式 / 裁剪。
  Widget _controlButtons() => Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
        child: Row(
          children: [
            _ctrlBtn(
              icon: _c.playing ? Icons.pause : Icons.play_arrow,
              label: _c.playing ? context.l10n.prevPause : context.l10n.prevPlay,
              active: _c.playing,
              onTap: _c.uri == null ? null : _c.togglePlay,
            ),
            const SizedBox(width: 8),
            _ctrlBtn(
              icon: Icons.crop_free,
              label: context.l10n.prevStabOverview,
              active: _c.fovOverview,
              onTap: _c.uri == null ? null : _c.toggleFovOverview,
            ),
            const SizedBox(width: 8),
            _ctrlBtn(
              icon: Icons.auto_fix_high,
              label: context.l10n.prevStabilization,
              active: _c.stabEnabled,
              onTap: _c.uri == null ? null : _c.toggleStab,
            ),
            const SizedBox(width: 8),
            _ctrlBtn(
              icon: _bgModeIcon(_c.backgroundMode),
              label: _c.backgroundModeName,
              active: false,
              onTap: _c.uri == null
                  ? null
                  : () {
                      _c.cycleBackgroundMode();
                      if (!_c.fovOverview) {
                        _toast(context.l10n.prevEnableOverviewHint);
                      }
                    },
            ),
            const SizedBox(width: 8),
            // 裁剪开关:开启→时间线显示选区(默认居中 1/3)可拖动调整,导出仅该段;关闭→导出整片。
            _ctrlBtn(
              icon: Icons.content_cut,
              label: context.l10n.prevTrim,
              active: _c.trimEnabled,
              onTap: _c.uri == null ? null : _c.toggleTrim,
            ),
          ],
        ),
      );

  // 参数模块整列(同一滚动):同步(顶,对齐官方 同步→稳定)→ 稳定 → 导出(稳定模块下方)。
  // 供窄屏「参数」Tab 与宽屏右栏复用。
  Widget _paramsPanel() => StabilizePanel(
        model: _c.params,
        trailing: SyncPanel(controller: _c), // 同步模块:置于稳定之上
        footer: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Divider(height: 22, color: GfColors.border),
            // 导出模块:嵌入(不自带滚动)→ 接在稳定模块下方,跟随整列一起滚到底。
            ExportPanel(controller: _c, embedded: true),
          ],
        ),
        loadedValues: _c.loadedParamValues, // 双击标题恢复加载值
      );

  // 窄屏(手机/竖屏):预览 + 运动数据 + 按钮 + 底部 Tab。
  Widget _bodyColumn() {
    return Column(
      children: [
        _topBar(),
        _previewBox(),
        if (_c.uri != null) ...[const SizedBox(height: 6), _gyroTimeline()],
        _controlButtons(),
        // 底部 Tab(输入/参数;导出已并入「参数」末尾)。
        GyroTabBar(
          index: _tab,
          onChanged: (i) => setState(() => _tab = i),
          tabs: [
            (icon: Icons.videocam_outlined, label: context.l10n.prevTabInput),
            (icon: Icons.settings_outlined, label: context.l10n.prevTabParams),
          ],
        ),
        Expanded(flex: 5, child: _tabContent()),
      ],
    );
  }

  // 宽屏(iPad 横屏):四等分三栏 —— 左「输入」(1) | 中 预览+运动数据+按钮(2) | 右 参数(上)/导出(下)(1)。
  Widget _wideBody() {
    return Column(
      children: [
        _topBar(),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 左栏:整个输入模块。
              Expanded(flex: 1, child: InputPanel(controller: _c)),
              const VerticalDivider(width: 1, color: GfColors.border),
              // 中栏(占 2 栏):上=预览区域(填充剩余空间,视频帧在内按比例适配),
              // 中=运动数据波形,底=5 个按钮。
              Expanded(
                flex: 2,
                child: Column(
                  children: [
                    Expanded(child: _previewContent()),
                    if (_c.uri != null) ...[
                      const SizedBox(height: 6),
                      _gyroTimeline(),
                    ],
                    _controlButtons(),
                  ],
                ),
              ),
              const VerticalDivider(width: 1, color: GfColors.border),
              // 右栏:参数模块(稳定 → 同步 → 导出,整列一起滚动)。
              Expanded(flex: 1, child: _paramsPanel()),
            ],
          ),
        ),
      ],
    );
  }

  // 预览控制按钮(只用图标,不放文字):激活=橙底白字,未激活=描边,禁用=灰。
  // [label] 不再可见,仅作无障碍语义(随系统语言本地化)。
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
      child: Semantics(
        label: label,
        button: true,
        enabled: enabled,
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
            child: Icon(icon, size: 20, color: fg),
          ),
        ),
      ),
    );
  }

  // 背景模式图标(对齐 setBackgroundMode 0..3):纯色 / 重复边缘像素 / 镜像边缘像素 / 羽化留边。
  // 单按钮循环切换,靠图标区分模式(不放文字)。
  IconData _bgModeIcon(int mode) {
    switch (mode) {
      case 1: // 重复边缘像素
        return Icons.blur_linear;
      case 2: // 镜像边缘像素
        return Icons.flip;
      case 3: // 羽化留边
        return Icons.gradient;
      default: // 0 纯色
        return Icons.format_color_fill;
    }
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

  // 视频总时长(µs),供裁剪手柄 frac↔µs 换算(与播放头/时间线同基准)。
  double get _durationUs => (_c.videoInfo?.durationS ?? 0) * 1e6;

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
            Text(
                context.l10n.prevAnalyzing(pct, '${_c.autosyncReady}',
                    '${_c.autosyncTotal}', fps),
                style: const TextStyle(color: GfColors.text, fontSize: 14)),
            const SizedBox(height: 6),
            Text(
                context.l10n.prevElapsedRemaining(
                    '${_c.autosyncElapsedSec}', '${_c.autosyncRemainingSec}'),
                style:
                    const TextStyle(color: GfColors.textSecondary, fontSize: 12)),
            const SizedBox(height: 10),
            TextButton(
              onPressed: _c.cancelAutosync,
              child: Text(context.l10n.prevCancel,
                  style: const TextStyle(color: GfColors.accent)),
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
            Text(
                context.l10n.prevExporting(pct, '${_c.exportFrame}',
                    '${_c.exportTotal}', fps),
                style: const TextStyle(color: GfColors.text, fontSize: 14)),
            const SizedBox(height: 6),
            Text(
                context.l10n.prevElapsedRemaining(
                    '${_c.exportElapsedSec}', '${_c.exportRemainingSec}'),
                style:
                    const TextStyle(color: GfColors.textSecondary, fontSize: 12)),
            const SizedBox(height: 10),
            TextButton(
              onPressed: _c.cancelExport,
              child: Text(context.l10n.prevCancel,
                  style: const TextStyle(color: GfColors.accent)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tabContent() {
    if (_tab == 0) return InputPanel(controller: _c);
    // 「参数」Tab:稳定 → 同步 → 导出(_paramsPanel 内含);未载入视频先给提示。
    return _c.uri == null
        ? Center(
            child: Text(context.l10n.prevSelectVideoHint,
                style: const TextStyle(color: GfColors.textSecondary)))
        : _paramsPanel();
  }
}
