import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:runcam_gf/runcam_gf.dart'; // ParamsModelAdvanced 扩展(导出组)
import '../edit_controller.dart';
import '../gyro_widgets.dart';
import '../gyroflow_theme.dart';
import '../../l10n/l10n.dart';

/// 「导出设置」面板(对齐官方 Export.qml 红框):编码器 / 输出大小(宽×高+锁定+预设)/
/// 比特率 / 使用GPU编码 / 导出音频 / 高级选项(插值、音频编码、关键帧间隔)。
/// 编码器/比特率/GPU/音频 绑 ParamsModel(只存值);输出尺寸绑 EditController.export*(intent,
/// 不写引擎以免破坏 1080P 预览);高级项为本地状态。导出渲染本身为后续切片。
class ExportPanel extends StatefulWidget {
  const ExportPanel({super.key, required this.controller, this.embedded = false});
  final EditController controller;
  /// 嵌入模式:不自带竖向滚动(返回 Column),供宽屏右栏「参数模块下方」跟随外层一起滚动。
  final bool embedded;
  @override
  State<ExportPanel> createState() => _ExportPanelState();
}

class _ExportPanelState extends State<ExportPanel> {
  int _lastSeq = -1; // 视频换了(尺寸变)时回填宽高框

  final _w = TextEditingController();
  final _h = TextEditingController();
  final _bitrate = TextEditingController();
  final _name = TextEditingController(); // 导出文件名
  final _wf = FocusNode(), _hf = FocusNode(), _bf = FocusNode(), _nf = FocusNode();

  EditController get c => widget.controller;
  ParamsModel get m => widget.controller.params;

  // 编码器:只列两端真能导出的(索引与原生 codecForIndex 一致,exportCodecIndex 直接传原生:
  // 0=H.264 / 1=HEVC)。ProRes 422 已去掉:安卓无硬件 ProRes 编码器(选了也会被静默当 HEVC),
  // 故移除该选项,只留两端通用的 H.264/HEVC。DNxHD/CineForm 是桌面 ffmpeg 专业编码,同样不列。
  static const _codecs = [
    (name: 'H.264/AVC', gpu: true, audio: true, bitrate: true, maxW: 4096, maxH: 4096, ext: '.mp4'),
    (name: 'H.265/HEVC', gpu: true, audio: true, bitrate: true, maxW: 8192, maxH: 8192, ext: '.mp4'),
  ];

  @override
  void initState() {
    super.initState();
    for (final f in [_wf, _hf, _bf]) {
      f.addListener(() {
        if (!f.hasFocus) _commit();
      });
    }
    _nf.addListener(() {
      if (!_nf.hasFocus) c.setExportFileName(_name.text);
    });
  }

  @override
  void dispose() {
    for (final t in [_w, _h, _bitrate, _name]) {
      t.dispose();
    }
    for (final f in [_wf, _hf, _bf, _nf]) {
      f.dispose();
    }
    super.dispose();
  }

  // 视频/编码器换了(尺寸+编码器索引当指纹)→ 回填宽高/比特率/文件名框。
  void _refillIfNeeded() {
    // 指纹含比特率:打开视频后默认比特率按源码率变了,也要回填输入框(否则停留在旧值如 63)。
    final seq = Object.hash(c.exportWidth, c.exportHeight,
        m.exportCodecIndex.clamp(0, _codecs.length - 1), m.exportBitrateMbps);
    if (seq == _lastSeq) return;
    _lastSeq = seq;
    _w.text = '${c.exportWidth}';
    _h.text = '${c.exportHeight}';
    _bitrate.text = '${m.exportBitrateMbps}';
    final ext = _codecs[m.exportCodecIndex.clamp(0, _codecs.length - 1)].ext;
    if (!_nf.hasFocus) _name.text = c.exportFileName(ext); // 返回 override 或默认名
  }

  void _commit() {
    var w = int.tryParse(_w.text.trim()) ?? c.exportWidth;
    var h = int.tryParse(_h.text.trim()) ?? c.exportHeight;
    if (w < 2) w = 2;
    if (h < 2) h = 2;
    if (w.isOdd) w += 1; // 偶数(编码器约束)
    if (h.isOdd) h += 1;
    final codec = _codecs[m.exportCodecIndex.clamp(0, _codecs.length - 1)];
    if (w > codec.maxW) w = codec.maxW;
    if (h > codec.maxH) h = codec.maxH;
    c.setExportSize(w, h);
    final br = int.tryParse(_bitrate.text.trim());
    if (br != null) m.exportBitrateMbps = br;
    _w.text = '$w';
    _h.text = '$h';
    _bitrate.text = '${m.exportBitrateMbps}';
  }

