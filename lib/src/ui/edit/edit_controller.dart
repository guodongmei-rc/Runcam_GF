import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:runcam_gf/src/state/params_model.dart';
import 'package:runcam_gf/src/state/engine_bridge.dart';
import 'package:runcam_gf/src/state/engine_bridge_impl.dart';
import 'package:runcam_gf/src/bridge/engine_api.g.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../l10n/l10n.dart';
import 'preview_backend.dart';

/// 编辑页控制器:持引擎生命周期 + ParamsModel + 当前预览后端。
/// 面板只通过 [params] 调参;预览只读 [backend]/[textureId]/[uri]。
class EditController extends ChangeNotifier {
  EditController() {
    params = ParamsModel(_bridge);
    // 暂停态:任一参数 recompute 后主动刷新一帧(ParamsModel 改完会 notify)。
    params.addListener(_onParamsChanged);
    // autosync 进度/结束事件(原生→Dart,经 EngineBridgeImpl 转流)。
    _autosyncProgSub = _bridge.autosyncProgress.listen(_onAutosyncProgress);
    _autosyncDoneSub = _bridge.autosyncFinished.listen(_onAutosyncFinished);
    // 导出进度事件(导出渲染接入后由原生回报,驱动导出蒙版)。
    _exportProgSub = _bridge.exportProgress.listen(_onExportProgress);
    // 恢复上次选定的导出目录(跨重启保留;iOS 书签/安卓 SAF 权限本就持久,卸载重装才清)。
    _loadPersistedExportFolder();
  }

  static const _kExportFolderPref = 'gf_export_folder';

