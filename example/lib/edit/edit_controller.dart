import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:runcam_gf/runcam_gf.dart';
import 'preview_backend.dart';

/// 编辑页控制器:持引擎生命周期 + ParamsModel + 当前预览后端。
/// 面板只通过 [params] 调参;预览只读 [backend]/[textureId]/[uri]。
class EditController extends ChangeNotifier {
  EditController() {
    params = ParamsModel(_bridge);
  }

  static const MethodChannel _picker = MethodChannel('runcam_gf_example/picker');
  final EngineBridge _bridge = EngineBridgeImpl();
  final PreviewApi _previewApi = PreviewApi();
  late final ParamsModel params;

  String? uri;
  VideoInfo? videoInfo; // openVideo 回的视频元数据,供「输入」面板显示
  Map<String, String> recordingSettings = {}; // 录制参数(ISO/快门/光圈…),供「输入」面板
  PreviewBackend backend = PreviewBackend.texture;
  bool playing = false;
  bool busy = false;
  String status = '点「选视频」开始';

  // Texture 后端
  int? textureId;
  double aspect = 16 / 9;
  // PlatformView 后端
  MethodChannel? _pvChannel;

  /// 选视频 → 引擎初始化(一次)→ 起当前后端。
  Future<void> openAndStart() async {
    final picked = await _picker.invokeMethod<String>('pickVideo');
    if (picked == null) return;
    _setBusy(true);
    try {
      await _bridge.createStabilizer();
      final info = await _bridge.openVideo(picked);
      await _bridge.setStabEnabled(true);
      await _bridge.setGyroOffset(48.0); // raw-IMU 机型默认补偿(阶段4 autosync 替)
      await params.pushAllDefaultsAndRecompute();
      recordingSettings = await _fetchRecordingSettings();
      uri = picked;
      videoInfo = info;
      final ow = info.outputWidth ?? 16, oh = info.outputHeight ?? 9;
      aspect = oh > 0 ? ow / oh : 16 / 9;
      await _startBackend();
      playing = true;
      status = '后端:${backend.label}';
    } catch (e) {
      status = '失败:$e';
    } finally {
      _setBusy(false);
    }
  }

  /// 一键切后端:拆当前 + 起另一个(会重新解码),参数状态不动。
  Future<void> switchBackend() async {
    if (uri == null || busy) return;
    _setBusy(true);
    try {
      await _stopBackend();
      backend = backend.other;
      await _startBackend();
      playing = true;
      status = '后端:${backend.label}';
    } finally {
      _setBusy(false);
    }
  }

  Future<void> togglePlay() async {
    playing = !playing;
    if (backend == PreviewBackend.texture) {
      await (playing ? _previewApi.play() : _previewApi.pause());
    } else {
      await _pvChannel?.invokeMethod(playing ? 'play' : 'pause');
    }
    notifyListeners();
  }

  /// PlatformView 创建回调:拿到 per-view 控制通道。
  void onPlatformViewCreated(int id) {
    _pvChannel = MethodChannel('runcam_gf/preview_pv_$id');
  }

  /// 文件名(uri 末段,可能是 content:// 或文件路径)。
  String? get videoName {
    final u = uri;
    if (u == null) return null;
    final seg = Uri.tryParse(u)?.pathSegments;
    if (seg != null && seg.isNotEmpty && seg.last.isNotEmpty) return seg.last;
    return u.split('/').last;
  }

  /// 是否检测到陀螺(由 recompute 回填的最大修正角推断,maxAngle>0=有校正量)。
  bool get hasGyro =>
      params.maxAnglePitch.abs() +
          params.maxAngleYaw.abs() +
          params.maxAngleRoll.abs() >
      0.01;

  /// 读视频元数据 JSON → additional_data.recording_settings(英文键→值字符串)。
  /// 解析失败/无该段 → 空,「输入」面板就不显示这些行。
  Future<Map<String, String>> _fetchRecordingSettings() async {
    try {
      final root = jsonDecode(await _bridge.getVideoMetadata());
      final add = root is Map ? root['additional_data'] : null;
      final rs = add is Map ? add['recording_settings'] : null;
      if (rs is Map) {
        return rs.map((k, v) => MapEntry('$k', '$v'));
      }
    } catch (_) {/* 元数据缺失/格式异常 → 不显示录制参数 */}
    return {};
  }

  Future<void> _startBackend() async {
    if (backend == PreviewBackend.texture) {
      final pi = await _previewApi.createPreviewTexture(uri!);
      textureId = pi.textureId;
      final w = pi.width ?? 16, h = pi.height ?? 9;
      aspect = h > 0 ? w / h : aspect;
      await _bridge.recomputeBlocking(); // GPU 重绑后再同步一次(沿用现有修复)
      await _previewApi.play();
    }
    // PlatformView 后端:UiKitView 在页面构建时创建,原生 init 自动播放。
  }

  Future<void> _stopBackend() async {
    if (backend == PreviewBackend.texture) {
      final t = textureId;
      textureId = null;
      if (t != null) await _previewApi.disposePreviewTexture(t);
    } else {
      await _pvChannel?.invokeMethod('dispose');
      _pvChannel = null;
    }
  }

  void _setBusy(bool b) {
    busy = b;
    notifyListeners();
  }

  @override
  void dispose() {
    _stopBackend();
    _bridge.freeStabilizer();
    super.dispose();
  }
}
