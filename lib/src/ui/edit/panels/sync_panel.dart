import 'package:flutter/material.dart';
import 'package:runcam_gf/runcam_gf.dart'; // ParamsModelAdvanced 扩展 + EditController + l10n
import '../gyro_widgets.dart';
import '../gyroflow_theme.dart';

/// 同步模块(对齐官方 Synchronization.qml):自动同步(+自动选点复选框) + 粗略偏移/搜索尺寸/
/// 最大同步点数(输入框 + 各自复选框) + 「高级选项」展开(每N帧/每点时长/分辨率/光流/位姿/偏移/
/// 低通(勾选显示 Hz 输入框)/显示特征/显示光流)。数值读写 ParamsModel 同步组(setter 自带 clamp)。
class SyncPanel extends StatefulWidget {
  const SyncPanel({super.key, required this.controller});
  final EditController controller;
  @override
  State<SyncPanel> createState() => _SyncPanelState();
}

class _SyncPanelState extends State<SyncPanel> {
  bool _adv = false;
  int _syncedSeq = -1; // 镜头加载(sync_settings 覆盖参数)后回填输入框

  final _offset = TextEditingController();
  final _search = TextEditingController();
  final _maxPts = TextEditingController();
  final _everyNth = TextEditingController();
  final _timePer = TextEditingController();
  final _lpf = TextEditingController();

  EditController get c => widget.controller;
  ParamsModel get m => widget.controller.params;

  static const _resValues = [0, 2160, 1080, 720, 480];

  @override
  void dispose() {
    for (final t in [_offset, _search, _maxPts, _everyNth, _timePer, _lpf]) {
      t.dispose();
    }
    super.dispose();
  }

  // 镜头档案 sync_settings 覆盖参数后(lensLoadSeq 变),回填输入框(不打断正在编辑)。
  void _refillIfNeeded() {
    if (c.lensLoadSeq == _syncedSeq) return;
    _syncedSeq = c.lensLoadSeq;
    _offset.text = _fmt(m.gyroOffsetMs / 1000.0);
    _search.text = _fmt(m.syncSearchSizeSec);
    _maxPts.text = '${m.maxSyncPoints}';
    _everyNth.text = '${m.everyNthFrame}';
    _timePer.text = _fmt(m.timePerSyncpointSec);
    _lpf.text = _fmt(m.imuLpfHz);
  }

