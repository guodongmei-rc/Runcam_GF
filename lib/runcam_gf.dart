export 'src/state/engine_bridge.dart' show EngineBridge, VideoInfo, StabInfo;
export 'src/state/engine_bridge_impl.dart' show EngineBridgeImpl;
export 'src/state/lens_profile_updater.dart' show LensProfileUpdater;
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
// 共享本地化:AppLocalizations / L.current / context.l10n(L10nX) / resolveAppLocale /
// kSupportedLocales。PreviewPage 已自带本地化,宿主无需用到这些;仅当宿主想在
// 自己的 MaterialApp 里复用同一套译文时才需要。show 收窄,不外泄生成机制。
export 'src/ui/l10n/l10n.dart'
    show AppLocalizations, L, L10nX, kSupportedLocales, resolveAppLocale;
// 统一吐司(编辑器内部使用)。需宿主在 Widget 树上提供 ToastificationWrapper。
export 'src/ui/toast.dart' show showAppToast;

// RuncamGF 防抖能力以共享 Dart 编辑器形式提供:宿主直接
// `Navigator.push(MaterialPageRoute(builder: (_) => const PreviewPage()))` 打开。
// (旧的「通过 com.runcam/gyroflow channel 拉起原生全屏页」入口已移除。)
