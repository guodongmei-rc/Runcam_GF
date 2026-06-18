import 'package:flutter/services.dart';

export 'src/state/engine_bridge.dart' show EngineBridge, VideoInfo, StabInfo;
export 'src/state/engine_bridge_impl.dart' show EngineBridgeImpl;
export 'src/state/params_model.dart'
    show
        ParamsModel,
        ParamsModelStabilize,
        ParamsModelZoom,
        ParamsModelAdvanced;
// 阶段1 预览:Pigeon 生成的 PreviewApi / PreviewInfo(供预览页直接调用)。
export 'src/bridge/engine_api.g.dart'
    show PreviewApi, PreviewInfo, ExportRequest;

/// RuncamGF — Gyroflow 视频防抖 Flutter 插件。
///
/// 原样从原 App 抽离: 通过 channel `com.runcam/gyroflow` 的 `open`
/// 拉起原生全屏防抖页(iOS: present GyroflowLauncher;Android: startActivity
/// GyroflowActivity)。仅真机可用(iOS 模拟器不支持)。
class RuncamGF {
  RuncamGF._();

  static const MethodChannel _channel = MethodChannel('com.runcam/gyroflow');

  /// 打开 Gyroflow 防抖原生界面(对齐原 App `dashboard_controller.openGyroflow`)。
  /// iOS 模拟器会抛 `SIMULATOR_UNSUPPORTED`。
  static Future<void> open() async {
    await _channel.invokeMethod<String>('open');
  }
}
