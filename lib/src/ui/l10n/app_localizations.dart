import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
  ];

  /// No description provided for @homeOpenGyroflow.
  ///
  /// In en, this message translates to:
  /// **'Open Gyroflow Stabilization'**
  String get homeOpenGyroflow;

  /// No description provided for @homeOpenFailed.
  ///
  /// In en, this message translates to:
  /// **'Open failed: {code} {message}'**
  String homeOpenFailed(String code, String message);

  /// No description provided for @homeSmokeFailedPlatform.
  ///
  /// In en, this message translates to:
  /// **'Smoke test failed: {code} {message}'**
  String homeSmokeFailedPlatform(String code, String message);

  /// No description provided for @homeSmokeFailed.
  ///
  /// In en, this message translates to:
  /// **'Smoke test failed: {error}'**
  String homeSmokeFailed(String error);

  /// No description provided for @homePreviewTexture.
  ///
  /// In en, this message translates to:
  /// **'Preview Texture spike (dev)'**
  String get homePreviewTexture;

  /// No description provided for @homePreviewPlatformView.
  ///
  /// In en, this message translates to:
  /// **'Preview PlatformView (dev)'**
  String get homePreviewPlatformView;

  /// No description provided for @prevLoadingVideo.
  ///
  /// In en, this message translates to:
  /// **'Loading video…'**
  String get prevLoadingVideo;

  /// No description provided for @prevSwitchTo.
  ///
  /// In en, this message translates to:
  /// **'Switch to {backend}'**
  String prevSwitchTo(String backend);

  /// No description provided for @prevPause.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get prevPause;

  /// No description provided for @prevPlay.
  ///
  /// In en, this message translates to:
  /// **'Play'**
  String get prevPlay;

  /// No description provided for @prevStabOverview.
  ///
  /// In en, this message translates to:
  /// **'Stabilization overview'**
  String get prevStabOverview;

  /// No description provided for @prevStabilization.
  ///
  /// In en, this message translates to:
  /// **'Stabilization'**
  String get prevStabilization;

  /// No description provided for @prevEnableOverviewHint.
  ///
  /// In en, this message translates to:
  /// **'Enable stabilization overview for a better preview'**
  String get prevEnableOverviewHint;

  /// No description provided for @prevTabInput.
  ///
  /// In en, this message translates to:
  /// **'Inputs'**
  String get prevTabInput;

  /// No description provided for @prevTabParams.
  ///
  /// In en, this message translates to:
  /// **'Parameters'**
  String get prevTabParams;

  /// No description provided for @prevTabExport.
  ///
  /// In en, this message translates to:
  /// **'Export'**
  String get prevTabExport;

  /// No description provided for @prevAnalyzing.
  ///
  /// In en, this message translates to:
  /// **'Analyzing {pct}%... ({ready}/{total} @ {fps}fps)'**
  String prevAnalyzing(String pct, String ready, String total, String fps);

  /// No description provided for @prevElapsedRemaining.
  ///
  /// In en, this message translates to:
  /// **'Elapsed: {elapsed}s, Remaining: {remaining}s'**
  String prevElapsedRemaining(String elapsed, String remaining);

  /// No description provided for @prevExporting.
  ///
  /// In en, this message translates to:
  /// **'Exporting {pct}%... ({frame}/{total} @ {fps}fps)'**
  String prevExporting(String pct, String frame, String total, String fps);

  /// No description provided for @prevCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get prevCancel;

  /// No description provided for @prevSelectVideoHint.
  ///
  /// In en, this message translates to:
  /// **'Select a video to adjust parameters'**
  String get prevSelectVideoHint;

  /// No description provided for @prevTrim.
  ///
  /// In en, this message translates to:
  /// **'Trim'**
  String get prevTrim;

  /// No description provided for @pvStatusInitial.
  ///
  /// In en, this message translates to:
  /// **'Tap \'Pick Video\' to start'**
  String get pvStatusInitial;

  /// No description provided for @pvStatusNativeDirect.
  ///
  /// In en, this message translates to:
  /// **'Native direct (PlatformView) · out={size}'**
  String pvStatusNativeDirect(String size);

  /// No description provided for @pvFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed: {detail}'**
  String pvFailed(String detail);

  /// No description provided for @pvTitle.
  ///
  /// In en, this message translates to:
  /// **'Preview PlatformView (dev)'**
  String get pvTitle;

  /// No description provided for @pvNoVideo.
  ///
  /// In en, this message translates to:
  /// **'No video selected'**
  String get pvNoVideo;

  /// No description provided for @pvPickVideo.
  ///
  /// In en, this message translates to:
  /// **'Pick Video'**
  String get pvPickVideo;

  /// No description provided for @pvPause.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get pvPause;

  /// No description provided for @pvPlay.
  ///
  /// In en, this message translates to:
  /// **'Play'**
  String get pvPlay;

  /// No description provided for @stabSection.
  ///
  /// In en, this message translates to:
  /// **'Stabilization'**
  String get stabSection;

  /// No description provided for @stabSmoothingMethod.
  ///
  /// In en, this message translates to:
  /// **'Smoothing method'**
  String get stabSmoothingMethod;

  /// No description provided for @stabNone.
  ///
  /// In en, this message translates to:
  /// **'No smoothing'**
  String get stabNone;

  /// No description provided for @stabDefault.
  ///
  /// In en, this message translates to:
  /// **'Default'**
  String get stabDefault;

  /// No description provided for @stabPlain3D.
  ///
  /// In en, this message translates to:
  /// **'Plain 3D'**
  String get stabPlain3D;

  /// No description provided for @stabFixedCamera.
  ///
  /// In en, this message translates to:
  /// **'Fixed camera'**
  String get stabFixedCamera;

  /// No description provided for @stabSmoothness.
  ///
  /// In en, this message translates to:
  /// **'Smoothness'**
  String get stabSmoothness;

  /// No description provided for @stabSmoothnessPitch.
  ///
  /// In en, this message translates to:
  /// **'Pitch smoothness'**
  String get stabSmoothnessPitch;

  /// No description provided for @stabSmoothnessYaw.
  ///
  /// In en, this message translates to:
  /// **'Yaw smoothness'**
  String get stabSmoothnessYaw;

  /// No description provided for @stabSmoothnessRoll.
  ///
  /// In en, this message translates to:
  /// **'Roll smoothness'**
  String get stabSmoothnessRoll;

  /// No description provided for @stabFixedPitch.
  ///
  /// In en, this message translates to:
  /// **'Pitch angle'**
  String get stabFixedPitch;

  /// No description provided for @stabFixedYaw.
  ///
  /// In en, this message translates to:
  /// **'Yaw angle'**
  String get stabFixedYaw;

  /// No description provided for @stabFixedRoll.
  ///
  /// In en, this message translates to:
  /// **'Roll angle'**
  String get stabFixedRoll;

  /// No description provided for @stabAdvanced.
  ///
  /// In en, this message translates to:
  /// **'Advanced'**
  String get stabAdvanced;

  /// No description provided for @stabPerAxis.
  ///
  /// In en, this message translates to:
  /// **'Per axis'**
  String get stabPerAxis;

  /// No description provided for @stabOnlyTrimRange.
  ///
  /// In en, this message translates to:
  /// **'Only within trim range'**
  String get stabOnlyTrimRange;

  /// No description provided for @stabMaxSmoothness.
  ///
  /// In en, this message translates to:
  /// **'Max smoothness'**
  String get stabMaxSmoothness;

  /// No description provided for @stabMaxSmoothnessHighVel.
  ///
  /// In en, this message translates to:
  /// **'Max smoothness at high velocity'**
  String get stabMaxSmoothnessHighVel;

  /// No description provided for @stabUnitSec.
  ///
  /// In en, this message translates to:
  /// **'s'**
  String get stabUnitSec;

  /// No description provided for @stabUnitMs.
  ///
  /// In en, this message translates to:
  /// **'ms'**
  String get stabUnitMs;

  /// No description provided for @stabLockHorizon.
  ///
  /// In en, this message translates to:
  /// **'Lock horizon'**
  String get stabLockHorizon;

  /// No description provided for @stabLockAmount.
  ///
  /// In en, this message translates to:
  /// **'Lock amount'**
  String get stabLockAmount;

  /// No description provided for @stabRollAngleCorrection.
  ///
  /// In en, this message translates to:
  /// **'Roll angle correction'**
  String get stabRollAngleCorrection;

  /// No description provided for @stabMaxRotationZoom.
  ///
  /// In en, this message translates to:
  /// **'Max rotation: Pitch {pitch}°, Yaw {yaw}°, Roll {roll}°\nMax zoom: {zoom}%'**
  String stabMaxRotationZoom(
    String pitch,
    String yaw,
    String roll,
    String zoom,
  );

  /// No description provided for @stabNoZooming.
  ///
  /// In en, this message translates to:
  /// **'No zooming'**
  String get stabNoZooming;

  /// No description provided for @stabDynamicZooming.
  ///
  /// In en, this message translates to:
  /// **'Dynamic zooming'**
  String get stabDynamicZooming;

  /// No description provided for @stabStaticZoom.
  ///
  /// In en, this message translates to:
  /// **'Static zoom'**
  String get stabStaticZoom;

  /// No description provided for @stabZoomLimit.
  ///
  /// In en, this message translates to:
  /// **'Zoom limit'**
  String get stabZoomLimit;

  /// No description provided for @stabZoomingSpeed.
  ///
  /// In en, this message translates to:
  /// **'Zooming speed'**
  String get stabZoomingSpeed;

  /// No description provided for @stabLensCorrection.
  ///
  /// In en, this message translates to:
  /// **'Lens correction'**
  String get stabLensCorrection;

  /// No description provided for @stabFov.
  ///
  /// In en, this message translates to:
  /// **'FOV'**
  String get stabFov;

  /// No description provided for @stabRollingShutter.
  ///
  /// In en, this message translates to:
  /// **'Rolling shutter correction'**
  String get stabRollingShutter;

  /// No description provided for @stabFrameReadoutTime.
  ///
  /// In en, this message translates to:
  /// **'Frame readout time'**
  String get stabFrameReadoutTime;

  /// No description provided for @stabVideoSpeed.
  ///
  /// In en, this message translates to:
  /// **'Video speed'**
  String get stabVideoSpeed;

  /// No description provided for @stabZoomingMethod.
  ///
  /// In en, this message translates to:
  /// **'Zooming method'**
  String get stabZoomingMethod;

  /// No description provided for @stabZoomLimitIterations.
  ///
  /// In en, this message translates to:
  /// **'Zoom limit iterations'**
  String get stabZoomLimitIterations;

  /// No description provided for @stabRestoredLoadedValues.
  ///
  /// In en, this message translates to:
  /// **'Restored loaded values'**
  String get stabRestoredLoadedValues;

  /// No description provided for @stabReadoutDirTopBottom.
  ///
  /// In en, this message translates to:
  /// **'Top to bottom'**
  String get stabReadoutDirTopBottom;

  /// No description provided for @stabReadoutDirBottomTop.
  ///
  /// In en, this message translates to:
  /// **'Bottom to top'**
  String get stabReadoutDirBottomTop;

  /// No description provided for @stabReadoutDirLeftRight.
  ///
  /// In en, this message translates to:
  /// **'Left to right'**
  String get stabReadoutDirLeftRight;

  /// No description provided for @stabReadoutDirRightLeft.
  ///
  /// In en, this message translates to:
  /// **'Right to left'**
  String get stabReadoutDirRightLeft;

  /// No description provided for @stabFrameReadoutDirToast.
  ///
  /// In en, this message translates to:
  /// **'Frame readout direction: {dir}'**
  String stabFrameReadoutDirToast(String dir);

  /// No description provided for @stabLinkSmoothing.
  ///
  /// In en, this message translates to:
  /// **'Link with smoothing'**
  String get stabLinkSmoothing;

  /// No description provided for @stabLinkZoomingSpeed.
  ///
  /// In en, this message translates to:
  /// **'Link with zooming speed'**
  String get stabLinkZoomingSpeed;

  /// No description provided for @stabLinkZoomingLimit.
  ///
  /// In en, this message translates to:
  /// **'Link with zooming limit'**
  String get stabLinkZoomingLimit;

  /// No description provided for @stabLinkToggleToast.
  ///
  /// In en, this message translates to:
  /// **'{label}: {state}'**
  String stabLinkToggleToast(String label, String state);

  /// No description provided for @stabEnabled.
  ///
  /// In en, this message translates to:
  /// **'Enabled'**
  String get stabEnabled;

  /// No description provided for @stabDisabled.
  ///
  /// In en, this message translates to:
  /// **'Disabled'**
  String get stabDisabled;

  /// No description provided for @syncTitle.
  ///
  /// In en, this message translates to:
  /// **'Synchronization'**
  String get syncTitle;

  /// No description provided for @syncSyncing.
  ///
  /// In en, this message translates to:
  /// **'Syncing…'**
  String get syncSyncing;

  /// No description provided for @syncAutoSync.
  ///
  /// In en, this message translates to:
  /// **'Auto sync'**
  String get syncAutoSync;

  /// No description provided for @syncRoughGyroOffset.
  ///
  /// In en, this message translates to:
  /// **'Rough gyro offset'**
  String get syncRoughGyroOffset;

  /// No description provided for @syncUnitSeconds.
  ///
  /// In en, this message translates to:
  /// **'s'**
  String get syncUnitSeconds;

  /// No description provided for @syncSearchSize.
  ///
  /// In en, this message translates to:
  /// **'Sync search size'**
  String get syncSearchSize;

  /// No description provided for @syncMaxSyncPoints.
  ///
  /// In en, this message translates to:
  /// **'Max sync points'**
  String get syncMaxSyncPoints;

  /// No description provided for @syncAdvanced.
  ///
  /// In en, this message translates to:
  /// **'Advanced'**
  String get syncAdvanced;

  /// No description provided for @syncEveryNthFrame.
  ///
  /// In en, this message translates to:
  /// **'Analyze every n-th frame'**
  String get syncEveryNthFrame;

  /// No description provided for @syncTimePerSyncPoint.
  ///
  /// In en, this message translates to:
  /// **'Time to analyze per sync point'**
  String get syncTimePerSyncPoint;

  /// No description provided for @syncProcessingResolution.
  ///
  /// In en, this message translates to:
  /// **'Processing resolution'**
  String get syncProcessingResolution;

  /// No description provided for @syncResNative.
  ///
  /// In en, this message translates to:
  /// **'Native'**
  String get syncResNative;

  /// No description provided for @syncOpticalFlowMethod.
  ///
  /// In en, this message translates to:
  /// **'Optical flow method'**
  String get syncOpticalFlowMethod;

  /// No description provided for @syncPoseMethod.
  ///
  /// In en, this message translates to:
  /// **'Pose method'**
  String get syncPoseMethod;

  /// No description provided for @syncOffsetMethod.
  ///
  /// In en, this message translates to:
  /// **'Offset method'**
  String get syncOffsetMethod;

  /// No description provided for @syncOffsetEssentialMatrix.
  ///
  /// In en, this message translates to:
  /// **'Essential matrix'**
  String get syncOffsetEssentialMatrix;

  /// No description provided for @syncOffsetVisualFeatures.
  ///
  /// In en, this message translates to:
  /// **'Visual features'**
  String get syncOffsetVisualFeatures;

  /// No description provided for @syncOffsetRsSync.
  ///
  /// In en, this message translates to:
  /// **'rs-sync'**
  String get syncOffsetRsSync;

  /// No description provided for @syncLowPassFilter.
  ///
  /// In en, this message translates to:
  /// **'Low pass filter'**
  String get syncLowPassFilter;

  /// No description provided for @syncFilterValue.
  ///
  /// In en, this message translates to:
  /// **'Filter value'**
  String get syncFilterValue;

  /// No description provided for @syncShowDetectedFeatures.
  ///
  /// In en, this message translates to:
  /// **'Show detected features'**
  String get syncShowDetectedFeatures;

  /// No description provided for @syncShowOpticalFlow.
  ///
  /// In en, this message translates to:
  /// **'Show optical flow'**
  String get syncShowOpticalFlow;

  /// No description provided for @expOutputSize.
  ///
  /// In en, this message translates to:
  /// **'Output size'**
  String get expOutputSize;

  /// No description provided for @expSizeOriginal.
  ///
  /// In en, this message translates to:
  /// **'Original'**
  String get expSizeOriginal;

  /// No description provided for @expSizeProportional.
  ///
  /// In en, this message translates to:
  /// **'Proportional'**
  String get expSizeProportional;

  /// No description provided for @expSelectVideoHint.
  ///
  /// In en, this message translates to:
  /// **'Select a video to configure export'**
  String get expSelectVideoHint;

  /// No description provided for @expTitle.
  ///
  /// In en, this message translates to:
  /// **'Export settings'**
  String get expTitle;

  /// No description provided for @expEncoder.
  ///
  /// In en, this message translates to:
  /// **'Encoder'**
  String get expEncoder;

  /// No description provided for @expBitrate.
  ///
  /// In en, this message translates to:
  /// **'Bitrate'**
  String get expBitrate;

  /// No description provided for @expAudio.
  ///
  /// In en, this message translates to:
  /// **'Export audio'**
  String get expAudio;

  /// No description provided for @expOutputPath.
  ///
  /// In en, this message translates to:
  /// **'Output path'**
  String get expOutputPath;

  /// No description provided for @expFileName.
  ///
  /// In en, this message translates to:
  /// **'File name'**
  String get expFileName;

  /// No description provided for @expExport.
  ///
  /// In en, this message translates to:
  /// **'Export'**
  String get expExport;

  /// No description provided for @expCancelExport.
  ///
  /// In en, this message translates to:
  /// **'Cancel export'**
  String get expCancelExport;

  /// No description provided for @expNoSyncTitle.
  ///
  /// In en, this message translates to:
  /// **'No sync points'**
  String get expNoSyncTitle;

  /// No description provided for @expNoSyncBody.
  ///
  /// In en, this message translates to:
  /// **'There are no sync points present, your result will be incorrect. Are you sure you want to render this file?'**
  String get expNoSyncBody;

  /// No description provided for @expYes.
  ///
  /// In en, this message translates to:
  /// **'Yes'**
  String get expYes;

  /// No description provided for @expNo.
  ///
  /// In en, this message translates to:
  /// **'No'**
  String get expNo;

  /// No description provided for @expSelectFolderTitle.
  ///
  /// In en, this message translates to:
  /// **'Select destination folder'**
  String get expSelectFolderTitle;

  /// No description provided for @expSelectFolderBody.
  ///
  /// In en, this message translates to:
  /// **'Due to file access restrictions, you need to select the destination folder manually.\nClick Ok and select the destination folder.'**
  String get expSelectFolderBody;

  /// No description provided for @expRenderDoneTitle.
  ///
  /// In en, this message translates to:
  /// **'Rendering completed'**
  String get expRenderDoneTitle;

  /// No description provided for @expRenderDoneBody.
  ///
  /// In en, this message translates to:
  /// **'The file was written to: {path}'**
  String expRenderDoneBody(String path);

  /// No description provided for @expFailedTitle.
  ///
  /// In en, this message translates to:
  /// **'Export failed'**
  String get expFailedTitle;

  /// No description provided for @expOk.
  ///
  /// In en, this message translates to:
  /// **'Ok'**
  String get expOk;

  /// No description provided for @expForegroundTitle.
  ///
  /// In en, this message translates to:
  /// **'Keep in foreground'**
  String get expForegroundTitle;

  /// No description provided for @expForegroundBody.
  ///
  /// In en, this message translates to:
  /// **'Keep this app in the foreground and don\'t lock the screen.\nDue to limitations of the system video encoders, rendering in the background is not supported.'**
  String get expForegroundBody;

  /// No description provided for @expDontShowAgain.
  ///
  /// In en, this message translates to:
  /// **'Don\'t show again'**
  String get expDontShowAgain;

  /// No description provided for @pviewNoVideo.
  ///
  /// In en, this message translates to:
  /// **'No video selected'**
  String get pviewNoVideo;

  /// No description provided for @pviewZoom.
  ///
  /// In en, this message translates to:
  /// **'Zoom: {value}'**
  String pviewZoom(String value);

  /// No description provided for @ctlOutputSizeSet.
  ///
  /// In en, this message translates to:
  /// **'Output size: {w}×{h} (preview {pw}×{ph})'**
  String ctlOutputSizeSet(String w, String h, String pw, String ph);

  /// No description provided for @ctlApplyOutputSizeFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to apply output size: {error}'**
  String ctlApplyOutputSizeFailed(String error);

  /// No description provided for @ctlSelectExportFolder.
  ///
  /// In en, this message translates to:
  /// **'Select export folder'**
  String get ctlSelectExportFolder;

  /// No description provided for @ctlRootDir.
  ///
  /// In en, this message translates to:
  /// **'Root directory'**
  String get ctlRootDir;

  /// No description provided for @ctlSelectFolderFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to select folder: {error}'**
  String ctlSelectFolderFailed(String error);

  /// No description provided for @ctlInitializingExport.
  ///
  /// In en, this message translates to:
  /// **'Initializing export…'**
  String get ctlInitializingExport;

  /// No description provided for @ctlExportComplete.
  ///
  /// In en, this message translates to:
  /// **'Export complete: {path}'**
  String ctlExportComplete(String path);

  /// No description provided for @ctlExportCancelled.
  ///
  /// In en, this message translates to:
  /// **'Export cancelled'**
  String get ctlExportCancelled;

  /// No description provided for @ctlExportFailed.
  ///
  /// In en, this message translates to:
  /// **'Export failed: {error}'**
  String ctlExportFailed(String error);

  /// No description provided for @ctlCancellingExport.
  ///
  /// In en, this message translates to:
  /// **'Cancelling export…'**
  String get ctlCancellingExport;

  /// No description provided for @ctlStatusInitial.
  ///
  /// In en, this message translates to:
  /// **'Open a file in the Inputs tab to start'**
  String get ctlStatusInitial;

  /// No description provided for @ctlBgSolid.
  ///
  /// In en, this message translates to:
  /// **'Solid color'**
  String get ctlBgSolid;

  /// No description provided for @ctlBgRepeatEdge.
  ///
  /// In en, this message translates to:
  /// **'Repeat edge pixels'**
  String get ctlBgRepeatEdge;

  /// No description provided for @ctlBgMirrorEdge.
  ///
  /// In en, this message translates to:
  /// **'Mirror edge pixels'**
  String get ctlBgMirrorEdge;

  /// No description provided for @ctlBgFeather.
  ///
  /// In en, this message translates to:
  /// **'Margin with feather'**
  String get ctlBgFeather;

  /// No description provided for @ctlNoLensProfile.
  ///
  /// In en, this message translates to:
  /// **'No lens profile loaded'**
  String get ctlNoLensProfile;

  /// No description provided for @ctlBackend.
  ///
  /// In en, this message translates to:
  /// **'Backend: {label}'**
  String ctlBackend(String label);

  /// No description provided for @ctlFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed: {error}'**
  String ctlFailed(String error);

  /// No description provided for @ctlNoSidecarFound.
  ///
  /// In en, this message translates to:
  /// **'No sidecar matching \"{base}\" found in folder'**
  String ctlNoSidecarFound(String base);

  /// No description provided for @ctlFolderSidecarLoaded.
  ///
  /// In en, this message translates to:
  /// **'Folder sidecar loaded'**
  String get ctlFolderSidecarLoaded;

  /// No description provided for @ctlFolderAuthFailed.
  ///
  /// In en, this message translates to:
  /// **'Folder authorization failed: {error}'**
  String ctlFolderAuthFailed(String error);

  /// No description provided for @ctlLensLoaded.
  ///
  /// In en, this message translates to:
  /// **'✓ Lens profile loaded'**
  String get ctlLensLoaded;

  /// No description provided for @ctlLensLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to load lens profile: {error}'**
  String ctlLensLoadFailed(String error);

  /// No description provided for @ctlMotionLoaded.
  ///
  /// In en, this message translates to:
  /// **'✓ Motion data loaded'**
  String get ctlMotionLoaded;

  /// No description provided for @ctlMotionLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to load motion data: {error}'**
  String ctlMotionLoadFailed(String error);

  /// No description provided for @ctlMotionReloadFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to reload motion data: {error}'**
  String ctlMotionReloadFailed(String error);

  /// No description provided for @ctlAutosyncing.
  ///
  /// In en, this message translates to:
  /// **'Auto syncing…'**
  String get ctlAutosyncing;

  /// No description provided for @ctlAutosyncFailed.
  ///
  /// In en, this message translates to:
  /// **'Auto sync failed: {error}'**
  String ctlAutosyncFailed(String error);

  /// No description provided for @ctlAutosyncNeedLens.
  ///
  /// In en, this message translates to:
  /// **'Load a lens profile before auto sync'**
  String get ctlAutosyncNeedLens;

  /// No description provided for @ctlAutosyncComplete.
  ///
  /// In en, this message translates to:
  /// **'Auto sync complete ({count} sync points, median offset {ms} ms)'**
  String ctlAutosyncComplete(String count, String ms);

  /// No description provided for @ctlAutosyncNoOffset.
  ///
  /// In en, this message translates to:
  /// **'Auto sync found no offset'**
  String get ctlAutosyncNoOffset;

  /// No description provided for @ctlLensWrongType.
  ///
  /// In en, this message translates to:
  /// **'Please select a .json lens profile'**
  String get ctlLensWrongType;

  /// No description provided for @ctlMotionWrongType.
  ///
  /// In en, this message translates to:
  /// **'Please select a motion file (.gcsv/.bbl/.bfl/.csv)'**
  String get ctlMotionWrongType;

  /// No description provided for @inputVideoInfo.
  ///
  /// In en, this message translates to:
  /// **'Video information'**
  String get inputVideoInfo;

  /// No description provided for @inputOpenFile.
  ///
  /// In en, this message translates to:
  /// **'Open file'**
  String get inputOpenFile;

  /// No description provided for @inputNone.
  ///
  /// In en, this message translates to:
  /// **'None'**
  String get inputNone;

  /// No description provided for @inputFileName.
  ///
  /// In en, this message translates to:
  /// **'File name'**
  String get inputFileName;

  /// No description provided for @inputDetectedCamera.
  ///
  /// In en, this message translates to:
  /// **'Detected camera'**
  String get inputDetectedCamera;

  /// No description provided for @inputDetectedLens.
  ///
  /// In en, this message translates to:
  /// **'Detected lens'**
  String get inputDetectedLens;

  /// No description provided for @inputDimensions.
  ///
  /// In en, this message translates to:
  /// **'Dimensions'**
  String get inputDimensions;

  /// No description provided for @inputDuration.
  ///
  /// In en, this message translates to:
  /// **'Duration'**
  String get inputDuration;

  /// No description provided for @inputFrameRate.
  ///
  /// In en, this message translates to:
  /// **'Frame rate'**
  String get inputFrameRate;

  /// No description provided for @inputCodec.
  ///
  /// In en, this message translates to:
  /// **'Codec'**
  String get inputCodec;

  /// No description provided for @inputPixelFormat.
  ///
  /// In en, this message translates to:
  /// **'Pixel format'**
  String get inputPixelFormat;

  /// No description provided for @inputAudio.
  ///
  /// In en, this message translates to:
  /// **'Audio'**
  String get inputAudio;

  /// No description provided for @inputRotation.
  ///
  /// In en, this message translates to:
  /// **'Rotation'**
  String get inputRotation;

  /// No description provided for @inputContainsGyro.
  ///
  /// In en, this message translates to:
  /// **'Contains gyro'**
  String get inputContainsGyro;

  /// No description provided for @inputDirHint.
  ///
  /// In en, this message translates to:
  /// **'In order to detect project files, video sequences or image sequences, click here and select the directory with input files.'**
  String get inputDirHint;

  /// No description provided for @inputLensMismatch.
  ///
  /// In en, this message translates to:
  /// **'Lens profile dimensions don\'t match the file dimensions. The result may not look correct.'**
  String get inputLensMismatch;

  /// No description provided for @inputLensAspectMismatch.
  ///
  /// In en, this message translates to:
  /// **'Lens profile aspect ratio doesn\'t match the file aspect ratio. The result will not look correct.'**
  String get inputLensAspectMismatch;

  /// No description provided for @inputLensNotLoaded.
  ///
  /// In en, this message translates to:
  /// **'Lens profile is not loaded, the results will not look correct. Please load a lens profile for your camera.'**
  String get inputLensNotLoaded;

  /// No description provided for @inputLensProfile.
  ///
  /// In en, this message translates to:
  /// **'Lens profile'**
  String get inputLensProfile;

  /// No description provided for @inputSearchLens.
  ///
  /// In en, this message translates to:
  /// **'Search...'**
  String get inputSearchLens;

  /// No description provided for @inputAdvanced.
  ///
  /// In en, this message translates to:
  /// **'Advanced'**
  String get inputAdvanced;

  /// No description provided for @inputUnderwaterLens.
  ///
  /// In en, this message translates to:
  /// **'Lens is under water'**
  String get inputUnderwaterLens;

  /// No description provided for @inputPixelFocalLength.
  ///
  /// In en, this message translates to:
  /// **'Pixel focal length'**
  String get inputPixelFocalLength;

  /// No description provided for @inputFocalCenter.
  ///
  /// In en, this message translates to:
  /// **'Focal center'**
  String get inputFocalCenter;

  /// No description provided for @inputDistortionCoeffs.
  ///
  /// In en, this message translates to:
  /// **'Distortion coefficients'**
  String get inputDistortionCoeffs;

  /// No description provided for @inputMotionData.
  ///
  /// In en, this message translates to:
  /// **'Motion data'**
  String get inputMotionData;

  /// No description provided for @inputDetectedFormat.
  ///
  /// In en, this message translates to:
  /// **'Detected format'**
  String get inputDetectedFormat;

  /// No description provided for @inputLoadAllMetadata.
  ///
  /// In en, this message translates to:
  /// **'Load all metadata'**
  String get inputLoadAllMetadata;

  /// No description provided for @inputOrientationIndicator.
  ///
  /// In en, this message translates to:
  /// **'Orientation indicator'**
  String get inputOrientationIndicator;

  /// No description provided for @inputFrameOffset.
  ///
  /// In en, this message translates to:
  /// **'Frame offset'**
  String get inputFrameOffset;

  /// No description provided for @inputUnitFrames.
  ///
  /// In en, this message translates to:
  /// **'frames'**
  String get inputUnitFrames;

  /// No description provided for @inputLowPassFilter.
  ///
  /// In en, this message translates to:
  /// **'Low pass filter'**
  String get inputLowPassFilter;

  /// No description provided for @inputGyroBias.
  ///
  /// In en, this message translates to:
  /// **'Gyro bias'**
  String get inputGyroBias;

  /// No description provided for @inputIntegrationMethod.
  ///
  /// In en, this message translates to:
  /// **'Integration method'**
  String get inputIntegrationMethod;

  /// No description provided for @inputImuOrientation.
  ///
  /// In en, this message translates to:
  /// **'IMU orientation'**
  String get inputImuOrientation;

  /// No description provided for @inputLensCamera.
  ///
  /// In en, this message translates to:
  /// **'Camera'**
  String get inputLensCamera;

  /// No description provided for @inputLensLens.
  ///
  /// In en, this message translates to:
  /// **'Lens'**
  String get inputLensLens;

  /// No description provided for @inputLensSetting.
  ///
  /// In en, this message translates to:
  /// **'Setting'**
  String get inputLensSetting;

  /// No description provided for @inputLensNote.
  ///
  /// In en, this message translates to:
  /// **'Additional info'**
  String get inputLensNote;

  /// No description provided for @inputLensDimensions.
  ///
  /// In en, this message translates to:
  /// **'Dimensions'**
  String get inputLensDimensions;

  /// No description provided for @inputLensCalibratedBy.
  ///
  /// In en, this message translates to:
  /// **'Calibrated by'**
  String get inputLensCalibratedBy;

  /// No description provided for @inputRsFocalLength.
  ///
  /// In en, this message translates to:
  /// **'Focal length'**
  String get inputRsFocalLength;

  /// No description provided for @inputRsFocusMode.
  ///
  /// In en, this message translates to:
  /// **'Focus mode'**
  String get inputRsFocusMode;

  /// No description provided for @inputRsIris.
  ///
  /// In en, this message translates to:
  /// **'Iris'**
  String get inputRsIris;

  /// No description provided for @inputRsIso.
  ///
  /// In en, this message translates to:
  /// **'ISO'**
  String get inputRsIso;

  /// No description provided for @inputRsShutterAngle.
  ///
  /// In en, this message translates to:
  /// **'Shutter angle'**
  String get inputRsShutterAngle;

  /// No description provided for @inputRsShutterSpeed.
  ///
  /// In en, this message translates to:
  /// **'Shutter speed'**
  String get inputRsShutterSpeed;

  /// No description provided for @inputRsExposure.
  ///
  /// In en, this message translates to:
  /// **'Exposure'**
  String get inputRsExposure;

  /// No description provided for @inputRsWhiteBalanceMode.
  ///
  /// In en, this message translates to:
  /// **'White balance mode'**
  String get inputRsWhiteBalanceMode;

  /// No description provided for @inputRsWhiteBalance.
  ///
  /// In en, this message translates to:
  /// **'White balance'**
  String get inputRsWhiteBalance;

  /// No description provided for @inputRsColorPrimaries.
  ///
  /// In en, this message translates to:
  /// **'Color primaries'**
  String get inputRsColorPrimaries;

  /// No description provided for @inputRsGammaEquation.
  ///
  /// In en, this message translates to:
  /// **'Gamma equation'**
  String get inputRsGammaEquation;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
