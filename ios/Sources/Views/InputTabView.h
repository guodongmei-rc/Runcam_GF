#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 输入 Tab —— 对齐官方布局,含三块:
///   ① 视频信息(只读 label:文件名/相机/镜头/尺寸/时长/帧率/编码/像素/音频/旋转/是否含陀螺)
///   ② 镜头配置文件(搜索框 + 结果列表 + 打开文件)
///   ③ 运动数据(打开 .gcsv)
///
/// 跟 Controller 用 block 通信。Controller 负责真正调 FFI / documentPicker。
@interface InputTabView : UIView

// ---- 动作回调(Controller 注入)----
@property (nonatomic, copy, nullable) void(^onOpenVideo)(void);
@property (nonatomic, copy, nullable) void(^onOpenLensFile)(void);
@property (nonatomic, copy, nullable) void(^onOpenMotionData)(void);
/// 搜索镜头:View 把关键字给 Controller,Controller 调 gyroflow_lens_search 返回
/// JSON 字符串([{"name","id"}...]),通过 completion 回传给 View 显示。
@property (nonatomic, copy, nullable) void(^onLensSearch)(NSString *query, void(^completion)(NSString *resultJson));
/// 用户在结果列表点了某个镜头,Controller 用这个 id 调 gyroflow_load_lens_profile。
@property (nonatomic, copy, nullable) void(^onSelectLensId)(NSString *lensId);
/// 「创建新的」镜头档案 —— 占位回调，Controller 决定弹出何种向导/页面
@property (nonatomic, copy, nullable) void(^onCreateNewLensProfile)(void);
/// 「导出 STMap」—— 占位回调
@property (nonatomic, copy, nullable) void(^onExportSTMap)(void);
/// 用户评价镜头档案（Good/Bad），good=YES 表示 Good
@property (nonatomic, copy, nullable) void(^onRateLensProfile)(BOOL good);
/// 「水下镜头」勾选切换，on=YES 表示水下（1.33），NO 表示空气（1.0）
@property (nonatomic, copy, nullable) void(^onUnderwaterToggled)(BOOL on);
/// 积分方法选择。回调参数是 **Rust FFI 索引**(0=None 1=Complementary 2=VQF 3=Simple gyro
/// 4=Simple gyro+accel 5=Mahony 6=Madgwick)，由 View 按当前列表是否含 "None" 换算好
/// (对齐安卓 GyroflowMotionPanel: method = hasQuaternions ? position : position+1)。
@property (nonatomic, copy, nullable) void(^onIntegrationMethodSelected)(NSInteger ffiIndex);
/// IMU 朝向被用户编辑提交(已校验为 3 位、仅含 xyzXYZ)。Controller 调
/// gyroflow_set_imu_orientation + 重算。对齐官方 MotionData.qml 可改朝向的行为。
@property (nonatomic, copy, nullable) void(^onIMUOrientationChanged)(NSString *orientation);
/// 「加载全部元数据」勾选切换(仅外挂运动数据文件场景显示)。Controller 用当前外挂
/// 文件重新调 gyroflow_load_gyro_data(对齐官方 MotionData.qml:215-222 切换即重载)。
@property (nonatomic, copy, nullable) void(^onLoadAllMetadataToggled)(BOOL on);
/// 「帧偏移」变化(勾选开关或数值提交; 关闭时回调 0)。Controller 调 gyroflow_set_frame_offset。
@property (nonatomic, copy, nullable) void(^onFrameOffsetChanged)(NSInteger frames);
/// 「授权视频所在文件夹」点击(视频无运动数据时显示)。Controller 弹系统目录选择器,
/// 授权后注册目录白名单并重载视频, 让同名 sidecar(gcsv/bbl/bfl/csv)自动检测生效。
@property (nonatomic, copy, nullable) void(^onAuthorizeMotionFolder)(void);

// ---- Controller 调这些刷新只读显示 ----
/// 刷新视频信息区。传 nil 字段用 "---"。
- (void)setVideoInfoFileName:(nullable NSString *)fileName
                  detectedCam:(nullable NSString *)cam
                 detectedLens:(nullable NSString *)lens
                         size:(nullable NSString *)size
                     duration:(nullable NSString *)duration
                          fps:(nullable NSString *)fps
                        codec:(nullable NSString *)codec
                   pixelFormat:(nullable NSString *)pixfmt
                        audio:(nullable NSString *)audio
                     rotation:(nullable NSString *)rotation
                     hasGyro:(nullable NSString *)hasGyro;

