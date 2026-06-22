import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  List<Map<String, String>> _lensResults = const [];
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
    setState(() {
      _lensResults = r;
      _searching = false;
    });
  }

  /// 点键盘「完成」:取消待执行搜索、收起键盘、收起搜索结果列表。
  void _onLensSearchDone(String _) {
    _lensSearchDebounce?.cancel();
    FocusScope.of(context).unfocus(); // 收起键盘
    setState(() {
      _lensResults = const []; // 收起搜索列表
      _searching = false;
    });
  }

  /// 边输入边搜(防抖 300ms,对齐桌面 fork 的 live SearchField);清空则立即清结果。
  void _onLensQueryChanged(String q) {
    _lensSearchDebounce?.cancel();
    if (q.trim().isEmpty) {
      setState(() {
        _lensResults = const [];
        _searching = false;
      });
      return;
    }
    _lensSearchDebounce =
        Timer(const Duration(milliseconds: 300), () => _runLensSearch(q));
  }

  Future<void> _pickLens(String id) async {
    await c.loadLens(id);
    if (!mounted) return;
    setState(() {
      _lensResults = const [];
      _lensQuery.clear();
    });
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
        : (loaded ? '无' : '---');
    final rot = vi?.rotationDeg != null ? '${vi!.rotationDeg}°' : '---';
    return [
      _title('视频信息'),
      const SizedBox(height: 10),
      // 与「运动数据」下的打开文件按钮一致:居中、宽 180、同款 _primaryButton。
      Center(
        child: SizedBox(
          width: 180,
          child: _primaryButton('打开文件', c.busy ? null : c.openAndStart),
        ),
      ),
      // 缺运动数据/镜头档案时:蓝色可点提示框,引导授权目录后自动扫描 sidecar(对齐原生)。
      if (c.showVideoDirHint) ...[
        const SizedBox(height: 8),
        _dirHintBox(),
      ],
      const SizedBox(height: 6),
      _row('文件名称', c.videoName ?? '---'),
      _row('检测到的相机', c.detectedCamera ?? '---'),
      _row('检测镜头', c.detectedLens ?? '---'),
      _row('尺寸', size),
      _row('时长', dur),
      _row('帧速率', fps),
      _row('编码解码器', codec),
      _row('像素格式', pix),
      _row('音频', audio),
      _row('旋转', rot),
      _row('包含陀螺仪数据', loaded ? (c.hasGyro ? 'Yes' : 'No') : '---'),
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
          child: const Text(
            '为检测项目文件、视频序列或图像序列，请点击此处选择带有输入文件的目录。',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white, fontSize: 12, height: 1.4),
          ),
        ),
      );

  // 镜头档案分辨率与视频不符的橙色警告框(文案/样式对齐桌面 Gyroflow)。
  Widget _lensMismatchBox() => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFFF0A030), // 橙色警告底(对齐官方 InfoMessageSmall warning)
          borderRadius: BorderRadius.circular(6),
        ),
        child: const Text(
          '镜头配置文件的尺寸与当前文件不符。结果看起来可能会不正确。',
          textAlign: TextAlign.center,
          style: TextStyle(color: Color(0xFF1A1A1A), fontSize: 12, height: 1.4),
        ),
      );

  // ---- 镜头配置文件 ----
  List<Widget> _lensProfile() => [
        _title('镜头配置文件'),
        const SizedBox(height: 10),
        // 搜索框(回车搜索内置镜头库)。
        TextField(
          controller: _lensQuery,
          enabled: c.uri != null,
          style: const TextStyle(color: GfColors.text, fontSize: 14),
          textInputAction: TextInputAction.done, // 键盘右下角显示「完成」
          decoration: InputDecoration(
            hintText: '搜索镜头…',
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
        // 搜索结果(点击加载)。
        for (final r in _lensResults)
          InkWell(
            onTap: () => _pickLens(r['id']!),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
              child: Text(r['name'] ?? r['id']!,
                  style: const TextStyle(color: GfColors.accent, fontSize: 13)),
            ),
          ),
        // 镜头档案分辨率与视频不符 → 橙色警告(对齐桌面 Gyroflow InfoMessageSmall)。
        if (c.lensDimsMismatch) ...[
          const SizedBox(height: 10),
          _lensMismatchBox(),
        ],
        const SizedBox(height: 10),
        // (「当前镜头」标题 + 镜头名已按需求去掉,直接显示镜头信息行。)
        for (final e in c.lensInfo.entries) _row(e.key, e.value),
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
                  '高级',
                  style: TextStyle(
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
          label: '水下镜头',
          value: c.underwaterLens,
          onChanged: (v) => setState(() => c.underwaterLens = v),
        ),
        _fieldLabel('像素焦距'),
        _twoField(_fx, (v) => c.lensFx = v, _fy, (v) => c.lensFy = v),
        _fieldLabel('聚焦中心'),
        _twoField(_cx, (v) => c.lensCx = v, _cy, (v) => c.lensCy = v),
        _fieldLabel('畸变系数'),
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
        _title('运动数据'),
        const SizedBox(height: 10),
        Center(
          child: SizedBox(
            width: 180,
            child: _primaryButton(
                '打开文件', (c.busy || c.uri == null) ? null : c.openMotionFile),
          ),
        ),
        const SizedBox(height: 8),
        _row('检测到的格式', c.motionFormat ?? c.detectedCamera ?? '---'),
        _row('文件名称', c.motionFileName ?? c.videoName ?? '---'),
        const SizedBox(height: 4),
        // 加载全部元数据 + 帧偏移:仅手动加载外挂运动数据后显示(对齐原生可见条件)。
        if (c.hasExternalMotion) ...[
          GyroCheck(
              label: '加载全部元数据',
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
            label: '方向指示器',
            value: c.orientationIndicator,
            onChanged: c.setOrientationIndicator),
        if (c.orientationIndicator) ...[
          const SizedBox(height: 6),
          OrientationIndicator(quats: c.quats),
        ],
      ];

  // 帧偏移(可负;关=0)→ 引擎 + recompute。
  Widget _frameOffsetRow() => _expandCheck('帧偏移', _frameOffsetOn, (v) {
        setState(() => _frameOffsetOn = v);
        c.setFrameOffset(v ? (int.tryParse(_frameOffset.text.trim()) ?? 0) : 0);
      },
          child: _unitField(_frameOffset, '帧',
              kbd: const TextInputType.numberWithOptions(signed: true),
              formatters: numFormatters(decimal: false, negative: true),
              onSubmitted: (s) => c.setFrameOffset(int.tryParse(s.trim()) ?? 0)));

  // 低通滤波器 + Hz(默认 50)→ params(自带 push+recompute)。
  Widget _lpfRow() => _expandCheck('低通滤波器', c.imuLpfOn, (v) {
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
  Widget _rotationRow() => _expandCheck('旋转', _rotationOn, (v) {
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
  Widget _gyroBiasRow() => _expandCheck('陀螺仪偏差', _biasOn, (v) {
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
      label: '积分方法',
      options: names,
      value: pos,
      onChanged: (p) => c.setIntegration(hasQ ? p : p + 1),
    );
  }

  Widget _imuOrientationRow() => Row(children: [
        const SizedBox(
            width: 104,
            child: Text('IMU 朝向',
                style: TextStyle(color: GfColors.textSecondary, fontSize: 13))),
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

  // ---- recording_settings 行 ----
  List<Widget> _recordingRows(Map<String, String> rs) {
    if (rs.isEmpty) return const [];
    const mapping = <String, String>{
      'Focal length': '焦距',
      'Focus mode': '对焦模式',
      'Iris': '光圈',
      'ISO': 'ISO',
      'Shutter angle': '快门角',
      'Shutter speed': '快门速度',
      'Exposure': '曝光度',
      'White balance mode': '白平衡模式',
      'White balance': '白平衡',
      'Color primaries': '基色',
      'Gamma equation': '伽玛方程',
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
