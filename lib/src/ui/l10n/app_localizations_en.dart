// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String homeSmokeFailedPlatform(String code, String message) {
    return 'Smoke test failed: $code $message';
  }

  @override
  String homeSmokeFailed(String error) {
    return 'Smoke test failed: $error';
  }

  @override
  String get homePreviewTexture => 'Preview Texture spike (dev)';

  @override
  String get homePreviewPlatformView => 'Preview PlatformView (dev)';

  @override
  String get prevLoadingVideo => 'Loading video…';

  @override
  String prevSwitchTo(String backend) {
    return 'Switch to $backend';
  }

  @override
  String get prevPause => 'Pause';

  @override
  String get prevPlay => 'Play';

  @override
  String get prevStabOverview => 'Stabilization overview';

  @override
  String get prevStabilization => 'Stabilization';

  @override
  String get prevEnableOverviewHint =>
      'Enable stabilization overview for a better preview';

  @override
  String get prevTabInput => 'Inputs';

  @override
  String get prevTabParams => 'Parameters';

  @override
  String get prevTabExport => 'Export';

  @override
  String prevAnalyzing(String pct, String ready, String total, String fps) {
    return 'Analyzing $pct%... ($ready/$total @ ${fps}fps)';
  }

  @override
  String prevElapsedRemaining(String elapsed, String remaining) {
    return 'Elapsed: ${elapsed}s, Remaining: ${remaining}s';
  }

  @override
  String prevExporting(String pct, String frame, String total, String fps) {
    return 'Exporting $pct%... ($frame/$total @ ${fps}fps)';
  }

  @override
  String get prevCancel => 'Cancel';

  @override
  String get prevSelectVideoHint => 'Select a video to adjust parameters';

  @override
  String get prevTrim => 'Trim';

  @override
  String get pvStatusInitial => 'Tap \'Pick Video\' to start';

  @override
  String pvStatusNativeDirect(String size) {
    return 'Native direct (PlatformView) · out=$size';
  }

  @override
  String pvFailed(String detail) {
    return 'Failed: $detail';
  }

  @override
  String get pvTitle => 'Preview PlatformView (dev)';

  @override
  String get pvNoVideo => 'No video selected';

  @override
  String get pvPickVideo => 'Pick Video';

  @override
  String get pvPause => 'Pause';

  @override
  String get pvPlay => 'Play';

  @override
  String get stabSection => 'Stabilization';

  @override
  String get stabSmoothingMethod => 'Smoothing method';

  @override
  String get stabNone => 'No smoothing';

  @override
  String get stabDefault => 'Default';

  @override
  String get stabPlain3D => 'Plain 3D';

  @override
  String get stabFixedCamera => 'Fixed camera';

  @override
  String get stabSmoothness => 'Smoothness';

  @override
  String get stabSmoothnessPitch => 'Pitch smoothness';

  @override
  String get stabSmoothnessYaw => 'Yaw smoothness';

  @override
  String get stabSmoothnessRoll => 'Roll smoothness';

  @override
  String get stabFixedPitch => 'Pitch angle';

  @override
  String get stabFixedYaw => 'Yaw angle';

  @override
  String get stabFixedRoll => 'Roll angle';

  @override
  String get stabAdvanced => 'Advanced';

  @override
  String get stabPerAxis => 'Per axis';

  @override
  String get stabOnlyTrimRange => 'Only within trim range';

  @override
  String get stabMaxSmoothness => 'Max smoothness';

  @override
  String get stabMaxSmoothnessHighVel => 'Max smoothness at high velocity';

  @override
  String get stabUnitSec => 's';

  @override
  String get stabUnitMs => 'ms';

  @override
  String get stabLockHorizon => 'Lock horizon';

  @override
  String get stabLockAmount => 'Lock amount';

  @override
  String get stabRollAngleCorrection => 'Roll angle correction';

  @override
  String stabMaxRotationZoom(
    String pitch,
    String yaw,
    String roll,
    String zoom,
  ) {
    return 'Max rotation: Pitch $pitch°, Yaw $yaw°, Roll $roll°\nMax zoom: $zoom%';
  }

  @override
  String get stabNoZooming => 'No zooming';

  @override
  String get stabDynamicZooming => 'Dynamic zooming';

  @override
  String get stabStaticZoom => 'Static zoom';

  @override
  String get stabZoomLimit => 'Zoom limit';

  @override
  String get stabZoomingSpeed => 'Zooming speed';

  @override
  String get stabLensCorrection => 'Lens correction';

  @override
  String get stabFov => 'FOV';

  @override
  String get stabRollingShutter => 'Rolling shutter correction';

  @override
  String get stabFrameReadoutTime => 'Frame readout time';

  @override
  String get stabVideoSpeed => 'Video speed';

  @override
  String get stabZoomingMethod => 'Zooming method';

  @override
  String get stabZoomLimitIterations => 'Zoom limit iterations';

  @override
  String get stabRestoredLoadedValues => 'Restored loaded values';

  @override
  String get stabReadoutDirTopBottom => 'Top to bottom';

  @override
  String get stabReadoutDirBottomTop => 'Bottom to top';

  @override
  String get stabReadoutDirLeftRight => 'Left to right';

  @override
  String get stabReadoutDirRightLeft => 'Right to left';

  @override
  String stabFrameReadoutDirToast(String dir) {
    return 'Frame readout direction: $dir';
  }

  @override
  String get stabLinkSmoothing => 'Link with smoothing';

  @override
  String get stabLinkZoomingSpeed => 'Link with zooming speed';

  @override
  String get stabLinkZoomingLimit => 'Link with zooming limit';

  @override
  String stabLinkToggleToast(String label, String state) {
    return '$label: $state';
  }

  @override
  String get stabEnabled => 'Enabled';

  @override
  String get stabDisabled => 'Disabled';

  @override
  String get syncTitle => 'Synchronization';

  @override
  String get syncSyncing => 'Syncing…';

  @override
  String get syncAutoSync => 'Auto sync';

  @override
  String get syncRoughGyroOffset => 'Rough gyro offset';

  @override
  String get syncUnitSeconds => 's';

  @override
  String get syncSearchSize => 'Sync search size';

  @override
  String get syncMaxSyncPoints => 'Max sync points';

  @override
  String get syncAdvanced => 'Advanced';

  @override
  String get syncEveryNthFrame => 'Analyze every n-th frame';

  @override
  String get syncTimePerSyncPoint => 'Time to analyze per sync point';

  @override
  String get syncProcessingResolution => 'Processing resolution';

  @override
  String get syncResNative => 'Native';

  @override
  String get syncOpticalFlowMethod => 'Optical flow method';

  @override
  String get syncPoseMethod => 'Pose method';

  @override
  String get syncOffsetMethod => 'Offset method';

  @override
  String get syncOffsetEssentialMatrix => 'Essential matrix';

  @override
  String get syncOffsetVisualFeatures => 'Visual features';

  @override
  String get syncOffsetRsSync => 'rs-sync';

  @override
  String get syncLowPassFilter => 'Low pass filter';

  @override
  String get syncFilterValue => 'Filter value';

  @override
  String get syncShowDetectedFeatures => 'Show detected features';

  @override
  String get syncShowOpticalFlow => 'Show optical flow';

  @override
  String get expOutputSize => 'Output size';

  @override
  String get expSizeOriginal => 'Original';

  @override
  String get expSizeProportional => 'Proportional';

  @override
  String get expSelectVideoHint => 'Select a video to configure export';

  @override
  String get expTitle => 'Export settings';

  @override
  String get expEncoder => 'Encoder';

  @override
  String get expBitrate => 'Bitrate';

  @override
  String get expAudio => 'Export audio';

  @override
  String get expOutputPath => 'Output path';

  @override
  String get expFileName => 'File name';

  @override
  String get expExport => 'Export';

  @override
  String get expCancelExport => 'Cancel export';

  @override
  String get expNoSyncTitle => 'No sync points';

  @override
  String get expNoSyncBody =>
      'There are no sync points present, your result will be incorrect. Are you sure you want to render this file?';

  @override
  String get expYes => 'Yes';

  @override
  String get expNo => 'No';

  @override
  String get expSelectFolderTitle => 'Select destination folder';

  @override
  String get expSelectFolderBody =>
      'Due to file access restrictions, you need to select the destination folder manually.\nClick Ok and select the destination folder.';

  @override
  String get expRenderDoneTitle => 'Rendering completed';

  @override
  String expRenderDoneBody(String path) {
    return 'The file was written to: $path';
  }

  @override
  String get expFailedTitle => 'Export failed';

  @override
  String get expOk => 'Ok';

  @override
  String get expForegroundTitle => 'Keep in foreground';

  @override
  String get expForegroundBody =>
      'Keep this app in the foreground and don\'t lock the screen.\nDue to limitations of the system video encoders, rendering in the background is not supported.';

  @override
  String get expDontShowAgain => 'Don\'t show again';

  @override
  String get pviewNoVideo => 'No video selected';

  @override
  String pviewZoom(String value) {
    return 'Zoom: $value';
  }

  @override
  String ctlOutputSizeSet(String w, String h, String pw, String ph) {
    return 'Output size: $w×$h (preview $pw×$ph)';
  }

  @override
  String ctlApplyOutputSizeFailed(String error) {
    return 'Failed to apply output size: $error';
  }

  @override
  String get ctlSelectExportFolder => 'Select export folder';

  @override
  String get ctlRootDir => 'Root directory';

  @override
  String get ctlInitializingExport => 'Initializing export…';

  @override
  String ctlExportComplete(String path) {
    return 'Export complete: $path';
  }

  @override
  String get ctlExportCancelled => 'Export cancelled';

  @override
  String ctlExportFailed(String error) {
    return 'Export failed: $error';
  }

  @override
  String get ctlCancellingExport => 'Cancelling export…';

  @override
  String get ctlStatusInitial => 'Open a file in the Inputs tab to start';

  @override
  String get ctlBgSolid => 'Solid color';

  @override
  String get ctlBgRepeatEdge => 'Repeat edge pixels';

  @override
  String get ctlBgMirrorEdge => 'Mirror edge pixels';

  @override
  String get ctlBgFeather => 'Margin with feather';

  @override
  String get ctlNoLensProfile => 'No lens profile loaded';

  @override
  String ctlBackend(String label) {
    return 'Backend: $label';
  }

  @override
  String ctlFailed(String error) {
    return 'Failed: $error';
  }

  @override
  String ctlNoSidecarFound(String base) {
    return 'No sidecar matching \"$base\" found in folder';
  }

  @override
  String get ctlFolderSidecarLoaded => 'Folder sidecar loaded';

  @override
  String ctlFolderAuthFailed(String error) {
    return 'Folder authorization failed: $error';
  }

  @override
  String get ctlLensLoaded => '✓ Lens profile loaded';

  @override
  String ctlLensLoadFailed(String error) {
    return 'Failed to load lens profile: $error';
  }

  @override
  String get ctlMotionLoaded => '✓ Motion data loaded';

  @override
  String ctlMotionLoadFailed(String error) {
    return 'Failed to load motion data: $error';
  }

  @override
  String ctlMotionReloadFailed(String error) {
    return 'Failed to reload motion data: $error';
  }

  @override
  String get ctlAutosyncing => 'Auto syncing…';

  @override
  String ctlAutosyncFailed(String error) {
    return 'Auto sync failed: $error';
  }

  @override
  String get ctlAutosyncNeedLens => 'Load a lens profile before auto sync';

  @override
  String ctlAutosyncComplete(String count, String ms) {
    return 'Auto sync complete ($count sync points, median offset $ms ms)';
  }

  @override
  String get ctlAutosyncNoOffset => 'Auto sync found no offset';

  @override
  String get ctlLensWrongType => 'Please select a .json lens profile';

  @override
  String get ctlMotionWrongType =>
      'Please select a motion file (.gcsv/.bbl/.bfl/.csv)';

  @override
  String get inputVideoInfo => 'Video information';

  @override
  String get inputOpenFile => 'Open file';

  @override
  String get inputNone => 'None';

  @override
  String get inputFileName => 'File name';

  @override
  String get inputDetectedCamera => 'Detected camera';

  @override
  String get inputDetectedLens => 'Detected lens';

  @override
  String get inputDimensions => 'Dimensions';

  @override
  String get inputDuration => 'Duration';

  @override
  String get inputFrameRate => 'Frame rate';

  @override
  String get inputCodec => 'Codec';

  @override
  String get inputPixelFormat => 'Pixel format';

  @override
  String get inputAudio => 'Audio';

  @override
  String get inputRotation => 'Rotation';

  @override
  String get inputContainsGyro => 'Contains gyro';

  @override
  String get inputDirHint =>
      'In order to detect project files, video sequences or image sequences, click here and select the directory with input files.';

  @override
  String get inputLensMismatch =>
      'Lens profile dimensions don\'t match the file dimensions. The result may not look correct.';

  @override
  String get inputLensAspectMismatch =>
      'Lens profile aspect ratio doesn\'t match the file aspect ratio. The result will not look correct.';

  @override
  String get inputLensNotLoaded =>
      'Lens profile is not loaded, the results will not look correct. Please load a lens profile for your camera.';

  @override
  String get inputLensProfile => 'Lens profile';

  @override
  String get inputSearchLens => 'Search...';

  @override
  String get inputAdvanced => 'Advanced';

  @override
  String get inputUnderwaterLens => 'Lens is under water';

  @override
  String get inputPixelFocalLength => 'Pixel focal length';

  @override
  String get inputFocalCenter => 'Focal center';

  @override
  String get inputDistortionCoeffs => 'Distortion coefficients';

  @override
  String get inputMotionData => 'Motion data';

  @override
  String get inputDetectedFormat => 'Detected format';

  @override
  String get inputLoadAllMetadata => 'Load all metadata';

  @override
  String get inputOrientationIndicator => 'Orientation indicator';

  @override
  String get inputFrameOffset => 'Frame offset';

  @override
  String get inputUnitFrames => 'frames';

  @override
  String get inputLowPassFilter => 'Low pass filter';

  @override
  String get inputGyroBias => 'Gyro bias';

  @override
  String get inputIntegrationMethod => 'Integration method';

  @override
  String get inputImuOrientation => 'IMU orientation';

  @override
  String get inputLensCamera => 'Camera';

  @override
  String get inputLensLens => 'Lens';

  @override
  String get inputLensSetting => 'Setting';

  @override
  String get inputLensNote => 'Additional info';

  @override
  String get inputLensDimensions => 'Dimensions';

  @override
  String get inputLensCalibratedBy => 'Calibrated by';

  @override
  String get inputRsFocalLength => 'Focal length';

  @override
  String get inputRsFocusMode => 'Focus mode';

  @override
  String get inputRsIris => 'Iris';

  @override
  String get inputRsIso => 'ISO';

  @override
  String get inputRsShutterAngle => 'Shutter angle';

  @override
  String get inputRsShutterSpeed => 'Shutter speed';

  @override
  String get inputRsExposure => 'Exposure';

  @override
  String get inputRsWhiteBalanceMode => 'White balance mode';

  @override
  String get inputRsWhiteBalance => 'White balance';

  @override
  String get inputRsColorPrimaries => 'Color primaries';

  @override
  String get inputRsGammaEquation => 'Gamma equation';
}