  // 全部固定比例分组(对齐官方 Export.qml outputSizePresets 的键),仅保留 ≥1080P 的尺寸
  // (按需求去掉 720p/480p 等;4:3 官方仅 480p,改为 ≥1080P 的常用 4:3 尺寸)。
  static const List<({String label, int wp, int hp, List<({String label, int w, int h})> fixed})>
      _aspectGroups = [
    (label: '16:9', wp: 16, hp: 9, fixed: [
      (label: '8k', w: 7680, h: 4320), (label: '6k', w: 6016, h: 3384),
      (label: '4k', w: 3840, h: 2160), (label: '1080p', w: 1920, h: 1080),
    ]),
    (label: '17:9', wp: 17, hp: 9, fixed: [
      (label: '4k', w: 4096, h: 2160), (label: '2k', w: 2048, h: 1080),
    ]),
    (label: '9:16', wp: 9, hp: 16, fixed: [
      (label: '8k', w: 4320, h: 7680), (label: '6k', w: 3384, h: 6016),
      (label: '4k', w: 2160, h: 3840), (label: '1080p', w: 1080, h: 1920),
    ]),
    // 4:3 官方无 4K/1080p 标准预设(原仅 480p,<1080P 已去掉)→ 只留 原始/比例/基于最大缩放。
    (label: '4:3', wp: 4, hp: 3, fixed: []),
    (label: '1:1', wp: 1, hp: 1, fixed: [
      (label: '4k', w: 2160, h: 2160), (label: '1080p', w: 1080, h: 1080),
    ]),
  ];

  // 某比例分组下的尺寸列表(对齐官方每个比例 tab):动态项(原始/比例/基于最大缩放,按该
  // 比例内缩计算)+ 该比例的 ≥1080P 固定尺寸。
  List<({String label, int w, int h})> _sizesForAspect(int gi) {
    final g = _aspectGroups[gi];
    final inW = c.videoInfo?.width ?? 16, inH = c.videoInfo?.height ?? 9;
    int even(num v) => (v.round() ~/ 2) * 2;
    final list = <({String label, int w, int h})>[
      (label: context.l10n.expSizeOriginal, w: inW, h: inH), // Original = 输入尺寸
    ];
    final scale = math.min(inW / g.wp, inH / g.hp);
    final pw = even(g.wp * scale), ph = even(g.hp * scale); // Proportional(取整,对齐官方 nw/nh)
    list.add((label: context.l10n.expSizeProportional, w: pw, h: ph));
    // 「基于最大缩放」已去掉:它依赖引擎在「降采样后的预览 output_size」上算出的 min_fov,
    // 与官方(全分辨率)不一致、两端也不一致,会误导用户。去掉,只留 原始/比例/固定尺寸。
    for (final p in g.fixed) {
      list.add((label: p.label, w: p.w, h: p.h));
    }
    return list;
  }

  // 当前视频输出比例对应的分组下标(默认 16:9)。
  int _currentAspectIndex() {
    final outW = c.videoInfo?.outputWidth ?? 16;
    final outH = c.videoInfo?.outputHeight ?? 9;
    final r = outH > 0 ? outW / outH : 16 / 9;
    for (var i = 0; i < _aspectGroups.length; i++) {
      final g = _aspectGroups[i];
      if ((r - g.wp / g.hp).abs() < 0.06) return i;
    }
    return 0;
  }

