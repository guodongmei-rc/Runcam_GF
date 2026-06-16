import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:runcam_gf/runcam_gf.dart';

import 'preview_page.dart';
import 'preview_platformview_page.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: HomePage(),
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
    final messenger = ScaffoldMessenger.of(context);
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
      messenger.showSnackBar(SnackBar(content: Text(msg)));
    } on PlatformException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('smoke 失败: ${e.code} ${e.message}')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('smoke 失败: $e')));
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
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                try {
                  await RuncamGF.open();
                } on PlatformException catch (e) {
                  messenger.showSnackBar(
                    SnackBar(content: Text('打开失败: ${e.code} ${e.message}')),
                  );
                }
              },
              child: const Text('打开 Gyroflow 防抖'),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _runSmoke,
              child: const Text('Run Engine Smoke (dev)'),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PreviewPage()),
              ),
              child: const Text('预览 Texture spike (dev)'),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PreviewPlatformViewPage()),
              ),
              child: const Text('预览 PlatformView (dev)'),
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
