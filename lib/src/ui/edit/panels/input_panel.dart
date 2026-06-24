import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../l10n/l10n.dart';
import '../edit_controller.dart';
import '../gyro_widgets.dart';
import '../gyroflow_theme.dart';
import '../orientation_indicator.dart';

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
  // 搜索框焦点:tap-outside 收键盘(对齐「同步搜索尺寸」数值框的交互)。
  final FocusNode _lensFocus = FocusNode();
  bool _searching = false;
  Timer? _lensSearchDebounce; // 边输入边搜的防抖

  // 镜头「高级」段:展开开关 + 8 个可编辑数值框 + 已回填的镜头加载序号。
  bool _advancedOpen = false;
  final _fx = TextEditingController();
  final _fy = TextEditingController();
  final _cx = TextEditingController();
  final _cy = TextEditingController();
  final _d0 = TextEditingController();
  final _d1 = TextEditingController();
  final _d2 = TextEditingController();
  final _d3 = TextEditingController();
  int _syncedLensSeq = -1;

  // 运动数据展开项。低通(Hz)/帧偏移=接引擎;Median/旋转/偏差=UI-only(对齐原生)。
  final _lpfHz = TextEditingController(text: '50.00');
  bool _frameOffsetOn = false;
  final _frameOffset = TextEditingController(text: '0');
  bool _medianOn = false;
  final _medianSamples = TextEditingController(text: '5');
  bool _rotationOn = false;
  final _rotPitch = TextEditingController(text: '0.0');
  final _rotRoll = TextEditingController(text: '0.0');
  final _rotYaw = TextEditingController(text: '0.0');
  bool _biasOn = false;
  final _biasX = TextEditingController(text: '0.00');
  final _biasY = TextEditingController(text: '0.00');
  final _biasZ = TextEditingController(text: '0.00');
  String? _syncedImu; // 已回填到输入框的 IMU 朝向(变了才刷,不覆盖编辑中)
  int _syncedGyroSeq = -1; // 已回填的运动数据序号(median/旋转/偏差)

  EditController get c => widget.controller;

  @override
  void dispose() {
    _lensSearchDebounce?.cancel();
    _imu.dispose();
    _lensQuery.dispose();
    _lensFocus.dispose();
    for (final t in [
      _fx, _fy, _cx, _cy, _d0, _d1, _d2, _d3, //
      _lpfHz, _frameOffset, _medianSamples, //
      _rotPitch, _rotRoll, _rotYaw, _biasX, _biasY, _biasZ,
    ]) {
      t.dispose();
    }
    super.dispose();
  }

  /// 仅在加载了新镜头(lensLoadSeq 变化)时把引擎回填值刷进输入框,
  /// 避免每次 notify(如 recompute)覆盖用户正在编辑的内容。
  void _syncLensFields() {
    if (c.lensLoadSeq == _syncedLensSeq) return;
    _syncedLensSeq = c.lensLoadSeq;
    double? dist(int i) =>
        i < c.lensDistortion.length ? c.lensDistortion[i] : null;
    String f(double? v) => v != null ? '$v' : '';
    _fx.text = f(c.lensFx);
    _fy.text = f(c.lensFy);
    _cx.text = f(c.lensCx);
    _cy.text = f(c.lensCy);
    _d0.text = f(dist(0));
    _d1.text = f(dist(1));
    _d2.text = f(dist(2));
    _d3.text = f(dist(3));
  }

  Future<void> _runLensSearch(String q) async {
    setState(() => _searching = true);
    final r = await c.searchLens(q);
    if (!mounted) return;
    c.setLensResults(r); // 结果提到控制器,便于页面任意处收起
    setState(() => _searching = false);
  }

  /// 点键盘「完成」:取消待执行搜索、收起键盘、收起搜索结果列表。
  void _onLensSearchDone(String _) {
    _lensSearchDebounce?.cancel();
    _lensFocus.unfocus(); // 收起键盘
    c.clearLensResults(); // 收起搜索列表
    setState(() => _searching = false);
  }

  /// 边输入边搜(防抖 300ms,对齐桌面 fork 的 live SearchField);清空则立即清结果。
  void _onLensQueryChanged(String q) {
    _lensSearchDebounce?.cancel();
    if (q.trim().isEmpty) {
      c.clearLensResults();
      setState(() => _searching = false);
      return;
    }
    _lensSearchDebounce =
        Timer(const Duration(milliseconds: 300), () => _runLensSearch(q));
  }

  Future<void> _pickLens(String id) async {
    await c.loadLens(id);
    if (!mounted) return;
    c.clearLensResults();
    _lensQuery.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: GfColors.bgPanel,
      child: AnimatedBuilder(
        animation: c,
        builder: (context, _) {
          _syncLensFields();
          // IMU 朝向回显:加载视频/外挂陀螺后引擎检测值变化时刷进输入框。
          if (_syncedImu != c.imuOrientation) {
            _syncedImu = c.imuOrientation;
            _imu.text = c.imuOrientation;
          }
          // median/旋转/偏差 回显:引擎读回值变化时刷进输入框 + 勾选态。
          if (_syncedGyroSeq != c.gyroInfoSeq) {
            _syncedGyroSeq = c.gyroInfoSeq;
            _medianOn = c.imuMedian > 0;
            if (c.imuMedian > 0) _medianSamples.text = '${c.imuMedian}';
            final r = c.imuRotation;
            _rotationOn = r.any((v) => v != 0);
            _rotPitch.text = '${r[0]}';
            _rotRoll.text = '${r[1]}';
            _rotYaw.text = '${r[2]}';
            final b = c.imuBias;
            _biasOn = b.any((v) => v != 0);
            _biasX.text = '${b[0]}';
            _biasY.text = '${b[1]}';
            _biasZ.text = '${b[2]}';
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
            children: [
              ..._videoInfo(),
              const SizedBox(height: 22),
              ..._lensProfile(),
              const SizedBox(height: 22),
              ..._motionData(),
            ],
          );
        },
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
    // 编码器/像素格式/音频/旋转:原生从 AVAsset/MediaExtractor 读入 VideoInfo(空=取不到)。
    final codec = (vi?.videoCodec?.isNotEmpty ?? false) ? vi!.videoCodec! : '---';
    // 像素格式:FFI 不透出真实 ffmpeg 值、iOS AVAsset 也难可靠取(原生 iOS 同样硬编码),
    // 取不到时回退常见默认 YUV420P 8 bit(对齐原生/桌面常见值),而非显示 ---。
    final pix = (vi?.pixelFormat?.isNotEmpty ?? false)
        ? vi!.pixelFormat!
        : (loaded ? 'YUV420P 8 bit' : '---');
    final audio = (vi?.audioCodec?.isNotEmpty ?? false)
        ? (vi!.audioSampleRate != null && vi.audioSampleRate! > 0
            ? '${vi.audioCodec} ${vi.audioSampleRate} Hz'
            : vi.audioCodec!)
        : (loaded ? context.l10n.inputNone : '---');
    final rot = vi?.rotationDeg != null ? '${vi!.rotationDeg}°' : '---';
    return [
      _title(context.l10n.inputVideoInfo),
      const SizedBox(height: 10),
      // 与「运动数据」下的打开文件按钮一致:居中、宽 180、同款 _primaryButton。
      Center(
        child: SizedBox(
          width: 180,
          child: _primaryButton(
              context.l10n.inputOpenFile, c.busy ? null : c.openAndStart),
        ),
      ),
      // 缺运动数据/镜头档案时:蓝色可点提示框,引导授权目录后自动扫描 sidecar(对齐原生)。
      if (c.showVideoDirHint) ...[
        const SizedBox(height: 8),
        _dirHintBox(),
      ],
      const SizedBox(height: 6),
      _row(context.l10n.inputFileName, c.videoName ?? '---'),
      _row(context.l10n.inputDetectedCamera, c.detectedCamera ?? '---'),
      _row(context.l10n.inputDetectedLens, c.detectedLens ?? '---'),
      _row(context.l10n.inputDimensions, size),
      _row(context.l10n.inputDuration, dur),
      _row(context.l10n.inputFrameRate, fps),
      _row(context.l10n.inputCodec, codec),
      _row(context.l10n.inputPixelFormat, pix),
      _row(context.l10n.inputAudio, audio),
      _row(context.l10n.inputRotation, rot),
      _row(context.l10n.inputContainsGyro,
          loaded ? (c.hasGyro ? 'Yes' : 'No') : '---'),
      ..._recordingRows(c.recordingSettings),
    ];
  }

  // 蓝色可点授权框:点击 → 选目录授权 → 扫描同名 sidecar 自动加载(对齐原生 InfoMessage)。
  Widget _dirHintBox() => GestureDetector(
        onTap: c.busy ? null : c.authorizeVideoFolder,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF1E5BB8), // 蓝底(对齐官方 InfoMessageSmall)
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            context.l10n.inputDirHint,
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: Colors.white, fontSize: 12, height: 1.4),
          ),
        ),
      );

  // 镜头提示框(对齐桌面 Gyroflow InfoMessageSmall):error=红底白字(更严重),
  // warning=橙底深字。用于「未加载镜头」「宽高比不符」「尺寸不符」三种提示。
  Widget _lensInfoBox(String text, {required bool error}) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: error
              ? const Color(0xFFD9534F) // 红色错误底
              : const Color(0xFFF0A030), // 橙色警告底
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
              color: error ? Colors.white : const Color(0xFF1A1A1A),
              fontSize: 12,
              height: 1.4),
        ),
      );

  // 检索结果列表(直接在搜索框下方、盖住「打开文件」):圆角卡片,最多 240 高、超出可滚,
  // 点击某条加载该镜头(_pickLens 会清空结果 → 列表收起、按钮恢复)。
  Widget _lensResultsList() => Material(
        color: GfColors.inputBg,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 240),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final r in c.lensResults)
                  InkWell(
                    onTap: () => _pickLens(r['id']!),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          vertical: 10, horizontal: 12),
                      child: Text(r['name'] ?? r['id']!,
                          style: const TextStyle(
                              color: GfColors.accent, fontSize: 13)),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );

  // ---- 镜头配置文件 ----
  List<Widget> _lensProfile() => [
        _title(context.l10n.inputLensProfile),
        const SizedBox(height: 10),
        // 搜索框(回车搜索内置镜头库)。
        TextField(
          controller: _lensQuery,
          focusNode: _lensFocus,
          // 有输入内容时,点空白处不收键盘(方便继续修改检索词);无内容时才收起。
          onTapOutside: (_) {
            if (_lensQuery.text.trim().isEmpty) _lensFocus.unfocus();
          },
          enabled: c.uri != null,
          style: const TextStyle(color: GfColors.text, fontSize: 14),
          textInputAction: TextInputAction.done, // 键盘右下角显示「完成」
          decoration: InputDecoration(
            hintText: context.l10n.inputSearchLens,
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
          onChanged: _onLensQueryChanged, // 跟随输入实时搜索(防抖)
          onSubmitted: _onLensSearchDone, // 点「完成」:收起键盘 + 搜索列表
        ),
        const SizedBox(height: 10),
        // 有检索结果:列表直接显示在输入框下方,盖住「打开文件」按钮;无结果时显示按钮。
        if (c.lensResults.isNotEmpty)
          _lensResultsList()
        else
          // 打开文件:选本地 .json 镜头档案(接 openLensFile),居中、宽 180、同款按钮。
          Center(
            child: SizedBox(
              width: 180,
              child: _primaryButton(context.l10n.inputOpenFile,
                  (c.busy || c.uri == null) ? null : c.openLensFile),
            ),
          ),
        // 镜头提示(对齐桌面 Gyroflow,载入视频后):
        //   未加载镜头 → 橙色警告(请加载镜头);已加载但宽高比不符 → 红色;仅尺寸不符 → 橙色。
        if (c.uri != null && !c.hasLensProfile) ...[
          const SizedBox(height: 10),
          _lensInfoBox(context.l10n.inputLensNotLoaded, error: false),
        ] else if (c.lensDimsMismatch) ...[
          const SizedBox(height: 10),
          _lensInfoBox(
              c.lensAspectMismatch
                  ? context.l10n.inputLensAspectMismatch
                  : context.l10n.inputLensMismatch,
              error: c.lensAspectMismatch),
        ],
        const SizedBox(height: 10),
        // (「当前镜头」标题 + 镜头名已按需求去掉,直接显示镜头信息行。)
        // lensInfo 的键为稳定标识符,_lensLabel 翻译成本地化标签后显示。
        for (final e in c.lensInfo.entries) _row(_lensLabel(e.key), e.value),
        // 镜头配置文件「打开文件 / 创建新的」按钮后续再做,先去掉。
        const SizedBox(height: 18),
        ..._lensAdvanced(),
      ];

  // ---- 镜头配置文件 → 高级(点击展开,可编辑,对齐原生)----
  // 像素焦距/聚焦中心/畸变系数来自 getLensInfoFull,可编辑;水下镜头本地偏好。
  List<Widget> _lensAdvanced() {
    return [
      InkWell(
        onTap: () => setState(() => _advancedOpen = !_advancedOpen),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  context.l10n.inputAdvanced,
                  style: const TextStyle(
                    color: GfColors.accent,
                    fontSize: 14,
                    decoration: TextDecoration.underline,
                    decorationColor: GfColors.accent,
                  ),
                ),
                Icon(_advancedOpen ? Icons.expand_less : Icons.expand_more,
                    color: GfColors.accent, size: 18),
              ],
            ),
          ),
        ),
      ),
      if (_advancedOpen) ...[
        const SizedBox(height: 6),
        GyroCheck(
          label: context.l10n.inputUnderwaterLens,
          value: c.underwaterLens,
          onChanged: (v) => setState(() => c.underwaterLens = v),
        ),
        _fieldLabel(context.l10n.inputPixelFocalLength),
        _twoField(_fx, (v) => c.lensFx = v, _fy, (v) => c.lensFy = v),
        _fieldLabel(context.l10n.inputFocalCenter),
        _twoField(_cx, (v) => c.lensCx = v, _cy, (v) => c.lensCy = v),
        _fieldLabel(context.l10n.inputDistortionCoeffs),
        _twoField(_d0, (v) => _setDist(0, v), _d1, (v) => _setDist(1, v)),
        const SizedBox(height: 10),
        _twoField(_d2, (v) => _setDist(2, v), _d3, (v) => _setDist(3, v)),
      ],
    ];
  }

  /// 畸变系数写回(列表可能为 const/过短,复制成可变并补齐)。
  void _setDist(int i, double? v) {
    final list = List<double?>.from(c.lensDistortion);
    while (list.length <= i) {
      list.add(null);
    }
    list[i] = v;
    c.lensDistortion = list;
  }

  Widget _fieldLabel(String t) => Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 6),
        child:
            Text(t, style: const TextStyle(color: GfColors.text, fontSize: 14)),
      );

  Widget _twoField(TextEditingController a, ValueChanged<double?> onA,
          TextEditingController b, ValueChanged<double?> onB) =>
      Row(children: [
        Expanded(child: _numField(a, onA)),
        const SizedBox(width: 10),
        Expanded(child: _numField(b, onB)),
      ]);

  // 可编辑数值框(对齐原生输入框样式)。
  Widget _numField(TextEditingController tc, ValueChanged<double?> onSet) =>
      Container(
        height: 38,
        decoration: BoxDecoration(
            color: GfColors.inputBg, borderRadius: BorderRadius.circular(6)),
        child: TextField(
          controller: tc,
          style: const TextStyle(color: GfColors.text, fontSize: 12),
          keyboardType:
              const TextInputType.numberWithOptions(decimal: true, signed: true),
          inputFormatters: numFormatters(decimal: true, negative: true),
          decoration: const InputDecoration(
            isDense: true,
            border: InputBorder.none,
            contentPadding:
                EdgeInsets.symmetric(horizontal: 10, vertical: 11),
          ),
          onChanged: (s) => onSet(double.tryParse(s.trim())),
        ),
      );

  // ---- 运动数据 ----
  List<Widget> _motionData() => [
        _title(context.l10n.inputMotionData),
        const SizedBox(height: 10),
        Center(
          child: SizedBox(
            width: 180,
            child: _primaryButton(context.l10n.inputOpenFile,
                (c.busy || c.uri == null) ? null : c.openMotionFile),
          ),
        ),
        const SizedBox(height: 8),
        _row(context.l10n.inputDetectedFormat,
            c.motionFormat ?? c.detectedCamera ?? '---'),
        _row(context.l10n.inputFileName, c.motionFileName ?? c.videoName ?? '---'),
        const SizedBox(height: 4),
        // 加载全部元数据 + 帧偏移:仅手动加载外挂运动数据后显示(对齐原生可见条件)。
        if (c.hasExternalMotion) ...[
          GyroCheck(
              label: context.l10n.inputLoadAllMetadata,
              value: c.loadAllMetadata,
              onChanged: c.setLoadAllMetadata),
          _frameOffsetRow(),
        ],
        _lpfRow(),
        _medianRow(), // Median filter:UI-only,对齐原生(无 FFI/委托)
        _rotationRow(), // 旋转:UI-only
        _gyroBiasRow(), // 陀螺仪偏差:UI-only
        const SizedBox(height: 6),
        _imuOrientationRow(),
        const SizedBox(height: 6),
        _integrationDropdown(),
        const SizedBox(height: 4),
        GyroCheck(
            label: context.l10n.inputOrientationIndicator,
            value: c.orientationIndicator,
            onChanged: c.setOrientationIndicator),
        if (c.orientationIndicator) ...[
          const SizedBox(height: 6),
          OrientationIndicator(quats: c.quats),
        ],
      ];

  // 帧偏移(可负;关=0)→ 引擎 + recompute。
  Widget _frameOffsetRow() =>
      _expandCheck(context.l10n.inputFrameOffset, _frameOffsetOn, (v) {
        setState(() => _frameOffsetOn = v);
        c.setFrameOffset(v ? (int.tryParse(_frameOffset.text.trim()) ?? 0) : 0);
      },
          child: _unitField(_frameOffset, context.l10n.inputUnitFrames,
              kbd: const TextInputType.numberWithOptions(signed: true),
              formatters: numFormatters(decimal: false, negative: true),
              onSubmitted: (s) => c.setFrameOffset(int.tryParse(s.trim()) ?? 0)));

  // 低通滤波器 + Hz(默认 50)→ params(自带 push+recompute)。
  Widget _lpfRow() =>
      _expandCheck(context.l10n.inputLowPassFilter, c.imuLpfOn, (v) {
        c.setImuLpfHz(v ? (double.tryParse(_lpfHz.text.trim()) ?? 50.0) : 0.0);
        setState(() {}); // imuLpfOn 由 params 决定,强制读新值刷选中态
      },
          child: _unitField(_lpfHz, 'Hz',
              kbd: const TextInputType.numberWithOptions(decimal: true),
              formatters: numFormatters(decimal: true, negative: false),
              onSubmitted: (s) =>
                  c.setImuLpfHz(double.tryParse(s.trim()) ?? 50.0)));

  // Median filter:接引擎(两端生效)。勾选=用 samples,取消=0。
  Widget _medianRow() => _expandCheck('Median filter', _medianOn, (v) {
        setState(() => _medianOn = v);
        c.setImuMedian(v ? (int.tryParse(_medianSamples.text.trim()) ?? 5) : 0);
      },
          child: _unitField(_medianSamples, 'samples',
              kbd: TextInputType.number,
              formatters: numFormatters(decimal: false, negative: false),
              onSubmitted: (s) {
                if (_medianOn) c.setImuMedian(int.tryParse(s.trim()) ?? 0);
              }));

  // 旋转 Pitch/Roll/Yaw:接引擎。取消=全 0。
  Widget _rotationRow() =>
      _expandCheck(context.l10n.inputRotation, _rotationOn, (v) {
        setState(() => _rotationOn = v);
        v
            ? c.setImuRotation(_d(_rotPitch), _d(_rotRoll), _d(_rotYaw))
            : c.setImuRotation(0, 0, 0);
      },
          child: _tripleField(
              const ['Pitch', 'Roll', 'Yaw'], [_rotPitch, _rotRoll, _rotYaw],
              onSubmitted: () {
            if (_rotationOn) {
              c.setImuRotation(_d(_rotPitch), _d(_rotRoll), _d(_rotYaw));
            }
          }));

  // 陀螺仪偏差 X/Y/Z:接引擎。取消=全 0。
  Widget _gyroBiasRow() =>
      _expandCheck(context.l10n.inputGyroBias, _biasOn, (v) {
        setState(() => _biasOn = v);
        v
            ? c.setImuBias(_d(_biasX), _d(_biasY), _d(_biasZ))
            : c.setImuBias(0, 0, 0);
      },
          child: _tripleField(const ['X', 'Y', 'Z'], [_biasX, _biasY, _biasZ],
              onSubmitted: () {
            if (_biasOn) c.setImuBias(_d(_biasX), _d(_biasY), _d(_biasZ));
          }));

  double _d(TextEditingController tc) => double.tryParse(tc.text.trim()) ?? 0.0;

  // 可展开勾选行:勾选框 +(选中时)缩进的展开内容。
  Widget _expandCheck(String label, bool value, ValueChanged<bool> onChanged,
          {Widget? child}) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        GyroCheck(label: label, value: value, onChanged: onChanged),
        if (value && child != null)
          Padding(
              padding: const EdgeInsets.only(left: 30, bottom: 8), child: child),
      ]);

  // 单字段 + 单位。
  Widget _unitField(TextEditingController tc, String unit,
          {TextInputType? kbd,
          List<TextInputFormatter>? formatters,
          ValueChanged<String>? onSubmitted}) =>
      Row(children: [
        SizedBox(
            width: 120,
            child: _motionField(tc,
                kbd: kbd, formatters: formatters, onSubmitted: onSubmitted)),
        const SizedBox(width: 8),
        Text(unit,
            style: const TextStyle(color: GfColors.textSecondary, fontSize: 13)),
      ]);

  // 三字段带小标签(Pitch/Roll/Yaw 或 X/Y/Z);任一字段提交触发 onSubmitted。
  Widget _tripleField(List<String> labels, List<TextEditingController> tcs,
          {VoidCallback? onSubmitted}) =>
      Row(children: [
        for (var i = 0; i < 3; i++) ...[
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(labels[i],
                  style: const TextStyle(
                      color: GfColors.textSecondary, fontSize: 11)),
              const SizedBox(height: 2),
              _motionField(tcs[i],
                  onSubmitted:
                      onSubmitted == null ? null : (_) => onSubmitted()),
            ]),
          ),
          if (i < 2) const SizedBox(width: 8),
        ],
      ]);

  Widget _motionField(TextEditingController tc,
          {TextInputType? kbd,
          List<TextInputFormatter>? formatters,
          ValueChanged<String>? onSubmitted}) =>
      Container(
        height: 36,
        decoration: BoxDecoration(
            color: GfColors.inputBg, borderRadius: BorderRadius.circular(6)),
        child: TextField(
          controller: tc,
          style: const TextStyle(color: GfColors.text, fontSize: 13),
          keyboardType:
              kbd ?? const TextInputType.numberWithOptions(decimal: true, signed: true),
          inputFormatters:
              formatters ?? numFormatters(decimal: true, negative: true),
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            isDense: true,
            border: InputBorder.none,
            contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          ),
          onSubmitted: onSubmitted,
        ),
      );

  // 深色实心按钮(对齐原生 primaryButton:可用=白字,禁用=灰字)。
  Widget _primaryButton(String label, VoidCallback? onPressed) {
    final enabled = onPressed != null;
    return Material(
      color: GfColors.inputBg, // 比 bgBar 亮一些,按钮更显眼
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onPressed,
        child: Container(
          height: 44,
          alignment: Alignment.center,
          child: Text(label,
              style: TextStyle(
                  color: enabled ? GfColors.text : GfColors.textSecondary,
                  fontSize: 14)),
        ),
      ),
    );
  }

  // 积分方法:列表是否含 None 由 has_quaternions 决定,FFI 索引↔UI 位置换算
  // (对齐原生 configureIntegrationMethodsHasQuaternions:有四元数→pos=ffi,否则 ffi-1)。
  Widget _integrationDropdown() {
    const withNone = [
      'None', 'Complementary', 'VQF', 'Simple gyro', //
      'Simple gyro + accel', 'Mahony', 'Madgwick',
    ];
    final hasQ = c.hasQuaternions;
    final names = hasQ ? withNone : withNone.sublist(1);
    final ffi = c.integrationMethod;
    final pos = (hasQ ? ffi : ffi - 1).clamp(0, names.length - 1);
    return GyroDropdown(
      label: context.l10n.inputIntegrationMethod,
      options: names,
      value: pos,
      onChanged: (p) => c.setIntegration(hasQ ? p : p + 1),
    );
  }

  Widget _imuOrientationRow() => Row(children: [
        SizedBox(
            width: 104,
            child: Text(context.l10n.inputImuOrientation,
                style: const TextStyle(
                    color: GfColors.textSecondary, fontSize: 13))),
        Expanded(
          child: TextField(
            controller: _imu,
            style: const TextStyle(color: GfColors.text, fontSize: 14),
            // 大小写表示轴向正反(如 ZyX),不能自动大写/纠错(对齐原生)。
            autocorrect: false,
            enableSuggestions: false,
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

  // lensInfo 的稳定标识键 → 本地化标签(对齐桌面 LensProfile 信息行)。
  String _lensLabel(String id) {
    final l = context.l10n;
    switch (id) {
      case 'camera':
        return l.inputLensCamera;
      case 'lens':
        return l.inputLensLens;
      case 'setting':
        return l.inputLensSetting;
      case 'note':
        return l.inputLensNote;
      case 'dimensions':
        return l.inputLensDimensions;
      case 'calibratedBy':
        return l.inputLensCalibratedBy;
      default:
        return id;
    }
  }

  // ---- recording_settings 行 ----
  // 元数据键(英文,来自 telemetry)按此顺序显示;再补未在表内的其它键。
  static const List<String> _recordingKeys = [
    'Focal length', 'Focus mode', 'Iris', 'ISO', 'Shutter angle', //
    'Shutter speed', 'Exposure', 'White balance mode', 'White balance', //
    'Color primaries', 'Gamma equation',
  ];

  // recording_settings 元数据键 → 本地化标签。
  String _recordingLabel(String key) {
    final l = context.l10n;
    switch (key) {
      case 'Focal length':
        return l.inputRsFocalLength;
      case 'Focus mode':
        return l.inputRsFocusMode;
      case 'Iris':
        return l.inputRsIris;
      case 'ISO':
        return l.inputRsIso;
      case 'Shutter angle':
        return l.inputRsShutterAngle;
      case 'Shutter speed':
        return l.inputRsShutterSpeed;
      case 'Exposure':
        return l.inputRsExposure;
      case 'White balance mode':
        return l.inputRsWhiteBalanceMode;
      case 'White balance':
        return l.inputRsWhiteBalance;
      case 'Color primaries':
        return l.inputRsColorPrimaries;
      case 'Gamma equation':
        return l.inputRsGammaEquation;
      default:
        return key;
    }
  }

  List<Widget> _recordingRows(Map<String, String> rs) {
    if (rs.isEmpty) return const [];
    final rows = <Widget>[];
    final shown = <String>{};
    for (final key in _recordingKeys) {
      final v = rs[key];
      if (v != null && v.isNotEmpty) {
        rows.add(_row(_recordingLabel(key), v));
        shown.add(key);
      }
    }
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
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style: const TextStyle(color: GfColors.textSecondary, fontSize: 14)),
        const SizedBox(width: 12),
        Expanded(
          child: Text(value,
              textAlign: TextAlign.end, // 长值自动换行,不溢出
              style: TextStyle(
                  color: isEmpty ? GfColors.textSecondary : GfColors.text,
                  fontSize: 14)),
        ),
      ]),
    );
  }
}
