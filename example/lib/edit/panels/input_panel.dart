import 'package:flutter/material.dart';
import '../edit_controller.dart';
import '../gyro_widgets.dart';
import '../gyroflow_theme.dart';

/// 「输入」面板:对齐原生「视频信息 + 镜头配置文件 + 运动数据」。
/// 已接引擎:低通滤波器 / IMU 朝向 / 积分方法 / 方向指示器(显示偏好)。
/// 标「后续」的(镜头搜索·打开·创建、运动数据文件、Median filter、旋转、陀螺仪偏差、统计/导出)
/// 需文件选择器或尚未接的桥方法,先按原生样子摆上并禁用。
class InputPanel extends StatefulWidget {
  const InputPanel({super.key, required this.controller});
  final EditController controller;
  @override
  State<InputPanel> createState() => _InputPanelState();
}

class _InputPanelState extends State<InputPanel> {
  late final TextEditingController _imu =
      TextEditingController(text: widget.controller.imuOrientation);
  final TextEditingController _lensQuery = TextEditingController();
  List<Map<String, String>> _lensResults = const [];
  bool _searching = false;

  EditController get c => widget.controller;

  @override
  void dispose() {
    _imu.dispose();
    _lensQuery.dispose();
    super.dispose();
  }

  Future<void> _runLensSearch(String q) async {
    setState(() => _searching = true);
    final r = await c.searchLens(q);
    if (!mounted) return;
    setState(() {
      _lensResults = r;
      _searching = false;
    });
  }

  Future<void> _pickLens(String id) async {
    await c.loadLens(id);
    if (!mounted) return;
    setState(() {
      _lensResults = const [];
      _lensQuery.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: GfColors.bgPanel,
      child: AnimatedBuilder(
        animation: c,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
          children: [
            ..._videoInfo(),
            const SizedBox(height: 22),
            ..._lensProfile(),
            const SizedBox(height: 22),
            ..._motionData(),
          ],
        ),
      ),
    );
  }

  // ---- 视频信息 ----
  List<Widget> _videoInfo() {
    final vi = c.videoInfo;
    final loaded = c.uri != null;
    final size = (vi?.width != null && vi?.height != null)
        ? '${vi!.width}×${vi.height}'
        : '---';
    final dur = vi?.durationS != null ? '${vi!.durationS!.toStringAsFixed(2)} s' : '---';
    final fps = vi?.fps != null ? '${vi!.fps!.toStringAsFixed(3)} fps' : '---';
    return [
      _title('视频信息'),
      const SizedBox(height: 10),
      GyroBigButton(label: '打开文件', onPressed: c.busy ? null : c.openAndStart),
      const SizedBox(height: 6),
      _row('文件名称', c.videoName ?? '---'),
      _row('检测到的相机', c.detectedCamera ?? '---'),
      _row('检测镜头', c.detectedLens ?? '---'),
      _row('尺寸', size),
      _row('时长', dur),
      _row('帧速率', fps),
      _row('编码解码器', loaded ? 'H.264' : '---'),
      _row('像素格式', loaded ? 'YUV420P' : '---'),
      _row('音频', '---'),
      _row('旋转', loaded ? '0°' : '---'),
      _row('包含陀螺仪数据', loaded ? (c.hasGyro ? 'Yes' : 'No') : '---'),
      ..._recordingRows(c.recordingSettings),
    ];
  }

