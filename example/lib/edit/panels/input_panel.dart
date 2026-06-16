import 'package:flutter/material.dart';
import '../edit_controller.dart';
import '../gyro_widgets.dart';
import '../gyroflow_theme.dart';

/// 「输入」面板:对齐原生「视频信息 + 镜头配置文件」。
/// 文件名/尺寸/时长/帧速率来自 VideoInfo;编码/像素/旋转 同原生写死;
/// 陀螺由 recompute 回填的 maxAngle 推断;相机/镜头待后续接镜头信息读取。
class InputPanel extends StatelessWidget {
  const InputPanel({super.key, required this.controller});
  final EditController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final vi = c.videoInfo;
    final loaded = c.uri != null;
    final size = (vi?.width != null && vi?.height != null)
        ? '${vi!.width}×${vi.height}'
        : '---';
    final dur = vi?.durationS != null ? '${vi!.durationS!.toStringAsFixed(2)} s' : '---';
    final fps = vi?.fps != null ? '${vi!.fps!.toStringAsFixed(3)} fps' : '---';

    return Container(
      color: GfColors.bgPanel,
      child: AnimatedBuilder(
        animation: c,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
          children: [
            _title('视频信息'),
            const SizedBox(height: 10),
            GyroBigButton(
                label: '打开文件', onPressed: c.busy ? null : c.openAndStart),
            const SizedBox(height: 6),
            _row('文件名称', c.videoName ?? '---'),
            _row('检测到的相机', '---'),
            _row('检测镜头', '---'),
            _row('尺寸', size),
            _row('时长', dur),
            _row('帧速率', fps),
            _row('编码解码器', loaded ? 'H.264' : '---'),
            _row('像素格式', loaded ? 'YUV420P' : '---'),
            _row('音频', '---'),
            _row('旋转', loaded ? '0°' : '---'),
            _row('包含陀螺仪数据', loaded ? (c.hasGyro ? 'Yes' : 'No') : '---'),
            // 录制参数(有内嵌元数据的视频才有:ISO/快门/光圈/Gamma…)。
            ..._recordingRows(c.recordingSettings),
            const SizedBox(height: 22),
            _title('镜头配置文件'),
            const SizedBox(height: 8),
            _row('当前镜头', '---'),
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('镜头搜索 / 加载:后续切片',
                  style: TextStyle(color: GfColors.textSecondary, fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }

  /// recording_settings(英文键)→ 原生同款中文行,缺失键不显示,未映射键按原 key 兜底。
  List<Widget> _recordingRows(Map<String, String> rs) {
    if (rs.isEmpty) return const [];
    const mapping = <String, String>{
      'Focal length': '焦距',
      'Focus mode': '对焦方式',
      'Iris': '光圈',
      'ISO': 'ISO',
      'Shutter angle': '快门角度',
      'Shutter speed': '快门速度',
      'Exposure': '曝光',
      'White balance mode': '白平衡模式',
      'White balance': '白平衡',
      'Color primaries': '色彩原色',
      'Gamma equation': 'Gamma 曲线',
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

  Widget _title(String t) => Text(t,
      style: const TextStyle(
          color: GfColors.text, fontSize: 18, fontWeight: FontWeight.bold));

  Widget _row(String label, String value) {
    final isEmpty = value == '---';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Text(label,
              style: const TextStyle(color: GfColors.textSecondary, fontSize: 14)),
          const Spacer(),
          Text(value,
              style: TextStyle(
                  color: isEmpty ? GfColors.textSecondary : GfColors.text,
                  fontSize: 14)),
        ],
      ),
    );
  }
}