  Future<void> _loadPersistedExportFolder() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final f = prefs.getString(_kExportFolderPref);
      if (f != null && f.isNotEmpty) {
        exportFolder = f;
        notifyListeners();
      }
    } catch (_) {/* 读取失败:维持未选状态 */}
  }

  Future<void> _persistExportFolder(String f) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kExportFolderPref, f);
    } catch (_) {/* 持久化失败忽略 */}
  }

  // 自动同步状态(供 UI 显示进度;真正偏移由 FFI autosync_finish 逐点写入)。
  bool hasLensProfile = false; // _fetchLensInfo 回填(getLensInfoFull has_lens)
  bool lensDoAutosync = false; // 镜头 sync_settings.do_autosync(触发门槛,非同步参数)
  // 同步参数统一存 ParamsModel 同步组(面板读写 / autosync 读 / 镜头 sync_settings 覆盖)。
  bool autosyncRunning = false;
  double autosyncProgressValue = 0.0; // 0..1
  int autosyncReady = 0, autosyncTotal = 0; // 已处理/总帧(蒙版显示)
  final Stopwatch _autosyncClock = Stopwatch(); // 耗时/剩余估算
  // autosync 算出的同步点:交错 [mid_ms, off_ms, ...],回显到陀螺波形竖线。
  List<double> autosyncSyncPoints = const [];
  StreamSubscription<(double, int, int)>? _autosyncProgSub;
  StreamSubscription<(double, List<double>, bool)>? _autosyncDoneSub;

  // 导出状态(驱动导出蒙版,对齐原生导出进度遮罩)。
  bool exportRunning = false;
  double exportProgressValue = 0.0; // 0..1
  int exportFrame = 0, exportTotal = 0; // 已导出/总帧
  final Stopwatch _exportClock = Stopwatch(); // 耗时/剩余估算
  StreamSubscription<(double, int, int)>? _exportProgSub;

  void _onParamsChanged() {
    if (!playing) {
      _refreshPreview();
      _fetchPreviewStateOnce(); // 暂停态参数 recompute 后刷新 HUD 缩放%/指示器
    }
  }

  /// 暂停态按需重渲预览一帧(播放时渲染循环已连续刷新,无需调用)。
  void _refreshPreview() {
    if (uri == null || playing) return;
    if (backend == PreviewBackend.texture) {
      _previewApi.renderOnce().catchError((Object _) {});
    } else {
      _pvChannel?.invokeMethod('renderOnce');
    }
  }

  static const MethodChannel _picker = MethodChannel('runcam_gf_example/picker');
  final EngineBridge _bridge = EngineBridgeImpl();
  final PreviewApi _previewApi = PreviewApi();
  late final ParamsModel params;

  String? uri;
  VideoInfo? videoInfo; // openVideo 回的视频元数据(原始输出尺寸,供导出选项)
  Map<String, String> recordingSettings = {}; // 录制参数(ISO/快门/光圈…),供「输入」面板

  // 导出输出尺寸(intent):独立于引擎 output_size(引擎恒 1080P 给预览);导出实装时
  // 在导出前 setOutputSizeExact(exportWidth,exportHeight)→渲染→切回 1080P 预览。默认=源输出尺寸。
  int exportWidth = 1920;
  int exportHeight = 1080;

  // 当前预览(引擎 output_size)实际尺寸:预览恒 ≤1080P,但比例/取景跟随所选输出大小。
  int? _previewW, _previewH;

  /// 把目标输出尺寸按比例降到 ≤1080P 高,作为预览用 output_size(保性能、画面比例一致)。
  (int, int) _previewSizeFor(int w, int h) {
    if (h > 1080 && w > 0) {
      var pw = (w * 1080 / h).round();
      if (pw.isOdd) pw += 1; // 偶数宽(编码器/纹理约束)
      return (pw, 1080);
    }
    return (w, h);
  }

  /// 选择导出输出大小。预览随之变化(对齐官方):把所选尺寸降到 ≤1080P 设引擎 output_size,
  /// 重算并重启预览后端重建纹理(FFI 要求输出纹理 == output_size)。同预览尺寸(如同比例
  /// 不同分辨率)则仅存 intent、不重解码(预览画面本就一致)。
  Future<void> setExportSize(int w, int h) async {
    if (w == exportWidth && h == exportHeight) return;
    exportWidth = w;
    exportHeight = h;
    if (uri == null || busy || w <= 0 || h <= 0) {
      notifyListeners();
      return;
    }
    final (pw, ph) = _previewSizeFor(w, h);
    if (pw == _previewW && ph == _previewH) {
      notifyListeners(); // 预览尺寸不变 → 画面一致,无需重解码
      return;
    }
    _setBusy(true);
    try {
      await _stopBackend();
      await _bridge.setOutputSizeExact(pw, ph);
      await _bridge.recomputeBlocking();
      _previewW = pw;
      _previewH = ph;
      aspect = ph > 0 ? pw / ph : aspect;
      playing = false; // 重启后停在首帧,等手动播放
      await _startBackend();
      _playheadUs = 0;
      _maybeRunPreviewClock();
      await _fetchPreviewStateOnce();
      status = L.current.ctlOutputSizeSet('$w', '$h', '$pw', '$ph');
    } catch (e) {
      status = L.current.ctlApplyOutputSizeFailed('$e');
    } finally {
      _setBusy(false);
    }
  }
  // 导出输出位置(intent):folder=用户选的输出目录(null=与源视频同目录,对齐官方默认);
  // fileNameOverride=用户改过的文件名(null=自动生成 输入名_stabilized.ext)。
  String? exportFolder;
  String? exportFileNameOverride;

  /// 源视频文件名(不含扩展名),用于生成默认导出名。
  String get _sourceBaseName {
    final n = videoName ?? 'output';
    final dot = n.lastIndexOf('.');
    return dot > 0 ? n.substring(0, dot) : n;
  }

  /// 默认导出文件名:输入名 + "_stabilized" + 扩展名(对齐官方 filename_with_suffix)。
  String defaultExportFileName(String ext) => '${_sourceBaseName}_stabilized$ext';

  /// 当前导出文件名(用户改过用其值,否则按默认生成)。ext 形如 ".mp4"。
  String exportFileName(String ext) =>
      (exportFileNameOverride != null && exportFileNameOverride!.isNotEmpty)
          ? exportFileNameOverride!
          : defaultExportFileName(ext);

  /// 输出目录显示文本(对齐官方移动端:不显示全路径,只显示卷标后的相对短名;
  /// 未选则提示需先选目录)。
  String get exportFolderDisplay =>
      exportFolder == null ? L.current.ctlSelectExportFolder : _shortFolder(exportFolder!);

  // 把目录 uri/路径压成「卷标/容器前缀之后的相对多级路径」(对齐官方 display_url:保留多层级
  // 文件夹名,但不显示根目录那一堆)。Android content uri 取卷标冒号后整段;iOS file:// 去掉
  // 已知容器前缀(File Provider Storage / iCloud / Data/Application/<uuid> …)后整段。
  String _shortFolder(String f) {
    String trim(String s) => s.replaceAll(RegExp(r'^/+|/+$'), '');
    try {
      // Android:content tree/document uri → 卷标冒号后的相对多级路径(如 DCIM/Camera)。
      for (final marker in ['/document/', '/tree/']) {
        final i = f.indexOf(marker);
        if (i >= 0) {
          var s = Uri.decodeComponent(f.substring(i + marker.length));
          final colon = s.indexOf(':');
          if (colon >= 0) s = s.substring(colon + 1);
          s = trim(s);
          return s.isEmpty ? L.current.ctlRootDir : s; // 卷标后无子路径 = 选了根目录
        }
      }
      // iOS/其它:去 file:// 前缀,按已知容器标记截取后整段(对齐官方)。
      var s = Uri.decodeFull(f).replaceFirst(RegExp(r'^file://'), '');
      const fps = '/File Provider Storage/';
      const icloud = '/com~apple~CloudDocs/';
      int idx;
      if ((idx = s.indexOf(icloud)) >= 0) {
        return 'iCloud/${trim(s.substring(idx + icloud.length))}';
      } else if ((idx = s.indexOf(fps)) >= 0) {
        s = s.substring(idx + fps.length);
      } else {
        // Data/Application/<uuid>/… 或 userfsd/<vol>/… → 丢掉容器前缀和其后第一段(uuid/卷)。
        for (final m in ['/Data/Application/', '/com.apple.filesystems.userfsd/']) {
          final j = s.indexOf(m);
          if (j >= 0) {
            final parts = trim(s.substring(j + m.length)).split('/');
            s = parts.length > 1 ? parts.sublist(1).join('/') : parts.join('/');
            break;
          }
        }
      }
      s = trim(s);
      if (s.isEmpty) return L.current.ctlRootDir; // 容器前缀后无子路径 = 根目录
      return s; // 剥掉容器/卷标前缀后,有几级显示几级(由 UI 换行展示)
    } catch (_) {
      return L.current.ctlRootDir;
    }
  }

  void setExportFileName(String name) {
    final t = name.trim();
    exportFileNameOverride = t.isEmpty ? null : t;
    notifyListeners();
  }

  /// 选择导出目录(原生 pickFolder:返回目录 uri/路径)。
  Future<void> pickExportFolder() async {
    try {
      final f = await _picker.invokeMethod<String>('pickFolder');
      if (f != null && f.isNotEmpty) {
        exportFolder = f;
        _persistExportFolder(f); // 记住选择,跨重启保留
        notifyListeners();
      }
    } catch (e) {
      status = L.current.ctlSelectFolderFailed('$e');
      notifyListeners();
    }
  }

  // 有精确时间戳(Hero8+/Insta360 等内嵌四元数):无同步点也能正确导出(对齐原生)。
  bool hasAccurateTimestamps = false;

  /// 同步点个数(autosyncSyncPoints 交错 [mid,off,...])。
  int get syncPointCount => autosyncSyncPoints.length ~/ 2;

  /// 已选导出目录(对齐原生「导出前必须先授权目标文件夹」)。
  bool get exportFolderChosen => exportFolder != null;

  /// 开始导出:复用共享 stabilizer 逐帧编码(原生 PreviewApi.startExport),进度经
  /// [onExportProgress] 驱动蒙版。返回 ''=成功,否则错误信息('已取消' 为用户中止)。
  Future<String> startExport(String ext) async {
    if (uri == null || exportRunning) return '忙';
    final name = exportFileName(ext);
    exportRunning = true;
    exportProgressValue = 0.0;
    exportFrame = 0;
    exportTotal = trimmedFrames; // 裁剪后帧数(全片时 == totalFrames)
    _exportClock
      ..reset()
      ..start();
    status = L.current.ctlInitializingExport;
    notifyListeners();
    // 导出前:① 禁止参数防抖 recompute 并跑完任何挂起/在飞的 recompute —— 否则改过参数后
    // 那个 200ms 防抖定时器会在导出 await 期间触发,与导出线程并发进引擎而崩溃(改参数后
    // 导出崩的根因)。② 暂停预览(停 Dart 时钟 + 原生渲染循环),但不销毁纹理 → 画面定格不转圈。
    params.exportInProgress = true;
    await params.flushPendingRecompute();
    playing = false;
    _maybeRunPreviewClock();
    try {
      if (backend == PreviewBackend.texture) {
        await _previewApi.pause();
      } else {
        await _pvChannel?.invokeMethod('pause');
      }
    } catch (_) {/* 暂停失败忽略 */}
    try {
      final err = await _previewApi.startExport(ExportRequest(
        srcUri: uri,
        outputUri: exportFolder ?? '',
        fileName: name,
        codecIndex: params.exportCodecIndex,
        bitrateMbps: params.exportBitrateMbps,
        exportAudio: params.exportAudio,
        width: exportWidth,
        height: exportHeight,
        // 开关关闭 → 传 0/0 表示导出整片;开启 → 传选区区间。
        trimStartUs: trimEnabled ? trimStartUs : 0,
        trimEndUs: trimEnabled ? trimEndUs : 0,
      ));
      exportRunning = false;
      _exportClock.stop();
      status = err.isEmpty
          ? L.current.ctlExportComplete('$exportFolderDisplay/$name')
          : (err == '已取消'
              ? L.current.ctlExportCancelled
              : L.current.ctlExportFailed(err));
      params.exportInProgress = false; // 恢复参数防抖 recompute(须在 _restore 重算前)
      // 导出把引擎 output_size 改成全分辨率了,恢复预览尺寸并重渲一帧(纹理仍在,不转圈)。
      await _restorePreviewAfterExport();
      notifyListeners();
      return err;
    } catch (e) {
      exportRunning = false;
      _exportClock.stop();
      status = L.current.ctlExportFailed('$e');
      params.exportInProgress = false;
      await _restorePreviewAfterExport();
      notifyListeners();
      return '$e';
    }
  }

  /// 取消导出(置原生标志,导出循环下一帧自停)。
  Future<void> cancelExport() async {
    if (!exportRunning) return;
    status = L.current.ctlCancellingExport;
    notifyListeners();
    try {
      await _previewApi.cancelExport();
    } catch (_) {/* 取消失败忽略,导出循环结束会收尾 */}
  }

  // 导出后把引擎 output_size 从全分辨率恢复回预览尺寸,并重渲当前帧(纹理未销毁,不重建后端)。
  Future<void> _restorePreviewAfterExport() async {
    if (uri == null) return;
    final pw = _previewW, ph = _previewH;
    if (pw == null || ph == null) return;
    try {
      await _bridge.setOutputSizeExact(pw, ph); // 导出改成了全分辨率,恢复预览尺寸
      await _bridge.recomputeBlocking();
      playing = false; // 导出后保持暂停,等用户手动播放
      // 导出会释放预览解码器(pauseForExport),收尾时 resumeAfterExport 重建的是**全新**解码器,
      // 默认只渲第一帧(t=0)→ 画面跳回开头,但 UI 进度条(_playheadUs)还停在原位 → 对不上。
      // 故 seek 回 _playheadUs,让重建后的解码器渲染用户原来所在的帧,画面与进度条一致。
      // 并夹到有效区间 [_playStartUs, _playEndUs](与 seekToProgress 一致):有裁剪框时进度条
      // 只在选区内,导出后恢复也保持同样约束,不让播放头落到选区外。
      final lo = _playStartUs, hi = _playEndUs;
      if (hi > 0) _playheadUs = _playheadUs.clamp(lo, hi);
      await _seekBackend(_playheadUs);
      _refreshPreview(); // 暂停态重渲当前帧(纹理仍在,无转圈)
      await _fetchPreviewStateOnce();
    } catch (_) {/* 恢复失败:预览可能需重开视频 */}
  }

  void _onExportProgress((double, int, int) e) {
    if (!exportRunning) return;
    exportProgressValue = e.$1;
    exportFrame = e.$2;
    if (e.$3 > 0) exportTotal = e.$3;
    notifyListeners(); // 完成/失败由 startExport 的返回值收尾
  }

  /// 导出蒙版用:速率(fps)/耗时/剩余(同 autosync 估算)。
  double get exportFps {
    final s = _exportClock.elapsedMilliseconds / 1000.0;
    return s > 0 ? exportFrame / s : 0.0;
  }

  int get exportElapsedSec => _exportClock.elapsed.inSeconds;

  int get exportRemainingSec {
    final fps = exportFps;
    if (fps <= 0 || exportTotal <= 0) return 0;
    final remain = exportTotal - exportFrame;
    return remain > 0 ? (remain / fps).round() : 0;
  }

  PreviewBackend backend = PreviewBackend.texture;
  bool playing = false;
  bool busy = false;
  bool stabEnabled = true; // 防抖开关(打开视频时置 true)
  bool fovOverview = false; // 稳定概览(显示完整稳定画面 = fov+1.0)
  String status = L.current.ctlStatusInitial;

  /// 当前背景模式索引(0..3),供预览控制按钮选图标。
  int get backgroundMode => params.backgroundMode;

  /// 背景模式名(对齐 setBackgroundMode 0..3)。
  String get backgroundModeName => [
        L.current.ctlBgSolid,
        L.current.ctlBgRepeatEdge,
        L.current.ctlBgMirrorEdge,
        L.current.ctlBgFeather,
      ][params.backgroundMode.clamp(0, 3)];

  /// 防抖开关。注意:核心 process_frame **不消费** stab_enabled 标志(只在桌面 glue 层用),
  /// 所以单调 setStabEnabled 对预览无效。这里用「平滑方式」切换实现预览防抖开关:
  ///   关 → 无平滑(0):跟随原始抖动、自适应缩放几乎不裁 → 画面≈未防抖;
  ///   开 → 还原用户选的平滑方式。
  Future<void> toggleStab() async {
    stabEnabled = !stabEnabled;
    await _bridge.setStabEnabled(stabEnabled); // 引擎标志(导出/未来用),无害
    await _bridge.setSmoothingMethod(stabEnabled ? params.smoothingMethod : 0);
    await _bridge.recomputeBlocking();
    _refreshPreview();
    await _fetchPreviewStateOnce();
    notifyListeners();
  }

  /// 切换稳定概览:fov_overview 等价于 fov 加 1.0(对齐 core lib.rs:774);
  /// 用现有 setFov 实现,不改 params.fov(关闭即还原)。
  Future<void> toggleFovOverview() async {
    fovOverview = !fovOverview;
    await _bridge.setFov(fovOverview ? params.fov + 1.0 : params.fov);
    await _bridge.recomputeBlocking();
    _refreshPreview();
    await _fetchPreviewStateOnce();
    notifyListeners();
  }

  /// 循环背景模式 纯色→边缘拉伸→边缘镜像→纯色(去掉「羽化留边」,按需求只在前三种间切换)。
  /// params setter 自带 push FFI + recompute + 刷新。
  void cycleBackgroundMode() {
    params.backgroundMode = (params.backgroundMode + 1) % 3;
  }

  // 镜头配置(「输入」面板)。
  // 镜头搜索结果(提到控制器:供输入面板显示 + 「点屏幕任意处」收起列表)。
  List<Map<String, String>> lensResults = const [];
  void setLensResults(List<Map<String, String>> r) {
    lensResults = r;
    notifyListeners();
  }

  void clearLensResults() {
    if (lensResults.isEmpty) return;
    lensResults = const [];
    notifyListeners();
  }

  String? detectedCamera; // 「检测到的相机」
  String? detectedLens; // 「检测镜头」
  String lensName = L.current.ctlNoLensProfile;
  Map<String, String> lensInfo = {}; // 相机/镜头/设置/其他信息/尺寸/校准人
  // 高级镜头档案(可编辑,数据来自 getLensInfoFull,对齐原生「高级」段)。
  double? lensFx, lensFy, lensCx, lensCy; // 像素焦距 fx/fy、聚焦中心 cx/cy
  List<double?> lensDistortion = const []; // 畸变系数 k1..k4
  int? lensCalibW, lensCalibH; // 镜头标定分辨率(判定是否与视频匹配)

  /// 已加载镜头档案的标定分辨率与当前视频分辨率不一致(对齐桌面 Gyroflow:加载了与视频
  /// 分辨率不符的镜头档案时,提示"结果看起来可能会不正确")。自动匹配按视频分辨率选档案,
  /// 故此提示只在加载了"错档案"(如给 GoPro 视频加载 RunCam 档案)时出现。
  bool get lensDimsMismatch {
    final vw = videoInfo?.width, vh = videoInfo?.height;
    final lw = lensCalibW, lh = lensCalibH;
    return hasLensProfile &&
        vw != null &&
        vh != null &&
        lw != null &&
        lh != null &&
        (lw != vw || lh != vh);
  }

  /// 镜头标定「宽高比」与视频宽高比不一致 —— 比单纯尺寸不符更严重(结果会不正确)。
  /// 对齐官方 LensProfile.qml:宽高比不符 → 红色 Error;仅尺寸不同(同比例)→ 橙色 Warning。
  bool get lensAspectMismatch {
    final vw = videoInfo?.width, vh = videoInfo?.height;
    final lw = lensCalibW, lh = lensCalibH;
    if (vw == null || vh == null || lw == null || lh == null || vh == 0 || lh == 0) {
      return false;
    }
    return (lw / lh).toStringAsFixed(3) != (vw / vh).toStringAsFixed(3);
  }
  bool underwaterLens = false; // 水下镜头(暂不接引擎,纯本地偏好)
  int lensLoadSeq = 0; // 每次加载镜头自增;面板据此回填输入框(不覆盖用户编辑)

  // 运动数据(外挂陀螺 sidecar)。
  String? motionFormat; // 检测到的格式(外挂时)
  String? motionFileName; // 文件名称(外挂时)
  bool loadAllMetadata = false; // 加载全部元数据(对齐 MotionData.qml)
  String? _motionFilePath; // 当前外挂文件,切换 loadAllMetadata 时重载用

  /// 是否已手动加载外挂运动数据。原生仅此场景才显示「加载全部元数据/帧偏移」
  /// (ViewController.mm setExternalMotionControlsVisible:YES,换视频复位)。
  bool get hasExternalMotion => _motionFilePath != null;

  // 运动数据设置(「输入」面板)。
  String imuOrientation = 'XYZ';
  int integrationMethod = 1; // FFI 索引:0=None 1=Comp 2=VQF 3=Simple… 6=Madgwick
  bool hasQuaternions = false; // 视频含精确四元数→积分方法列表含 None(对齐原生)

  // 运动数据高级项(接引擎,两端均生效;回显自 getGyroInfo)。
  int imuMedian = 0; // 中值滤波采样数(0=关)
  List<double> imuRotation = const [0, 0, 0]; // pitch/roll/yaw
  List<double> imuBias = const [0, 0, 0]; // x/y/z
  int gyroInfoSeq = 0; // 每次回显自增;面板据此刷输入框(不覆盖编辑中)
  bool orientationIndicator = false; // 方向指示器开关
  bool get imuLpfOn => params.imuLpfHz > 0;

  // 陀螺波形:交错采样 [x,y,z(,w)],供预览下方时间线绘制(对齐原生 GyroTimelineView)。
  List<double> gyroSamples = const [];
  int gyroAxes = 3; // 3=原始角速度 xyz;4=四元数 xyzw(无原始角速度时退回)

  // 方向指示器姿态:double[8](原始 wxyz + 平滑 wxyz),由预览时钟驱动逐帧查询。
  List<double> quats = const [];
  Timer? _orientTimer;
  final Stopwatch _orientClock = Stopwatch();
  int _playheadUs = 0; // Dart 端播放头(与解码位置近似;驱动 HUD + 方向指示器)
  int _lastElapsedUs = 0;
  bool _orientBusy = false;

  // 预览 HUD(对齐桌面 Gyroflow 时间轴上方那块):当前播放头处的 fov → 缩放%。
  double currentFov = 0.0; // 0=未知;HUD 用 zoomPercent 读
  /// HUD 缩放%(= 100/fov,对齐桌面「Zoom: xx%」)。当前帧 fov 未知时回退全局 minFov。
  double get zoomPercent {
    final f = currentFov > 0 ? currentFov : params.minFov;
    return f > 0 ? 100.0 / f : 0.0;
  }

  int get playheadUs => _playheadUs; // HUD 时间显示用
  /// 当前帧序号(从 0 起;按 fps 估算)。
  int get currentFrameIndex {
    final fps = videoInfo?.fps ?? 0;
    return fps > 0 ? (_playheadUs * fps / 1e6).floor() : 0;
  }

  int get totalFrames => videoInfo?.frameCount ?? 0;

  // ── 裁剪区间(单按钮开关:开启时导出仅渲染 [trimStartUs, trimEndUs],关闭时导出整片)──
  // 基准时长(µs):与时间线/播放头一致(progress 0..1 映射到 [0, durationUs])。
  int get _durationUs => ((videoInfo?.durationS ?? 0) * 1e6).round();
  bool trimEnabled = false; // 是否启用裁剪(关=导出整片)
  int trimStartUs = 0;
  int? _trimEndUs; // null = 到结尾(= _durationUs);打开新视频时复位
  int get trimEndUs => _trimEndUs ?? _durationUs;
  static const int _minTrimGapUs = 100000; // 最小区间 0.1s

  /// 裁剪起点/终点的归一化位置(0..1),供时间线绘制选区与手柄。
  double get trimStartFrac =>
      _durationUs > 0 ? (trimStartUs / _durationUs).clamp(0.0, 1.0) : 0.0;
  double get trimEndFrac =>
      _durationUs > 0 ? (trimEndUs / _durationUs).clamp(0.0, 1.0) : 1.0;

  /// 是否按裁剪区间导出(= 开关开)。关闭时导出整片。
  bool get isTrimmed => trimEnabled;

  /// 裁剪后的帧数(导出蒙版进度用;真实总帧由原生回报覆盖)。关闭时 = 整片帧数。
  int get trimmedFrames {
    if (!trimEnabled) return totalFrames;
    final fps = videoInfo?.fps ?? 0;
    if (fps <= 0) return totalFrames;
    return ((trimEndUs - trimStartUs).clamp(0, _durationUs) / 1e6 * fps).round();
  }

  /// 预览/seek 的有效播放区间:裁剪开 → [trimStart, trimEnd];关 → [0, 末帧]。
  int get _playStartUs => trimEnabled ? trimStartUs : 0;
  int get _playEndUs => trimEnabled ? trimEndUs : _endUs;

  /// 切换裁剪开关:开启时选区默认取「居中、占总长 1/3」,并把预览跳到选区起点
  /// (只看选中片段);关闭时清空选区(导出整片)。
  Future<void> toggleTrim() async {
    trimEnabled = !trimEnabled;
    if (trimEnabled) {
      final dur = _durationUs;
      if (dur > 0) {
        trimStartUs = (dur / 3).round(); // 居中的 1/3:[1/3, 2/3]
        _trimEndUs = (dur * 2 / 3).round();
      }
      // 进入裁剪:播放头落到选区起点并 seek 预览(预览只放选中片段)。
      _playheadUs = trimStartUs;
      _lastElapsedUs = _orientClock.elapsedMicroseconds;
      await _seekBackend(_playheadUs);
      if (!playing) _refreshPreview();
      await _fetchPreviewStateOnce();
    } else {
      trimStartUs = 0;
      _trimEndUs = null;
    }
    notifyListeners();
  }

  void setTrimStartUs(int us) {
    final dur = _durationUs;
    if (dur <= 0) return;
    final maxStart = (trimEndUs - _minTrimGapUs).clamp(0, dur);
    trimStartUs = us.clamp(0, maxStart);
    notifyListeners();
  }

  void setTrimEndUs(int us) {
    final dur = _durationUs;
    if (dur <= 0) return;
    final minEnd = (trimStartUs + _minTrimGapUs).clamp(0, dur);
    _trimEndUs = us.clamp(minEnd, dur);
    notifyListeners();
  }

  /// 真正最后一帧的时间戳(µs):按帧数/帧率算 = (帧数-1)/fps。比整段 durationS 更准
  /// (durationS 含最后一帧的显示时长,落在末帧之后),用于末尾判定/重播判定,避免停在
  /// 中途帧或 HUD 帧号越界。取不到 fps/帧数时退回 durationS。
  int get _endUs {
    final fps = videoInfo?.fps ?? 0;
    final total = videoInfo?.frameCount ?? 0;
    if (fps > 0 && total > 0) return (((total - 1) / fps) * 1e6).round();
    return ((videoInfo?.durationS ?? 0) * 1e6).round();
  }

  // Texture 后端
  int? textureId;
  double aspect = 16 / 9;
  // PlatformView 后端
  MethodChannel? _pvChannel;

  /// 选视频 → 引擎初始化(一次)→ 起当前后端。
  /// 暂停当前预览(原生播放器 + Dart 预览时钟)。供「打开文件」点击时先停住正在播放的视频。
  /// 两端统一走 PreviewApi.pause / PlatformView 'pause',iOS、安卓行为一致。
  Future<void> _pausePreview() async {
    if (!playing) return;
    playing = false;
    try {
      if (backend == PreviewBackend.texture) {
        await _previewApi.pause();
      } else {
        await _pvChannel?.invokeMethod('pause');
      }
    } catch (_) {/* 暂停失败忽略 */}
    _maybeRunPreviewClock();
    notifyListeners();
  }

  Future<void> openAndStart() async {
    // 点「打开文件」立即暂停当前播放:选片器打开期间旧视频不再后台播放(iOS/安卓一致);
    // 用户取消选择时也保持暂停。
    await _pausePreview();
    final picked = await _picker.invokeMethod<String>('pickVideo');
    if (picked == null) return;
    _setBusy(true);
    // 重新打开视频前:先彻底拆掉上一个预览后端(停旧解码线程 + 释放 wgpu surface)。
    // 否则旧解码线程仍在调 nativeProcessFrame,而下面 createStabilizer/openVideo/recompute
    // 又在改同一「单例」引擎 → 两边并发动引擎 → wgpu 致命错误 + surface 销毁 SIGABRT
    // (先开 GoPro 10 再开 GoPro 6 必崩的根因:旧 decoder 喂帧与新视频初始化打架)。
    playing = false;
    _maybeRunPreviewClock(); // 停 Dart 预览时钟(取消方向/HUD 定时器)
    try {
      await _stopBackend(); // dispose 旧 PreviewController:decoder.stop() + surfaceDestroyed
    } catch (_) {/* 无旧后端/拆除失败:忽略,继续打开新视频 */}
    // 新视频:外挂运动数据状态复位(对齐原生 setExternalMotionControlsVisible:NO)。
    _motionFilePath = null;
    motionFormat = null;
    motionFileName = null;
    loadAllMetadata = false;
    stabEnabled = true; // 新视频:防抖默认开
    fovOverview = false; // 关闭稳定概览
    _gyroDataDetected = false; // 新视频:重置陀螺检测锁存(下方默认 recompute 后重判)
    exportFileNameOverride = null; // 新视频:导出名回到默认(输入名_stabilized);目录保留(对齐官方)
    autosyncSyncPoints = const []; // 新视频:清旧同步点
    trimEnabled = false; // 新视频:裁剪开关复位(导出整片)
    trimStartUs = 0;
    _trimEndUs = null;
    // 不复位 _folderAuthorized:授权过一次后整个会话不再显示蓝框(对齐用户预期)。
    try {
      await _bridge.createStabilizer();
      final info = await _bridge.openVideo(picked);
      videoInfo = info; // 提前置好,供 _fetchGyroInfo 按视频时长选积分方法
      // 默认导出比特率 = 源视频码率 / 1024 / 1024(对齐官方 VideoInformation.qml:76);
      // 取不到则保留模型默认。新视频每次按源码率重置。
      final srcBitrate = info.videoBitrate ?? 0;
      if (srcBitrate > 0) {
        params.exportBitrateMbps = (srcBitrate / 1024 / 1024).round();
      }
      await _bridge.setStabEnabled(true);
      // 镜头库自动匹配(对齐 ViewController.mm:1798):视频无内嵌镜头档案时,用检测到的
      // 相机名查内置库、按视频实际分辨率筛子档案加载;否则缺 optimal_fov 会让 FOV 偏大
      // ~1.22x、可见范围对不上官方。须在 pushAllDefaultsAndRecompute(末尾 recompute)前完成。
      // 不再强推 gyro_offset:原生全程不写 stabilizer(ParamsModel.m:110),交给 autosync。
      await _autoMatchLensIfNeeded(info);
      // 预览统一 1080P:把输出按宽高比降采样到 1080 高(源 >1080 才降;源 <=1080 不动)。
      // 用 setOutputSizeExact 按「输出」尺寸缩放(iOS setPreviewResolution 用的是输入尺寸,
      // 对 4:3 输入/16:9 输出的机型如 GoPro 会错宽高比,故这里自己按 output 算)。
      final srcOw = info.outputWidth ?? 0, srcOh = info.outputHeight ?? 0;
      exportWidth = srcOw > 0 ? srcOw : 1920; // 导出默认 = 源输出尺寸
      exportHeight = srcOh > 0 ? srcOh : 1080;
      // 预览 output_size:源尺寸降到 ≤1080P 高(记录下来,供切换输出大小时判重)。
      final (ppw, pph) = _previewSizeFor(exportWidth, exportHeight);
      if (srcOh > 1080 && srcOw > 0) {
        await _bridge.setOutputSizeExact(ppw, pph);
      }
      _previewW = ppw;
      _previewH = pph;
      final rawImu = await _isRawImu(); // 无精确四元数=raw-IMU(需同步)
      hasAccurateTimestamps = !rawImu; // 有精确四元数=不需同步点也能正确导出(对齐原生)
      await params.pushAllDefaultsAndRecompute();
      // 此刻为默认平滑(非0):修正角真实反映陀螺有无 → 锁存,后续关防抖不再翻转。
      _gyroDataDetected = _hasGyroAngles;
      recordingSettings = await _fetchRecordingSettings();
      await _fetchLensInfo(); // 读回镜头信息(内嵌或自动匹配后的)+ hasLensProfile
      await _fetchGyroInfo(); // IMU朝向/积分方法/has_quaternions 回显
      await _fetchGyroTimeline(); // 陀螺波形采样
      uri = picked;
      final ow = info.outputWidth ?? 16, oh = info.outputHeight ?? 9;
      aspect = oh > 0 ? ow / oh : 16 / 9;
      playing = false; // 打开后停在首帧,等用户手动点播放
      await _startBackend();
      _playheadUs = 0;
      _maybeRunPreviewClock();
      await _fetchPreviewStateOnce(); // 方向指示器:载入即回显起始姿态(不等播放)
      status = L.current.ctlBackend(backend.label);
      _snapshotLoadedParams(); // 快照「加载镜头(及覆盖)后的参数值」,供双击标题恢复
      // 陀螺-画面同步(严格对齐原生 ViewController.mm:940 四闸门):
      //   镜头档案声明 do_autosync(lensDoAutosync,如 RunCam 系列)+ 有运动 + 非精确时间戳
      //   + 未在同步中 → 跑 autosync 求逐点偏移。否则**不做任何偏移兜底**(原生 else 只 recompute,
      //   已由上面的 pushAllDefaultsAndRecompute 完成);需要时用户手动点「自动同步」。
      //   注意:不再以「有无镜头档案」为触发条件,也不再强推 48ms(那是之前与原生的偏差)。
      if (lensDoAutosync && hasGyro && rawImu && !autosyncRunning) {
        await _startAutosync(picked);
      }
      // 本视频无内嵌陀螺、但之前已授权过目录 → 自动重扫该目录里本视频的同名 sidecar
      // (无需再次弹授权框)。扫到则加载并重算/刷新/按需补跑 autosync。
      await _autoRescanSidecars(picked);
    } catch (e) {
      status = L.current.ctlFailed('$e');
    } finally {
      _setBusy(false);
    }
  }

  // 「加载镜头(及覆盖)后的参数值」快照(原始模型单位)。双击参数行标题恢复到这些值。
  final Map<String, double> loadedParamValues = {};

  void _snapshotLoadedParams() {
    final m = params;
    loadedParamValues
      ..clear()
      ..addAll({
        'smoothness': m.smoothness,
        'smoothnessPitch': m.smoothnessPitch,
        'smoothnessYaw': m.smoothnessYaw,
        'smoothnessRoll': m.smoothnessRoll,
        'maxSmoothnessSec': m.maxSmoothnessSec,
        'alphaHighVelSec': m.alphaHighVelSec,
        'horizonLockAmount': m.horizonLockAmount,
        'horizonLockRoll': m.horizonLockRoll,
        'maxZoomPercent': m.maxZoomPercent,
        'adaptiveZoomSec': m.adaptiveZoomSec,
        'lensCorrection': m.lensCorrection,
        'fov': m.fov,
        'frameReadoutMs': m.frameReadoutMs,
        'videoSpeed': m.videoSpeed,
        'addPitch': m.addPitch,
        'addYaw': m.addYaw,
        'addRoll': m.addRoll,
        'maxZoomIterations': m.maxZoomIterations.toDouble(),
        'smoothingMethod': m.smoothingMethod.toDouble(),
        'croppingMode': m.croppingMode.toDouble(),
        'zoomingMethod': m.zoomingMethod.toDouble(),
      });
  }

  /// 一键切后端:拆当前 + 起另一个(会重新解码),参数状态不动。
  Future<void> switchBackend() async {
    if (uri == null || busy) return;
    _setBusy(true);
    try {
      await _stopBackend();
      backend = backend.other;
      playing = false; // 切后端后同样停在首帧,等手动播放
      await _startBackend();
      status = L.current.ctlBackend(backend.label);
    } finally {
      _setBusy(false);
    }
  }

  Future<void> togglePlay() async {
    final start = _playStartUs, end = _playEndUs;
    final atEnd = end > 0 && _playheadUs >= end;
    final outside = trimEnabled && _playheadUs < start; // 裁剪时落在选区之外
    playing = !playing;
    // 末尾/选区外重播:回到有效起点。整片用原生 play() 自带「到尾从头」无需 seek(0);
    // 裁剪时起点非 0,须显式 seek 原生到选区起点。
    if (playing && (atEnd || outside)) {
      _playheadUs = start;
      if (trimEnabled) await _seekBackend(_playheadUs);
    }
    if (backend == PreviewBackend.texture) {
      await (playing ? _previewApi.play() : _previewApi.pause());
    } else {
      await _pvChannel?.invokeMethod(playing ? 'play' : 'pause');
    }
    _maybeRunPreviewClock();
    notifyListeners();
  }

  /// PlatformView 创建回调:拿到 per-view 控制通道。
  void onPlatformViewCreated(int id) {
    _pvChannel = MethodChannel('runcam_gf/preview_pv_$id');
  }

  /// 文件名(uri 末段,可能是 content:// 或文件路径)。只保留纯文件名,不含目录/卷标。
  String? get videoName {
    final u = uri;
    if (u == null) return null;
    return _lastSegment(u);
  }

  // 打开视频时(默认平滑、非0)锁存的「有陀螺数据」结论。之后关防抖(平滑=0)会让
  // 当前修正角归零,但视频本身仍有运动数据,故用锁存值,避免切功能时蓝框误现。
  bool _gyroDataDetected = false;

  /// 当前修正角是否非零(默认平滑下=有陀螺校正量;关防抖时会归零)。
  bool get _hasGyroAngles =>
      params.maxAnglePitch.abs() +
          params.maxAngleYaw.abs() +
          params.maxAngleRoll.abs() >
      0.01;

  /// 是否有运动数据(对齐原生 gyroflow_has_motion_data 的语义):
  /// 首选「陀螺/四元数时间线非空」这个直接信号(与运动大小无关,很稳的视频也准)——
  /// 这正是之前蓝框误现的修复:修正角推断对运动小的视频会误判为「无运动」。
  /// 退回锁存检测/修正角,做双保险。
  bool get hasGyro =>
      gyroSamples.isNotEmpty || _gyroDataDetected || _hasGyroAngles;

  // 是否已授权过目录(授权后整个会话不再显示蓝框,跨视频/换页保留;静态故新建
  // controller 也保留)。对齐用户预期「授权过就不再要求授权」。
  static bool _folderAuthorized = false;

  // 已授权目录路径(安卓 SAF tree uri / iOS file:// 目录)。授权后整会话保留,
  // 供打开新视频时自动重扫该目录里本视频的同名 sidecar(目录已在原生白名单内,
  // 无需再次授权)。修复:授权一次后换视频不再出现蓝框、也不自动匹配新视频 sidecar。
  static String? _authorizedFolder;

  /// 视频信息蓝色授权提示框是否显示(对齐原生 refreshVideoDirHint:缺运动数据或
  /// 镜头档案 → 引导授权;已授权过则不再显示)。
  bool get showVideoDirHint =>
      uri != null &&
      !busy &&
      !_folderAuthorized &&
      (!hasGyro || !hasLensProfile);

  /// 授权视频所在目录 → 注册白名单 → 扫描同名 sidecar(运动数据/镜头)→ 自动加载。
  /// 对齐原生 selectMotionFolder + scanGrantedFolder。目录枚举在原生(content://、
  /// iOS 安全作用域 dart:io 读不到),Dart 只编排。
  Future<void> authorizeVideoFolder() async {
    if (uri == null) return;
    _setBusy(true);
    try {
      final folder = await _picker.invokeMethod<String>('pickFolder');
      if (folder == null) return; // 用户取消(不置已授权)
      _folderAuthorized = true; // 授权后不再显示蓝框(无论是否扫到文件)
      _authorizedFolder = folder; // 记住目录,供后续视频自动重扫(见 _autoRescanSidecars)
      await _bridge.folderAccessGranted(folder); // 注册白名单(否则下面读不到文件)
      final found = await _scanAndLoadSidecars(folder);
      await _bridge.recomputeBlocking();
      await _fetchLensInfo();
      await _fetchGyroInfo();
      await _fetchGyroTimeline(); // 运动数据变了,刷新陀螺波形
      _refreshPreview();
      await _fetchPreviewStateOnce();
      // 现在有运动数据 + 镜头声明 do_autosync + raw-IMU → 补跑 autosync(对齐原生触发条件)。
      final rawImu = await _isRawImu();
      if (lensDoAutosync && hasGyro && rawImu && !autosyncRunning) {
        await _startAutosync(uri!);
      } else {
        status = !found
            ? L.current.ctlNoSidecarFound(_videoBaseName())
            : L.current.ctlFolderSidecarLoaded;
      }
    } catch (e) {
      status = L.current.ctlFolderAuthFailed('$e');
    } finally {
      _setBusy(false);
      notifyListeners();
    }
  }

  /// 在 [folder] 里扫描当前视频同名 sidecar(运动数据/镜头 json)并加载。
  /// 返回是否扫到任意文件。供首次授权(authorizeVideoFolder)与打开新视频后的
  /// 自动重扫(_autoRescanSidecars)复用;不负责 recompute/刷新(由调用方按需做)。
  Future<bool> _scanAndLoadSidecars(String folder) async {
    final base = _videoBaseName();
    final scanJson = await _picker.invokeMethod<String>(
        'scanFolderForSidecars', {'folder': folder, 'base': base});
    debugPrint('[dirAuth] folder=$folder base=$base scan=$scanJson');
    final scan = scanJson != null ? jsonDecode(scanJson) : null;
    final motionPath = (scan is Map) ? scan['motionPath'] as String? : null;
    final lensPath = (scan is Map) ? scan['lensPath'] as String? : null;
    // 运动数据:扫到就加载并更新「运动数据」面板状态(对齐 openMotionFile)。
    if (motionPath != null && motionPath.isNotEmpty) {
      await _bridge.loadGyro(motionPath, loadAllMetadata);
      _motionFilePath = motionPath;
      motionFileName = _lastSegment(motionPath);
      // 检测到的格式 = telemetry 检测源(对齐桌面),取不到退回扩展名。
      final ext = _extOf(motionPath);
      motionFormat = (await _detectedMotionSource()) ??
          (ext.isNotEmpty ? ext : 'IMU sidecar');
      debugPrint('[dirAuth] 已加载运动数据: $motionFileName (格式=$motionFormat)');
      // gcsv 带来相机身份(camera_id)→ 从内置库自动加载镜头(RunCam6 这类视频本身
      // 无 telemetry、镜头不是 .json 文件的机型,对齐 ViewController.mm:914)。
      final lr = await _bridge.autoloadLensForCamera();
      debugPrint('[dirAuth] autoloadLensForCamera rc=$lr');
    }
    // 若目录里有同名 .json 镜头档案(部分机型),加载它覆盖(用户显式授权=以扫到的为准)。
    if (lensPath != null && lensPath.isNotEmpty) {
      final r = await _bridge.loadLens(lensPath);
      debugPrint('[dirAuth] 已加载镜头 json: $lensPath -> $r');
    }
    return (motionPath != null && motionPath.isNotEmpty) ||
        (lensPath != null && lensPath.isNotEmpty);
  }

  /// 打开新视频后:若已授权过目录、且本视频无内嵌陀螺,则用已授权目录自动重扫
  /// 本视频的同名 sidecar 并加载(目录已在白名单/scoped,静默完成)。修复「授权一次后
  /// 换视频不再出现蓝框、新视频 sidecar 不自动匹配」。扫到才重算/刷新/补跑 autosync。
  Future<void> _autoRescanSidecars(String videoUri) async {
    if (hasGyro || !_folderAuthorized || _authorizedFolder == null) return;
    final found = await _scanAndLoadSidecars(_authorizedFolder!);
    if (!found) return;
    await _bridge.recomputeBlocking();
    await _fetchLensInfo();
    await _fetchGyroInfo();
    await _fetchGyroTimeline();
    _gyroDataDetected = _hasGyroAngles; // 重判陀螺锁存(运动数据已载入)
    _refreshPreview();
    await _fetchPreviewStateOnce();
    final rawImu = await _isRawImu();
    if (lensDoAutosync && hasGyro && rawImu && !autosyncRunning) {
      await _startAutosync(videoUri);
    }
  }

  /// 拉取陀螺波形采样(原始角速度优先,空则退回四元数)。打开视频/加载运动数据后调。
  Future<void> _fetchGyroTimeline() async {
    try {
      const n = 400;
      var s = await _bridge.gyroTimeline(n);
      var axes = 3;
      if (s.isEmpty) {
        s = await _bridge.quaternionTimeline(n);
        axes = 4;
      }
      gyroSamples = s;
      gyroAxes = axes;
      notifyListeners();
    } catch (_) {/* 无数据 → 空波形 */}
  }

  /// 运动数据「检测到的格式」—— 取 telemetry 检测到的相机/源(如 "Runcam Runcam6"),
  /// 对齐桌面 MotionData.qml「Detected format」=camera。loadGyro 后调用(此时
  /// getVideoMetadata 的 camera 已是 gcsv 的 detected_source)。取不到返回 null。
  Future<String?> _detectedMotionSource() async {
    try {
      final m = jsonDecode(await _bridge.getVideoMetadata());
      final c = (m is Map) ? m['camera'] : null;
      return (c is String && c.isNotEmpty) ? c : null;
    } catch (_) {
      return null;
    }
  }

  /// 当前视频文件名去扩展名(用于匹配同名 sidecar)。
  String _videoBaseName() {
    final n = videoName ?? '';
    final i = n.lastIndexOf('.');
    return i > 0 ? n.substring(0, i) : n;
  }

  /// 镜头库搜索 → [{name,id}] 列表(空查询/失败=空)。
  Future<List<Map<String, String>>> searchLens(String q) async {
    if (q.trim().isEmpty) return const [];
    try {
      final arr = jsonDecode(await _bridge.lensSearch(q));
      if (arr is List) {
        return arr
            .whereType<Map>()
            .map((m) => {'name': '${m['name'] ?? ''}', 'id': '${m['id'] ?? ''}'})
            .where((m) => (m['id'] ?? '').isNotEmpty)
            .toList();
      }
    } catch (_) {/* 搜索失败 → 空 */}
    return const [];
  }

  /// 加载镜头档案(内置 id 或文件路径)→ recompute + 刷新镜头信息。
  Future<void> loadLens(String idOrPath) async {
    if (uri == null) return;
    _setBusy(true);
    try {
      await _bridge.loadLens(idOrPath);
      await _bridge.recomputeBlocking();
      await _fetchLensInfo();
      status = L.current.ctlLensLoaded;
    } catch (e) {
      status = L.current.ctlLensLoadFailed('$e');
    } finally {
      _setBusy(false);
    }
  }

  /// 打开视频时的镜头库自动匹配 —— 严格对齐 ViewController.mm:1798-1852。
  /// 视频自带内嵌镜头档案(has_lens)则不动;否则用检测到的相机名查内置库,
  /// **按视频实际「宽×高」筛子档案**(错档案没有 optimal_fov → FOV 偏大~1.22x、
  /// 可见范围对不上),筛不到再退回第一条。匹配失败不阻断打开。
  /// 不在此 recompute —— 紧随其后的 pushAllDefaultsAndRecompute 会统一 recompute。
  Future<void> _autoMatchLensIfNeeded(VideoInfo info) async {
    try {
      // 已有镜头档案(内嵌或先前匹配)→ 不覆盖(对齐 gyroflow_has_lens_profile==0)。
      final lens = jsonDecode(await _bridge.getLensInfoFull());
      if (lens is Map && lens['has_lens'] == true) {
        debugPrint('[lensMatch] 已有内嵌/已加载镜头档案 → 跳过自动匹配 (name=${lens['name']})');
        return;
      }
      // 检测到的相机名(telemetry)→ 内置库搜索关键字。
      final meta = jsonDecode(await _bridge.getVideoMetadata());
      final camera = meta is Map ? meta['camera'] : null;
      debugPrint('[lensMatch] 无镜头档案; 检测相机=$camera; 视频=${info.width}x${info.height}');
      if (camera is! String || camera.isEmpty) return;
      final matches = jsonDecode(await _bridge.lensSearch(camera));
      if (matches is! List || matches.isEmpty) {
        debugPrint('[lensMatch] lensSearch("$camera") 无结果');
        return;
      }
      // 按视频实际分辨率筛 name 里带 "WxH" 的子档案(对齐 ViewController.mm:1816)。
      final dimsKey = '${info.width}x${info.height}';
      Map? chosen;
      for (final m in matches) {
        if (m is Map &&
            m['name'] is String &&
            (m['name'] as String).contains(dimsKey)) {
          chosen = m;
          break;
        }
      }
      final byDims = chosen != null;
      chosen ??= matches.first is Map ? matches.first as Map : null; // 兜底:第一条
      final id = chosen?['id'];
      if (id is! String || id.isEmpty) return;
      debugPrint('[lensMatch] ${byDims ? "按分辨率命中" : "兜底第一条"} → ${chosen?['name']} (id=$id), 共 ${matches.length} 条候选');
      await _bridge.loadLens(id); // 内部含 load_lens_profile + apply_loaded_lens_extras
    } catch (e) {
      debugPrint('[lensMatch] 自动匹配异常: $e');
    }
  }

  Future<void> _fetchLensInfo() async {
    try {
      final j = jsonDecode(await _bridge.getLensInfoFull());
      if (j is! Map) return;
      hasLensProfile = j['has_lens'] == true; // autosync 前置:有畸变模型才能跑
      // 镜头 sync_settings(对齐 ViewController.mm:1431-1448 的 11 项):do_autosync 触发门槛 +
      // 全部同步参数(max_sync_points/every_nth_frame/time_per_syncpoint… 决定同步点数与处理帧数,
      // 对齐官方,随镜头档案而定)。读到则覆盖官方默认。
      final sync = j['sync_settings'];
      // do_autosync 永远显式重置:镜头档案没有「自动同步」内容(无 sync_settings 或 do_autosync≠true)
      // 时绝不触发自动同步(对齐 iOS:仅声明 do_autosync 的档案才自动同步,否则等用户手动点)。
      lensDoAutosync = sync is Map && sync['do_autosync'] == true;
      if (sync is Map) {
        num? n(String k) => sync[k] is num ? sync[k] as num : null;
        bool? b(String k) => sync[k] is bool ? sync[k] as bool : null;
        // 写进 ParamsModel 同步组(面板与 autosync 共享;未指定的键保持默认/现值)。
        final io = n('initial_offset');
        if (io != null) params.gyroOffsetMs = io.toDouble();
        final ioi = b('initial_offset_inv');
        if (ioi != null) params.checkNegativeInitialOffset = ioi;
        final ss = n('search_size');
        if (ss != null) params.syncSearchSizeSec = ss.toDouble();
        final cif = b('calc_initial_fast');
        if (cif != null) params.calcInitialFast = cif;
        final mp = n('max_sync_points');
        if (mp != null) params.maxSyncPoints = mp.toInt();
        final enf = n('every_nth_frame');
        if (enf != null) params.everyNthFrame = enf.toInt();
        final tps = n('time_per_syncpoint');
        if (tps != null) params.timePerSyncpointSec = tps.toDouble();
        final ofm = n('of_method');
        if (ofm != null) params.ofMethod = ofm.toInt();
        final ofs = n('offset_method');
        if (ofs != null) params.offsetMethod = ofs.toInt();
        final pm = n('pose_method');
        if (pm != null) params.poseMethod = pm.toInt();
        final asp = b('auto_sync_points');
        if (asp != null) params.autoSyncPointsExperimental = asp;
      }
      String? s(String k) {
        final v = j[k];
        return (v is String && v.isNotEmpty) ? v : null;
      }

      double? d(String k) {
        final v = j[k];
        return v is num ? v.toDouble() : null;
      }

      detectedCamera = s('camera');
      detectedLens = s('lens') ?? s('lens_model');
      lensName = s('name') ?? s('identifier') ?? L.current.ctlNoLensProfile;
      final cd = j['calib_dimension'];
      lensCalibW = (cd is Map && cd['w'] is num) ? (cd['w'] as num).toInt() : null;
      lensCalibH = (cd is Map && cd['h'] is num) ? (cd['h'] as num).toInt() : null;
      final dim = (cd is Map && cd['w'] != null && cd['h'] != null)
          ? '${cd['w']}×${cd['h']}'
          : null;
      // 键为稳定标识符(非显示文本),由「输入」面板 _lensLabel 翻译成本地化标签。
      lensInfo = {
        'camera': ?detectedCamera,
        'lens': ?detectedLens,
        // 设置 / 其他信息:对齐原生,即使为空也保留该行(显示空值)。
        'setting': s('camera_setting') ?? '',
        'note': s('note') ?? '',
        'dimensions': ?dim,
        'calibratedBy': ?s('calibrated_by'),
      };
      // 高级段:像素焦距 fx/fy、聚焦中心 cx/cy、畸变系数 k1..k4(null=该档案未提供)。
      lensFx = d('fx');
      lensFy = d('fy');
      lensCx = d('cx');
      lensCy = d('cy');
      final dc = j['distortion_coeffs'];
      lensDistortion = dc is List
          ? dc.map((e) => e is num ? e.toDouble() : null).toList()
          : const [];
      lensLoadSeq++; // 通知面板:新镜头数据已就绪,回填输入框
    } catch (_) {/* 镜头信息缺失 → 保持默认 */}
  }

  /// 低通滤波器开关:开=50Hz、关=0(params 自带 push+recompute)。
  void setImuLpfOn(bool on) => params.imuLpfHz = on ? 50.0 : 0.0;

  /// 低通滤波器 Hz(0=关)→ params(自带 push+recompute)。
  void setImuLpfHz(double hz) => params.imuLpfHz = hz;

  /// 镜头「打开文件」:选镜头档案 → loadLens(已含 recompute + 刷新镜头信息)。
  /// 仅接受 .json 镜头档案;选了其它类型则提示并不加载(跨端统一在此校验扩展名)。
  Future<void> openLensFile() async {
    if (uri == null || busy) return;
    final picked = await _picker.invokeMethod<String>('pickLensFile');
    if (picked == null) return;
    if (_extOf(picked) != 'JSON') {
      status = L.current.ctlLensWrongType;
      notifyListeners();
      return;
    }
    await loadLens(picked);
  }

  /// 运动数据「打开文件」:选陀螺 sidecar → loadGyro → recompute → 刷新。
  /// 仅接受 .gcsv 运动数据;选了其它类型则提示并不加载。
  Future<void> openMotionFile() async {
    if (uri == null || busy) return;
    final picked = await _picker.invokeMethod<String>('pickMotionFile');
    if (picked == null) return;
    // 接受全部受支持的运动数据格式(与目录扫描 scanFolderForSidecars 的 motionExts 对齐)。
    const motionExts = {'GCSV', 'BBL', 'BFL', 'CSV'};
    if (!motionExts.contains(_extOf(picked))) {
      status = L.current.ctlMotionWrongType;
      notifyListeners();
      return;
    }
    _setBusy(true);
    try {
      await _bridge.loadGyro(picked, loadAllMetadata);
      _motionFilePath = picked;
      motionFileName = _lastSegment(picked);
      // 检测到的格式 = telemetry 检测源(对齐桌面 MotionData「Detected format」=camera);
      // 取不到才退回文件扩展名。
      final ext = _extOf(picked);
      motionFormat = (await _detectedMotionSource()) ??
          (ext.isNotEmpty ? ext : 'IMU sidecar');
      // gcsv 带来相机身份 → 从内置库自动加载镜头(RunCam6 等,对齐 ViewController.mm:914)。
      await _bridge.autoloadLensForCamera();
      await _bridge.recomputeBlocking();
      await _fetchLensInfo(); // load_all_metadata 可能带入内嵌镜头档案
      await _fetchGyroInfo(); // 外挂陀螺多为 raw IMU,回显朝向/积分方法
      await _fetchGyroTimeline(); // 刷新陀螺波形
      await _fetchPreviewStateOnce();
      status = L.current.ctlMotionLoaded;
    } catch (e) {
      status = L.current.ctlMotionLoadFailed('$e');
    } finally {
      _setBusy(false);
    }
  }

  /// 「加载全部元数据」切换:若已外挂文件,用新标志重载(对齐 MotionData.qml:215)。
  Future<void> setLoadAllMetadata(bool on) async {
    loadAllMetadata = on;
    final p = _motionFilePath;
    if (p == null) {
      notifyListeners();
      return;
    }
    _setBusy(true);
    try {
      await _bridge.loadGyro(p, on);
      await _bridge.recomputeBlocking();
      await _fetchLensInfo();
      await _fetchGyroInfo();
    } catch (e) {
      status = L.current.ctlMotionReloadFailed('$e');
    } finally {
      _setBusy(false);
    }
  }

  /// 帧偏移(整帧,可负;0=关闭)→ 引擎 + recompute。
  Future<void> setFrameOffset(int frames) async {
    await _bridge.setFrameOffset(frames);
    await _bridge.recomputeBlocking();
    _refreshPreview();
    notifyListeners();
  }

  /// 中值滤波采样数(0=关)→ 引擎 + recompute。
  Future<void> setImuMedian(int samples) async {
    imuMedian = samples;
    await _bridge.setImuMedian(samples);
    await _bridge.recomputeBlocking();
    await _fetchPreviewStateOnce();
    _refreshPreview();
    notifyListeners();
  }

  /// IMU 旋转(度)→ 引擎 + recompute。
  Future<void> setImuRotation(double pitch, double roll, double yaw) async {
    imuRotation = [pitch, roll, yaw];
    await _bridge.setImuRotation(pitch, roll, yaw);
    await _bridge.recomputeBlocking();
    await _fetchPreviewStateOnce();
    _refreshPreview();
    notifyListeners();
  }

  /// 陀螺 bias(°/s)→ 引擎 + recompute。
  Future<void> setImuBias(double x, double y, double z) async {
    imuBias = [x, y, z];
    await _bridge.setImuBias(x, y, z);
    await _bridge.recomputeBlocking();
    await _fetchPreviewStateOnce();
    _refreshPreview();
    notifyListeners();
  }

  /// 取 uri/path 的纯文件名(去掉目录与卷标前缀)。
  /// 安卓 content:// 的末段常是 SAF document-id,解码后形如 "primary:DCIM/Camera/VID_001.mp4",
  /// 需再切掉 ':' 与 '/' 之前的部分,只留 "VID_001.mp4"(对齐「文件名称只显示文件名」)。
  String _lastSegment(String p) {
    final seg = Uri.tryParse(p)?.pathSegments;
    final last = (seg != null && seg.isNotEmpty && seg.last.isNotEmpty)
        ? seg.last
        : p.split('/').last;
    return last.split(RegExp(r'[/:]')).last;
  }

  /// 取扩展名大写(无扩展名或 content:// 取不到时返回空)。
  String _extOf(String p) {
    final name = _lastSegment(p);
    final i = name.lastIndexOf('.');
    return (i >= 0 && i < name.length - 1)
        ? name.substring(i + 1).toUpperCase()
        : '';
  }

  /// IMU 朝向(如 XYZ/ZyX)→ 引擎 + recompute。
  Future<void> setImuOrientationStr(String v) async {
    imuOrientation = v;
    await _bridge.setImuOrientation(v);
    await _bridge.recomputeBlocking();
    _refreshPreview();
    notifyListeners();
  }

  /// 积分方法 → 引擎 + recompute。
  Future<void> setIntegration(int v) async {
    integrationMethod = v;
    await _bridge.setIntegrationMethod(v);
    await _bridge.recomputeBlocking();
    _refreshPreview();
    notifyListeners();
  }

  void setOrientationIndicator(bool on) {
    orientationIndicator = on;
    _maybeRunPreviewClock();
    if (on && _orientTimer == null) _fetchPreviewStateOnce(); // 暂停态也回显当前姿态
    notifyListeners();
  }

  /// 是否 raw-IMU 机型(无精确四元数,需同步偏移/autosync)。
  /// 对齐原生 autosync 四闸门里的「无精确时间戳」判断;此处用现成的 has_quaternions
  /// 作代理(无四元数≈raw-IMU,如 GoPro Hero5/6/7)。读不到时保守返回 false(不推偏移)。
  Future<bool> _isRawImu() async {
    try {
      final j = jsonDecode(await _bridge.getGyroInfo());
      return !(j is Map && j['has_quaternions'] == true);
    } catch (_) {
      return false;
    }
  }

  /// 启动自动同步。参数取官方默认(对齐桌面 Synchronization.qml / ParamsModel.m,
  /// 与 fork SyncParams 一致):search 5s、3 点、每帧、1.5s/点、DIS光流(2)、
  /// findEssential(0)、rs-sync(2)、initial 0、不快速初值、不查负偏移、不自动采样点。
  /// 逐帧喂帧在原生;进度/结束经事件回 [_onAutosyncProgress]/[_onAutosyncFinished]。
  Future<void> _startAutosync(String uri) async {
    autosyncRunning = true;
    autosyncProgressValue = 0.0;
    autosyncReady = 0;
    autosyncTotal = 0;
    autosyncSyncPoints = const []; // 清旧同步点
    _autosyncClock
      ..reset()
      ..start();
    status = L.current.ctlAutosyncing;
    notifyListeners();
    debugPrint('[autosync] start maxPts=${params.maxSyncPoints} '
        'everyNth=${params.everyNthFrame} pose=${params.poseMethod} '
        'of=${params.ofMethod} offset=${params.offsetMethod} '
        'search=${params.syncSearchSizeSec} init=${params.gyroOffsetMs}');
    // 释放预览解码器(让出硬件解码器)→ autosync 自己的解码器才能 start 成功:部分设备(如高通)
    // 不能同时存在 2 个全分辨率硬件解码器,预览解码器不释放则 MediaCodec.start() 失败。
    // setExportMode 只释放解码器、保留纹理/surface(不像 _stopBackend 重建纹理会偶发黑屏);
    // 结束后在 _onAutosyncFinished 重建。iOS 的 setExportMode 为空操作(无此并发限制)。
    if (backend == PreviewBackend.texture) {
      try {
        await _previewApi.setExportMode(true);
      } catch (_) {/* 忽略 */}
    }
    try {
      // 同步参数取 ParamsModel 同步组(默认=官方,镜头 sync_settings/同步面板可覆盖)。
      await _bridge.autosyncStart(
        uri,
        params.gyroOffsetMs,
        params.syncSearchSizeSec,
        params.maxSyncPoints,
        params.everyNthFrame,
        params.timePerSyncpointSec,
        params.ofMethod,
        params.poseMethod,
        params.offsetMethod,
        params.calcInitialFast,
        params.checkNegativeInitialOffset,
        params.autoSyncPointsExperimental,
      );
    } catch (e) {
      autosyncRunning = false;
      _autosyncClock.stop();
      status = L.current.ctlAutosyncFailed('$e');
      // autosync 没起来:把刚释放的预览解码器重建回来,别让画面卡死。
      if (backend == PreviewBackend.texture) {
        try {
          await _previewApi.setExportMode(false);
        } catch (_) {/* 忽略 */}
      }
      notifyListeners();
    }
  }

  /// 用户手动触发自动同步(供「运动数据」面板按钮调用)。
  Future<void> startAutosyncManual() async {
    final u = uri;
    if (u == null || autosyncRunning) return;
    if (!hasLensProfile) {
      status = L.current.ctlAutosyncNeedLens;
      notifyListeners();
      return;
    }
    await _startAutosync(u);
  }

  Future<void> cancelAutosync() async {
    if (!autosyncRunning) return;
    try {
      await _bridge.autosyncCancel();
    } catch (_) {}
  }

  /// 后端 seek(Texture/PlatformView 统一入口)。
  Future<void> _seekBackend(int us) async {
    try {
      if (backend == PreviewBackend.texture) {
        await _previewApi.seekTo(us);
      } else {
        await _pvChannel?.invokeMethod('seekTo', {'us': us});
      }
    } catch (_) {/* platformView 暂未接 seek:仅更新播放头/波形 */}
  }

  /// 拖动陀螺时间线 seek 到进度 p(0..1):更新播放头 + 原生 seek + 重渲/刷 HUD。
  /// 裁剪开启时只能 seek 到选区内 [trimStart, trimEnd];否则封顶到真正末帧。
  Future<void> seekToProgress(double p) async {
    final durUs = _durationUs;
    if (durUs <= 0) return;
    final lo = _playStartUs, hi = _playEndUs;
    var t = (p.clamp(0.0, 1.0) * durUs).round();
    // 封顶到有效区间:拖到选区/末帧外即夹住,避免 HUD 帧号越界或越出选中片段。
    if (hi > 0) t = t.clamp(lo, hi);
    _playheadUs = t;
    _lastElapsedUs = _orientClock.elapsedMicroseconds; // 重置时钟基准,避免下拍 dt 跳变
    await _seekBackend(_playheadUs);
    if (!playing) _refreshPreview();
    await _fetchPreviewStateOnce();
    notifyListeners();
  }

  void _onAutosyncProgress((double, int, int) e) {
    autosyncProgressValue = e.$1;
    autosyncReady = e.$2;
    autosyncTotal = e.$3;
    notifyListeners();
  }

  /// 蒙版用:已处理速率 fps(= 已处理帧 / 已耗秒)。
  double get autosyncFps {
    final s = _autosyncClock.elapsedMilliseconds / 1000.0;
    return s > 0 ? autosyncReady / s : 0.0;
  }

  int get autosyncElapsedSec => _autosyncClock.elapsed.inSeconds;

  /// 蒙版用:剩余秒数估算(剩余帧 / fps)。
  int get autosyncRemainingSec {
    final fps = autosyncFps;
    if (fps <= 0 || autosyncTotal <= 0) return 0;
    final left = (autosyncTotal - autosyncReady) / fps;
    return left > 0 ? left.ceil() : 0;
  }

  Future<void> _onAutosyncFinished((double, List<double>, bool) e) async {
    _autosyncClock.stop();
    debugPrint('[autosync] finished ok=${e.$3} '
        'points=${e.$2.length ~/ 2} median=${e.$1}ms');
    autosyncSyncPoints = e.$2; // 同步点 [mid_ms, off_ms, ...] → 回显到陀螺波形
    // 重建 autosync 前释放的预览解码器(趁「分析中…」蒙版还盖着,重建不可见再隐藏蒙版)。
    if (backend == PreviewBackend.texture) {
      try {
        await _previewApi.setExportMode(false);
      } catch (_) {/* 忽略 */}
    }
    autosyncRunning = false;
    // 偏移已由 FFI autosync_finish 逐点写入 gyro 并 recompute;这里只需重渲 + 刷 HUD + 波形。
    await _fetchGyroTimeline();
    _refreshPreview();
    await _fetchPreviewStateOnce();
    status = e.$3
        ? L.current.ctlAutosyncComplete(
            '${e.$2.length ~/ 2}', e.$1.toStringAsFixed(1))
        : L.current.ctlAutosyncNoOffset;
    notifyListeners();
  }

  /// 读回运动数据当前状态(回显):IMU朝向 / has_quaternions / 积分方法。
  /// iOS 缺 integration_method 字段时,按 has_quaternions 推默认并显式设一次。
  Future<void> _fetchGyroInfo() async {
    try {
      final j = jsonDecode(await _bridge.getGyroInfo());
      if (j is! Map) return;
      hasQuaternions = j['has_quaternions'] == true;
      final o = j['imu_orientation'];
      if (o is String && o.isNotEmpty) imuOrientation = o;
      final integ = j['integration_method'];
      if (integ is num) {
        integrationMethod = integ.toInt();
      } else {
        // iOS 无 getter → 按桌面 MotionData.qml:113-119 选并设一次:
        //   有四元数 = None(0);无四元数默认 VQF(2),视频 <10s 用 Complementary(1)。
        final durMs = (videoInfo?.durationS ?? 0) * 1000;
        integrationMethod = hasQuaternions
            ? 0
            : (durMs > 0 && durMs < 10000 ? 1 : 2);
        await _bridge.setIntegrationMethod(integrationMethod);
        await _bridge.recomputeBlocking();
      }
      final m = j['median'];
      if (m is num) imuMedian = m.toInt();
      imuRotation = _triple(j['rotation']);
      imuBias = _triple(j['bias']);
      gyroInfoSeq++; // 通知面板回填 median/旋转/偏差 输入框
    } catch (_) {/* 缺失 → 保持默认 */}
  }

  /// 把 JSON 的 [a,b,c] 转成 3 元 double 列表(缺失/异常→全 0)。
  List<double> _triple(Object? v) {
    if (v is List && v.length >= 3) {
      return [for (var i = 0; i < 3; i++) (v[i] is num) ? (v[i] as num).toDouble() : 0.0];
    }
    return const [0, 0, 0];
  }

  /// 查一次当前播放头处的预览状态(HUD 缩放% + 方向指示器姿态),供暂停/刚载入/
  /// 参数改动后回显。fov 总查;quats 仅在方向指示器开时查(省开销)。
  Future<void> _fetchPreviewStateOnce() async {
    try {
      currentFov = await _bridge.getFovAtTimestamp(_playheadUs);
      if (orientationIndicator) {
        final q = await _bridge.quatsAtTimestamp(_playheadUs);
        if (q.length >= 8) quats = q;
      }
      notifyListeners();
    } catch (_) {/* 无数据 → 保持上次 */}
  }

  /// 「正在播放 + 已载视频」时跑 30fps 预览时钟,推进播放头、查 fov(HUD)与姿态;
  /// 否则停表省开销。播放头到末尾回绕。
  void _maybeRunPreviewClock() {
    final shouldRun = playing && uri != null;
    if (shouldRun && _orientTimer == null) {
      _lastElapsedUs = _orientClock.elapsedMicroseconds;
      _orientClock.start();
      _orientTimer = Timer.periodic(
          const Duration(milliseconds: 33), (_) => _previewTick());
    } else if (!shouldRun && _orientTimer != null) {
      _orientTimer!.cancel();
      _orientTimer = null;
      _orientClock.stop();
    }
  }

  Future<void> _previewTick() async {
    if (_orientBusy) return; // 上一帧 channel 还没回,跳过本帧
    final nowUs = _orientClock.elapsedMicroseconds;
    final dt = nowUs - _lastElapsedUs;
    _lastElapsedUs = nowUs;
    final endUs = _playEndUs;
    _playheadUs += dt;
    if (endUs > 0 && _playheadUs >= endUs) {
      if (trimEnabled) {
        // 裁剪播放:到选区终点 → 循环回选区起点继续播放(预览只放选中片段)。
        _playheadUs = _playStartUs;
        _orientBusy = true;
        try {
          await _seekBackend(_playheadUs);
        } catch (_) {/* seek 失败:下一拍重试 */}
        _orientBusy = false;
        notifyListeners();
        return;
      }
      // 整片:播放到末尾**不去动原生**——让 MDK 自己播到真 EOF 自然进入 Stopped 态(画面停在末帧)。
      // 这里只停 Dart 时钟 + 置暂停态(按钮显示播放)。重播时 play() 从 Stopped set(Playing)
      // 自动从 0 开始(对齐原生 ViewController:1561/636,一次点击即重播)。
      // 若强行 pause/seek 会让 MDK 停在「非 Stopped 的末帧」,重播检测时灵时不灵 → 要点两遍。
      _playheadUs = endUs;
      playing = false;
      _maybeRunPreviewClock(); // playing=false → 取消 Dart 时钟(不发原生 pause)
      notifyListeners();
      return;
    }
    _orientBusy = true;
    try {
      currentFov = await _bridge.getFovAtTimestamp(_playheadUs); // HUD 缩放%
      if (orientationIndicator) {
        final q = await _bridge.quatsAtTimestamp(_playheadUs);
        if (q.length >= 8) quats = q;
      }
      notifyListeners();
    } catch (_) {/* 无数据 → 保持上次 */} finally {
      _orientBusy = false;
    }
  }

  /// 读视频元数据 JSON → additional_data.recording_settings(英文键→值字符串)。
  /// 解析失败/无该段 → 空,「输入」面板就不显示这些行。
  Future<Map<String, String>> _fetchRecordingSettings() async {
    try {
      final root = jsonDecode(await _bridge.getVideoMetadata());
      final add = root is Map ? root['additional_data'] : null;
      final rs = add is Map ? add['recording_settings'] : null;
      if (rs is Map) {
        return rs.map((k, v) => MapEntry('$k', '$v'));
      }
    } catch (_) {/* 元数据缺失/格式异常 → 不显示录制参数 */}
    return {};
  }

  Future<void> _startBackend() async {
    if (backend == PreviewBackend.texture) {
      final pi = await _previewApi.createPreviewTexture(uri!);
      textureId = pi.textureId;
      final w = pi.width ?? 16, h = pi.height ?? 9;
      aspect = h > 0 ? w / h : aspect;
      await _bridge.recomputeBlocking(); // GPU 重绑后再同步一次(沿用现有修复)
      if (playing) {
        await _previewApi.play();
      } else {
        await _previewApi.renderOnce(); // 不自动播放:只渲首帧停住
      }
    }
    // PlatformView 后端:UiKitView 在页面构建时创建,原生 init 渲首帧并暂停(由 togglePlay 经通道控制播放)。
  }

  Future<void> _stopBackend() async {
    if (backend == PreviewBackend.texture) {
      final t = textureId;
      textureId = null;
      if (t != null) await _previewApi.disposePreviewTexture(t);
    } else {
      await _pvChannel?.invokeMethod('dispose');
      _pvChannel = null;
    }
  }

  void _setBusy(bool b) {
    busy = b;
    notifyListeners();
  }

  @override
  void dispose() {
    params.removeListener(_onParamsChanged);
    _orientTimer?.cancel();
    _autosyncProgSub?.cancel();
    _autosyncDoneSub?.cancel();
    _exportProgSub?.cancel();
    _stopBackend();
    _bridge.freeStabilizer();
    super.dispose();
  }
}