  // ---- 镜头配置文件 ----
  List<Widget> _lensProfile() => [
        _title('镜头配置文件'),
        const SizedBox(height: 10),
        // 搜索框(回车搜索内置镜头库)。
        TextField(
          controller: _lensQuery,
          enabled: c.uri != null,
          style: const TextStyle(color: GfColors.text, fontSize: 14),
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: '搜索镜头…',
            hintStyle: const TextStyle(color: GfColors.textSecondary),
            isDense: true,
            filled: true,
            fillColor: GfColors.inputBg,
            suffixIcon: _searching
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2)))
                : const Icon(Icons.search, color: GfColors.textSecondary, size: 18),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
          ),
          onSubmitted: _runLensSearch,
        ),
        // 搜索结果(点击加载)。
        for (final r in _lensResults)
          InkWell(
            onTap: () => _pickLens(r['id']!),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
              child: Text(r['name'] ?? r['id']!,
                  style: const TextStyle(color: GfColors.accent, fontSize: 13)),
            ),
          ),
        const SizedBox(height: 10),
        _row('当前镜头', c.lensName),
        for (final e in c.lensInfo.entries) _row(e.key, e.value),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _disabledButton('打开文件')),
          const SizedBox(width: 12),
          Expanded(child: _disabledButton('创建新的')),
        ]),
      ];

  // ---- 运动数据 ----
  List<Widget> _motionData() => [
        _title('运动数据'),
        const SizedBox(height: 10),
        Center(child: SizedBox(width: 180, child: _disabledButton('打开文件'))),
        const SizedBox(height: 8),
        _row('检测到的格式', '---'),
        _row('文件名称', '---'),
        const SizedBox(height: 4),
        GyroCheck(
            label: '低通滤波器', value: c.imuLpfOn, onChanged: c.setImuLpfOn),
        _disabledCheck('Median filter'),
        _disabledCheck('旋转'),
        _disabledCheck('陀螺仪偏差'),
        const SizedBox(height: 6),
        _imuOrientationRow(),
        const SizedBox(height: 6),
        GyroDropdown(
          label: '积分方法',
          options: const ['None', 'Complementary', 'VQF', 'Madgwick'],
          value: c.integrationMethod.clamp(0, 3),
          onChanged: c.setIntegration,
        ),
        const SizedBox(height: 4),
        GyroCheck(
            label: '方向指示器',
            value: c.orientationIndicator,
            onChanged: c.setOrientationIndicator),
        const SizedBox(height: 12),
        Center(
          child: Text('统计   导出  (后续)',
              style: TextStyle(
                  color: GfColors.textSecondary.withValues(alpha: 0.6), fontSize: 13)),
        ),
      ];

  Widget _imuOrientationRow() => Row(children: [
        const SizedBox(
            width: 104,
            child: Text('IMU 朝向',
                style: TextStyle(color: GfColors.textSecondary, fontSize: 13))),
        Expanded(
          child: TextField(
            controller: _imu,
            style: const TextStyle(color: GfColors.text, fontSize: 14),
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: GfColors.inputBg,
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
            ),
            onSubmitted: (v) => c.setImuOrientationStr(v.trim()),
          ),
        ),
      ]);

  // ---- recording_settings 行 ----
  List<Widget> _recordingRows(Map<String, String> rs) {
    if (rs.isEmpty) return const [];
    const mapping = <String, String>{
      'Focal length': '焦距',
      'Focus mode': '对焦模式',
      'Iris': '光圈',
      'ISO': 'ISO',
      'Shutter angle': '快门角',
      'Shutter speed': '快门速度',
      'Exposure': '曝光度',
      'White balance mode': '白平衡模式',
      'White balance': '白平衡',
      'Color primaries': '基色',
      'Gamma equation': '伽玛方程',
    };
    final rows = <Widget>[];
    final shown = <String>{};
    mapping.forEach((key, label) {
      final v = rs[key];
      if (v != null && v.isNotEmpty) {
        rows.add(_row(label, v));
        shown.add(key);
      }
    });
    rs.forEach((k, v) {
      if (!shown.contains(k) && v.isNotEmpty) rows.add(_row(k, v));
    });
    return rows;
  }

  // ---- 通用小部件 ----
  Widget _title(String t) => Text(t,
      style: const TextStyle(
          color: GfColors.text, fontSize: 18, fontWeight: FontWeight.bold));

  Widget _row(String label, String value) {
    final isEmpty = value == '---';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(children: [
        Text(label,
            style: const TextStyle(color: GfColors.textSecondary, fontSize: 14)),
        const Spacer(),
        Text(value,
            style: TextStyle(
                color: isEmpty ? GfColors.textSecondary : GfColors.text, fontSize: 14)),
      ]),
    );
  }

  // 「后续」占位:按钮 / 复选框,禁用灰显。
  Widget _disabledButton(String label) => Container(
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
            color: GfColors.bgBar, borderRadius: BorderRadius.circular(8)),
        child: Text('$label(后续)',
            style: const TextStyle(color: GfColors.textSecondary, fontSize: 14)),
      );

  Widget _disabledCheck(String label) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
                border: Border.all(
                    color: GfColors.textSecondary.withValues(alpha: 0.4), width: 2),
                borderRadius: BorderRadius.circular(4)),
          ),
          const SizedBox(width: 10),
          Text('$label(后续)',
              style: TextStyle(
                  color: GfColors.textSecondary.withValues(alpha: 0.6), fontSize: 14)),
        ]),
      );
}
