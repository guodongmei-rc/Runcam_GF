import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'l10n/l10n.dart';
import 'toast.dart';
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

  // 点页面任意空白处:收起镜头检索结果列表。
  // 不强制收键盘 —— 镜头搜索框「有输入时」要保持键盘(其收起由搜索框自身 onTapOutside 处理)。
  void _dismissLensOverlay() {
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
          // 三套布局:① 宽屏(iPad 横屏,≥_kWideBreakpoint)三栏;② 手机横屏两栏
          // (左 预览/运动数据/按钮 4 : 右 Tab 3);③ 竖屏 走原 Tab 单列。
          // 包一层 GestureDetector:点页面任意空白处收起镜头检索列表(子控件照常响应)。
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _dismissLensOverlay,
            child: LayoutBuilder(
              builder: (context, c) {
                final wide = c.maxWidth >= _kWideBreakpoint;
                final phoneLandscape = !wide && c.maxWidth > c.maxHeight;
                final body = wide
                    ? _wideBody()
                    : (phoneLandscape ? _phoneLandscapeBody() : _bodyColumn());
                // 手机横屏:不预留左右安全区(用满整宽);其余布局四周都留。
                return SafeArea(
                  left: !phoneLandscape,
                  right: !phoneLandscape,
                  child: body,
                );
              },
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

  // iPad 横屏等宽屏阈值:>= 此宽度切三栏(输入 | 预览 | 参数/导出);
  // 取 1000 以便手机横屏(含 Pro Max ~956)走两栏而非三栏。
  static const double _kWideBreakpoint = 1000;

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

  // 运动数据波形(预览下方、按钮上方);未载入视频返回空占位。height 默认 84,
  // 手机横屏传一半(42)以省竖向空间。
  Widget _gyroTimeline({double height = 84}) {
    if (_c.uri == null) return const SizedBox.shrink();
    return GyroTimelineView(
      height: height,
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
  // compact(手机横屏):按钮高度与上下间距减半。
  Widget _controlButtons({bool compact = false}) {
    final h = compact ? 22.0 : 44.0;
    final isz = compact ? 16.0 : 20.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(10, compact ? 5 : 10, 10, compact ? 5 : 10),
      child: Row(
        children: [
          _ctrlBtn(
            icon: _c.playing ? Icons.pause : Icons.play_arrow,
            label: _c.playing ? context.l10n.prevPause : context.l10n.prevPlay,
            active: _c.playing,
            onTap: _c.uri == null ? null : _c.togglePlay,
            height: h,
            iconSize: isz,
          ),
          const SizedBox(width: 8),
          _ctrlBtn(
            svgAsset: 'assets/icons/fov-overview.svg', // 官方稳定概览图标
            label: context.l10n.prevStabOverview,
            active: _c.fovOverview,
            onTap: _c.uri == null ? null : _c.toggleFovOverview,
            height: h,
            iconSize: isz,
          ),
          const SizedBox(width: 8),
          _ctrlBtn(
            svgAsset: 'assets/icons/gyroflow.svg', // 官方防抖图标
            label: context.l10n.prevStabilization,
            active: _c.stabEnabled,
            onTap: _c.uri == null ? null : _c.toggleStab,
            height: h,
            iconSize: isz,
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
            height: h,
            iconSize: isz,
          ),
          const SizedBox(width: 8),
          // 裁剪开关:开启→时间线显示选区(默认居中 1/3)可拖动调整,导出仅该段;关闭→导出整片。
          _ctrlBtn(
            icon: Icons.content_cut,
            label: context.l10n.prevTrim,
            active: _c.trimEnabled,
            onTap: _c.uri == null ? null : _c.toggleTrim,
            height: h,
            iconSize: isz,
          ),
        ],
      ),
    );
  }

  // 参数模块整列(同一滚动):同步(顶,对齐官方 同步→稳定)→ 稳定 → 导出(稳定模块下方)。
  // 仅 iPad 三栏右栏用(无 Tab,故把导出接在稳定下方一起滚)。
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

  // 「参数」Tab 内容:稳定 + 同步(导出在独立「导出」Tab,故此处不含导出)。
  Widget _paramsTab() => StabilizePanel(
        model: _c.params,
        trailing: SyncPanel(controller: _c),
        loadedValues: _c.loadedParamValues,
      );

  // 窄屏(手机/竖屏):预览 + 运动数据 + 按钮 + 底部 Tab。
  Widget _bodyColumn() {
    return Column(
      children: [
        _topBar(),
        _previewBox(),
        if (_c.uri != null) ...[const SizedBox(height: 6), _gyroTimeline()],
        _controlButtons(),
        _tabBar(),
        Expanded(flex: 5, child: _tabContent()),
      ],
    );
  }

  // Tab 栏:输入 / 参数 / 导出(三个)。compact(手机横屏)高度约减半。
  Widget _tabBar({bool compact = false}) => GyroTabBar(
        index: _tab,
        compact: compact,
        onChanged: (i) => setState(() => _tab = i),
        tabs: [
          (icon: Icons.videocam_outlined, label: context.l10n.prevTabInput),
          (icon: Icons.settings_outlined, label: context.l10n.prevTabParams),
          (icon: Icons.file_download_outlined, label: context.l10n.prevTabExport),
        ],
      );

  // 手机横屏顶栏:返回按钮 + 紧挨其右的标题(不居中)。
  Widget _topBarLeft() => Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_ios,
                color: GfColors.unselectedBottomBarColor),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          const Text('Gyroflow',
              style: TextStyle(
                  color: GfColors.unselectedBottomBarColor, fontSize: 18)),
        ],
      );

  // 手机横屏:整体是左右两栏(无全宽顶栏)。
  //   左(4):顶栏(返回+标题)在左上 → 预览(填充)→ 运动数据 → 5 按钮;
  //   右(3):Tab 标签直接顶到最上端 → Tab 内容。
  Widget _phoneLandscapeBody() {
    // 手机横屏:参数区里所有 Slider 强制两行(标题一行、滑条一行、左对齐)。
    return SliderLayout(
      twoRow: true,
      child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 4,
          child: Column(
            children: [
              _topBarLeft(),
              Expanded(child: _previewContent()),
              if (_c.uri != null) ...[
                const SizedBox(height: 6),
                _gyroTimeline(height: 42), // 手机横屏:运动数据高度减半
              ],
              _controlButtons(), // 原始高度
            ],
          ),
        ),
        const VerticalDivider(width: 1, color: GfColors.border),
        Expanded(
          flex: 3,
          child: Column(
            children: [
              _tabBar(), // 直接顶到最上端,原始高度
              Expanded(child: _tabContent()),
            ],
          ),
        ),
      ],
      ),
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
              // 右栏:参数模块(稳定 → 同步 → 导出,整列一起滚动);无视频时显示但不可操作。
              Expanded(flex: 1, child: _disabledIfNoVideo(_paramsPanel())),
            ],
          ),
        ),
      ],
    );
  }

  // 预览控制按钮(只用图标,不放文字):激活=橙底白字,未激活=描边,禁用=灰。
  // [label] 不再可见,仅作无障碍语义(随系统语言本地化)。
  Widget _ctrlBtn(
      {IconData? icon,
      String? svgAsset, // 自定义 SVG 图标(如官方稳定概览图标),与 icon 二选一
      required String label,
      required bool active,
      required VoidCallback? onTap,
      double height = 44,
      double iconSize = 20}) {
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
            height: height,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active && enabled ? GfColors.accent : Colors.transparent,
              border: Border.all(
                  color: enabled ? GfColors.accent : GfColors.textSecondary),
              borderRadius: BorderRadius.circular(8),
            ),
            child: svgAsset != null
                ? SvgPicture.asset(svgAsset,
                    width: iconSize,
                    height: iconSize,
                    colorFilter: ColorFilter.mode(fg, BlendMode.srcIn))
                : Icon(icon, size: iconSize, color: fg),
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

  // 浮动 toast(toastification,清掉旧的不堆积)。
  void _toast(String msg) => showAppToast(msg);

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

  // 未导入视频时:内容照常显示但整体不可操作(拦截点击 + 变暗)。
  Widget _disabledIfNoVideo(Widget child) => _c.uri == null
      ? IgnorePointer(child: Opacity(opacity: 0.5, child: child))
      : child;

  Widget _tabContent() {
    switch (_tab) {
      case 0:
        return InputPanel(controller: _c); // 「输入」需可操作(要选视频),不禁用
      case 1:
        // 「参数」Tab:稳定 + 同步;无视频时显示但不可操作。
        return _disabledIfNoVideo(_paramsTab());
      default:
        return _disabledIfNoVideo(ExportPanel(controller: _c)); // 「导出」Tab
    }
  }
}
