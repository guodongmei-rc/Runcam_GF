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

// 阶段3:共享编辑器 UI。PreviewPage 为整页编辑器(自带本地化与主题),
// 宿主 app 直接 `Navigator.push(MaterialPageRoute(builder: (_) => const PreviewPage()))`
// 即可使用,无需任何 l10n / 主题配置。EditController 供需要自定义页面壳的宿主使用。
export 'src/ui/preview_page.dart' show PreviewPage;
export 'src/ui/edit/edit_controller.dart' show EditController;
// 共享本地化:AppLocalizations / L.current / context.l10n / resolveAppLocale /
// kSupportedLocales。PreviewPage 已自带本地化,宿主无需用到这些;仅当宿主想在
// 自己的 MaterialApp 里复用同一套译文时才需要。
export 'src/ui/l10n/l10n.dart';
// 统一吐司(编辑器内部使用)。需宿主在 Widget 树上提供 ToastificationWrapper。
export 'src/ui/toast.dart' show showAppToast;

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