/// 设置/刷新「录制参数」动态行(ISO/快门/白平衡/曝光/焦距/对焦方式等, 对齐官方 recording_settings)。
/// 只显示字典里存在的键; 传 nil/空则清空。
- (void)setRecordingSettings:(nullable NSDictionary *)settings;

/// 刷新镜头区当前已加载档案名(显示在搜索框下方)。
- (void)setLoadedLensName:(nullable NSString *)name;
/// 刷新运动数据区状态文字（占位/老接口）。
- (void)setMotionStatus:(nullable NSString *)status;

/// 刷新运动数据「检测到的格式」+「文件名称」+ 已加载布尔。loaded=NO 时只显示 ---。
- (void)setMotionInfoFormat:(nullable NSString *)format
                   fileName:(nullable NSString *)fileName
                     loaded:(BOOL)loaded;

/// 运动数据「打开文件」按钮启用开关。未载入视频时禁用(对齐官方 MotionData.qml:36
/// 无视频拒绝加载运动数据); 视频载入完成后 Controller 传 YES 启用。
- (void)setMotionOpenFileEnabled:(BOOL)enabled;

/// 视频信息·蓝色目录授权提示框显隐(打开文件按钮下方)。视频载入完成且
/// 无运动数据/镜头信息时显示, 对齐官方 VideoInformation.qml:164-178 InfoMessageSmall。
- (void)setVideoDirHintVisible:(BOOL)visible;

/// 「加载全部元数据」当前勾选值(Controller 加载外挂文件时传给 FFI; 控件隐藏时恒 NO,
/// 对齐官方 root.allMetadata = visible && checked)。
- (BOOL)loadAllMetadataChecked;

/// 外挂运动数据加载成功后传 YES 显示「加载全部元数据/帧偏移」两控件;
/// 选择新视频时传 NO 隐藏并复位勾选/数值(对齐官方 MotionData.qml:213/227 可见条件)。
- (void)setExternalMotionControlsVisible:(BOOL)visible;

/// 配置「积分方法」下拉(不触发回调)。对齐安卓 GyroflowMotionPanel / 官方 MotionData.qml：
/// hasQuats=YES 时列表为 [None, Complementary, VQF, ...](原生四元数机型可选 None)，
/// NO 时列表不含 None。selectedFFIIndex 为 Rust FFI 索引(0=None 1=Complementary 2=VQF ...)。
/// 每次加载视频/陀螺数据后都应调用，否则下拉会残留上一个视频的显示。
- (void)configureIntegrationMethodsHasQuaternions:(BOOL)hasQuats selectedFFIIndex:(NSInteger)ffiIndex;

/// 程序化设置「IMU 朝向」输入框显示的真实值(不触发 onIMUOrientationChanged)。
/// 传 nil/空串则恢复占位提示。
- (void)setIMUOrientationText:(nullable NSString *)text;

/// 逐帧驱动「方向指示器」: raw/smoothed 各指向长度 4 的 double 数组 (w,x,y,z)。
/// 对齐官方 quats_at_timestamp → orientationIndicator.updateOrientation。
- (void)updateOrientationIndicatorRaw:(const double *)raw smoothed:(const double *)smoothed;

/// 刷新镜头档案详情面板（截图对齐的字段）。任何字段为 nil 用 "---" 占位。
/// official=YES 时隐藏「非官方」警告横幅；NO 时显示。
- (void)setLensDetailsOfficial:(BOOL)official
                        camera:(nullable NSString *)camera
                          lens:(nullable NSString *)lens
                       setting:(nullable NSString *)setting
                     otherInfo:(nullable NSString *)otherInfo
                     dimension:(nullable NSString *)dimension
                    calibrator:(nullable NSString *)calibrator;

/// 刷新镜头档案「高级」面板的标定数值。任意为 NaN 时显示 "---"。
- (void)setLensCalibrationUnderwater:(BOOL)underwater
                                  fx:(double)fx fy:(double)fy
                                  cx:(double)cx cy:(double)cy
                                  k1:(double)k1 k2:(double)k2 k3:(double)k3 k4:(double)k4;

@end

NS_ASSUME_NONNULL_END