  String _fmt(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : '$v';

  @override
  Widget build(BuildContext context) {
    _refillIfNeeded();
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.syncTitle,
            style: const TextStyle(
                color: GfColors.text, fontSize: 15, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        // 自动同步按钮(居中)+ 后面「自动选点」复选框(auto_sync_points)。
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            OutlinedButton.icon(
              onPressed: (c.uri == null || c.autosyncRunning)
                  ? null
                  : c.startAutosyncManual,
              icon: const Icon(Icons.sync, size: 16),
              label: Text(c.autosyncRunning ? l10n.syncSyncing : l10n.syncAutoSync),
              style: OutlinedButton.styleFrom(
                foregroundColor: GfColors.accent,
                side: const BorderSide(color: GfColors.accent),
              ),
            ),
            const SizedBox(width: 8),
            _check(m.autoSyncPointsExperimental,
                (v) => setState(() => m.autoSyncPointsExperimental = v)),
          ],
        ),
        // 粗略大致偏移(秒,可负)+ 双向搜索复选框(initial_offset_inv)。
        _numRow(l10n.syncRoughGyroOffset, _offset, l10n.syncUnitSeconds, (s) {
          final v = double.tryParse(s.trim());
          if (v != null) m.gyroOffsetMs = v * 1000.0;
        }, _submitOffset,
            negative: true,
            trailing: _check(m.checkNegativeInitialOffset,
                (v) => setState(() => m.checkNegativeInitialOffset = v))),
        // 同步搜索尺寸(秒)+ 先粗后细复选框(calc_initial_fast)。
        _numRow(l10n.syncSearchSize, _search, l10n.syncUnitSeconds, (s) {
          final v = double.tryParse(s.trim());
          if (v != null) m.syncSearchSizeSec = v;
        }, _submitSearch,
            trailing: _check(m.calcInitialFast,
                (v) => setState(() => m.calcInitialFast = v))),
        // 最大同步点数(整数,无复选框,对齐官方)。
        _numRow(l10n.syncMaxSyncPoints, _maxPts, '', (s) {
          final v = int.tryParse(s.trim());
          if (v != null) m.maxSyncPoints = v;
        }, _submitMaxPts, decimal: false),
        // 高级选项:居中 + 主题色。
        Center(
          child: InkWell(
            onTap: () => setState(() => _adv = !_adv),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(l10n.syncAdvanced,
                      style: const TextStyle(
                          color: GfColors.accent,
                          fontSize: 14,
                          fontWeight: FontWeight.w600)),
                  Icon(_adv ? Icons.expand_less : Icons.expand_more,
                      color: GfColors.accent, size: 18),
                ],
              ),
            ),
          ),
        ),
        if (_adv) ...[
          _numRow(l10n.syncEveryNthFrame, _everyNth, '', (s) {
            final v = int.tryParse(s.trim());
            if (v != null) m.everyNthFrame = v;
          }, _submitEveryNth, decimal: false),
          _numRow(l10n.syncTimePerSyncPoint, _timePer, l10n.syncUnitSeconds, (s) {
            final v = double.tryParse(s.trim());
            if (v != null) m.timePerSyncpointSec = v;
          }, _submitTimePer),
          GyroDropdown(
            label: l10n.syncProcessingResolution,
            options: [l10n.syncResNative, '4K', '1080p', '720p', '480p'],
            value: _resValues.indexOf(m.syncProcessingHeight).clamp(0, 4),
            onChanged: (i) => setState(() => m.syncProcessingHeight = _resValues[i]),
          ),
          // 光流方法去掉 AKAZE:下拉 [PyrLK, DIS] ↔ of_method [1, 2]。
          GyroDropdown(
            label: l10n.syncOpticalFlowMethod,
            options: const ['OpenCV (PyrLK)', 'OpenCV (DIS)'],
            value: m.ofMethod == 2 ? 1 : 0,
            onChanged: (i) => setState(() => m.ofMethod = i == 1 ? 2 : 1),
          ),
          GyroDropdown(
            label: l10n.syncPoseMethod,
            options: const [
              'findEssentialMat',
              'Almeida',
              'EightPoint',
              'findHomography'
            ],
            value: m.poseMethod.clamp(0, 3),
            onChanged: (i) => setState(() => m.poseMethod = i),
          ),
          GyroDropdown(
            label: l10n.syncOffsetMethod,
            options: [
              l10n.syncOffsetEssentialMatrix,
              l10n.syncOffsetVisualFeatures,
              l10n.syncOffsetRsSync
            ],
            value: m.offsetMethod.clamp(0, 2),
            onChanged: (i) => setState(() => m.offsetMethod = i),
          ),
          GyroCheck(
            label: l10n.syncLowPassFilter,
            value: m.imuLpfHz > 0,
            onChanged: (v) {
              setState(() => m.imuLpfHz = v ? 50.0 : 0.0);
              _lpf.text = _fmt(m.imuLpfHz);
            },
          ),
          // 勾选低通时:下方显示滤波值输入框(Hz,clamp 0–500)。
          if (m.imuLpfHz > 0)
            _numRow(l10n.syncFilterValue, _lpf, 'Hz', (s) {
              final v = double.tryParse(s.trim());
              if (v != null) m.imuLpfHz = v;
            }, _submitLpf),
          GyroCheck(
            label: l10n.syncShowDetectedFeatures,
            value: m.showDetectedFeatures,
            onChanged: (v) => setState(() => m.showDetectedFeatures = v),
          ),
          GyroCheck(
            label: l10n.syncShowOpticalFlow,
            value: m.showOpticalFlow,
            onChanged: (v) => setState(() => m.showOpticalFlow = v),
          ),
        ],
        const Divider(), // 与下方「平滑方式」分隔
      ],
    );
  }

  // ---- 提交:解析 → 写 ParamsModel(自带 clamp)→ 回填 clamp 后的值 ----
  void _submitOffset() {
    final v = double.tryParse(_offset.text.trim());
    if (v != null) m.gyroOffsetMs = v * 1000.0;
    _offset.text = _fmt(m.gyroOffsetMs / 1000.0);
  }

  void _submitSearch() {
    final v = double.tryParse(_search.text.trim());
    if (v != null) m.syncSearchSizeSec = v;
    // 官方:搜索 >10s 自动勾「先粗后细」。
    if (m.syncSearchSizeSec > 10) m.calcInitialFast = true;
    setState(() => _search.text = _fmt(m.syncSearchSizeSec));
  }

  void _submitMaxPts() {
    final v = int.tryParse(_maxPts.text.trim());
    if (v != null) m.maxSyncPoints = v;
    _maxPts.text = '${m.maxSyncPoints}';
  }

  void _submitEveryNth() {
    final v = int.tryParse(_everyNth.text.trim());
    if (v != null) m.everyNthFrame = v;
    _everyNth.text = '${m.everyNthFrame}';
  }

  void _submitTimePer() {
    final v = double.tryParse(_timePer.text.trim());
    if (v != null) m.timePerSyncpointSec = v;
    _timePer.text = _fmt(m.timePerSyncpointSec);
  }

  void _submitLpf() {
    final v = double.tryParse(_lpf.text.trim());
    if (v != null) m.imuLpfHz = v;
    setState(() => _lpf.text = _fmt(m.imuLpfHz));
  }

  // 数值输入行:标签 + 输入框(+ 单位 + 可选尾随复选框)。[decimal]/[negative] 控制可输入字符。
  // [liveSet] 每次输入即写入参数(确保点自动同步时用的是最新值);[onSubmit] 提交时回填 clamp 值。
  Widget _numRow(String label, TextEditingController ctrl, String unit,
          ValueChanged<String> liveSet, VoidCallback onSubmit,
          {Widget? trailing, bool decimal = true, bool negative = false}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(
                flex: 3,
                child: Text(label,
                    style:
                        const TextStyle(color: GfColors.text, fontSize: 14))),
            Expanded(
              flex: 2,
              child: TextField(
                controller: ctrl,
                keyboardType: TextInputType.numberWithOptions(
                    decimal: decimal, signed: negative),
                inputFormatters: numFormatters(decimal: decimal, negative: negative),
                textInputAction: TextInputAction.done,
                style: const TextStyle(color: GfColors.text, fontSize: 14),
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: GfColors.inputBg,
                  suffixText: unit.isEmpty ? null : unit,
                  suffixStyle: const TextStyle(
                      color: GfColors.textSecondary, fontSize: 12),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: BorderSide.none),
                ),
                onChanged: liveSet, // 实时写入参数(点自动同步时用最新值)
                onSubmitted: (_) => onSubmit(),
                onTapOutside: (_) {
                  onSubmit();
                  FocusManager.instance.primaryFocus?.unfocus();
                },
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 8), trailing],
          ],
        ),
      );

  // 行内复选框(无标签):用与 GyroCheck 完全相同的方框样式(20×20 描边 + ✓)。
  Widget _check(bool value, ValueChanged<bool> onChanged) => InkWell(
        onTap: () => onChanged(!value),
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(4), // 扩大点击区
          child: Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border.all(
                  color: value ? GfColors.accent : GfColors.textSecondary,
                  width: 2),
              borderRadius: BorderRadius.circular(4),
            ),
            child: value
                ? const Text('✓',
                    style: TextStyle(
                        color: GfColors.accent, fontSize: 13, height: 1))
                : null,
          ),
        ),
      );
}
