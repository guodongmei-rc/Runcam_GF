// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String homeSmokeFailedPlatform(String code, String message) {
    return 'smoke 失败:$code $message';
  }

  @override
  String homeSmokeFailed(String error) {
    return 'smoke 失败:$error';
  }

  @override
  String get homePreviewTexture => '预览 Texture spike (dev)';

  @override
  String get homePreviewPlatformView => '预览 PlatformView (dev)';

  @override
  String get prevLoadingVideo => '加载视频中…';

  @override
  String prevSwitchTo(String backend) {
    return '切到 $backend';
  }

  @override
  String get prevPause => '暂停';

  @override
  String get prevPlay => '播放';

  @override
  String get prevStabOverview => '稳定概览';

  @override
  String get prevStabilization => '防抖';

  @override
  String get prevEnableOverviewHint => '打开稳定概览才能更好的预览效果';

  @override
  String get prevTabInput => '输入';

  @override
  String get prevTabParams => '参数';

  @override
  String get prevTabExport => '导出';

  @override
  String prevAnalyzing(String pct, String ready, String total, String fps) {
    return '分析中 $pct%... ($ready/$total @ ${fps}fps)';
  }

  @override
  String prevElapsedRemaining(String elapsed, String remaining) {
    return '耗时: $elapsed秒, 剩余: $remaining秒';
  }

  @override
  String prevExporting(String pct, String frame, String total, String fps) {
    return '导出中 $pct%... ($frame/$total @ ${fps}fps)';
  }

  @override
  String get prevCancel => '取消';

  @override
  String get prevSelectVideoHint => '选视频后可调参';

  @override
  String get prevTrim => '裁剪';

  @override
  String get pvStatusInitial => '点「选视频」开始';

  @override
  String pvStatusNativeDirect(String size) {
    return '原生直出 (PlatformView) · out=$size';
  }

  @override
  String pvFailed(String detail) {
    return '失败: $detail';
  }

  @override
  String get pvTitle => '预览 PlatformView (dev)';

  @override
  String get pvNoVideo => '未选视频';

  @override
  String get pvPickVideo => '选视频';

  @override
  String get pvPause => '暂停';

  @override
  String get pvPlay => '播放';

  @override
  String get stabSection => '稳定';

  @override
  String get stabSmoothingMethod => '平滑方式';

  @override
  String get stabNone => '无平滑';

  @override
  String get stabDefault => '默认';

  @override
  String get stabPlain3D => '纯3D';

  @override
  String get stabFixedCamera => '固定摄像头';

  @override
  String get stabSmoothness => '平滑度';

  @override
  String get stabSmoothnessPitch => 'Pitch 平滑度';

  @override
  String get stabSmoothnessYaw => 'Yaw 平滑度';

  @override
  String get stabSmoothnessRoll => 'Roll 平滑度';

  @override
  String get stabFixedPitch => 'Pitch 角度';

  @override
  String get stabFixedYaw => 'Yaw 角度';

  @override
  String get stabFixedRoll => 'Roll 角度';

  @override
  String get stabAdvanced => '高级选项';

  @override
  String get stabPerAxis => '按轴';

  @override
  String get stabOnlyTrimRange => '仅限修剪范围内';

  @override
  String get stabMaxSmoothness => '最大平滑度';

  @override
  String get stabMaxSmoothnessHighVel => '高速最大平滑度';

  @override
  String get stabUnitSec => '秒';

  @override
  String get stabUnitMs => '毫秒';

  @override
  String get stabLockHorizon => '锁定地平线';

  @override
  String get stabLockAmount => '锁定量';

  @override
  String get stabRollAngleCorrection => 'Roll 角度校正';

  @override
  String stabMaxRotationZoom(
    String pitch,
    String yaw,
    String roll,
    String zoom,
  ) {
    return '最大旋转: Pitch $pitch°, Yaw $yaw°, Roll $roll°\n最大缩放: $zoom%';
  }

  @override
  String get stabNoZooming => '无缩放';

  @override
  String get stabDynamicZooming => '动态缩放';

  @override
  String get stabStaticZoom => '静态缩放';

  @override
  String get stabZoomLimit => '缩放限额';

  @override
  String get stabZoomingSpeed => '缩放速度';

  @override
  String get stabLensCorrection => '镜头校正';

  @override
  String get stabFov => '视场角';

  @override
  String get stabRollingShutter => '卷帘快门校正';

  @override
  String get stabFrameReadoutTime => '帧读出时间';

  @override
  String get stabVideoSpeed => '视频速度';

  @override
  String get stabZoomingMethod => '缩放方式';

  @override
  String get stabZoomLimitIterations => '缩放限额迭代次数';

  @override
  String get stabRestoredLoadedValues => '已恢复加载值';

  @override
  String get stabReadoutDirTopBottom => '上→下';

  @override
  String get stabReadoutDirBottomTop => '下→上';

  @override
  String get stabReadoutDirLeftRight => '左→右';

  @override
  String get stabReadoutDirRightLeft => '右→左';

  @override
  String stabFrameReadoutDirToast(String dir) {
    return '帧读出方向:$dir';
  }

  @override
  String get stabLinkSmoothing => '链接平滑';

  @override
  String get stabLinkZoomingSpeed => '链接缩放速度';

  @override
  String get stabLinkZoomingLimit => '链接缩放限制';

  @override
  String stabLinkToggleToast(String label, String state) {
    return '$label:$state';
  }

  @override
  String get stabEnabled => '已开启';

  @override
  String get stabDisabled => '已关闭';

  @override
  String get syncTitle => '同步';

  @override
  String get syncSyncing => '同步中…';

  @override
  String get syncAutoSync => '自动同步';

  @override
  String get syncRoughGyroOffset => '粗略大致偏移';

  @override
  String get syncUnitSeconds => '秒';

  @override
  String get syncSearchSize => '同步搜索尺寸';

  @override
  String get syncMaxSyncPoints => '最大同步点数';

  @override
  String get syncAdvanced => '高级选项';

  @override
  String get syncEveryNthFrame => '每 N 帧执行分析';

  @override
  String get syncTimePerSyncPoint => '每个同步点分析时长';

  @override
  String get syncProcessingResolution => '处理分辨率';

  @override
  String get syncResNative => '原生';

  @override
  String get syncOpticalFlowMethod => '光流方法';

  @override
  String get syncPoseMethod => '位姿方法';

  @override
  String get syncOffsetMethod => '偏移方法';

  @override
  String get syncOffsetEssentialMatrix => '本质矩阵';

  @override
  String get syncOffsetVisualFeatures => '视觉功能';

  @override
  String get syncOffsetRsSync => '卷帘快门同步';

  @override
  String get syncLowPassFilter => '低通滤波器';

  @override
  String get syncFilterValue => '滤波值';

  @override
  String get syncShowDetectedFeatures => '显示检测到的特性';

  @override
  String get syncShowOpticalFlow => '显示光流';

  @override
  String get expOutputSize => '输出大小';

  @override
  String get expSizeOriginal => '原始';

  @override
  String get expSizeProportional => '比例';

  @override
  String get expSelectVideoHint => '选视频后可设置导出';

  @override
  String get expTitle => '导出设置';

  @override
  String get expEncoder => '编码器';

  @override
  String get expBitrate => '比特率';

  @override
  String get expAudio => '导出音频';

  @override
  String get expOutputPath => '输出路径';

  @override
  String get expFileName => '文件名';

  @override
  String get expExport => '导出';

  @override
  String get expCancelExport => '取消导出';

  @override
  String get expNoSyncTitle => '不存在同步点';

  @override
  String get expNoSyncBody => '不存在同步点,您的结果将不正确。您确定要渲染此文件吗?';

  @override
  String get expYes => '是';

  @override
  String get expNo => '否';

  @override
  String get expSelectFolderTitle => '选择目标文件夹';

  @override
  String get expSelectFolderBody => '由于文件访问限制,您需要手动选择目标文件夹。\n点击确定并选择目标文件夹。';

  @override
  String get expRenderDoneTitle => '渲染完成';

  @override
  String expRenderDoneBody(String path) {
    return '文件已写入:$path';
  }

  @override
  String get expFailedTitle => '导出失败';

  @override
  String get expOk => '确定';

  @override
  String get expForegroundTitle => '保持前台';

  @override
  String get expForegroundBody => '将此 APP 保持在前台运行并不要锁定屏幕。\n受限于系统视频编码器,不支持后台渲染。';

  @override
  String get expDontShowAgain => '不再显示';

  @override
  String get pviewNoVideo => '未选视频';

  @override
  String pviewZoom(String value) {
    return '缩放: $value';
  }

  @override
  String ctlOutputSizeSet(String w, String h, String pw, String ph) {
    return '输出大小:$w×$h(预览 $pw×$ph)';
  }

  @override
  String ctlApplyOutputSizeFailed(String error) {
    return '应用输出大小失败:$error';
  }

  @override
  String get ctlSelectExportFolder => '请选择导出目录';

  @override
  String get ctlRootDir => '根目录';

  @override
  String get ctlInitializingExport => '正在初始化导出…';

  @override
  String ctlExportComplete(String path) {
    return '导出完成:$path';
  }

  @override
  String get ctlExportCancelled => '已取消导出';

  @override
  String ctlExportFailed(String error) {
    return '导出失败:$error';
  }

  @override
  String get ctlCancellingExport => '正在取消导出…';

  @override
  String get ctlStatusInitial => '在「输入」tab 打开文件开始';

  @override
  String get ctlBgSolid => '纯色';

  @override
  String get ctlBgRepeatEdge => '边缘拉伸';

  @override
  String get ctlBgMirrorEdge => '边缘镜像';

  @override
  String get ctlBgFeather => '羽化留边';

  @override
  String get ctlNoLensProfile => '未加载镜头档案';

  @override
  String ctlBackend(String label) {
    return '后端:$label';
  }

  @override
  String ctlFailed(String error) {
    return '失败:$error';
  }

  @override
  String ctlNoSidecarFound(String base) {
    return '目录里未找到匹配「$base」的 sidecar';
  }

  @override
  String get ctlFolderSidecarLoaded => '已加载目录 sidecar';

  @override
  String ctlFolderAuthFailed(String error) {
    return '目录授权失败:$error';
  }

  @override
  String get ctlLensLoaded => '✓ 已加载镜头档案';

  @override
  String ctlLensLoadFailed(String error) {
    return '镜头加载失败:$error';
  }

  @override
  String get ctlMotionLoaded => '✓ 已加载运动数据';

  @override
  String ctlMotionLoadFailed(String error) {
    return '运动数据加载失败:$error';
  }

  @override
  String ctlMotionReloadFailed(String error) {
    return '重载运动数据失败:$error';
  }

  @override
  String get ctlAutosyncing => '自动同步中…';

  @override
  String ctlAutosyncFailed(String error) {
    return '自动同步失败:$error';
  }

  @override
  String get ctlAutosyncNeedLens => '需先加载镜头档案才能自动同步';

  @override
  String ctlAutosyncComplete(String count, String ms) {
    return '自动同步完成($count 个同步点,中位偏移 $ms ms)';
  }

  @override
  String get ctlAutosyncNoOffset => '自动同步未找到偏移';

  @override
  String get ctlLensWrongType => '请选择 .json 镜头档案';

  @override
  String get ctlMotionWrongType => '请选择运动数据文件 (.gcsv/.bbl/.bfl/.csv)';

  @override
  String get inputVideoInfo => '视频信息';

  @override
  String get inputOpenFile => '打开文件';

  @override
  String get inputNone => '无';

  @override
  String get inputFileName => '文件名称';

  @override
  String get inputDetectedCamera => '检测到的相机';

  @override
  String get inputDetectedLens => '检测镜头';

  @override
  String get inputDimensions => '尺寸';

  @override
  String get inputDuration => '时长';

  @override
  String get inputFrameRate => '帧速率';

  @override
  String get inputCodec => '编码解码器';

  @override
  String get inputPixelFormat => '像素格式';

  @override
  String get inputAudio => '音频';

  @override
  String get inputRotation => '旋转';

  @override
  String get inputContainsGyro => '包含陀螺仪数据';

  @override
  String get inputDirHint => '为检测项目文件、视频序列或图像序列，请点击此处选择带有输入文件的目录。';

  @override
  String get inputLensMismatch => '镜头配置文件的尺寸与当前文件不符。结果看起来可能会不正确。';

  @override
  String get inputLensAspectMismatch => '镜头配置文件的宽高比与当前文件不符。结果看起来可能会不正确。';

  @override
  String get inputLensNotLoaded => '镜头配置文件并未加载,结果看起来可能会不正确。请为您的相机加载镜头配置文件。';

  @override
  String get inputLensProfile => '镜头配置文件';

  @override
  String get inputSearchLens => '搜索镜头…';

  @override
  String get inputAdvanced => '高级';

  @override
  String get inputUnderwaterLens => '水下镜头';

  @override
  String get inputPixelFocalLength => '像素焦距';

  @override
  String get inputFocalCenter => '聚焦中心';

  @override
  String get inputDistortionCoeffs => '畸变系数';

  @override
  String get inputMotionData => '运动数据';

  @override
  String get inputDetectedFormat => '检测到的格式';

  @override
  String get inputLoadAllMetadata => '加载全部元数据';

  @override
  String get inputOrientationIndicator => '方向指示器';

  @override
  String get inputFrameOffset => '帧偏移';

  @override
  String get inputUnitFrames => '帧';

  @override
  String get inputLowPassFilter => '低通滤波器';

  @override
  String get inputGyroBias => '陀螺仪偏差';

  @override
  String get inputIntegrationMethod => '积分方法';

  @override
  String get inputImuOrientation => 'IMU 朝向';

  @override
  String get inputLensCamera => '相机';

  @override
  String get inputLensLens => '镜头';

  @override
  String get inputLensSetting => '设置';

  @override
  String get inputLensNote => '其他信息';

  @override
  String get inputLensDimensions => '尺寸';

  @override
  String get inputLensCalibratedBy => '校准人';

  @override
  String get inputRsFocalLength => '焦距';

  @override
  String get inputRsFocusMode => '对焦模式';

  @override
  String get inputRsIris => '光圈';

  @override
  String get inputRsIso => 'ISO';

  @override
  String get inputRsShutterAngle => '快门角';

  @override
  String get inputRsShutterSpeed => '快门速度';

  @override
  String get inputRsExposure => '曝光度';

  @override
  String get inputRsWhiteBalanceMode => '白平衡模式';

  @override
  String get inputRsWhiteBalance => '白平衡';

  @override
  String get inputRsColorPrimaries => '基色';

  @override
  String get inputRsGammaEquation => '伽玛方程';
}