  // 输出大小选择弹窗:横向比例 tab + 竖向尺寸列表(对齐官方 sizeMenu)。
  Future<void> _showSizeMenu() async {
    int sel = _currentAspectIndex();
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final sizes = _sizesForAspect(sel);
          return AlertDialog(
            backgroundColor: GfColors.bgPanel,
            titlePadding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            title: Text(context.l10n.expOutputSize,
                style: const TextStyle(color: GfColors.text, fontSize: 15)),
            content: SizedBox(
              width: 320,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 横向:比例 tab。
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (var i = 0; i < _aspectGroups.length; i++)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: _aspectTab(_aspectGroups[i].label, i == sel,
                                () => setLocal(() => sel = i)),
                          ),
                      ],
                    ),
                  ),
                  const Divider(height: 16),
                  // 竖向:该比例下尺寸。
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final s in sizes)
                            InkWell(
                              onTap: () {
                                c.setExportSize(s.w, s.h);
                                _w.text = '${s.w}';
                                _h.text = '${s.h}';
                                setState(() {});
                                Navigator.of(ctx).pop();
                              },
                              child: Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(
                                    vertical: 11, horizontal: 8),
                                child: Text('${s.label}   ${s.w} × ${s.h}',
                                    style: const TextStyle(
                                        color: GfColors.text, fontSize: 14)),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _aspectTab(String label, bool active, VoidCallback onTap) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: active ? GfColors.accent : Colors.transparent,
            border: Border.all(
                color: active ? GfColors.accent : GfColors.textSecondary),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(label,
              style: TextStyle(
                  color: active ? Colors.white : GfColors.textSecondary,
                  fontSize: 13)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    _refillIfNeeded();
    final children = _content(context);
    // 嵌入(宽屏右栏 / 参数页末尾,跟随外层 ListView 一起滚)→ Column;否则自带 ListView。
    Widget body = widget.embedded
        ? Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children),
          )
        : Container(
            color: GfColors.bgPanel,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
              children: children,
            ),
          );
    // 没有视频时:内容照常显示(对齐稳定/同步模块),但整体不可操作(拦截点击 + 轻微变暗)。
    if (c.uri == null) {
      body = IgnorePointer(child: Opacity(opacity: 0.5, child: body));
    }
    return body;
  }

  List<Widget> _content(BuildContext context) {
    final codec = _codecs[m.exportCodecIndex.clamp(0, _codecs.length - 1)];
    return [
          Text(context.l10n.expTitle,
              style: const TextStyle(
                  color: GfColors.text,
                  fontSize: 15,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          // 编码器
          GyroDropdown(
            label: context.l10n.expEncoder,
            options: _codecs.map((c) => c.name).toList(),
            value: m.exportCodecIndex.clamp(0, _codecs.length - 1),
            onChanged: (i) => setState(() => m.exportCodecIndex = i),
          ),
          // 输出大小:宽 [锁] 高 + 预设。宽高只读(只能经预设选),锁符号居中替代 ×、始终锁定。
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(children: [
              SizedBox(
                  width: 70,
                  child: Text(context.l10n.expOutputSize,
                      style: const TextStyle(
                          color: GfColors.textSecondary, fontSize: 13))),
              Expanded(child: _numField(_w, _wf, readOnly: true)),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Icon(Icons.link, size: 18, color: GfColors.accent),
              ),
              Expanded(child: _numField(_h, _hf, readOnly: true)),
              // 预设(横向比例 tab + 竖向尺寸,对齐官方 sizeMenu)。
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.tune, size: 18, color: GfColors.textSecondary),
                onPressed: _showSizeMenu,
              ),
            ]),
          ),
          // 比特率(仅 H.264/HEVC)
          if (codec.bitrate)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(children: [
                SizedBox(
                    width: 70,
                    child: Text(context.l10n.expBitrate,
                        style: const TextStyle(
                            color: GfColors.textSecondary, fontSize: 13))),
                Expanded(child: _numField(_bitrate, _bf, decimal: false)),
                const Padding(
                  padding: EdgeInsets.only(left: 6),
                  child: Text('Mbps',
                      style:
                          TextStyle(color: GfColors.textSecondary, fontSize: 12)),
                ),
              ]),
            ),
          // 导出音频(codec 不支持则禁用)
          _check(context.l10n.expAudio, codec.audio && m.exportAudio,
              enabled: codec.audio,
              onChanged: (v) => setState(() => m.exportAudio = v)),
          const Divider(height: 22),
          // 输出路径(目录显示 + 「…」选目录)。有几级显示几级,放不下自动换行。
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: SizedBox(
                  width: 70,
                  child: Text(context.l10n.expOutputPath,
                      style: const TextStyle(
                          color: GfColors.textSecondary, fontSize: 13))),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(c.exportFolderDisplay,
                    softWrap: true, // 多级路径一行放不下则换行
                    style: const TextStyle(
                        color: GfColors.text, fontSize: 13, height: 1.4)),
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.more_horiz,
                  size: 20, color: GfColors.accent),
              onPressed: c.pickExportFolder, // 「…」选择目录
            ),
          ]),
          // 文件名(默认 输入名_stabilized.ext,可编辑)。
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(children: [
              SizedBox(
                  width: 70,
                  child: Text(context.l10n.expFileName,
                      style: const TextStyle(
                          color: GfColors.textSecondary, fontSize: 13))),
              Expanded(
                child: SizedBox(
                  height: 36,
                  child: TextField(
                    controller: _name,
                    focusNode: _nf,
                    style: const TextStyle(color: GfColors.text, fontSize: 13),
                    textInputAction: TextInputAction.done,
                    onSubmitted: c.setExportFileName,
                    decoration: InputDecoration(
                      isDense: true,
                      filled: true,
                      fillColor: GfColors.inputBg,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide.none),
                    ),
                  ),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 10),
          // 导出按钮(对齐官方 Render):无同步点确认 → 选目录授权 → 前台提示 → 导出。
          GyroBigButton(
            label: c.exportRunning ? context.l10n.expCancelExport : context.l10n.expExport,
            onPressed: (c.busy || c.uri == null)
                ? null
                : (c.exportRunning ? () => c.cancelExport() : _onExportTap),
          ),
    ];
  }

  static bool _foregroundHintShown = false; // 前台提示「不再显示」(会话内)

  // 导出点击编排(对齐旧原生 exportStabilizedVideo → proceedExport → beginExport)。
  Future<void> _onExportTap() async {
    final l10n = context.l10n;
    final ext = _codecs[m.exportCodecIndex.clamp(0, _codecs.length - 1)].ext;
    // 1) 无精确时间戳且无同步点 → 结果不准,先确认。
    if (!c.hasAccurateTimestamps && c.syncPointCount == 0) {
      final go = await _confirm(l10n.expNoSyncTitle,
          l10n.expNoSyncBody,
          okText: l10n.expYes, cancelText: l10n.expNo);
      if (go != true) return;
    }
    // 2) 未选输出目录 → 提示后选目录(对齐原生「先授权再导出」)。
    if (!c.exportFolderChosen) {
      final go = await _confirm(l10n.expSelectFolderTitle,
          l10n.expSelectFolderBody);
      if (go != true) return;
      await c.pickExportFolder();
      if (!c.exportFolderChosen) return; // 用户取消了选目录
    }
    // 3) 前台运行提示(对齐原生,移动端专属;勾「不再显示」会话内不再弹)。
    if (!_foregroundHintShown && mounted) await _foregroundHint();
    // 4) 开始导出(进度经蒙版显示,完成/失败由返回值收尾)。
    final err = await c.startExport(ext);
    if (!mounted) return;
    if (err.isEmpty) {
      // 导出成功提示(对齐原生 Modal.Success「渲染完成。文件已写入: …」,仅「确定」)。
      await _confirm(context.l10n.expRenderDoneTitle,
          context.l10n.expRenderDoneBody(
              '${c.exportFolderDisplay}/${c.exportFileName(ext)}'),
          okText: context.l10n.expOk);
    } else if (err != '已取消' && err != '忙') {
      await _confirm(context.l10n.expFailedTitle, err, okText: context.l10n.expOk);
    }
  }

  Future<bool?> _confirm(String title, String msg,
      {String? okText, String? cancelText}) {
    final okLabel = okText ?? context.l10n.expOk;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: GfColors.bgPanel,
        title: Text(title,
            style: const TextStyle(color: GfColors.text, fontSize: 15)),
        content: Text(msg,
            style: const TextStyle(color: GfColors.textSecondary, fontSize: 13)),
        actions: [
          if (cancelText != null)
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(cancelText,
                    style: const TextStyle(color: GfColors.textSecondary))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(okLabel,
                  style: const TextStyle(color: GfColors.accent))),
        ],
      ),
    );
  }

  Future<void> _foregroundHint() {
    final l10n = context.l10n;
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: GfColors.bgPanel,
        title: Text(l10n.expForegroundTitle,
            style: const TextStyle(color: GfColors.text, fontSize: 15)),
        content: Text(
            l10n.expForegroundBody,
            style: const TextStyle(color: GfColors.textSecondary, fontSize: 13)),
        actions: [
          TextButton(
              onPressed: () {
                _foregroundHintShown = true;
                Navigator.pop(ctx);
              },
              child: Text(l10n.expDontShowAgain,
                  style: const TextStyle(color: GfColors.textSecondary))),
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.expOk,
                  style: const TextStyle(color: GfColors.accent))),
        ],
      ),
    );
  }

  Widget _numField(TextEditingController ctrl, FocusNode focus,
          {bool decimal = false,
          ValueChanged<String>? onChanged,
          bool readOnly = false}) =>
      SizedBox(
        height: 36,
        child: TextField(
          controller: ctrl,
          focusNode: focus,
          readOnly: readOnly, // 只读:输出大小只能经预设选,不可手输
          keyboardType:
              TextInputType.numberWithOptions(decimal: decimal),
          inputFormatters: numFormatters(decimal: decimal, negative: false),
          textAlign: TextAlign.center,
          textInputAction: TextInputAction.done,
          style: const TextStyle(color: GfColors.text, fontSize: 13),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: GfColors.inputBg,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide.none),
          ),
          onChanged: onChanged,
          onSubmitted: (_) => focus.unfocus(),
          onTapOutside: (_) => focus.unfocus(),
        ),
      );

  // 复选行(GyroCheck 同款,可禁用)。
  Widget _check(String label, bool value,
          {required bool enabled, required ValueChanged<bool> onChanged}) =>
      Opacity(
        opacity: enabled ? 1 : 0.4,
        child: GyroCheck(
          label: label,
          value: value,
          onChanged: enabled ? onChanged : (_) {},
        ),
      );
}
