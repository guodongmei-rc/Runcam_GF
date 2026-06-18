import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:runcam_gf/runcam_gf.dart';

/// 预览 PlatformView (dev):对照 Texture 路。
///
/// 选视频 → 同一套引擎初始化(createStabilizer→openVideo→setStabEnabled→gyroOffset→recompute,
/// **不降分辨率**,与原生全屏页一致)→ 放一个 `UiKitView`,原生 MTKView 直出。
/// 用来和「预览 Texture spike」在同一条 4K 片上对比流畅度。
class PreviewPlatformViewPage extends StatefulWidget {
  const PreviewPlatformViewPage({super.key});

  @override
  State<PreviewPlatformViewPage> createState() => _PreviewPlatformViewPageState();
}

class _PreviewPlatformViewPageState extends State<PreviewPlatformViewPage> {
  static const MethodChannel _picker = MethodChannel('runcam_gf_example/picker');
  final EngineBridge _bridge = EngineBridgeImpl();
  late final ParamsModel _model = ParamsModel(_bridge);

  String? _uri;
  String _status = '点「选视频」开始';
  bool _playing = false; // 打开后停在首帧,手动点播放(对齐原生 + PreviewPlatformView init 渲首帧暂停)
  MethodChannel? _pv; // 每个 PlatformView 实例的控制通道

  Future<void> _start() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final uri = await _picker.invokeMethod<String>('pickVideo');
      if (uri == null) return;
      // 引擎初始化:与 Texture 页同一套,但**不降分辨率**(原生直出,全 4K 对照)。
      await _bridge.createStabilizer();
      final info = await _bridge.openVideo(uri);
      await _bridge.setStabEnabled(true);
      // 不再强推 gyro_offset(原生不写 stabilizer);此演示页不做镜头自动匹配,仅作直出对照。
      await _model.pushAllDefaultsAndRecompute();
      if (!mounted) return;
      setState(() {
        _uri = uri;
        _playing = false; // 打开后停在首帧,手动点播放
        _status = '原生直出 (PlatformView) · out=${info.outputWidth}x${info.outputHeight}';
      });
    } on PlatformException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('失败: ${e.code} ${e.message}')));
    }
  }

  void _onPlatformViewCreated(int id) {
    _pv = MethodChannel('runcam_gf/preview_pv_$id');
  }

  Future<void> _togglePlay() async {
    final next = !_playing;
    await _pv?.invokeMethod(next ? 'play' : 'pause');
    if (mounted) setState(() => _playing = next);
  }

  @override
  void dispose() {
    _pv?.invokeMethod('dispose');
    _bridge.freeStabilizer();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('预览 PlatformView (dev)')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(_status, textAlign: TextAlign.center),
          ),
          Expanded(
            child: _uri == null
                ? const Center(child: Text('未选视频'))
                : UiKitView(
                    viewType: 'runcam_gf/preview_platformview',
                    creationParams: {'uri': _uri},
                    creationParamsCodec: const StandardMessageCodec(),
                    onPlatformViewCreated: _onPlatformViewCreated,
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton(onPressed: _start, child: const Text('选视频')),
                ElevatedButton(
                  onPressed: _uri == null ? null : _togglePlay,
                  child: Text(_playing ? '暂停' : '播放'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
