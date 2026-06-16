import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:runcam_gf/runcam_gf.dart';

/// 阶段1 预览 Texture spike 页面(增量 A)。
///
/// 选视频 → `createPreviewTexture` → Flutter `Texture(textureId:)` 显示原生
/// 返回的 CVPixelBuffer(增量 A 为纯色青色块,证外部纹理链路通)。
class PreviewPage extends StatefulWidget {
  const PreviewPage({super.key});

  @override
  State<PreviewPage> createState() => _PreviewPageState();
}

class _PreviewPageState extends State<PreviewPage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const MethodChannel _picker = MethodChannel('runcam_gf_example/picker');
  final PreviewApi _api = PreviewApi();
  // 引擎桥:与 PreviewController 共享同一 stabilizer 句柄(RuncamGfPlugin 注入闭包)。
  // 预览前必须先 createStabilizer + openVideo + 推默认值,PreviewController 才能 process_frame。
  final EngineBridge _bridge = EngineBridgeImpl();
  late final ParamsModel _model = ParamsModel(_bridge);
  int? _textureId;
  double _aspect = 16 / 9;
  String _status = '';

  // seek:openVideo 返回的 VideoInfo.durationS(秒)换算成微秒,作为滑块 0..1 的标尺。
  int _durationUs = 0;
  double _seekValue = 0;

  // 播放时的帧驱动(textureFrameAvailable 单独不足以驱动引擎 60,需 Dart 侧持续帧)。
  // ticker 持续运行=每帧促 Flutter 上屏,间接保证原生 DisplayLink/解码持续产帧。
  late final AnimationController _anim =
      AnimationController(vsync: this, duration: const Duration(seconds: 2))
        ..repeat();

  // 增量 B:实测「合成 FPS」。Dart 的 addTimingsCallback 只统计框架帧、看不到外部纹理
  // 合成,故改为每秒向原生取 copyPixelBuffer 被调次数(= Flutter 实际合成上屏该纹理的帧数)。
  int _produceFps = 0;
  int _compositeFps = 0;
  Timer? _fpsTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _fpsTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (_textureId == null) return;
      final raw = await _api.takeCompositedFrameCount(); // 编码: produce*1000+composite
      if (!mounted) return;
      setState(() {
        _produceFps = raw ~/ 1000;
        _compositeFps = raw % 1000;
      });
    });
  }

  Future<void> _start() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final uri = await _picker.invokeMethod<String>('pickVideo');
      if (uri == null) return;
      // 共享 stabilizer 上加载该视频(复用 smoke 那套):创建句柄 → 打开视频 →
      // 开防抖总开关 → 推默认值并 recompute。完成后 PreviewController 才能拿它 process_frame。
      await _bridge.createStabilizer();
      final videoInfo = await _bridge.openVideo(uri);
      await _bridge.setStabEnabled(true);
      await _model.pushAllDefaultsAndRecompute();
      // 【诊断·阶段1】防抖根因探针:recompute 后引擎回填的 maxAngle/minFov。
      //   - maxAngle≈0 且 minFov≈1  → 引擎没拿到陀螺/无校正量 → 画面必然“不防抖”
      //     (多半是该视频无嵌入陀螺,或被转码剥掉,与 S8 ⑤⑦ 同源)。
      //   - maxAngle 非零 且 minFov<1 → 陀螺 OK、应当防抖;若仍不抖则是渲染侧问题。
      final maxAngle = [
        _model.maxAnglePitch.abs(),
        _model.maxAngleYaw.abs(),
        _model.maxAngleRoll.abs(),
      ].reduce((a, b) => a > b ? a : b);
      final minFov = _model.minFov;
      final gyroOk = maxAngle > 0.01 && minFov < 0.999;
      final info = await _api.createPreviewTexture(uri);
      // 【修复·防抖不上屏】createPreviewTexture 内部(PreviewController.setupWithUri)会再
      //   调一次 gyroflow_use_default_gpu 把 GPU 设备**重新绑定**到防抖管线——这发生在上面
      //   pushAllDefaultsAndRecompute 之后,会丢掉 recompute 已上传到 GPU 的平滑/缩放变换,
      //   于是 process_frame 渲成直通(画面不防抖,但 maxAngle 仍非零)。
      //   不改原生:在 GPU 重绑之后再 recompute 一次,把变换重新同步到 GPU,
      //   恢复老 open() 页“recompute 为最后一步 GPU 操作”的不变量。
      await _bridge.recomputeBlocking();
      if (!mounted) return;
      // PreviewInfo 字段为可空 int?:做空处理,别让 int? 直接参与比较/除法。
      final w = info.width ?? 16;
      final h = info.height ?? 9;
      final durationS = videoInfo.durationS ?? 0;
      setState(() {
        _textureId = info.textureId;
        _aspect = h > 0 ? w / h : 16 / 9;
        _durationUs = (durationS * 1e6).toInt();
        _seekValue = 0;
        _status = 'tex=${info.textureId ?? '-'} ${w}x$h\n'
            'maxAngle=${maxAngle.toStringAsFixed(2)}° '
            'minFov=${minFov.toStringAsFixed(3)} '
            '${gyroOk ? "✅陀螺OK→应防抖" : "⚠️无陀螺/无校正→不会防抖"}';
      });
      await _api.play();
    } on PlatformException catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('预览失败: ${e.code} ${e.message}')),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (_textureId == null) return;
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        _api.pause();
        break;
      case AppLifecycleState.resumed:
        _api.play();
        break;
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _anim.dispose();
    _fpsTimer?.cancel();
    _fpsTimer = null;
    final id = _textureId;
    if (id != null) _api.disposePreviewTexture(id);
    _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final id = _textureId;
    return Scaffold(
      appBar: AppBar(title: const Text('预览 Texture spike')),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: Stack(
                alignment: Alignment.topRight,
                children: [
                  id == null
                      ? const Text('点下方按钮选视频')
                      : AspectRatio(
                          aspectRatio: _aspect,
                          child: Texture(textureId: id),
                        ),
                  // 帧驱动 + live 指示(左上小方块):随 _anim ticker 旋转,流畅=引擎在 60。
                  Align(
                    alignment: Alignment.topLeft,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: RotationTransition(
                        turns: _anim,
                        child: Container(width: 16, height: 16, color: Colors.orange),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      color: Colors.black54,
                      child: Text(
                        'produce: $_produceFps  composite: $_compositeFps',
                        style: const TextStyle(
                          color: Colors.greenAccent,
                          fontFeatures: [FontFeature.tabularFigures()],
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Text(_status),
                const SizedBox(height: 8),
                // seek 滑块:0..1 映射到 [0, _durationUs]。仅在已有预览时可用。
                Slider(
                  value: _seekValue.clamp(0, 1),
                  onChanged: id == null || _durationUs <= 0
                      ? null
                      : (value) {
                          setState(() => _seekValue = value);
                          _api.seekTo((value * _durationUs).toInt());
                        },
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton(
                      onPressed: _start,
                      child: const Text('选视频并预览'),
                    ),
                    ElevatedButton(
                      onPressed: () => _api.play(),
                      child: const Text('播放'),
                    ),
                    ElevatedButton(
                      onPressed: () => _api.pause(),
                      child: const Text('暂停'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
