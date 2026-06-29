import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:runcam_gf/runcam_gf.dart';
import 'package:toastification/toastification.dart';

// l10n / showAppToast / PreviewPage 现由插件 barrel 导出(编辑器 UI 已并入插件)。
import 'preview_platformview_page.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: kSupportedLocales,
      // 系统语言为简体中文 → 中文,其它一律英文(见 resolveAppLocale)。
      localeListResolutionCallback: resolveAppLocale,
      // 每次重建同步全局译文实例,供无 BuildContext 的状态层(EditController 等)读取。
      builder: (context, child) {
        L.current = AppLocalizations.of(context)!;
        // ToastificationWrapper:提供吐司专用 overlay(在全局之上显示)。
        return ToastificationWrapper(child: child ?? const SizedBox.shrink());
      },
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final EngineBridge _bridge = EngineBridgeImpl();
  late final ParamsModel _model = ParamsModel(_bridge);
  String _status = '';

  // 两端统一走原生「文档选择器」通道,对齐老原生页:
  // 安卓 ACTION_OPEN_DOCUMENT → content://(nativeOpenVideo 只认它);
  // iOS UIDocumentPicker(asCopy)→ 原始文件临时副本路径(陀螺轨道完整,
  // 避免相册导出转码剥掉遥测)。
  static const MethodChannel _pickerChannel =
      MethodChannel('runcam_gf_example/picker');

  @override
  void dispose() {
    _model.dispose();
    super.dispose();
  }

  /// 返回引擎可直接 openVideo 的 URI:安卓 content://、iOS 文件路径。
  Future<String?> _pickVideoUri() => _pickerChannel.invokeMethod<String>('pickVideo');

  Future<void> _runSmoke() async {
    final l10n = context.l10n;
    try {
      final uri = await _pickVideoUri();
      if (uri == null) return;
      await _bridge.createStabilizer();
      final info = await _bridge.openVideo(uri);
      // 关键:加载视频后显式打开防抖总开关(对齐 ViewController.mm 的
      // gyroflow_set_stab_enabled(s, 1);ParamsModel 不管这个非面板开关)。
      await _bridge.setStabEnabled(true);
      // 再把所有默认值推到引擎并 recompute 一次(等价 Controller 初始化),保证有回填。
      await _model.pushAllDefaultsAndRecompute();
      _model.smoothness = 0.6; // 非默认值(默认 0.5),触发 setter→立即推→200ms 防抖 recompute
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (!mounted) return;
      final msg = 'output=${info.outputWidth}x${info.outputHeight} '
          'minFov=${_model.minFov.toStringAsFixed(4)} '
          'maxAngle P/Y/R=${_model.maxAnglePitch.toStringAsFixed(2)}/'
          '${_model.maxAngleYaw.toStringAsFixed(2)}/'
          '${_model.maxAngleRoll.toStringAsFixed(2)}';
      setState(() => _status = msg);
      showAppToast(msg);
    } on PlatformException catch (e) {
      showAppToast(l10n.homeSmokeFailedPlatform(e.code, e.message ?? ''));
    } catch (e) {
      showAppToast(l10n.homeSmokeFailed('$e'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('RuncamGF example')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton(
              onPressed: _runSmoke,
              child: const Text('Run Engine Smoke (dev)'),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PreviewPage()),
              ),
              child: Text(context.l10n.homePreviewTexture),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PreviewPlatformViewPage()),
              ),
              child: Text(context.l10n.homePreviewPlatformView),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(_status, textAlign: TextAlign.center),
            ),
          ],
        ),
      ),
    );
  }
}
