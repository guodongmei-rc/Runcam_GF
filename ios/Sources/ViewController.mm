#import "ViewController.h"
#import "GFSegmentedTabs.h"

#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Photos/Photos.h>
#import <mach/mach.h>

// 进程物理内存占用(MB)。用 phys_footprint(和 Xcode Memory gauge 口径一致)诊断导出内存。
static double gf_footprint_mb(void) {
    task_vm_info_data_t info; mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS) {
        return (double)info.phys_footprint / (1024.0 * 1024.0);
    }
    return -1.0;
}

#import "gyroflow_ffi.h"
#import "GyroTimelineModel.h"
#import "GyroTimelineView.h"
#import "ParamsModel.h"
#import "SyncSectionView.h"
#import "SyncProgressOverlayView.h"
#import "StabilizeSectionView.h"
#import "AdvancedSectionView.h"
#import "ExportSectionView.h"
#import "SyncAdvancedView.h"
#import "AutosyncRunner.h"
#import "InputTabView.h"
#import "GFTheme.h"
#import "GFViewKit.h"
#import "GFBookmarkStore.h"
#import "PreviewHUDView.h"
#import "PlaybackControlRowView.h"
#import "GFExportUtils.h"

#include <cmath>
#include <memory>

#include <mdk/Player.h>
#include <mdk/RenderAPI.h>

@interface ViewController () <UIDocumentPickerDelegate, MTKViewDelegate, AdvancedSectionViewDelegate, UIColorPickerViewControllerDelegate> {
    std::unique_ptr<mdk::Player> _mdkPlayer;
    mdk::MetalRenderAPI _mdkRenderAPI;
    int _mdkSurfaceWidth;
    int _mdkSurfaceHeight;
}

@property (nonatomic, strong) UIButton *stabilizationButton;
@property (nonatomic, strong) UIButton *exportButton;
@property (nonatomic, strong) UIButton *playPauseButton;
@property (nonatomic, assign) BOOL videoPaused;
@property (nonatomic, strong) UIView   *lensWarningBanner;  // 预览黄色横幅容器: 未加载镜头档案警告(带内边距)
@property (nonatomic, assign) BOOL pickingLensProfile;  // YES = 文件选择器拾到的是镜头 JSON,NO = 视频
@property (nonatomic, assign) BOOL pickingMotionData;   // YES = 拾到的是 .gcsv 陀螺数据
@property (nonatomic, strong) NSURL *lastMotionDataURL; // 最近一次外挂运动数据文件(「加载全部元数据」切换重载用)
@property (nonatomic, assign) BOOL pickingMotionFolder; // YES = 拾到的是「视频所在文件夹」授权(同名 sidecar 自动检测)
@property (nonatomic, assign) BOOL hasRenderedAnyMDKFrame; // 本视频是否渲出过至少一帧(prepare 首帧缺失兜底用)
@property (nonatomic, strong) NSURL *motionFolderScopedURL; // 已授权目录(持有 security scope, 换目录时才释放)
@property (nonatomic, strong) UIProgressView *exportProgress;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *fpsLabel;
@property (nonatomic, strong) UILabel *gyroLabel;
@property (nonatomic, strong) UILabel *playInfoLabel;
// 每帧 process_frame_metal_bgra8 返回的 itm.fov, 用来算当前帧实时 zoom%
// (跟桌面 UI 时间轴旁那个动态变化的"缩放: 64.71%"对齐)。
@property (nonatomic, assign) double currentFrameFov;
// 陀螺仪波形时间轴（MVC：Model 持数据，View 负责画，Controller 在此装配）
@property (nonatomic, strong) GyroTimelineModel *gyroModel;
@property (nonatomic, strong) GyroTimelineView *gyroTimelineView;
// 参数面板 (M + 4 View + UIScrollView 容器)
@property (nonatomic, strong) ParamsModel           *paramsModel;
@property (nonatomic, strong) SyncSectionView       *syncSection;
@property (nonatomic, strong) SyncProgressOverlayView *syncOverlay;
@property (nonatomic, strong) UIView                *analysisMask;  // 分析时的全屏蒙版,独立于 syncOverlay
@property (nonatomic, strong) StabilizeSectionView  *stabilizeSection;
@property (nonatomic, strong) AdvancedSectionView   *advancedSection;
@property (nonatomic, strong) ExportSectionView     *exportSection;
@property (nonatomic, strong) CAShapeLayer          *safeAreaLayer;
@property (nonatomic, copy, nullable) void(^pendingColorCompletion)(UIColor *);
@property (nonatomic, assign) CFTimeInterval fpsWindowStart;
@property (nonatomic, assign) NSInteger fpsWindowFrames;
@property (nonatomic, assign) double fpsWindowFFIMsSum;
@property (nonatomic, assign) double fpsWindowTotalMsSum;
@property (nonatomic, strong) dispatch_source_t mainThreadWatchdog;
@property (nonatomic, strong) dispatch_queue_t renderQueue;
@property (nonatomic, strong) MTKView *videoView;
@property (nonatomic, strong) UIView *dropPlaceholder;       // 无视频时「选择文件」占位框(PreviewHUDView 持有)
@property (nonatomic, strong) PreviewHUDView *previewHUD;     // 预览叠加层(状态/FPS/陀螺/播放信息/黄条/占位框)
@property (nonatomic, strong) NSLayoutConstraint *videoAspectConstraint;
@property (nonatomic, strong) dispatch_queue_t exportQueue;
@property (nonatomic, assign) BOOL exporting;
@property (nonatomic, assign) BOOL exportResolutionOk;  // 输出大小校验(对齐官方 canExport): 超编码器上限时禁用导出
@property (nonatomic, assign) BOOL lensDoAutosync;      // 镜头档案 sync_settings.do_autosync(官方自动同步门槛之一)
@property (nonatomic, assign) BOOL pickingExportFolder;  // documentPicker 分支: 本次 pick 的是导出存储目录
@property (nonatomic, strong) NSURL *exportFolderURL;    // 用户选定的导出存储目录(nil=未授权,导出前强制授权)
@property (nonatomic, strong) NSURL *pendingExportSrcURL; // 非 nil: 选完导出目录后继续导出这个源(对齐官方"先授权再导出")
@property (atomic, assign) BOOL exportCancelled;

// 主内容栈（键盘弹出时只 transform 它，不 transform self.view，避免露出窗口背景的黑空白）
@property (nonatomic, strong) UIStackView *mainStack;

@property (nonatomic, strong) id<MTLDevice> metalDevice;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong) id<MTLTexture> currentMDKRenderTarget;
@property (nonatomic, strong) id<MTLTexture> mdkInputTexture;

@property (nonatomic, assign) GyroflowStabilizer *stabilizer;
@property (nonatomic, assign) GyroflowVideoInfo videoInfo;
@property (nonatomic, assign) BOOL gyroflowReady;
@property (nonatomic, assign) BOOL playbackReady;
@property (nonatomic, assign) int64_t exportSavedPositionMs;  // 导出前 MDK 播放位置, 导出后 seek 回
@property (nonatomic, assign) BOOL stabilizationEnabled;
@property (nonatomic, assign) BOOL hasRenderedStabilizedFrame;
@property (nonatomic, assign) NSInteger loadGeneration;
@property (nonatomic, strong) dispatch_queue_t gyroQueue;

@property (nonatomic, strong) NSURL *securityScopedURL;
@property (nonatomic, strong) NSURL *pendingScanLensURL;   // 授权目录扫描到的同名镜头 json, 视频加载链路末尾兜底加载
@property (nonatomic, assign) BOOL hasSecurityScope;

// Phase β:自动同步
@property (nonatomic, strong, nullable) AutosyncRunner *autosyncRunner;
@property (atomic, assign) BOOL hasAccurateTimestamps;  // 视频自带精确时间戳(GoPro 等), 无需同步点
@property (atomic, assign) NSInteger syncPointCount;    // autosync 算出的同步点数; 导出时判断是否提示
@property (nonatomic, assign) BOOL motionFromVideo;     // 运动数据来自视频本身(内嵌)还是外挂(对齐官方 filename 匹配)
@property (nonatomic, assign) BOOL integrationIsNone;   // 积分方法是否 None(直接用四元数, FFI 0)

// 三 Tab 布局(对齐官方:输入/参数/导出)
@property (nonatomic, strong) GFSegmentedTabs *tabSegmented;
@property (nonatomic, strong) InputTabView *inputTab;        // 输入页
@property (nonatomic, strong) UIScrollView *tabScroll;       // 承载当前 tab 内容
@property (nonatomic, strong) UIView *inputContainer;        // 输入页容器
@property (nonatomic, strong) UIView *paramsContainer;       // 参数页容器(4 个 section)
@property (nonatomic, strong) UIView *exportContainer;       // 导出页容器
// 自适应布局(iPad 横屏三栏 / 其余单列 Tab)
@property (nonatomic, strong) UIStackView *buttonRow;        // 播放/暂停 + 防抖开关
@property (nonatomic, strong) UIView *currentLayoutRoot;     // 当前顶层布局容器(切换时拆除)
@property (nonatomic, assign) BOOL threeColumnApplied;       // 当前是否三栏
@property (nonatomic, assign) BOOL adaptiveLayoutBuilt;      // 是否已首次构建
@property (nonatomic, assign) GyroflowStabilizer *lensSearchStab;  // 没加载视频时专用于镜头库搜索

@end

static const void *GyroflowDemoCurrentRenderTarget(const void *opaque) {
    ViewController *controller = (__bridge ViewController *)opaque;
    return (__bridge const void *)controller.currentMDKRenderTarget;
}

// 渲染队列识别标记: drainRenderQueue 用它防止在渲染队列自身上 dispatch_sync 死锁。
static void *kGFRenderQueueKey = &kGFRenderQueueKey;

@implementation ViewController

// 同步排干渲染队列(等正在执行的 draw 跑完), 销毁 _mdkPlayer/stabilizer 前必须调。
// 若当前就在渲染队列上(理论上只可能是 dealloc 落在渲染线程), 队列已串行化, 直接跳过。
- (void)drainRenderQueue {
    if (self.renderQueue == nil) {
        return;
    }
    if (dispatch_get_specific(kGFRenderQueueKey) != NULL) {
        return;
    }
    dispatch_sync(self.renderQueue, ^{});
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"Gyroflow Demo";
    self.view.backgroundColor = [GFTheme backgroundColor];
    self.gyroQueue = dispatch_queue_create("com.codex.gyroflowdemo.gyro", DISPATCH_QUEUE_SERIAL);
    self.exportQueue = dispatch_queue_create("com.codex.gyroflowdemo.export", DISPATCH_QUEUE_SERIAL);

    self.metalDevice = MTLCreateSystemDefaultDevice();
    self.commandQueue = [self.metalDevice newCommandQueue];

    // 播放控制条(常驻预览下方): 播放/暂停 + 防抖开关(PlaybackControlRowView)。
    PlaybackControlRowView *controlRow = [[PlaybackControlRowView alloc] initWithFrame:CGRectZero];
    [controlRow.playPauseButton addTarget:self action:@selector(togglePlayPause) forControlEvents:UIControlEventTouchUpInside];
    [controlRow.stabilizationButton addTarget:self action:@selector(toggleStabilization) forControlEvents:UIControlEventTouchUpInside];
    self.playPauseButton = controlRow.playPauseButton;
    self.stabilizationButton = controlRow.stabilizationButton;
    self.buttonRow = controlRow;   // 自适应布局复用(竖屏主栈 / 横屏中栏)

    // 导出按钮(嵌入导出设置卡片「输出路径」行下方, 见下方 embedExportButton)
    self.exportButton = [GFViewKit primaryButtonWithTitle:@"导出"];   // 对齐官方导出页按钮文案
    self.exportButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.exportButton.enabled = NO;
    [self.exportButton addTarget:self action:@selector(exportStabilizedVideo) forControlEvents:UIControlEventTouchUpInside];

    self.exportProgress = [GFViewKit themedProgressView];

    self.videoView = [[MTKView alloc] initWithFrame:CGRectZero device:self.metalDevice];
    self.videoView.translatesAutoresizingMaskIntoConstraints = NO;
    self.videoView.delegate = self;
    self.videoView.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    self.videoView.framebufferOnly = NO;
    // 帧驱动渲染: paused=YES + enableSetNeedsDisplay=NO = Apple 定义的「显式 draw」模式,
    // MTKView 自带的 60Hz 时钟不再自转。draw 只来自:
    //   ① MDK setRenderCallback(解码出新帧, 见 startMDKPlaybackWithURL) —— 播放时 = 视频帧率;
    //   ② 参数 recompute 完成 / 防抖开关 / 预览分辨率切换后手动补一次(刷新当前帧)。
    // 历史教训: 之前 paused=NO 60fps 自转 + MDK 回调双路叠加, 暂停时同一帧每秒被全量
    // 防抖处理 60 次, 真机实测暂停期 CPU ~100%(主线程饱和)、播放期 ~180%。
    self.videoView.enableSetNeedsDisplay = NO;
    self.videoView.paused = YES;
    self.videoView.backgroundColor = UIColor.blackColor;
    // 关键：不让 MTKView 用 view.bounds*contentScaleFactor 覆盖我们显式设的 drawableSize，
    // 否则 Gyroflow 的 output_size 会跟 drawable.texture 大小对不上。
    self.videoView.autoResizeDrawable = NO;

    self.fpsWindowStart = CACurrentMediaTime();
    self.fpsWindowFrames = 0;
    self.fpsWindowFFIMsSum = 0.0;
    self.fpsWindowTotalMsSum = 0.0;
    [self startMainThreadWatchdog];
    // 预览渲染专用串行队列 —— drawInMTKView(含 gyroflow FFI)全部在此队列执行。
    // 实测(perf_diag): 防抖开启时 draw 每帧 ~13ms 占主线程 40%, 参数一改 gyroflow
    // 惰性重算平滑曲线、下一次 FFI 等锁可达 1.2s, 在主线程就是整个 UI 冻结。
    // 挪到渲染队列后 FFI 等锁只停预览, UI 不受影响。
    self.renderQueue = dispatch_queue_create(
        "gyroflow.preview.render",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    dispatch_queue_set_specific(self.renderQueue, kGFRenderQueueKey, kGFRenderQueueKey, NULL);

    // 预览叠加层(状态文字/FPS/陀螺/播放信息/镜头黄条/选择文件占位): PreviewHUDView,
    // 铺满 videoView, 空白区触摸穿透。子控件引用回填到原属性名, 既有读写代码不变。
    PreviewHUDView *hud = [[PreviewHUDView alloc] initWithFrame:CGRectZero];
    hud.translatesAutoresizingMaskIntoConstraints = NO;
    __weak typeof(self) weakSelfHud = self;
    hud.onSelectFile = ^{
        [weakSelfHud selectVideo];
    };
    [self.videoView addSubview:hud];
    [NSLayoutConstraint activateConstraints:@[
        [hud.topAnchor      constraintEqualToAnchor:self.videoView.topAnchor],
        [hud.bottomAnchor   constraintEqualToAnchor:self.videoView.bottomAnchor],
        [hud.leadingAnchor  constraintEqualToAnchor:self.videoView.leadingAnchor],
        [hud.trailingAnchor constraintEqualToAnchor:self.videoView.trailingAnchor],
    ]];
    self.previewHUD = hud;
    self.statusLabel = hud.statusLabel;
    self.fpsLabel = hud.fpsLabel;
    self.gyroLabel = hud.gyroLabel;
    self.playInfoLabel = hud.playInfoLabel;
    self.lensWarningBanner = hud.lensWarningBanner;
    self.dropPlaceholder = hud.dropPlaceholder;

    // ==== 分析时的 2 层结构 ====
    //   1) analysisMask: 全屏 35% 黑半透 UIView, 仅作蒙版拦截所有触摸
    //   2) syncOverlay : SyncProgressOverlayView(透明背景, 内含居中面板)
    // 两个独立加 vc.view,z-order: ...所有 UI... → analysisMask → syncOverlay → closeButton
    // GyroflowLauncher viewDidLoad 后才加 closeButton, z-order 自然在最顶, 始终可点。
    // 分析时调 show 同时显示 mask + overlay; 完成调 hide 同时隐藏。
    self.analysisMask = [UIView new];
    self.analysisMask.translatesAutoresizingMaskIntoConstraints = NO;
    self.analysisMask.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.35];
    self.analysisMask.userInteractionEnabled = YES;
    self.analysisMask.hidden = YES;
    [self.view addSubview:self.analysisMask];
    [NSLayoutConstraint activateConstraints:@[
        [self.analysisMask.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor],
        [self.analysisMask.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.analysisMask.topAnchor      constraintEqualToAnchor:self.view.topAnchor],
        [self.analysisMask.bottomAnchor   constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    self.syncOverlay = [[SyncProgressOverlayView alloc] initWithFrame:CGRectZero];
    self.syncOverlay.translatesAutoresizingMaskIntoConstraints = NO;
    // 透明背景:mask 在它下面承担"暗化",overlay 本身只显示居中面板。
    self.syncOverlay.backgroundColor = [UIColor clearColor];
    [self.view addSubview:self.syncOverlay];
    [NSLayoutConstraint activateConstraints:@[
        [self.syncOverlay.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor],
        [self.syncOverlay.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.syncOverlay.topAnchor      constraintEqualToAnchor:self.view.topAnchor],
        [self.syncOverlay.bottomAnchor   constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    // ---- Model + 4 个 SectionView(参数 Tab 用)----
    self.paramsModel = [[ParamsModel alloc] init];

    self.syncSection      = [[SyncSectionView alloc] initWithFrame:CGRectZero];
    self.stabilizeSection = [[StabilizeSectionView alloc] initWithFrame:CGRectZero];
    // zoomSection (ZoomSectionView) 已合并到 StabilizeSectionView 内的 ZoomGroupView,
    // 「视场角 / 卷帘 / 帧读出 / 视频速度 / 附加3D旋转」放在 ZoomGroupView 的「高级选项」里。
    self.advancedSection  = [[AdvancedSectionView alloc] initWithFrame:CGRectZero];
    self.advancedSection.presenterDelegate = self;

    // 参数/导出/输入容器统一由自适应布局(rebuildAdaptiveLayout)按竖屏/横屏构建。

    // 初始无视频时,所有 section 禁用(按用户要求:视频文件为空时不能操作界面按钮)
    [self setAllSectionsEnabled:NO];

    // 输入容器:InputTabView
    self.inputTab = [[InputTabView alloc] initWithFrame:CGRectZero];
    self.inputTab.translatesAutoresizingMaskIntoConstraints = NO;
    self.inputContainer = self.inputTab;
    [self wireInputTabCallbacks];

    // 导出容器:导出设置(编解码器/输出大小/比特率/GPU/音频) + 导出按钮 + 进度条 + 提示
    self.exportSection = [[ExportSectionView alloc] initWithFrame:CGRectZero];
    // 输出大小超编码器上限 → 禁用导出(对齐官方 canExport, Export.qml:117 / App.qml:255)
    self.exportResolutionOk = YES;
    __weak typeof(self) weakSelfExport = self;
    self.exportSection.onResolutionValidChanged = ^(BOOL valid) {
        __strong typeof(weakSelfExport) sSelf = weakSelfExport;
        if (sSelf == nil) {
            return;
        }
        sSelf.exportResolutionOk = valid;
        [sSelf updateExportButtonEnabled];
    };
    // 导出按钮嵌进导出设置卡片「输出路径」行下方(对齐官方截图顺序:
    // 输出路径 → 导出 → 编解码器 → 输出大小 → 比特率 → 音频)
    [self.exportSection embedExportButton:self.exportButton];
    // 「…」选导出存储目录(对齐官方 OutputPathField 目录选择): 选定后成品写入该目录,
    // 未选保持默认存相册。
    self.exportSection.onPickExportFolder = ^{
        __strong typeof(weakSelfExport) sSelf = weakSelfExport;
        if (sSelf == nil) {
            return;
        }
        [sSelf presentExportFolderPicker];
    };
    // 文件名编辑提交 → 对所选导出目录查重: 已有同名 → 自增 _X 回写; 无同名保持输入。
    // 未选目录(默认存相册)无法按名查询, 不处理。
    self.exportSection.onOutputFileNameEdited = ^{
        __strong typeof(weakSelfExport) sSelf = weakSelfExport;
        if (sSelf == nil) {
            return;
        }
        [sSelf resolveOutputFileNameConflict];
    };
    // 文件名实时变化 → 刷新「导出」按钮可用态(对齐官方 filename.length > 3 才可导出)。
    self.exportSection.onOutputFileNameChanged = ^{
        __strong typeof(weakSelfExport) sSelf = weakSelfExport;
        if (sSelf == nil) {
            return;
        }
        [sSelf updateExportButtonEnabled];
    };

    // Tab 切换器(自定义分段, 对齐安卓: 图标 + 文字 + 选中主题色下划线)
    self.tabSegmented = [[GFSegmentedTabs alloc] initWithTitles:@[@"输入", @"参数", @"导出"]
                                                     iconNames:@[@"video", @"gearshape", @"square.and.arrow.down"]];
    self.tabSegmented.selectedSegmentIndex = 0;
    self.tabSegmented.translatesAutoresizingMaskIntoConstraints = NO;
    [self.tabSegmented addTarget:self action:@selector(tabChanged:) forControlEvents:UIControlEventValueChanged];

    // Tab 内容滚动容器(同一时刻只放一个 container)
    self.tabScroll = [[UIScrollView alloc] init];
    self.tabScroll.translatesAutoresizingMaskIntoConstraints = NO;
    self.tabScroll.backgroundColor = UIColor.clearColor;

    __weak typeof(self) weakSelfParams = self;
    self.paramsModel.onRecomputeFinished = ^{
        __strong typeof(weakSelfParams) sSelf = weakSelfParams;
        if (sSelf == nil) return;
        [sSelf.stabilizeSection refreshReadOnly];
        [sSelf.exportSection refreshReadOnly];
        if (sSelf.paramsModel.previewResolutionHeight > 0) {
            // 预览分辨率生效: gyroflow 实际渲染输出要缩到预览尺寸。一次 recompute 后
            // paramsModel 可能把 output_size 推回了逻辑全尺寸(如改高级·输出大小),
            // 这里只在 drawable 与目标预览尺寸有偏差时才重新对齐, 避免拖动滑杆时
            // 每次 recompute 都多跑一次 recompute_blocking。
            CGSize desired = [sSelf previewScaledSizeForWidth:(uint32_t)sSelf.paramsModel.outputSize.width
                                                       height:(uint32_t)sSelf.paramsModel.outputSize.height];
            if (desired.width > 0.5
                && !CGSizeEqualToSize(sSelf.videoView.drawableSize, desired)) {
                [sSelf applyPreviewOutputSizeToStabilizer];
            }
        } else {
            CGSize ns = sSelf.paramsModel.outputSize;
            if (ns.width > 0.5 && ns.height > 0.5
                && !CGSizeEqualToSize(sSelf.videoView.drawableSize, ns)) {
                sSelf.videoView.drawableSize = ns;
            }
        }
        [sSelf updateSafeAreaOverlay];
        // 帧驱动模式下 MTKView 不自转: 参数变化 recompute 完成后手动补一次 draw,
        // 让暂停状态下拖参数也能立即看到当前帧的新效果。
        [sSelf requestPreviewDraw];
    };
    // 预览分辨率(方案: 驱动输出/drawable, 对齐桌面 set_preview_resolution):
    // 输入纹理 + MDK surface 始终保持视频原生(填满输入纹理, 不留黑边), 只把 gyroflow
    // 输出 output_size 与 drawable 按预览分辨率等比缩小。屏幕预览矩形由 aspect 约束固定,
    // 比例不变, MTKView 把更小的 drawable 放大铺满同样大小的矩形 —— 只降像素不缩画面。
    // 详见 applyPreviewOutputSizeToStabilizer。
    self.paramsModel.onPreviewResolutionChanged = ^{
        __strong typeof(weakSelfParams) sSelf = weakSelfParams;
        if (sSelf == nil) {
            return;
        }
        [sSelf applyPreviewOutputSizeToStabilizer];
    };
    // 导出·输出大小改变 → 同步协调更新 stabilizer/videoInfo/drawable, 预览跟随比例、不出现尺寸不匹配那一帧。
    self.paramsModel.onOutputSizeChanged = ^{
        __strong typeof(weakSelfParams) sSelf = weakSelfParams;
        if (sSelf == nil) {
            return;
        }
        [sSelf applyPreviewOutputSizeToStabilizer];
    };

    // MVC 装配:陀螺时间轴
    self.gyroModel = [[GyroTimelineModel alloc] init];
    self.gyroTimelineView = [[GyroTimelineView alloc] initWithFrame:CGRectZero];
    self.gyroTimelineView.translatesAutoresizingMaskIntoConstraints = NO;
    // 拖动 / 点击时间轴 -> seek 到对应位置
    __weak typeof(self) weakSelfTimeline = self;
    self.gyroTimelineView.onSeek = ^(double progress) {
        __strong typeof(weakSelfTimeline) sSelf = weakSelfTimeline;
        if (sSelf == nil || !sSelf->_mdkPlayer || !sSelf.playbackReady) {
            return;
        }
        double durMs = sSelf.videoInfo.duration_s * 1000.0;
        if (durMs <= 0.0) {
            return;
        }
        int64_t pos = (int64_t)llround(progress * durMs);
        sSelf->_mdkPlayer->seek(pos);
    };

    // videoView 长宽比 / 时间轴高度 是「自身约束」(只约束自己的 width/height),
    // 不依赖容器, 在竖屏/横屏布局间复用、不随重建失效。创建并激活一次。
    self.videoAspectConstraint = [self.videoView.heightAnchor constraintEqualToAnchor:self.videoView.widthAnchor multiplier:9.0 / 16.0];
    [NSLayoutConstraint activateConstraints:@[
        self.videoAspectConstraint,
        [self.gyroTimelineView.heightAnchor constraintEqualToConstant:64.0],
        [self.buttonRow.heightAnchor constraintEqualToConstant:44.0],   // 播放/防抖按钮固定高度
        [self.tabScroll.heightAnchor constraintGreaterThanOrEqualToConstant:200.0],
    ]];

    // 自适应布局:iPad 横屏=三栏(输入/预览/参数), 其余(iPad竖屏+iPhone)=单列 Tab。
    [self rebuildAdaptiveLayout];

    // 安全区域 overlay layer：挂到 videoView，显示/隐藏由 paramsModel.showSafeArea 控制。
    self.safeAreaLayer = [CAShapeLayer layer];
    self.safeAreaLayer.fillColor = UIColor.clearColor.CGColor;
    // 跟主题色橙保持一致（之前是黄色 RGB(1.0,0.85,0)，跟黑底 + 橙强调的整体风格不搭）
    self.safeAreaLayer.strokeColor = [GFTheme primaryColor].CGColor;
    self.safeAreaLayer.lineWidth = 2.0;
    self.safeAreaLayer.hidden = YES;
    [self.videoView.layer addSublayer:self.safeAreaLayer];

    // 启动时恢复历史授权目录进 gyroflow 白名单 —— 对齐官方 App.qml:679
    // restore_allowed_folders: 授权过的目录持久生效, 同名 sidecar 自动加载不用每次会话重新授权。
    [self restoreGrantedFolders];
    // 恢复用户上次选定的导出存储目录(「…」按钮, 无则默认存相册)
    [self restoreExportFolder];

    // 监听键盘弹出/收起,自动把被遮的输入框滚动到可见区
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillShow:)
                                                 name:UIKeyboardWillShowNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillHide:)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];

    // 点击空白处收键盘（cancelsTouchesInView=NO 让按钮 / cell 仍能响应）
    UITapGestureRecognizer *tapToDismiss = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboardOnBackgroundTap)];
    tapToDismiss.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:tapToDismiss];
    [self.view bringSubviewToFront:self.analysisMask];
    [self.view bringSubviewToFront:self.syncOverlay];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // 启动时 viewDidLoad 的 bounds 可能还不是最终朝向, 这里按真实 bounds 校正一次;
    // rebuildAdaptiveLayout 内有「模式未变则跳过」守卫, 之后即空操作, 不会布局循环。
    [self rebuildAdaptiveLayout];
    [self updateSafeAreaOverlay];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self releaseCurrentSecurityScope];
    if (_mainThreadWatchdog) {
        dispatch_source_cancel(_mainThreadWatchdog);
    }
    // 排干渲染队列在飞的 draw(队列里 weakSelf 已为 nil, 只需等正在执行的那次),
    // 再销毁 player / stabilizer。
    [self drainRenderQueue];
    if (_mdkPlayer) {
        _mdkPlayer->set(mdk::State::Stopped);
        _mdkPlayer.reset();
    }
    if (self.stabilizer != NULL) {
        gyroflow_stabilizer_free(self.stabilizer);
        self.stabilizer = NULL;
    }
}

- (void)selectVideo {
    self.pickingLensProfile = NO;
    self.pickingMotionData = NO;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeMovie]];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)selectMotionData {
    self.pickingLensProfile = NO;
    self.pickingMotionData = YES;
    // .gcsv / .csv / .bbl / .bfl —— 都按通用数据/文本类型选,拿到再交给 Rust 按内容识别
    NSMutableArray<UTType *> *types = [NSMutableArray array];
    [types addObject:UTTypeData];
    [types addObject:UTTypePlainText];
    UTType *csv = [UTType typeWithIdentifier:@"public.comma-separated-values-text"];
    if (csv) [types addObject:csv];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

// 「授权视频所在文件夹」—— 弹系统目录选择器。授权后注册进 gyroflow 目录白名单并
// 重载视频, 让 telemetry-parser 的同名 sidecar 自动检测(gcsv/bbl/bfl/csv)生效。
// 适用场景: 视频经 Files 从外部目录(iCloud Drive/其它 App 文件夹)选入,
// 单文件 security scope 不覆盖同目录其它文件。
- (void)selectMotionFolder {
    self.pickingLensProfile = NO;
    self.pickingMotionData = NO;
    self.pickingMotionFolder = YES;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder]];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    picker.directoryURL = self.securityScopedURL.URLByDeletingLastPathComponent; // 默认定位到视频所在目录
    [self presentViewController:picker animated:YES completion:nil];
}

// —— 授权目录持久化: 对齐官方 save/restore_allowed_folders(core/filesystem/mod.rs:609-634,
// macOS/iOS 用 security-scoped bookmark 存设置、启动恢复)。FFI 没暴露这两个函数,
// 在 App 层用 NSURL 书签 + NSUserDefaults 实现同等语义。 ——
static NSString * const kGFGrantedFolderBookmarksKey = @"gf_granted_folder_bookmarks";

// 导出存储目录书签持久化(单条, 覆盖式): 重启后 restoreExportFolder 恢复。
static NSString * const kGFExportFolderBookmarkKey = @"gf_export_folder_bookmark";

// 启动时恢复导出存储目录(用户上次选定/授权的)。失效/被删则保持 nil,下次导出强制重新授权。
- (void)restoreExportFolder {
    NSURL *url = [GFBookmarkStore resolveFolderForKey:kGFExportFolderBookmarkKey];
    if (url != nil) {
        self.exportFolderURL = [url startAccessingSecurityScopedResource] ? url : nil;
    }
    // 「输出路径:」同行显示当前导出目录(末两级路径, 未授权→「未选择」)
    [self.exportSection setExportFolderDisplay:[self exportFolderDisplayString:self.exportFolderURL]];
}

// 导出目录显示串: 只显示用户文件夹层级、剥掉系统沙盒前缀(照搬官方
// filesystem::display_url, core/filesystem/mod.rs:531-556)。nil → nil。
- (NSString *)exportFolderDisplayString:(NSURL *)url {
    if (url == nil) {
        return nil;
    }
    NSString *path = url.path;
    // 目录统一补尾部 "/"(对齐官方 normalize_url 对 folder 的处理): 否则选的是某层根目录
    // (路径正好停在锚点、无尾斜杠)时匹配不到锚点 → 回落显示整串系统路径。
    if (![path hasSuffix:@"/"]) {
        path = [path stringByAppendingString:@"/"];
    }
    // 外部目录(Files/iCloud Drive 选入)
    NSRange r = [path rangeOfString:@"/File Provider Storage/"];
    if (r.location != NSNotFound) {
        return [path substringFromIndex:NSMaxRange(r)];
    }
    r = [path rangeOfString:@"/com~apple~CloudDocs/"];
    if (r.location != NSNotFound) {
        return [@"iCloud/" stringByAppendingString:[path substringFromIndex:NSMaxRange(r)]];
    }
    // App 容器: .../Data/Application/<UUID>/Documents/... → 去掉 UUID, 留 Documents 起
    for (NSString *anchor in @[@"/Data/Application/", @"/com.apple.filesystems.userfsd/"]) {
        NSRange a = [path rangeOfString:anchor];
        if (a.location != NSNotFound) {
            NSString *after = [path substringFromIndex:NSMaxRange(a)]; // "<UUID>/..."
            NSRange slash = [after rangeOfString:@"/"];
            return (slash.location != NSNotFound) ? [after substringFromIndex:NSMaxRange(slash)] : after;
        }
    }
    return path;
}

// 「导出」按钮可用态(对齐官方 canExport): 引擎就绪 + 输出大小合法 + 未在导出中 +
// 文件名长度 > 3(App.qml:253)。各状态变化后统一调它, 避免散落的判断不一致。
- (void)updateExportButtonEnabled {
    BOOL nameOk = (self.exportSection.outputFileName.length > 3);
    self.exportButton.enabled = self.gyroflowReady && self.exportResolutionOk && !self.exporting && nameOk;
}

// 打开导出存储目录选择器(「…」按钮与导出前强制授权共用)。
- (void)presentExportFolderPicker {
    self.pickingExportFolder = YES;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder]];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    picker.directoryURL = self.exportFolderURL;
    [self presentViewController:picker animated:YES completion:nil];
}

// 导出前的"请选择目标文件夹"提示「不再显示」持久化键(对齐官方文件访问限制说明)。
static NSString * const kGFExportFolderHintKey = @"gf_dontShowAgain_exportFolderHint";

// 启动时把持久化的授权目录恢复进白名单。startAccessing 不配对 stop ——
// 对齐官方 folder_access_granted 的语义(访问期未知, 一直持有, mod.rs:600)。
- (void)restoreGrantedFolders {
    for (NSURL *url in [GFBookmarkStore resolveFoldersForListKey:kGFGrantedFolderBookmarksKey]) {
        [url startAccessingSecurityScopedResource];
        gyroflow_folder_access_granted(url.absoluteString.UTF8String);
        NSLog(@"[Gyroflow] 已恢复授权目录: %@", url.absoluteString);
    }
}

- (void)selectLensProfile {
    self.pickingLensProfile = YES;
    UTType *jsonType = [UTType typeWithIdentifier:@"public.json"] ?: UTTypeJSON;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[jsonType]];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)togglePlayPause {
    if (!_mdkPlayer || !self.playbackReady) {
        return;
    }
    self.videoPaused = !self.videoPaused;
    if (self.videoPaused) {
        _mdkPlayer->set(mdk::State::Paused);
        [self.playPauseButton setTitle:@"播放" forState:UIControlStateNormal];
    } else {
        _mdkPlayer->set(mdk::State::Playing);
        [self.playPauseButton setTitle:@"暂停" forState:UIControlStateNormal];
    }
}

- (void)toggleStabilization {
    self.stabilizationEnabled = !self.stabilizationEnabled;
    self.hasRenderedStabilizedFrame = NO;
    [self.stabilizationButton setTitle:(self.stabilizationEnabled ? @"关闭防抖" : @"开启防抖") forState:UIControlStateNormal];
    [self updateDrawableSizeForCurrentMode];
    [self requestPreviewDraw];

    if (self.stabilizationEnabled && !self.gyroflowReady) {
        self.statusLabel.text = @"视频继续播放；Gyroflow 仍在后台加载，加载完成后自动进入防抖输出。";
    } else if (self.stabilizationEnabled) {
        self.statusLabel.text = @"MDK + Metal 防抖已开启，使用播放器帧时间戳渲染。";
    } else {
        self.statusLabel.text = @"已关闭防抖，MDK 原始画面继续播放。";
    }
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (url == nil) {
        return;
    }

    // 分支:这次 pick 的是导出存储目录 / 目录授权 / 镜头档案 / 运动数据 / 视频
    if (self.pickingExportFolder) {
        self.pickingExportFolder = NO;
        // 换目录时释放旧 scope; 新目录 scope 一直持有(导出随时可能发生)
        if (self.exportFolderURL) {
            [self.exportFolderURL stopAccessingSecurityScopedResource];
        }
        self.exportFolderURL = [url startAccessingSecurityScopedResource] ? url : nil;
        [GFBookmarkStore setFolderBookmark:url forKey:kGFExportFolderBookmarkKey];
        [GFViewKit toast:[NSString stringWithFormat:@"导出将保存到: %@", url.lastPathComponent] inView:self.view];
        [self.exportSection setExportFolderDisplay:[self exportFolderDisplayString:self.exportFolderURL]]; // 「输出路径:」同行更新目录(末两级路径)
        [self resolveOutputFileNameConflict];   // 换目录后按新目录重新查重当前文件名
        // 若这次授权是导出前强制触发的 → 授权成功后接着导出
        if (self.pendingExportSrcURL != nil && self.exportFolderURL != nil) {
            NSURL *src = self.pendingExportSrcURL;
            self.pendingExportSrcURL = nil;
            [self beginExportFromURL:src];
        }
        return;
    }
    if (self.pickingMotionFolder) {
        self.pickingMotionFolder = NO;
        // 换目录时释放旧 scope; 新目录 scope 一直持有(sidecar 检测随时可能发生)
        if (self.motionFolderScopedURL) {
            [self.motionFolderScopedURL stopAccessingSecurityScopedResource];
        }
        self.motionFolderScopedURL = [url startAccessingSecurityScopedResource] ? url : nil;
        gyroflow_folder_access_granted(url.absoluteString.UTF8String);
        // 持久化授权目录(对齐官方 OutputPathField.qml:125-126 folder_access_granted + save_allowed_folders)
        [GFBookmarkStore addFolderBookmark:url toListKey:kGFGrantedFolderBookmarksKey];
        // 扫描目录及子目录找当前视频的同名运动数据/镜头文件并加载
        [self scanGrantedFolder:url];
        return;
    }
    if (self.pickingMotionData) {
        self.pickingMotionData = NO;
        [self loadMotionDataFromURL:url loadAllMetadata:[self.inputTab loadAllMetadataChecked]];
        return;
    }
    if (self.pickingLensProfile) {
        self.pickingLensProfile = NO;
        [self loadLensProfileFromURL:url];
        return;
    }

    [self releaseCurrentSecurityScope];
    self.securityScopedURL = url;
    self.hasSecurityScope = [url startAccessingSecurityScopedResource];

    // 新视频: 外挂运动数据状态复位(引擎随全新 stabilizer 自动归零, 这里只复位 UI);
    // 「打开文件」在视频载入完成前禁用(对齐官方 MotionData.qml:36 无视频拒绝加载)。
    self.lastMotionDataURL = nil;
    [self.inputTab setExternalMotionControlsVisible:NO];
    [self.inputTab setMotionOpenFileEnabled:NO]; // 载入完成后按 hasMotion 重新决定显隐
    [self.inputTab setVideoDirHintVisible:NO];       // 蓝色目录授权提示同理, 载入完成后再决定
    self.pendingScanLensURL = nil;                   // 上一个视频扫描到的镜头不带入新视频

    // 注册视频父目录到 gyroflow 目录白名单 —— iOS 沙盒下 get_folder 只认白名单
    // (ALLOWED_FOLDERS, core/filesystem/mod.rs:253-260), 不注册则同名 sidecar
    // 自动加载永远失效。App 容器内的视频注册即生效; Files 选的外部目录单文件
    // scope 不覆盖邻居, 还需用户走「授权视频所在文件夹」目录选择器。
    gyroflow_folder_access_granted(url.URLByDeletingLastPathComponent.absoluteString.UTF8String);

    self.loadGeneration += 1;
    NSInteger generation = self.loadGeneration;

    [self startMDKPlaybackWithURL:url generation:generation];
    [self loadGyroflowForURL:url generation:generation];
}

// 选择器取消: 清掉本次 pick 意图(否则下次 pick 会走错分支)。
// 若是"导出前强制授权目标文件夹"被取消 → 中止导出, 不回落相册(对齐官方:必须授权)。
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    BOOL wasExportFolder = self.pickingExportFolder;
    self.pickingExportFolder = NO;
    self.pickingMotionFolder = NO;
    self.pickingMotionData = NO;
    self.pickingLensProfile = NO;
    if (wasExportFolder && self.pendingExportSrcURL != nil) {
        self.pendingExportSrcURL = nil;
        self.statusLabel.text = @"已取消导出：需要先选择目标文件夹才能导出。";
    }
}

// 授权目录后的自动扫描: 递归(含子目录)找「与当前视频同名」的运动数据(gcsv/bbl/bfl/csv)
// 和镜头(json)文件。
// - 同名运动数据在视频同目录(或没找到) → 对齐官方 VideoInformation.qml:174: 重载视频,
//   core 的 sidecar 自动检测 + gcsv 内 lensprofile 字段自动配镜头一并生效;
// - 在子目录 → core 的同目录检测够不到, 走手动加载链路(含按相机自动配镜头 + 自动同步);
// - 同名镜头 json → 记入 pendingScanLensURL, 视频加载链路末尾仍无镜头时兜底加载
//   (官方 core 只认 gcsv 内 lensprofile 字段, 不认识同名 json, 这里是产品扩展)。
- (void)scanGrantedFolder:(NSURL *)folder {
    if (self.securityScopedURL == nil) {
        return;
    }
    NSString *base = self.securityScopedURL.lastPathComponent.stringByDeletingPathExtension;
    NSString *videoDirPath = self.securityScopedURL.URLByDeletingLastPathComponent.path;
    NSArray<NSString *> *motionExts = @[@"gcsv", @"bbl", @"bfl", @"csv"];
    NSURL *motionURL = nil;
    NSURL *lensURL = nil;
    NSDirectoryEnumerator<NSURL *> *files =
        [[NSFileManager defaultManager] enumeratorAtURL:folder
                              includingPropertiesForKeys:@[NSURLIsRegularFileKey]
                                                 options:NSDirectoryEnumerationSkipsHiddenFiles
                                            errorHandler:nil];
    for (NSURL *f in files) {
        if (![f.lastPathComponent.stringByDeletingPathExtension isEqualToString:base]) {
            continue;
        }
        NSString *ext = f.pathExtension.lowercaseString;
        if (motionURL == nil && [motionExts containsObject:ext]) {
            motionURL = f;
        } else if (lensURL == nil && [ext isEqualToString:@"json"]) {
            lensURL = f;
        }
        if (motionURL != nil && lensURL != nil) {
            break;
        }
    }
    NSLog(@"[Gyroflow] 授权目录扫描: motion=%@ lens=%@", motionURL.path ?: @"无", lensURL.path ?: @"无");
    self.pendingScanLensURL = lensURL;

    BOOL motionInVideoDir = (motionURL != nil
        && [motionURL.URLByDeletingLastPathComponent.path isEqualToString:videoDirPath]);
    if (motionURL != nil && !motionInVideoDir) {
        // 子目录里的同名运动数据: 手动链路同步执行, 完成后镜头仍缺则用扫描到的 json 兜底
        [self loadMotionDataFromURL:motionURL loadAllMetadata:[self.inputTab loadAllMetadataChecked]];
        if (lensURL != nil && self.stabilizer != NULL && gyroflow_has_lens_profile(self.stabilizer) != 0) {
            self.pendingScanLensURL = nil;
            [self loadLensProfileFromURL:lensURL];
        }
        [self refreshVideoDirHint];
        return;
    }
    // 同目录或未找到: 重载视频(官方授权后语义), pendingScanLensURL 在加载链路末尾消费
    if (self.securityScopedURL) {
        self.loadGeneration += 1;
        [self.inputTab setMotionOpenFileEnabled:NO];
        [self loadGyroflowForURL:self.securityScopedURL generation:self.loadGeneration];
    }
}

// 蓝色目录授权提示框显隐: 视频已载入且(无运动数据 或 无镜头)时显示。
- (void)refreshVideoDirHint {
    if (self.stabilizer == NULL) {
        [self.inputTab setVideoDirHintVisible:NO];
        return;
    }
    BOOL hasMotion = (gyroflow_has_motion_data(self.stabilizer) == 0);
    BOOL hasLens = (gyroflow_has_lens_profile(self.stabilizer) == 0);
    [self.inputTab setVideoDirHintVisible:(!hasMotion || !hasLens)];
}

- (void)loadLensProfileFromURL:(NSURL *)url {
    if (self.stabilizer == NULL) {
        self.statusLabel.text = @"先加载一个视频再选择镜头档案。";
        return;
    }
    BOOL needsReleaseScope = [url startAccessingSecurityScopedResource];
    int32_t rc = gyroflow_load_lens_profile(self.stabilizer, url.path.UTF8String);
    if (needsReleaseScope) {
        [url stopAccessingSecurityScopedResource];
    }
    if (rc != 0) {
        NSString *msg = [self lastGyroflowError];
        self.statusLabel.text = [NSString stringWithFormat:@"镜头档案加载失败:%@", msg];
        return;
    }
    gyroflow_apply_loaded_lens_extras(self.stabilizer);  // 应用档案自带 frame_readout/gyro_lpf(对齐官方)
    // 加载完后内部会 recompute_blocking。刷新 UI 状态。
    GyroflowVideoInfo updated = {0};
    gyroflow_get_video_info(self.stabilizer, &updated);
    self.videoInfo = updated;
    [self updateDrawableSizeForCurrentMode];
    self.lensWarningBanner.hidden = YES;  // 已手动加载镜头档案, 收起警告横幅
    NSString *fileName = url.lastPathComponent;

    // 用户反馈:镜头上传完**不要**立即播放,要等用户跑完自动同步后再播。
    // 我们保持暂停,提示用户接下来该做什么。autosync 完成的 onFinished 里会
    // 强制 set(Playing) 把播放接起来。
    self.statusLabel.text = [NSString stringWithFormat:@"✓ 已加载镜头档案:%@,请点「自动同步」运行光流估姿后开始播放。", fileName];
    [self refreshInputTabLensInfo];
    [self refreshVideoDirHint];
}

- (void)loadMotionDataFromURL:(NSURL *)url loadAllMetadata:(BOOL)loadAllMetadata {
    if (self.stabilizer == NULL) {
        self.statusLabel.text = @"先加载一个视频再上传陀螺数据。";
        return;
    }
    BOOL needsReleaseScope = [url startAccessingSecurityScopedResource];
    // loadAllMetadata 对齐官方「Load all metadata」(默认不勾): 不勾只取陀螺流,
    // 勾上按主视频完整解析(镜头档案/fps/卷帘)。
    int32_t rc = gyroflow_load_gyro_data(self.stabilizer, url.path.UTF8String, loadAllMetadata ? 1 : 0);
    if (needsReleaseScope) {
        [url stopAccessingSecurityScopedResource];
    }
    if (rc != 0) {
        NSString *msg = [self lastGyroflowError];
        [self.inputTab setMotionStatus:[NSString stringWithFormat:@"陀螺数据加载失败:%@", msg]];
        self.statusLabel.text = [NSString stringWithFormat:@"陀螺数据加载失败:%@", msg];
        return;
    }
    // 记住文件并亮出「加载全部元数据/帧偏移」(仅外挂文件场景, 对齐官方可见条件);
    // 勾选切换时用 lastMotionDataURL 重载。
    self.lastMotionDataURL = url;
    [self.inputTab setExternalMotionControlsVisible:YES];  // 已手动加载运动数据, 收起目录授权提示

    // 清除上一份运动数据算出的同步点/偏移 —— 引擎已在 load_gyro_data 里清掉
    // (gyro.clear() → clear_offsets, core/gyro_source/mod.rs:517-527), 这里把
    // UI/ParamsModel 同步归零(对齐官方 telemetry_loaded → update_offset_model)。
    // 否则旧偏移残留显示, 且会被当作下次 autosync 的 initialOffsetMs 污染检测。
    self.paramsModel.gyroOffsetMs = 0;
    [self.syncSection refreshGyroOffsetFromModel];
    [self.gyroTimelineView setSyncPoints:nil];
    self.syncPointCount = 0;
    [self.syncSection setHasSyncPoints:NO];

    BOOL hasMotion = (gyroflow_has_motion_data(self.stabilizer) == 0);

    // #2 自动选积分方式(对齐官方 MotionData.qml): 外挂陀螺多为原始 IMU →
    //    默认 VQF; 视频 < 10s → Complementary。FFI 索引: 1=Complementary, 2=VQF
    //    (0=None 用原生四元数, 外挂 sidecar 一般没有, 故不用)。
    double durSec = self.videoInfo.duration_s;
    uint32_t integ = (durSec > 0.0 && durSec < 10.0) ? 1u : 2u;
    gyroflow_set_integration_method(self.stabilizer, integ);
    gyroflow_recompute_blocking(self.stabilizer);   // 同步重积分+重算, 供下面 autosync 用
    // UI 下拉同步: 外挂 gcsv 为 raw IMU(无原生四元数), 列表不含 None
    [self.inputTab configureIntegrationMethodsHasQuaternions:NO selectedFFIIndex:(NSInteger)integ];

    // 刷新陀螺波形 + 视频信息
    [self.gyroModel loadFromStabilizer:self.stabilizer sampleCount:600];
    self.gyroTimelineView.model = self.gyroModel;
    [self.inputTab setMotionStatus:[NSString stringWithFormat:@"✓ 已加载陀螺数据:%@(has_motion=%d)", url.lastPathComponent, hasMotion]];
    // 用户手动上传 .gcsv/.csv/.bbl —— 格式 = 文件扩展名，文件名 = 实际文件名
    NSString *ext = url.pathExtension.uppercaseString ?: @"";
    [self.inputTab setMotionInfoFormat:(ext.length > 0 ? ext : @"IMU sidecar")
                              fileName:url.lastPathComponent
                                loaded:hasMotion];
    [self refreshInputTabVideoInfo];

    // 相机身份(camera_id)是随 .gcsv 加载才确定的(视频本身无 telemetry, 如 RunCam 6) →
    // 现在按它自动从内置库匹配并加载镜头(对齐桌面端「打开视频自动加载镜头」)。
    // 仅在当前尚无镜头时尝试, 不覆盖用户手动加载的镜头。放在 autosync 之前 ——
    // autosync 需要镜头反畸变, 这样能顺带解决「没镜头跑不了同步」。
    if (gyroflow_has_lens_profile(self.stabilizer) != 0) {   // !=0 表示当前没镜头
        int32_t lr = gyroflow_autoload_lens_for_camera(self.stabilizer);
        if (lr == 0) {
            gyroflow_apply_loaded_lens_extras(self.stabilizer);  // 应用档案 frame_readout/gyro_lpf
            [self refreshInputTabLensInfo];
            self.lensWarningBanner.hidden = YES;  // 预览黄条: 已自动加载镜头, 收起
                    NSLog(@"[Gyroflow] 已按相机自动加载镜头档案(gcsv 加载后)");
        } else {
            NSLog(@"[Gyroflow] 相机无可匹配镜头档案 rc=%d", lr);
        }
    }
    // 刷新「IMU 朝向」—— 真实值是随 .gcsv 加载才有的(如 RunCam6 = xYz)。
    char imuOriBuf2[16] = {0};
    if (gyroflow_get_imu_orientation(self.stabilizer, imuOriBuf2, sizeof(imuOriBuf2)) == 0) {
        [self.inputTab setIMUOrientationText:[NSString stringWithUTF8String:imuOriBuf2]];
    }

    // #1 自动同步 —— 对齐官方(Synchronization.qml:59-72)/安卓(maybeAutoSync)四门槛:
    //    do_autosync(镜头档案声明, 上面 autoload 配上 RunCam 档案后 refreshInputTabLensInfo
    //    已解析进 lensDoAutosync) + 有运动数据 + 无精确时间戳 + 没在同步中。
    //    不满足时由用户手动点「自动同步」。startAutosync 自带前置判断:
    //    无镜头档案会弹提示让用户先传镜头(autosync 需要镜头反畸变)。
    int32_t hasAccurate = gyroflow_has_accurate_timestamps(self.stabilizer);
    self.hasAccurateTimestamps = (hasAccurate == 1);
    self.motionFromVideo = NO;   // 外挂运动数据(loadMotionDataFromURL)→ 非视频自带, usesQuats=false(对齐官方 filename 不匹配)
    [self refreshUsesQuats];
    [self refreshVideoDirHint];
    if (self.lensDoAutosync && hasMotion && hasAccurate != 1 && self.autosyncRunner == nil) {
        self.statusLabel.text = @"✓ 陀螺数据已加载,正在自动同步…";
        [self startAutosync];
    } else {
        [self.paramsModel scheduleRecompute];
        self.statusLabel.text = @"✓ 陀螺数据已加载,可直接开启防抖或导出。";
    }
}

#pragma mark - 三 Tab 切换 + 输入页接线

- (void)tabChanged:(GFSegmentedTabs *)seg {
    switch (seg.selectedSegmentIndex) {
        case 0: [self showTabContainer:self.inputContainer]; break;
        case 1: [self showTabContainer:self.paramsContainer]; break;
        case 2: [self showTabContainer:self.exportContainer]; break;
    }
}

- (void)showTabContainer:(UIView *)container {
    // 清掉 tabScroll 现有子视图
    for (UIView *v in self.tabScroll.subviews) { [v removeFromSuperview]; }
    container.translatesAutoresizingMaskIntoConstraints = NO;
    [self.tabScroll addSubview:container];
    [NSLayoutConstraint activateConstraints:@[
        [container.topAnchor      constraintEqualToAnchor:self.tabScroll.topAnchor],
        [container.bottomAnchor   constraintEqualToAnchor:self.tabScroll.bottomAnchor],
        [container.leadingAnchor  constraintEqualToAnchor:self.tabScroll.leadingAnchor],
        [container.trailingAnchor constraintEqualToAnchor:self.tabScroll.trailingAnchor],
        [container.widthAnchor    constraintEqualToAnchor:self.tabScroll.widthAnchor],
    ]];
}

#pragma mark - 自适应布局(iPad 横屏三栏 / 其余单列 Tab)

- (BOOL)shouldUseThreeColumnForSize:(CGSize)size {
    BOOL pad = (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad);
    return pad && (size.width > size.height);
}

- (void)rebuildAdaptiveLayout {
    [self applyAdaptiveLayoutForThreeColumn:[self shouldUseThreeColumnForSize:self.view.bounds.size]];
}

- (void)applyAdaptiveLayoutForThreeColumn:(BOOL)threeCol {
    if (self.adaptiveLayoutBuilt && threeCol == self.threeColumnApplied) {
        return;  // 模式没变, 不重建
    }
    [self teardownCurrentLayout];
    if (threeCol) { [self buildLandscapeLayout]; }
    else          { [self buildPortraitLayout]; }
    self.threeColumnApplied = threeCol;
    self.adaptiveLayoutBuilt = YES;
}

// 把所有共享视图从父视图摘下, 移除旧顶层容器, 便于重挂到新布局。
- (void)teardownCurrentLayout {
    NSArray<UIView *> *shared = @[
        self.videoView, self.gyroTimelineView, self.buttonRow, self.tabSegmented,
        self.tabScroll, self.inputTab, self.syncSection, self.stabilizeSection,
        self.advancedSection, self.exportSection,
        self.exportProgress,   // exportButton 常驻 exportSection 卡片内, 不单独摘挂
    ];
    for (UIView *v in shared) {
        if ([v isKindOfClass:[UIView class]]) { [v removeFromSuperview]; }
    }
    [self.currentLayoutRoot removeFromSuperview];
    self.currentLayoutRoot = nil;
}

// 竖屏 / iPhone: 单列(预览+时间轴+按钮+Tab切换+Tab内容)。
- (void)buildPortraitLayout {
    self.tabSegmented.hidden = NO;
    self.exportSection.sizeRowStacked = NO;   // 竖屏: 输出大小单行(标签+控件同行)

    UIStackView *paramsStack = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.syncSection, self.stabilizeSection, self.advancedSection]];
    paramsStack.axis = UILayoutConstraintAxisVertical;
    paramsStack.spacing = 12.0;
    paramsStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.paramsContainer = paramsStack;

    UIStackView *exportStack = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.exportSection, self.exportProgress]];
    exportStack.axis = UILayoutConstraintAxisVertical; exportStack.spacing = 12.0;
    exportStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.exportContainer = exportStack;

    self.inputContainer = self.inputTab;

    // 预览容器: videoView 在其中居中、aspect-fit, 高度封顶(安全区 45%), 对齐官方桌面版
    // VideoArea.qml 的信箱式缩放——输出比例再高也不把下方 Tab 挤出屏幕(同三栏布局做法)。
    UIView *previewContainer = [[UIView alloc] init];
    previewContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.videoView.translatesAutoresizingMaskIntoConstraints = NO;
    [previewContainer addSubview:self.videoView];
    NSLayoutConstraint *vFillW = [self.videoView.widthAnchor constraintEqualToAnchor:previewContainer.widthAnchor];
    vFillW.priority = 999;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        previewContainer, self.gyroTimelineView, self.buttonRow, self.tabSegmented, self.tabScroll]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    self.mainStack = stack;
    self.currentLayoutRoot = stack;
    // 放最底层: 蒙版(viewDidLoad 加)和返回按钮(GyroflowLauncher 后加)自然在其之上, 不被盖住。
    [self.view insertSubview:stack atIndex:0];

    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor  constraintEqualToAnchor:guide.leadingAnchor  constant:16.0],
        [stack.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-16.0],
        [stack.topAnchor      constraintEqualToAnchor:guide.topAnchor      constant:24.0],
        [stack.bottomAnchor   constraintEqualToAnchor:guide.bottomAnchor   constant:-12.0],
        // 容器高度跟随视频(required), 视频高封顶 45% 安全区(required), 铺满宽 999;
        // 比例过高时 999 让步 → 视频等比缩小、水平居中, Tab 区域不再被挤压。
        [previewContainer.heightAnchor constraintEqualToAnchor:self.videoView.heightAnchor],
        [self.videoView.heightAnchor  constraintLessThanOrEqualToAnchor:guide.heightAnchor multiplier:0.45],
        [self.videoView.widthAnchor   constraintLessThanOrEqualToAnchor:previewContainer.widthAnchor],
        [self.videoView.centerXAnchor constraintEqualToAnchor:previewContainer.centerXAnchor],
        [self.videoView.centerYAnchor constraintEqualToAnchor:previewContainer.centerYAnchor],
        vFillW,
    ]];

    NSInteger idx = self.tabSegmented.selectedSegmentIndex;
    UIView *cur = (idx == 1) ? self.paramsContainer : (idx == 2) ? self.exportContainer : self.inputContainer;
    [self showTabContainer:cur];
}

// iPad 横屏: 三栏。左=输入, 中=预览+时间轴+播放/防抖, 右=同步/稳定/导出/高级(可滚动)。
- (void)buildLandscapeLayout {
    self.tabSegmented.hidden = YES;
    self.exportSection.sizeRowStacked = YES;   // 横屏窄列: 输出大小两行(标签上/控件下)
    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;

    // 左栏: 输入(滚动)
    UIScrollView *leftScroll = [[UIScrollView alloc] init];
    leftScroll.translatesAutoresizingMaskIntoConstraints = NO;
    leftScroll.showsVerticalScrollIndicator = NO;
    leftScroll.showsHorizontalScrollIndicator = NO;
    [leftScroll addSubview:self.inputTab];

    // 中栏: 预览容器(填满剩余高度) + 时间轴(固定) + 播放/防抖(固定)。
    // 预览容器高度随屏幕自适应; videoView 在其中居中、按比例 aspect-fit, 不反向约束容器。
    UIView *previewContainer = [[UIView alloc] init];
    previewContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.videoView.translatesAutoresizingMaskIntoConstraints = NO;
    [previewContainer addSubview:self.videoView];
    NSLayoutConstraint *vFillW = [self.videoView.widthAnchor  constraintEqualToAnchor:previewContainer.widthAnchor];
    vFillW.priority = 999;
    NSLayoutConstraint *vFillH = [self.videoView.heightAnchor constraintEqualToAnchor:previewContainer.heightAnchor];
    vFillH.priority = 999;

    UIStackView *centerStack = [[UIStackView alloc] initWithArrangedSubviews:@[
        previewContainer, self.gyroTimelineView, self.buttonRow]];
    centerStack.axis = UILayoutConstraintAxisVertical;
    centerStack.spacing = 12.0;
    centerStack.translatesAutoresizingMaskIntoConstraints = NO;

    // 右栏: 同步/稳定/导出(设置+按钮+进度+提示)/高级(滚动)
    UIStackView *rightStack = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.syncSection, self.stabilizeSection,
        self.exportSection, self.exportProgress,
        self.advancedSection]];
    rightStack.axis = UILayoutConstraintAxisVertical; rightStack.spacing = 12.0;
    rightStack.translatesAutoresizingMaskIntoConstraints = NO;
    UIScrollView *rightScroll = [[UIScrollView alloc] init];
    rightScroll.translatesAutoresizingMaskIntoConstraints = NO;
    rightScroll.showsVerticalScrollIndicator = NO;
    rightScroll.showsHorizontalScrollIndicator = NO;
    [rightScroll addSubview:rightStack];

    UIView *columns = [[UIView alloc] init];
    columns.translatesAutoresizingMaskIntoConstraints = NO;
    [columns addSubview:leftScroll];
    [columns addSubview:centerStack];
    [columns addSubview:rightScroll];
    self.currentLayoutRoot = columns;
    // 放最底层: 蒙版和返回按钮自然在其之上, 不被左栏盖住。
    [self.view insertSubview:columns atIndex:0];

    [NSLayoutConstraint activateConstraints:@[
        [columns.leadingAnchor  constraintEqualToAnchor:guide.leadingAnchor  constant:16.0],
        [columns.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-16.0],
        [columns.topAnchor      constraintEqualToAnchor:guide.topAnchor      constant:24.0],
        [columns.bottomAnchor   constraintEqualToAnchor:guide.bottomAnchor   constant:-12.0],
        // 左栏(26%)
        [leftScroll.leadingAnchor constraintEqualToAnchor:columns.leadingAnchor],
        [leftScroll.topAnchor     constraintEqualToAnchor:columns.topAnchor],
        [leftScroll.bottomAnchor  constraintEqualToAnchor:columns.bottomAnchor],
        [leftScroll.widthAnchor   constraintEqualToAnchor:columns.widthAnchor multiplier:0.26],
        // 右栏(32%)
        [rightScroll.trailingAnchor constraintEqualToAnchor:columns.trailingAnchor],
        [rightScroll.topAnchor      constraintEqualToAnchor:columns.topAnchor],
        [rightScroll.bottomAnchor   constraintEqualToAnchor:columns.bottomAnchor],
        [rightScroll.widthAnchor    constraintEqualToAnchor:columns.widthAnchor multiplier:0.26],
        // 中栏(余下, 占满列高; 预览容器吸收剩余高度, 陀螺/按钮固定高度)
        [centerStack.leadingAnchor  constraintEqualToAnchor:leftScroll.trailingAnchor  constant:12.0],
        [centerStack.trailingAnchor constraintEqualToAnchor:rightScroll.leadingAnchor constant:-12.0],
        [centerStack.topAnchor      constraintEqualToAnchor:columns.topAnchor],
        [centerStack.bottomAnchor   constraintEqualToAnchor:columns.bottomAnchor],
        // 预览在容器内居中 + aspect-fit(≤ required / 铺满 999 / 长宽比 required, 不反向约束容器)
        [self.videoView.centerXAnchor constraintEqualToAnchor:previewContainer.centerXAnchor],
        [self.videoView.centerYAnchor constraintEqualToAnchor:previewContainer.centerYAnchor],
        [self.videoView.widthAnchor   constraintLessThanOrEqualToAnchor:previewContainer.widthAnchor],
        [self.videoView.heightAnchor  constraintLessThanOrEqualToAnchor:previewContainer.heightAnchor],
        vFillW,
        vFillH,
        // 左栏内容: 宽=可视宽, 竖向可滚
        [self.inputTab.topAnchor      constraintEqualToAnchor:leftScroll.contentLayoutGuide.topAnchor],
        [self.inputTab.bottomAnchor   constraintEqualToAnchor:leftScroll.contentLayoutGuide.bottomAnchor],
        [self.inputTab.leadingAnchor  constraintEqualToAnchor:leftScroll.contentLayoutGuide.leadingAnchor],
        [self.inputTab.trailingAnchor constraintEqualToAnchor:leftScroll.contentLayoutGuide.trailingAnchor],
        // 右栏内容
        [rightStack.topAnchor      constraintEqualToAnchor:rightScroll.contentLayoutGuide.topAnchor],
        [rightStack.bottomAnchor   constraintEqualToAnchor:rightScroll.contentLayoutGuide.bottomAnchor],
        [rightStack.leadingAnchor  constraintEqualToAnchor:rightScroll.contentLayoutGuide.leadingAnchor],
        [rightStack.trailingAnchor constraintEqualToAnchor:rightScroll.contentLayoutGuide.trailingAnchor],
    ]];
    // 左右栏固定宽度、内容宽=可视宽(required) → 不横向滑动, 内容须能压进列宽。
    [NSLayoutConstraint activateConstraints:@[
        [self.inputTab.widthAnchor constraintEqualToAnchor:leftScroll.frameLayoutGuide.widthAnchor],
        [rightStack.widthAnchor    constraintEqualToAnchor:rightScroll.frameLayoutGuide.widthAnchor],
    ]];
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    // 立即按"目标尺寸"切换布局(不等动画完成): 先拆旧布局再建新布局, 让新布局只在新尺寸下
    // 做布局, 避免"旧布局在新尺寸"的旋转过渡约束冲突。
    [self applyAdaptiveLayoutForThreeColumn:[self shouldUseThreeColumnForSize:size]];
}

- (void)wireInputTabCallbacks {
    __weak typeof(self) weakSelf = self;
    self.inputTab.onOpenVideo = ^{
        [weakSelf selectVideo];
    };
    self.inputTab.onOpenLensFile = ^{
        [weakSelf selectLensProfile];
    };
    self.inputTab.onOpenMotionData = ^{
        [weakSelf selectMotionData];
    };
    self.inputTab.onLensSearch = ^(NSString *query, void(^completion)(NSString *)) {
        __strong typeof(weakSelf) sSelf = weakSelf;
        if (!sSelf) {
            if (completion) completion(@"[]");
            return;
        }
        // 始终用专用搜索 stabilizer（裸句柄、无视频/镜头状态），让搜索结果不被
        // 当前加载的镜头/视频过滤。用 self.stabilizer 时,Rust 侧 lens_search 会
        // 按已知 camera 缩窄结果,有镜头时反而搜不到东西。
        if (sSelf.lensSearchStab == NULL) {
            sSelf.lensSearchStab = gyroflow_stabilizer_new();
        }
        GyroflowStabilizer *stab = sSelf.lensSearchStab;
        if (stab == NULL) {
            if (completion) completion(@"[]");
            return;
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            char buf[65536];
            buf[0] = 0;
            int32_t n = gyroflow_lens_search(stab, query.UTF8String, buf, sizeof(buf));
            NSString *json = (n >= 0) ? [NSString stringWithUTF8String:buf] : @"[]";
            if (completion) completion(json ?: @"[]");
        });
    };
    self.inputTab.onSelectLensId = ^(NSString *lensId) {
        __strong typeof(weakSelf) sSelf = weakSelf;
        if (!sSelf || sSelf.stabilizer == NULL) return;
        int32_t rc = gyroflow_load_lens_profile(sSelf.stabilizer, lensId.UTF8String);
        if (rc != 0) {
            sSelf.statusLabel.text = [NSString stringWithFormat:@"镜头加载失败:%@", [sSelf lastGyroflowError]];
            return;
        }
        gyroflow_apply_loaded_lens_extras(sSelf.stabilizer);  // 应用档案自带 frame_readout/gyro_lpf
        GyroflowVideoInfo updated = {0};
        gyroflow_get_video_info(sSelf.stabilizer, &updated);
        sSelf.videoInfo = updated;
        [sSelf updateDrawableSizeForCurrentMode];
        sSelf.lensWarningBanner.hidden = YES;  // 已从内置库加载镜头档案, 收起警告横幅
        [sSelf.paramsModel scheduleRecompute];
        [sSelf refreshInputTabLensInfo];
        [sSelf refreshInputTabVideoInfo];
        sSelf.statusLabel.text = @"✓ 已从内置库加载镜头档案。";
    };

    // TODO[FFI]: 「创建新的」镜头标定向导、「导出 STMap」、Good/Bad 上报
    // 当前 FFI 尚不支持，先弹个 toast/alert 表示占位。
    self.inputTab.onCreateNewLensProfile = ^{
        __strong typeof(weakSelf) sSelf = weakSelf;
        if (!sSelf) return;
        sSelf.statusLabel.text = @"⚠️ 「创建新的」镜头标定向导待实现。";
    };
    self.inputTab.onExportSTMap = ^{
        __strong typeof(weakSelf) sSelf = weakSelf;
        if (!sSelf) return;
        sSelf.statusLabel.text = @"⚠️ 「导出 STMap」待实现。";
    };
    self.inputTab.onRateLensProfile = ^(BOOL good) {
        __strong typeof(weakSelf) sSelf = weakSelf;
        if (!sSelf) return;
        sSelf.statusLabel.text = good ? @"已感谢你的 Good 评价。" : @"已记录 Bad 评价，感谢反馈。";
        // TODO[FFI]: 把评价上报给镜头库 / 后台服务
    };

    // 积分方法 —— View 回调直接给 Rust FFI 索引(0=None 1=Complementary 2=VQF ...,
    // 列表是否含 None 由 View 按 hasQuaternions 决定, 对齐安卓 GyroflowMotionPanel)。
    self.inputTab.onIntegrationMethodSelected = ^(NSInteger ffiIndex) {
        __strong typeof(weakSelf) sSelf = weakSelf;
        if (!sSelf || sSelf.stabilizer == NULL) return;
        int32_t rc = gyroflow_set_integration_method(sSelf.stabilizer, (uint32_t)ffiIndex);
        if (rc == 0) {
            sSelf.integrationIsNone = (ffiIndex == 0);   // 重算 usesQuats(对齐官方绑定 integrationMethod)
            [sSelf refreshUsesQuats];
            [sSelf.paramsModel scheduleRecompute];
            NSArray *names = @[@"None", @"Complementary", @"VQF", @"Simple gyro", @"Simple gyro + accel", @"Mahony", @"Madgwick"];
            NSString *name = (ffiIndex >= 0 && ffiIndex < (NSInteger)names.count) ? names[ffiIndex] : @"?";
            sSelf.statusLabel.text = [NSString stringWithFormat:@"积分方法已切换为 %@", name];
        } else {
            sSelf.statusLabel.text = [NSString stringWithFormat:@"积分方法切换失败:%@", [sSelf lastGyroflowError]];
        }
    };

    // IMU 朝向编辑回写 —— 对齐官方 MotionData.qml(set_imu_orientation + 重算)。
    // View 已校验为 3 位、仅含 xyzXYZ; 这里直接写引擎并触发重算。
    self.inputTab.onIMUOrientationChanged = ^(NSString *orientation) {
        __strong typeof(weakSelf) sSelf = weakSelf;
        if (!sSelf || sSelf.stabilizer == NULL || orientation.length == 0) return;
        int32_t rc = gyroflow_set_imu_orientation(sSelf.stabilizer, orientation.UTF8String);
        if (rc == 0) {
            [sSelf.paramsModel scheduleRecompute];
            sSelf.statusLabel.text = [NSString stringWithFormat:@"IMU 朝向已设为 %@", orientation];
        } else {
            sSelf.statusLabel.text = [NSString stringWithFormat:@"IMU 朝向设置失败:%@", [sSelf lastGyroflowError]];
        }
    };

    // 「加载全部元数据」切换 → 用当前外挂文件重载(对齐官方 MotionData.qml:215-222 切换即重载)
    self.inputTab.onLoadAllMetadataToggled = ^(BOOL on) {
        __strong typeof(weakSelf) sSelf = weakSelf;
        if (!sSelf || sSelf.lastMotionDataURL == nil) return;
        [sSelf loadMotionDataFromURL:sSelf.lastMotionDataURL loadAllMetadata:on];
    };

    // 「授权视频所在文件夹」→ 弹目录选择器(授权后注册白名单+重载视频, sidecar 自动检测生效)
    self.inputTab.onAuthorizeMotionFolder = ^{
        [weakSelf selectMotionFolder];
    };

    // 「帧偏移」(帧, 可负; 关闭=0) → 渲染前整帧平移视频时间戳(对齐官方 Frame offset)
    self.inputTab.onFrameOffsetChanged = ^(NSInteger frames) {
        __strong typeof(weakSelf) sSelf = weakSelf;
        if (!sSelf || sSelf.stabilizer == NULL) return;
        if (gyroflow_set_frame_offset(sSelf.stabilizer, (int32_t)frames) == 0) {
            [sSelf.paramsModel scheduleRecompute];
            sSelf.statusLabel.text = [NSString stringWithFormat:@"帧偏移已设为 %ld 帧", (long)frames];
        } else {
            sSelf.statusLabel.text = [NSString stringWithFormat:@"帧偏移设置失败:%@", [sSelf lastGyroflowError]];
        }
    };

    // 水下镜头切换 —— 直接调 FFI 设折射率（1.33/1.0），对齐官方桌面版 LensProfile.qml
    self.inputTab.onUnderwaterToggled = ^(BOOL on) {
        __strong typeof(weakSelf) sSelf = weakSelf;
        if (!sSelf || sSelf.stabilizer == NULL) return;
        double coef = on ? 1.33 : 1.0;
        int32_t rc = gyroflow_set_light_refraction_coefficient(sSelf.stabilizer, coef);
        if (rc == 0) {
            [sSelf.paramsModel scheduleRecompute];
            sSelf.statusLabel.text = on ? @"已开启水下镜头折射补偿（1.33）" : @"已关闭水下镜头补偿（1.0）";
        } else {
            sSelf.statusLabel.text = [NSString stringWithFormat:@"水下镜头设置失败:%@", [sSelf lastGyroflowError]];
        }
    };
}

// 解析 gyroflow_get_lens_info JSON 内可能存在的某个字符串字段（取第一个命中）
static NSString *_gfPickString(NSDictionary *info, NSArray<NSString *> *keys) {
    for (NSString *k in keys) {
        id v = info[k];
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) return v;
    }
    return nil;
}

// 取数值字段（double），不存在/非数 → NAN
static double _gfPickDouble(NSDictionary *info, NSArray<NSString *> *keys) {
    for (NSString *k in keys) {
        id v = info[k];
        if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v doubleValue];
    }
    return NAN;
}


// 刷新输入页「镜头配置」区当前已加载镜头名 + 详情字段（截图对齐）
// 用 gyroflow_get_lens_info_full —— 暴露 calib_dimension / calibrated_by /
// camera_matrix / distortion_coeffs 等字段，对应官方桌面版镜头详情面板。
- (void)refreshInputTabLensInfo {
    if (self.stabilizer == NULL) return;
    char buf[8192];
    buf[0] = 0;
    int32_t rc = gyroflow_get_lens_info_full(self.stabilizer, buf, sizeof(buf));
    if (rc != 0) {
        NSLog(@"[Gyroflow] gyroflow_get_lens_info_full rc=%d err=%s", rc, gyroflow_last_error());
        return;
    }
    NSString *json = [NSString stringWithUTF8String:buf];
    NSLog(@"[Gyroflow] lens_info_full JSON = %@", json);
    NSData *d = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *info = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    if (![info isKindOfClass:[NSDictionary class]]) return;

    BOOL has = [info[@"has_lens"] boolValue];
    NSString *name       = _gfPickString(info, @[@"name", @"identifier"]);
    NSString *camera     = _gfPickString(info, @[@"camera"]);
    NSString *lens       = _gfPickString(info, @[@"lens", @"lens_model"]);
    NSString *setting    = _gfPickString(info, @[@"camera_setting"]);
    NSString *otherInfo  = _gfPickString(info, @[@"note"]);
    NSString *calibrator = _gfPickString(info, @[@"calibrated_by"]);
    BOOL official        = [info[@"official"] boolValue];
    // 水下镜头：用 FFI 新暴露的 light_refraction_coefficient 判断（1.33=水下，1.0=空气）
    double lightCoef = [info[@"light_refraction_coefficient"] doubleValue];
    BOOL underwater  = lightCoef > 1.1; // > 1.1 即认为是水（默认 1.0，水 1.33）

    // 标定尺寸（swap 后的实际尺寸）
    NSString *dim = nil;
    id calibDim = info[@"calib_dimension"];
    if ([calibDim isKindOfClass:[NSDictionary class]]) {
        id w = calibDim[@"w"];
        id h = calibDim[@"h"];
        if ([w respondsToSelector:@selector(intValue)] && [h respondsToSelector:@selector(intValue)] && [w intValue] > 0) {
            dim = [NSString stringWithFormat:@"%dx%d", [w intValue], [h intValue]];
        }
    }
    if (dim == nil && self.videoInfo.width > 0 && self.videoInfo.height > 0) {
        dim = [NSString stringWithFormat:@"%ux%u", self.videoInfo.width, self.videoInfo.height];
    }

    // camera_matrix → fx/fy/cx/cy（FFI 直接拍扁成顶层 4 个字段，null 表示没有）
    double fx = _gfPickDouble(info, @[@"fx"]);
    double fy = _gfPickDouble(info, @[@"fy"]);
    double cx = _gfPickDouble(info, @[@"cx"]);
    double cy = _gfPickDouble(info, @[@"cy"]);

    // distortion_coeffs: [k1, k2, k3, k4]
    double k1 = NAN, k2 = NAN, k3 = NAN, k4 = NAN;
    id dc = info[@"distortion_coeffs"];
    if ([dc isKindOfClass:[NSArray class]]) {
        NSArray *arr = dc;
        if (arr.count > 0 && [arr[0] isKindOfClass:[NSNumber class]]) k1 = [arr[0] doubleValue];
        if (arr.count > 1 && [arr[1] isKindOfClass:[NSNumber class]]) k2 = [arr[1] doubleValue];
        if (arr.count > 2 && [arr[2] isKindOfClass:[NSNumber class]]) k3 = [arr[2] doubleValue];
        if (arr.count > 3 && [arr[3] isKindOfClass:[NSNumber class]]) k4 = [arr[3] doubleValue];
    }

    [self.inputTab setLoadedLensName:(has && name) ? name : nil];
    [self.inputTab setLensDetailsOfficial:(official || !has)  // 没加载镜头时不显示警告
                                   camera:camera
                                     lens:lens
                                  setting:setting
                                otherInfo:otherInfo
                                dimension:dim
                               calibrator:calibrator];
    [self.inputTab setLensCalibrationUnderwater:underwater
                                             fx:fx fy:fy
                                             cx:cx cy:cy
                                             k1:k1 k2:k2 k3:k3 k4:k4];

    // 镜头 profile 自带的 sync_settings —— 对齐官方 LensProfile.qml:146→loadGyroflow({synchronization:obj.sync_settings})
    id syncObj = info[@"sync_settings"];
    // do_autosync: 官方自动同步门槛之一(Synchronization.qml:59, 档案声明"需要自动同步",
    // 如 RunCam 系列)。每次镜头刷新都重置再解析, 换镜头/无字段时回到 NO。
    self.lensDoAutosync = NO;
    if ([syncObj isKindOfClass:[NSDictionary class]]) {
        id da = ((NSDictionary *)syncObj)[@"do_autosync"];
        if ([da respondsToSelector:@selector(boolValue)]) {
            self.lensDoAutosync = [da boolValue];
        }
    }
    if ([syncObj isKindOfClass:[NSDictionary class]] && [(NSDictionary *)syncObj count] > 0) {
        [self applyLensSyncSettings:(NSDictionary *)syncObj];
    }
}

// 应用镜头 profile 里的 sync_settings 到 ParamsModel + 刷新两个同步 view。
// 字段对齐官方 Synchronization.qml:loadGyroflow 接收的 11 个 key。
- (void)applyLensSyncSettings:(NSDictionary *)s {
    if (s.count == 0) return;
    NSLog(@"[Gyroflow] applyLensSyncSettings <- %@", s);
    ParamsModel *m = self.paramsModel;
    if (m == nil) return;

    id v;
    if ((v = s[@"initial_offset"])     && [v respondsToSelector:@selector(doubleValue)]) m.gyroOffsetMs                = [v doubleValue];
    if ((v = s[@"initial_offset_inv"]) && [v respondsToSelector:@selector(boolValue)])   m.checkNegativeInitialOffset  = [v boolValue];
    if ((v = s[@"search_size"])        && [v respondsToSelector:@selector(doubleValue)]) m.syncSearchSizeSec           = [v doubleValue];
    if ((v = s[@"calc_initial_fast"])  && [v respondsToSelector:@selector(boolValue)])   m.calcInitialFast             = [v boolValue];
    if ((v = s[@"max_sync_points"])    && [v respondsToSelector:@selector(intValue)])    m.maxSyncPoints               = [v intValue];
    if ((v = s[@"every_nth_frame"])    && [v respondsToSelector:@selector(intValue)])    m.everyNthFrame               = [v intValue];
    if ((v = s[@"time_per_syncpoint"]) && [v respondsToSelector:@selector(doubleValue)]) m.timePerSyncpointSec         = [v doubleValue];
    if ((v = s[@"of_method"])          && [v respondsToSelector:@selector(intValue)])    m.ofMethod                    = [v intValue];
    if ((v = s[@"offset_method"])      && [v respondsToSelector:@selector(intValue)])    m.offsetMethod                = [v intValue];
    if ((v = s[@"pose_method"])        && [v respondsToSelector:@selector(intValue)])    m.poseMethod                  = [v intValue];
    if ((v = s[@"auto_sync_points"])   && [v respondsToSelector:@selector(boolValue)])   m.autoSyncPointsExperimental  = [v boolValue];
    // do_autosync 不进 ParamsModel: 它是触发门槛不是同步参数, 已在 refreshInputTabLensInfo
    // 解析进 self.lensDoAutosync, 自动触发处(对齐官方 Synchronization.qml:59-72)使用。

    // 触发 UI 刷新 —— SyncSectionView.setModel 内部会级联调 advancedView.model
    // 把整个同步面板 + 高级同步面板的字段重新从 ParamsModel 读出来显示
    self.syncSection.model = m;
}

// 刷新输入页「视频信息」区
- (void)refreshInputTabVideoInfo {
    if (self.stabilizer == NULL) return;
    char buf[2048];
    buf[0] = 0;
    NSString *cam = nil;
    NSString *lens = nil;
    if (gyroflow_get_lens_info(self.stabilizer, buf, sizeof(buf)) == 0) {
        NSData *d = [[NSString stringWithUTF8String:buf] dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *info = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        if ([info isKindOfClass:[NSDictionary class]]) {
            cam = info[@"camera"];
            lens = info[@"lens"];
            if (![cam isKindOfClass:[NSString class]] || cam.length == 0) cam = nil;
            if (![lens isKindOfClass:[NSString class]] || lens.length == 0) lens = nil;
        }
    }
    GyroflowVideoInfo vi = self.videoInfo;
    BOOL hasMotion = (gyroflow_has_motion_data(self.stabilizer) == 0);
    NSString *sizeStr = (vi.width > 0) ? [NSString stringWithFormat:@"%ux%u", vi.width, vi.height] : nil;
    NSString *durStr  = (vi.duration_s > 0) ? [NSString stringWithFormat:@"%.2f s", vi.duration_s] : nil;
    NSString *fpsStr  = (vi.fps > 0) ? [NSString stringWithFormat:@"%.3f fps", vi.fps] : nil;
    [self.inputTab setVideoInfoFileName:self.securityScopedURL.lastPathComponent
                            detectedCam:cam
                           detectedLens:lens
                                   size:sizeStr
                               duration:durStr
                                    fps:fpsStr
                                  codec:@"H.264"
                            pixelFormat:@"YUV420P"
                                  audio:nil
                               rotation:@"0°"
                               hasGyro:(hasMotion ? @"Yes" : @"No")];

    // 录制参数(ISO/快门/白平衡/曝光/焦距/对焦方式等, 对齐官方 recording_settings) —— 存在才显示
    char mbuf[8192];
    mbuf[0] = 0;
    NSDictionary *rec = nil;
    if (gyroflow_get_video_metadata(self.stabilizer, mbuf, sizeof(mbuf)) == 0) {
        NSData *md = [[NSString stringWithUTF8String:mbuf] dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *mo = md ? [NSJSONSerialization JSONObjectWithData:md options:0 error:nil] : nil;
        id add = [mo isKindOfClass:[NSDictionary class]] ? mo[@"additional_data"] : nil;
        id rs = [add isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)add)[@"recording_settings"] : nil;
        if ([rs isKindOfClass:[NSDictionary class]]) rec = rs;
    }
    [self.inputTab setRecordingSettings:rec];
}

// 计算并刷新 usesQuats(对齐官方 Synchronization.qml:211):
//   usesQuats = 运动数据来自视频本身 && (精确时间戳 || (有四元数 && 积分方法 None))。
// 载入视频 / 加载外挂运动数据 / 改积分方法后都应调用一次。
- (void)refreshUsesQuats {
    BOOL usesQuats = NO;
    if (self.stabilizer != NULL && self.motionFromVideo) {
        BOOL hasAccurate = (gyroflow_has_accurate_timestamps(self.stabilizer) == 1);
        BOOL hasQuats = (gyroflow_has_quaternions(self.stabilizer) == 1);
        usesQuats = hasAccurate || (hasQuats && self.integrationIsNone);
    }
    [self.syncSection setUsesQuats:usesQuats];
}

- (void)startMDKPlaybackWithURL:(NSURL *)url generation:(NSInteger)generation {
    self.playbackReady = NO;
    self.gyroflowReady = NO;
    self.stabilizationEnabled = NO;
    self.hasRenderedStabilizedFrame = NO;
    self.stabilizationButton.enabled = NO;
    self.exportButton.enabled = NO;
    // 视频还没解析完, 所有 section 禁用 (按用户要求)
    [self setAllSectionsEnabled:NO];
    // 显示"正在分析视频"浮窗 + 全屏蒙版。和导出蒙版一致: 显示后置顶,
    // 确保盖在三栏/单列布局之上(布局重建会把容器加到 view 顶部)。
    self.analysisMask.hidden = NO;
    [self.view bringSubviewToFront:self.analysisMask];
    [self.syncOverlay showWithTitle:@"正在分析视频" onCancel:nil];
    [self.view bringSubviewToFront:self.syncOverlay];
    self.playPauseButton.enabled = NO;
    self.videoPaused = NO;
    [self.playPauseButton setTitle:@"暂停" forState:UIControlStateNormal];
    self.currentMDKRenderTarget = nil;
    self.mdkInputTexture = nil;
    self.hasRenderedAnyMDKFrame = NO;   // 新视频: 首帧兜底标志复位
    _mdkSurfaceWidth = 0;
    _mdkSurfaceHeight = 0;
    [self.stabilizationButton setTitle:@"开启防抖" forState:UIControlStateNormal];

    if (_mdkPlayer) {
        _mdkPlayer->set(mdk::State::Stopped);
        // 渲染队列可能正拿着 _mdkPlayer 在画帧: 先排干在飞的 draw 再销毁
        // (上面 playbackReady 已置 NO, 排干后新排队的 draw 会被守卫挡掉)。
        [self drainRenderQueue];
        _mdkPlayer.reset();
    }

    _mdkPlayer = std::make_unique<mdk::Player>();
    [self configureMDKRenderAPI];

    __weak typeof(self) weakSelf = self;
    _mdkPlayer->setRenderCallback([weakSelf](void *) {
        // 解码线程 → 渲染队列(不再经主线程): 防抖 FFI + Metal 编码全在渲染队列跑,
        // 主线程只收 HUD 刷新的小任务。
        [weakSelf requestPreviewDraw];
    });

    // 播放到结尾 MDK 会切到 Stopped 状态：UI 把按钮复位成「播放」
    _mdkPlayer->onStateChanged([weakSelf](mdk::PlaybackState state) {
        if (state != mdk::PlaybackState::Stopped) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            ViewController *sSelf = weakSelf;
            if (sSelf == nil || !sSelf.playbackReady) return;
            sSelf.videoPaused = YES;
            [sSelf.playPauseButton setTitle:@"播放" forState:UIControlStateNormal];
        });
    });

    std::string path(url.path.UTF8String ?: "");
    _mdkPlayer->setMedia(path.c_str());
    _mdkPlayer->prepare(0, [weakSelf, generation](int64_t position, bool *) -> bool {
        dispatch_async(dispatch_get_main_queue(), ^{
            ViewController *strongSelf = weakSelf;
            if (strongSelf == nil || generation != strongSelf.loadGeneration || !strongSelf->_mdkPlayer) {
                return;
            }

            if (position < 0) {
                strongSelf.statusLabel.text = @"MDK 打开视频失败。";
                return;
            }

            const mdk::MediaInfo &mediaInfo = strongSelf->_mdkPlayer->mediaInfo();
            if (!mediaInfo.video.empty()) {
                int width = mediaInfo.video[0].codec.width;
                int height = mediaInfo.video[0].codec.height;
                if (width > 0 && height > 0) {
                    strongSelf.videoView.drawableSize = CGSizeMake(width, height);
                    [strongSelf updatePreviewAspectWithWidth:(uint32_t)width height:(uint32_t)height];
                    strongSelf->_mdkPlayer->setVideoSurfaceSize(width, height);
                    strongSelf->_mdkSurfaceWidth = width;
                    strongSelf->_mdkSurfaceHeight = height;
                }
            }

            strongSelf.playbackReady = YES;
            // 不在这里 set Playing —— 等 gyroflow 加载完且 has_lens 检查通过后再播,
            // 否则没镜头档案时用户会看到画面跑了一段再被暂停。
            strongSelf.videoPaused = YES;
            strongSelf.playPauseButton.enabled = YES;
            [strongSelf.playPauseButton setTitle:@"播放" forState:UIControlStateNormal];
            strongSelf.statusLabel.text = @"MDK 已就绪,正在后台加载 Gyroflow 数据...";
            // 帧驱动模式首帧竞态: prepare 期间 MDK 解出首帧触发的 renderCallback 往往
            // 早于这里的 playbackReady=YES, 那次 draw 被守卫丢掉且不再有后续 tick →
            // 黑屏。ready 后主动补一次 draw 把首帧画出来。
            [strongSelf requestPreviewDraw];
            // 高码率文件(Sony 4K 107Mbps 实测): prepare 期间首帧解码根本没完成,
            // renderVideo 一直 -1 且 renderCallback 不再来 → 上面那次 draw 也空跑。
            // 此时强制 seek(0) 让 MDK 解码首帧 —— seek 解完首帧会触发 renderCallback
            // → draw, 画面出来。已渲出过帧则不动(避免多余 seek)。
            if (!strongSelf.hasRenderedAnyMDKFrame) {
                strongSelf->_mdkPlayer->seek(0);
            }
        });
        return true;
    });
}

- (void)configureMDKRenderAPI {
    _mdkRenderAPI = mdk::MetalRenderAPI();
    _mdkRenderAPI.device = (__bridge const void *)self.metalDevice;
    _mdkRenderAPI.cmdQueue = (__bridge const void *)self.commandQueue;
    _mdkRenderAPI.opaque = (__bridge const void *)self;
    _mdkRenderAPI.currentRenderTarget = GyroflowDemoCurrentRenderTarget;
    // 不传 layer: MDK 只拿它做 HDR/SDR colorspace(RenderAPI.h:94), 却会在 renderVideo()
    // 内直接改 layer 属性 —— renderVideo 现在跑渲染队列, UIKit 禁止在主线程外改
    // view 持有的 layer(实测报警)。渲染目标全程走 currentRenderTarget 纹理回调, 不依赖 layer。
    _mdkRenderAPI.colorFormat = (unsigned)MTLPixelFormatBGRA8Unorm;
    _mdkPlayer->setRenderAPI(&_mdkRenderAPI);
    _mdkPlayer->setAspectRatio(mdk::KeepAspectRatio);
}

// 导出期间释放 MDK 播放器 —— 导出走 AVAssetReader 解码, MDK 完全用不上, 纯占内存
// (4K 视频它的解码器/帧缓冲是基线内存的大头)。先存播放位置, 销毁 player + 预览纹理。
// drawInMTKView 已有 (!_mdkPlayer || !playbackReady || exporting) 守卫, 销毁安全。
- (void)teardownMDKForExport {
    if (_mdkPlayer) {
        self.exportSavedPositionMs = _mdkPlayer->position();
        _mdkPlayer->set(mdk::State::Stopped);
        // exporting=YES 已挡住新 draw; 再排干渲染队列在飞的 draw 才能安全销毁 player
        [self drainRenderQueue];
        _mdkPlayer.reset();
    }
    self.playbackReady = NO;
    self.currentMDKRenderTarget = nil;
    self.mdkInputTexture = nil;
    self.hasRenderedAnyMDKFrame = NO;   // MDK 重建后首帧兜底标志复位
    _mdkSurfaceWidth = 0;
    _mdkSurfaceHeight = 0;
    NSLog(@"[Export] MDK 已释放(savedPos=%lldms), 回收解码器/预览内存", (long long)self.exportSavedPositionMs);
}

// 导出完成后重建 MDK 播放器, seek 回导出前位置, 保持暂停。
// 只重建 MDK(渲染/解码), **不碰 gyroflow / stabilizer / gyroflowReady** —— 防抖数据导出期间一直在。
- (void)restoreMDKAfterExport {
    if (self.securityScopedURL == nil || _mdkPlayer) return;
    NSURL *url = self.securityScopedURL;
    NSInteger generation = self.loadGeneration;
    int64_t seekPos = self.exportSavedPositionMs;

    _mdkPlayer = std::make_unique<mdk::Player>();
    [self configureMDKRenderAPI];

    __weak typeof(self) weakSelf = self;
    _mdkPlayer->setRenderCallback([weakSelf](void *) {
        [weakSelf requestPreviewDraw];
    });
    _mdkPlayer->onStateChanged([weakSelf](mdk::PlaybackState state) {
        if (state != mdk::PlaybackState::Stopped) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            ViewController *sSelf = weakSelf;
            if (sSelf == nil || !sSelf.playbackReady) return;
            sSelf.videoPaused = YES;
            [sSelf.playPauseButton setTitle:@"播放" forState:UIControlStateNormal];
        });
    });
    std::string path(url.path.UTF8String ?: "");
    _mdkPlayer->setMedia(path.c_str());
    _mdkPlayer->prepare(seekPos, [weakSelf, generation](int64_t position, bool *) -> bool {
        dispatch_async(dispatch_get_main_queue(), ^{
            ViewController *sSelf = weakSelf;
            if (sSelf == nil || generation != sSelf.loadGeneration || !sSelf->_mdkPlayer) return;
            if (position < 0) return;
            const mdk::MediaInfo &mi = sSelf->_mdkPlayer->mediaInfo();
            if (!mi.video.empty()) {
                int w = mi.video[0].codec.width, h = mi.video[0].codec.height;
                if (w > 0 && h > 0) {
                    sSelf->_mdkPlayer->setVideoSurfaceSize(w, h);
                    sSelf->_mdkSurfaceWidth = w;
                    sSelf->_mdkSurfaceHeight = h;
                }
            }
            sSelf.playbackReady = YES;
            sSelf.videoPaused = YES;
            sSelf.playPauseButton.enabled = YES;  // MDK 重建完成, 重新允许播放(导出完成块设按钮时还没 ready)
            [sSelf.playPauseButton setTitle:@"播放" forState:UIControlStateNormal];
            [sSelf updateDrawableSizeForCurrentMode];  // 恢复预览 drawable(防抖输出尺寸, 末尾自带 draw)
            // 高码率文件首帧兜底(同 startMDKPlaybackWithURL 的 prepare 回调): prepare 期间
            // 首帧没解出来就强制 seek 回导出前位置触发解码。
            if (!sSelf.hasRenderedAnyMDKFrame) {
                sSelf->_mdkPlayer->seek(position);
            }
            NSLog(@"[Export] MDK 已重建并 seek 回 %lldms", (long long)position);
        });
        return true;
    });
}

// Helper: log every FFI call return value so we can pinpoint which step misbehaves.
#define GF_CALL(expr) do { \
    int32_t _rc = (expr); \
    if (_rc != 0) { \
        NSLog(@"[Gyroflow] %s -> %d  err=%s", #expr, _rc, gyroflow_last_error()); \
    } else { \
        NSLog(@"[Gyroflow] %s -> ok", #expr); \
    } \
} while (0)

- (void)loadGyroflowForURL:(NSURL *)url generation:(NSInteger)generation {
    dispatch_async(self.gyroQueue, ^{
        GyroflowStabilizer *newStabilizer = gyroflow_stabilizer_new();
        if (newStabilizer == NULL) {
            [self updateStatus:[NSString stringWithFormat:@"创建 Gyroflow 失败：%@", [self lastGyroflowError]]];
            return;
        }

        // 不在后台线程预绑 wgpu/Metal 设备 —— 让 process_frame_metal_bgra8
        // 在主线程首次渲染时按需 lazy 初始化 wgpu，避免和 demo 里 viewDidLoad
        // 创建的 MTLDevice 之间产生竞争。

        GyroflowVideoInfo info = {0};
        int32_t result = gyroflow_load_video_file(newStabilizer, url.path.UTF8String, &info);
        if (result != 0) {
            NSString *message = [NSString stringWithFormat:@"视频正在播放，但 Gyroflow 加载失败：%@", [self lastGyroflowError]];
            gyroflow_stabilizer_free(newStabilizer);
            [self updateStatus:message];
            return;
        }
        NSLog(@"[Gyroflow] load_video_file ok  size=%ux%u  fps=%.3f", info.width, info.height, info.fps);

        const BOOL hasMotionEarly      = (gyroflow_has_motion_data(newStabilizer) == 0);
        const BOOL hasLensProfileEarly = (gyroflow_has_lens_profile(newStabilizer) == 0);
        NSLog(@"[Gyroflow] has_motion=%d  has_lens=%d", hasMotionEarly, hasLensProfileEarly);

        // ===== 这些都是「桌面端默认值」，gyroflow_load_video_file 已经按
        //       telemetry 自动配置好了 —— 包括 GoPro 的 integration_method=0
        //       (使用相机原生 quaternion 而非 VQF 重积分) 和 imu_orientation
        //       的自动识别。只对真正想偏离默认值的字段才 override，否则会把
        //       高精度的厂商 quat 替换成低精度的 VQF 重积分结果，导致看上去
        //       「只是裁剪、没有真正防抖」。 =====

        // 完全对齐官方 iOS 的默认值（IMG_1346 截图: "平滑度 50.0%"）。
        // 之前调到 0.85/0.95 想压更多抖动，但结果用户反馈"和官方差很多"——
        // 因为我们参数比官方激进近一倍。回到 0.5 才能和官方 1:1 对照。
        // 接受随之而来的"原始抖动残留"——那是 gyroflow 算法在 50% 强度下的
        // 物理表现，跟官方一样。
        // ParamsModel 管的参数(smoothness / gyro_offset / lens_correction /
        // max_zoom / adaptive_zoom / output_size 等)统一由
        // paramsModel.loadDefaultsFromStabilizer 在主线程上完成。
        // 这里只保留 ParamsModel 不管的两个:
        GF_CALL(gyroflow_set_interpolation(newStabilizer, 0));   // 预览用 Bilinear
        GF_CALL(gyroflow_set_stab_enabled(newStabilizer, 1));    // 防抖开关由 toggle 按钮控制
        // 对齐桌面 MotionData.qml + lib.rs:init_from_video_data 的默认积分方法选择:
        //   有原生四元数(Hero8+/Insta360 等)          → method 0(None, 用厂商高精度 quat)
        //   无原生四元数(Hero5/6、Sony 等只有原始 IMU) → 时长 <10s: Complementary(1); ≥10s: VQF(2)
        // gyroflow_load_video_file 已按 telemetry 把有四元数的自动配成 method 0(保持不动);
        // 无四元数的 iOS Rust 默认停在 method=2(VQF), 但桌面只有 <10s 才用 Complementary、
        // ≥10s 仍是 VQF。之前这里无条件覆盖成 Complementary, 导致 ≥10s 的 GoPro/Sony 视频
        // (官方=VQF) 积分结果和官方不一致。改成对齐官方的「时长分支」。
        // 用 gyroflow_has_quaternions 精确判断是否有厂商原生四元数(对齐官方 contains_quats),
        // 不再用 has_accurate_timestamps 代理(后者是时间戳标志, 跟"有四元数"不等价)。
        // integrationUIIndex 记录最终积分方法对应的下拉 UI 索引(uiIndex=ffi-1),
        // 带到下面主线程块去同步下拉框; -1 = 有原生四元数(method 0=None, 下拉无 None 项, 不改)。
        NSInteger integrationUIIndex = -1;
        if (gyroflow_has_quaternions(newStabilizer) != 1) {
            double durSec = info.duration_s; // load_video_file 已填
            uint32_t integ = (durSec > 0.0 && durSec < 10.0) ? 1u : 2u; // <10s Complementary, 否则 VQF
            GF_CALL(gyroflow_set_integration_method(newStabilizer, integ));
            integrationUIIndex = (NSInteger)(integ - 1); // uiIndex = ffi - 1
        }

        const BOOL hasMotion       = (gyroflow_has_motion_data(newStabilizer) == 0);
        BOOL hasLensProfile        = (gyroflow_has_lens_profile(newStabilizer) == 0);
        BOOL autoMatchedLens       = NO;
        NSString *autoMatchedLensName = nil;

        // 注:不要在这里做基于 name 字段的"二次匹配"。Rust gyroflow_load_video_file
        // 内部已经通过 LensProfile.get_all_matching_profiles() 展开 compatible_settings
        // 并按 [identifier > resolution+fps > aspect+fps > resolution > aspect] 优先级挑
        // 出正确的子档案，camera_matrix / calib_dimension 已按比例缩放到视频实际分辨率。
        // 只是 gyroflow_get_lens_info 返回的 name 是 base profile 的 name（swap 时未替换），
        // 看起来分辨率"不对"，实际数据是对的。要展示真实 calib_dimension / camera_matrix
        // / calibrated_by 等字段必须扩 FFI（参见 src/core/ffi.rs:gyroflow_get_lens_info）。

        // 未匹配到镜头档案 → 用 telemetry 检测出来的相机名去内置库自动搜索匹配一条
        if (!hasLensProfile) {
            char infoBuf[2048] = {0};
            if (gyroflow_get_lens_info(newStabilizer, infoBuf, sizeof(infoBuf)) == 0) {
                NSData *infoData = [[NSString stringWithUTF8String:infoBuf] dataUsingEncoding:NSUTF8StringEncoding];
                NSDictionary *infoDict = infoData ? [NSJSONSerialization JSONObjectWithData:infoData options:0 error:nil] : nil;
                NSString *camera = [infoDict isKindOfClass:[NSDictionary class]] ? infoDict[@"camera"] : nil;
                if ([camera isKindOfClass:[NSString class]] && camera.length > 0) {
                    char searchBuf[65536] = {0};
                    int32_t n = gyroflow_lens_search(newStabilizer, camera.UTF8String, searchBuf, sizeof(searchBuf));
                    if (n > 0) {
                        NSData *resData = [[NSString stringWithUTF8String:searchBuf] dataUsingEncoding:NSUTF8StringEncoding];
                        NSArray *matches = resData ? [NSJSONSerialization JSONObjectWithData:resData options:0 error:nil] : nil;
                        if ([matches isKindOfClass:[NSArray class]] && matches.count > 0) {
                            // 不再盲取 firstObject —— 用视频实际宽×高字符串筛选,
                            // 挑出 name 里带 "WxH" 的子档案 (例如 "2704x2028" / "2704x1520")。
                            // 错的子档案 (如 4000x3000) 没有 optimal_fov, 会导致 UI 显示的 fov
                            // 大 1/optimal_fov 倍 (typical ~1.22x), zoom% 系统性偏小。
                            NSString *dimsKey = [NSString stringWithFormat:@"%ux%u",
                                                 self.videoInfo.width, self.videoInfo.height];
                            NSDictionary *chosen = nil;
                            for (id m in matches) {
                                if (![m isKindOfClass:[NSDictionary class]]) continue;
                                id n = ((NSDictionary *)m)[@"name"];
                                if (![n isKindOfClass:[NSString class]]) continue;
                                if ([(NSString *)n rangeOfString:dimsKey].location != NSNotFound) {
                                    chosen = (NSDictionary *)m;
                                    break;
                                }
                            }
                            if (chosen == nil) {
                                NSLog(@"[Gyroflow] auto-match: no candidate with dims '%@' in %lu matches, fallback firstObject",
                                      dimsKey, (unsigned long)matches.count);
                                chosen = matches.firstObject;
                            } else {
                                NSLog(@"[Gyroflow] auto-match: dims-filtered '%@' -> %@", dimsKey, chosen[@"name"]);
                            }
                            NSDictionary *first = chosen;
                            NSString *lensId = [first isKindOfClass:[NSDictionary class]] ? first[@"id"] : nil;
                            NSString *lensName = [first isKindOfClass:[NSDictionary class]] ? first[@"name"] : nil;
                            if ([lensId isKindOfClass:[NSString class]] && lensId.length > 0) {
                                int32_t rc = gyroflow_load_lens_profile(newStabilizer, lensId.UTF8String);
                                if (rc == 0 && gyroflow_has_lens_profile(newStabilizer) == 0) {
                                    gyroflow_apply_loaded_lens_extras(newStabilizer);  // 应用档案 frame_readout/gyro_lpf
                                    hasLensProfile = YES;
                                    autoMatchedLens = YES;
                                    autoMatchedLensName = ([lensName isKindOfClass:[NSString class]] && lensName.length > 0) ? lensName : lensId;
                                    NSLog(@"[Gyroflow] auto-matched lens from library: camera=%@ -> %@", camera, autoMatchedLensName);
                                }
                            }
                        }
                    }
                }
            }
        }

        // 授权目录扫描记下的同名镜头 json: 库自动匹配后仍无镜头时兜底加载
        // (core 只认 gcsv 内 lensprofile 字段, 同名 json 是产品扩展)。
        if (!hasLensProfile && self.pendingScanLensURL != nil) {
            NSURL *scanLens = self.pendingScanLensURL;
            self.pendingScanLensURL = nil;
            if (gyroflow_load_lens_profile(newStabilizer, scanLens.path.UTF8String) == 0
                && gyroflow_has_lens_profile(newStabilizer) == 0) {
                gyroflow_apply_loaded_lens_extras(newStabilizer);
                hasLensProfile = YES;
                autoMatchedLens = YES;
                autoMatchedLensName = scanLens.lastPathComponent;
                NSLog(@"[Gyroflow] 已加载授权目录扫描到的同名镜头档案: %@", scanLens.path);
            }
        }

        GyroflowVideoInfo previewInfo = {0};
        gyroflow_get_video_info(newStabilizer, &previewInfo);
        NSLog(@"[Gyroflow] final preview size: %ux%u -> out %ux%u",
              previewInfo.width, previewInfo.height,
              previewInfo.output_width, previewInfo.output_height);

        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.loadGeneration) {
                gyroflow_stabilizer_free(newStabilizer);
                return;
            }
            if (self.stabilizer != NULL) {
                gyroflow_stabilizer_free(self.stabilizer);
            }
            self.stabilizer = newStabilizer;
            self.videoInfo = previewInfo;
            self.gyroflowReady = YES;
            self.dropPlaceholder.hidden = YES;   // 已加载视频, 收起「选择文件」占位
            // 视频解析完成, 所有 section 解锁 (按用户要求)
            [self setAllSectionsEnabled:YES];
            // 隐藏「正在分析视频」浮窗 + 蒙版 (autosync 启动会再 show 一次新文案 + 进度)
            self.analysisMask.hidden = YES;
            [self.syncOverlay hide];

            // ParamsModel 加载默认值并应用到 stabilizer(内部同步 recompute_blocking)
            // 输出大小预设换算用视频原生尺寸 (输出大小已移到导出设置 ExportSectionView)。
            self.exportSection.inputSize = CGSizeMake(self.videoInfo.width, self.videoInfo.height);
            // 输出路径默认名(对齐官方 VideoArea.qml:437-438 每次加载重置): 视频名_stabilized.mp4
            [self.exportSection setDefaultOutputFileName:
                [NSString stringWithFormat:@"%@_stabilized.mp4",
                 self.securityScopedURL.lastPathComponent.stringByDeletingPathExtension]];
            [self resolveOutputFileNameConflict];   // 默认名也查重: 所选目录已有同名 → _X
            // 不强推 output_size: applyAllToStabilizer 看到 CGSizeZero 会跳过 FFI 推送,
            // 保留 stabilizer 当前值 (镜头档案 / gyroflow_new_stabilizer 初始化决定)。
            // 用户可在「导出设置·输出大小」手动改; 桌面默认 2704×1520 来自 lens.output_dimension,
            // iOS 还没 FFI 暴露这字段, 暂时落到 stabilizer 已有值上。
            [self.paramsModel loadDefaultsFromStabilizer:self.stabilizer];
            // 重读 videoInfo 拿到 stabilizer 当前的 output_size, 同步给 paramsModel
            // 让「高级·输出大小」输入框能显示真实值。
            GyroflowVideoInfo updatedInfo = {0};
            gyroflow_get_video_info(self.stabilizer, &updatedInfo);
            self.videoInfo = updatedInfo;
            if (updatedInfo.output_width > 0 && updatedInfo.output_height > 0) {
                self.paramsModel.outputSize = CGSizeMake(updatedInfo.output_width, updatedInfo.output_height);
            }
            [self updateDrawableSizeForCurrentMode];
            self.syncSection.model      = self.paramsModel;
            self.stabilizeSection.model = self.paramsModel;
            self.advancedSection.model  = self.paramsModel;
            self.exportSection.model    = self.paramsModel;
            [self wireAutosyncHandler];
            self.stabilizationButton.enabled = YES;
            [self updateExportButtonEnabled];
            // 刷新输入页的视频信息 + 镜头信息
            [self refreshInputTabVideoInfo];
            [self refreshInputTabLensInfo];
            // 同步积分方法下拉框 —— **每次加载都重建**(对齐安卓 GyroflowMotionPanel):
            //   有原生四元数(Hero8+/Hero10 等): 列表含 None 且选中 None(引擎实际用 method 0);
            //   无四元数: 列表不含 None, 选中后台已设的 Complementary/VQF。
            // 之前只在无四元数时刷新且列表无 None 项 → 加载 quat 视频后下拉残留上一个
            // 视频的显示(如 "VQF"), 与引擎实际 None 不符 —— 即"积分方法显示不对"bug。
            BOOL videoHasQuats = (gyroflow_has_quaternions(self.stabilizer) == 1);
            NSInteger selectedFFI = videoHasQuats ? 0 : (integrationUIIndex >= 0 ? integrationUIIndex + 1 : 2);
            [self.inputTab configureIntegrationMethodsHasQuaternions:videoHasQuats
                                                    selectedFFIIndex:selectedFFI];
            // 同步「IMU 朝向」显示真实自动识别值(对齐官方; 之前写死占位 "ZyX" 跟视频无关)。
            // iOS 不覆盖 imu_orientation, 引擎用的就是这个值, 仅之前没读出来显示。
            char imuOriBuf[16] = {0};
            if (gyroflow_get_imu_orientation(self.stabilizer, imuOriBuf, sizeof(imuOriBuf)) == 0) {
                [self.inputTab setIMUOrientationText:[NSString stringWithUTF8String:imuOriBuf]];
            }

            // 加载陀螺仪波形时间轴数据（MVC：Controller 触发 Model 加载，再交给 View）
            BOOL gyroOK = [self.gyroModel loadFromStabilizer:self.stabilizer sampleCount:600];
            self.gyroTimelineView.model = self.gyroModel;
            self.gyroTimelineView.progress = 0.0;
            // 视频总时长(ms)给 view 用来按 midpoint_ms 给 autosync syncpoint 定位
            self.gyroTimelineView.videoDurationMs = self.videoInfo.duration_s * 1000.0;
            // 新视频要清掉上次的 autosync 标注(否则会画在错误位置)
            [self.gyroTimelineView setSyncPoints:nil];
            self.syncPointCount = 0;  // 新视频, 同步点清零(autosync 完成后再回填)
            [self.syncSection setHasSyncPoints:NO]; // 新视频无同步点(对齐官方 offsets 清零)
            NSLog(@"[Gyroflow] gyro timeline %@  samples=%ld  maxAbs=%.1f°/s",
                  gyroOK ? @"已加载" : @"无数据",
                  (long)self.gyroModel.sampleCount, self.gyroModel.maxAbsValue);
            // 方案 C: mdkInputTexture 永远按视频原生建, MDK 内部解码低清后拉伸贴进来。
            [self makeMDKInputTextureWithWidth:self.videoInfo.width height:self.videoInfo.height];
            [self updateDrawableSizeForCurrentMode];
            self.statusLabel.text = [NSString stringWithFormat:
                @"MDK 播放中\nGyroflow 已加载\n输入：%ux%u %.2ffps\n输出：%ux%u\n陀螺数据：%@   镜头配置：%@",
                self.videoInfo.width,
                self.videoInfo.height,
                self.videoInfo.fps,
                self.videoInfo.output_width,
                self.videoInfo.output_height,
                hasMotion      ? @"已加载" : @"缺失",
                hasLensProfile ? @"已匹配" : @"未匹配"
            ];

            // 运动数据面板「检测到的格式」+「文件名称」—— 视频自带 IMU 时用视频源
            NSString *detected = nil;
            char liBuf[2048] = {0};
            if (gyroflow_get_lens_info(self.stabilizer, liBuf, sizeof(liBuf)) == 0) {
                NSData *liData = [[NSString stringWithUTF8String:liBuf] dataUsingEncoding:NSUTF8StringEncoding];
                NSDictionary *liDict = liData ? [NSJSONSerialization JSONObjectWithData:liData options:0 error:nil] : nil;
                id cam = [liDict isKindOfClass:[NSDictionary class]] ? liDict[@"camera"] : nil;
                if ([cam isKindOfClass:[NSString class]] && [(NSString *)cam length] > 0) detected = cam;
            }
            [self.inputTab setMotionInfoFormat:detected
                                      fileName:self.securityScopedURL.lastPathComponent
                                        loaded:hasMotion];
            // 视频已载入 → 允许打开外挂运动数据(对齐官方: 无视频拒绝加载)
            [self.inputTab setMotionOpenFileEnabled:YES];
            // 蓝色目录授权提示框(视频信息·打开文件下方, 对齐官方 VideoInformation.qml:164-178):
            // 无运动数据或无镜头时显示, 点击授权目录后自动扫描同名文件
            [self.inputTab setVideoDirHintVisible:(!hasMotion || !hasLensProfile)];

            // gyroflow 加载完成,现在决定是否开播:
            //   - 匹配上镜头档案 → 自动开播
            //   - 没匹配档案 → 保持暂停,等用户上传 .json 或手动播放
            if (!hasLensProfile) {
                self.lensWarningBanner.hidden = NO;  // 预览顶部黄条: 未加载镜头档案
                // MDK 之前没起播,这里保持暂停状态即可
                self.videoPaused = YES;
                [self.playPauseButton setTitle:@"播放" forState:UIControlStateNormal];
                self.statusLabel.text = @"⚠️ 未匹配到镜头档案（内置库自动搜索也无果）。请到「输入」页镜头区打开 .json 档案，或点「播放」强行继续（畸变矫正不准）。";
                // 防抖默认开启 —— 即使没镜头档案也打开(结果可能不准, 已有黄条提示)。
                self.stabilizationEnabled = YES;
                self.hasRenderedStabilizedFrame = NO;
                [self.stabilizationButton setTitle:@"关闭防抖" forState:UIControlStateNormal];
                [self updateDrawableSizeForCurrentMode];
            } else {
                self.lensWarningBanner.hidden = YES;
                // 不自动播放(按用户要求,视频必须用户主动点播放才放)。保持暂停态。
                self.videoPaused = YES;
                [self.playPauseButton setTitle:@"播放" forState:UIControlStateNormal];
                if (autoMatchedLens) {
                    self.statusLabel.text = [NSString stringWithFormat:@"✓ 已自动匹配镜头档案：%@", autoMatchedLensName];
                }

                // 对齐官方桌面版 VideoArea.qml:744/755/767 ——
                // 加载视频完成后自动打开 stabilization 开关。
                self.stabilizationEnabled = YES;
                self.hasRenderedStabilizedFrame = NO;
                [self.stabilizationButton setTitle:@"关闭防抖" forState:UIControlStateNormal];
                [self updateDrawableSizeForCurrentMode];

                // 自动同步触发 —— 完整对齐官方(Synchronization.qml:59-72)与安卓
                // (GyroflowActivity.maybeAutoSync), 四个条件缺一不可:
                //   ① 镜头档案 sync_settings.do_autosync==true(档案声明需要自动同步, 如 RunCam 系列);
                //   ② 有运动数据;
                //   ③ 无精确时间戳(Hero8+/Insta360/Sony 等精确时间戳机型天然零偏移, 跳过);
                //   ④ 尚无同步点/没在同步中(autosyncRunner==nil, 对齐官方 offsets_model.rowCount()==0)。
                // 不满足时(如 GoPro Hero5/6 raw-IMU 档案不带 do_autosync)不自动跑,
                // 由用户手动点「自动同步」(与官方/安卓行为一致)。陀螺偏移永不预设常数。
                int32_t hasAccurateTs = gyroflow_has_accurate_timestamps(self.stabilizer);
                BOOL hasAccurate = (hasAccurateTs == 1);
                self.hasAccurateTimestamps = hasAccurate;  // 导出时判断是否需要同步点提示
                self.motionFromVideo = YES;  // 视频自带陀螺(内嵌)
                self.integrationIsNone = (gyroflow_has_quaternions(self.stabilizer) == 1); // quat 源默认积分=None(iOS 不覆盖)
                [self refreshUsesQuats];
                NSLog(@"[Autosync] 自动触发判断：doAutosync=%d hasMotion=%d hasAccurateTimestamps=%d",
                      (int)self.lensDoAutosync, hasMotion, hasAccurateTs);
                if (self.lensDoAutosync && hasMotion && !hasAccurate && self.autosyncRunner == nil) {
                    NSLog(@"[Autosync] 自动触发：do_autosync + motion + !accurate_timestamps（偏移将由 autosync 检测）");
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        if (self.stabilizer == NULL || self.autosyncRunner != nil) return;
                        [self startAutosync];
                    });
                } else {
                    NSLog(@"[Autosync] 不自动同步：doAutosync=%d hasAccurate=%d（可手动点「自动同步」）",
                          (int)self.lensDoAutosync, (int)hasAccurate);
                }
            }
        });
    });
}

// 按预览分辨率把给定宽高等比缩小到目标高度像素。对应桌面 controller.rs:881
// `set_preview_resolution` 的几何缩放: new_h = target_h; new_w = width * target_h / height。
// previewResolutionHeight == 0 (或 >= 源高) → 原尺寸(不缩放)。
// 宽高都夹偶数: gyroflow 输出纹理 / Metal 渲染目标要求偶数边。
- (CGSize)previewScaledSizeForWidth:(uint32_t)width height:(uint32_t)height {
    // 先夹到源内(与导出一致): 目标比源大时按 scale=min(源/请求) 缩到源分辨率内, 保持比例。
    // 这样无论选 8K 还是比例, 稳定都在「夹后尺寸」上算 → 取景固定、且预览取景 == 导出取景。
    uint32_t inW = self.videoInfo.width, inH = self.videoInfo.height;
    if (inW > 0 && inH > 0 && width > 0 && height > 0) {
        double sc = MIN((double)inW / width, (double)inH / height);
        if (sc < 1.0) {
            width  = (uint32_t)floor((double)width  * sc);
            height = (uint32_t)floor((double)height * sc);
        }
    }
    int targetH = self.paramsModel.previewResolutionHeight;
    if (targetH <= 0 || width == 0 || height == 0 || targetH >= (int)height) {
        return CGSizeMake(width, height);
    }
    uint32_t newW = (uint32_t)llround((double)width * (double)targetH / (double)height);
    uint32_t newH = (uint32_t)targetH;
    newW = newW < 4 ? 4 : (newW & ~1u);
    newH = newH < 4 ? 4 : (newH & ~1u);
    return CGSizeMake(newW, newH);
}

// 预览分辨率(驱动输出方案)。桌面 set_preview_resolution 改的是渲染输出分辨率,
// 不是输入解码 surface。这里把 stabilizer 的 output_size 按预览分辨率等比缩小 ——
// paramsModel.outputSize 始终保留逻辑全尺寸(供高级·输出大小显示 / 导出还原),
// 实际渲染用缩放后的尺寸。recompute 后重读 videoInfo 让 output_* 反映真实渲染尺寸,
// 再让 drawable 跟上。预览矩形比例不变, 只降像素不缩画面。
- (void)applyPreviewOutputSizeToStabilizer {
    if (self.stabilizer == NULL) {
        return;
    }
    CGSize full = self.paramsModel.outputSize;
    if (full.width < 0.5 || full.height < 0.5) {
        return;  // 输出尺寸还没就绪(视频未加载完), load 流程稍后会再 apply
    }
    CGSize scaled = [self previewScaledSizeForWidth:(uint32_t)full.width height:(uint32_t)full.height];
    gyroflow_set_output_size_exact(self.stabilizer, (uint32_t)scaled.width, (uint32_t)scaled.height);
    gyroflow_recompute_blocking(self.stabilizer);
    GyroflowVideoInfo vi = {0};
    gyroflow_get_video_info(self.stabilizer, &vi);
    self.videoInfo = vi;
    [self updateDrawableSizeForCurrentMode];
    NSLog(@"[preview_res] target=%d -> output %ux%u (logical full %.0fx%.0f, input stays %ux%u)",
          self.paramsModel.previewResolutionHeight,
          self.videoInfo.output_width, self.videoInfo.output_height,
          full.width, full.height,
          self.videoInfo.width, self.videoInfo.height);
}

- (void)makeMDKInputTextureWithWidth:(uint32_t)width height:(uint32_t)height {
    if (width == 0 || height == 0) {
        self.mdkInputTexture = nil;
        return;
    }
    if (self.mdkInputTexture.width == width && self.mdkInputTexture.height == height) {
        return;
    }

    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                          width:width
                                                                                         height:height
                                                                                      mipmapped:NO];
    descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    descriptor.storageMode = MTLStorageModePrivate;
    self.mdkInputTexture = [self.metalDevice newTextureWithDescriptor:descriptor];
}

- (void)updateDrawableSizeForCurrentMode {
    if (self.stabilizationEnabled && self.gyroflowReady && self.videoInfo.output_width > 0 && self.videoInfo.output_height > 0) {
        // drawable = videoInfo.output_*(已是预览分辨率缩放后的实际渲染尺寸,
        // applyPreviewOutputSizeToStabilizer 设置, 且必须 == gyroflow 输出, 见 1424 行守卫)。
        // aspect 用「逻辑全尺寸」paramsModel.outputSize 的比例: 偶数夹取会让缩放后比例有
        // ~0.04% 漂移, 用稳定的全尺寸比例可保证切换预览分辨率时预览矩形丝毫不变。
        self.videoView.drawableSize = CGSizeMake(self.videoInfo.output_width, self.videoInfo.output_height);
        CGSize logical = self.paramsModel.outputSize;
        if (logical.width > 0.5 && logical.height > 0.5) {
            [self updatePreviewAspectWithWidth:(uint32_t)logical.width height:(uint32_t)logical.height];
        } else {
            [self updatePreviewAspectWithWidth:self.videoInfo.output_width height:self.videoInfo.output_height];
        }
    } else if (self.videoInfo.width > 0 && self.videoInfo.height > 0) {
        // 非防抖: MDK 直接渲染到 drawable。按预览分辨率缩小 drawable 像素, aspect 用真实
        // 原生比例固定预览矩形, MTKView 把更小的 drawable 放大铺满 → 只降像素不缩画面。
        CGSize ps = [self previewScaledSizeForWidth:self.videoInfo.width height:self.videoInfo.height];
        self.videoView.drawableSize = ps;
        [self updatePreviewAspectWithWidth:self.videoInfo.width height:self.videoInfo.height];
    }
    // 帧驱动模式下 MTKView 不自转: 防抖开关/预览分辨率切换改完 drawable 后手动补一次
    // draw 刷新当前帧(drawInMTKView 自带 playbackReady/exporting 守卫, 早期调用安全)。
    [self requestPreviewDraw];
}

- (void)updatePreviewAspectWithWidth:(uint32_t)width height:(uint32_t)height {
    if (width == 0 || height == 0 || self.videoAspectConstraint == nil) {
        return;
    }

    CGFloat currentMultiplier = self.videoAspectConstraint.multiplier;
    CGFloat nextMultiplier = (CGFloat)height / (CGFloat)width;
    if (fabs(currentMultiplier - nextMultiplier) < 0.0001) {
        return;
    }

    [NSLayoutConstraint deactivateConstraints:@[self.videoAspectConstraint]];
    self.videoAspectConstraint = [self.videoView.heightAnchor constraintEqualToAnchor:self.videoView.widthAnchor multiplier:nextMultiplier];
    self.videoAspectConstraint.active = YES;

    [UIView performWithoutAnimation:^{
        [self.view layoutIfNeeded];
    }];
}

// 所有手动补帧统一走这里: draw 串行化到渲染队列, 避免主线程与渲染队列并发进
// drawInMTKView(MTKView paused+显式 draw 模式下, delegate 回调跑在调用 draw 的线程)。
- (void)requestPreviewDraw {
    if (self.renderQueue == nil) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.renderQueue, ^{
        [weakSelf.videoView draw];
    });
}

// [perf_diag] 主线程卡顿守望: 后台每 250ms 往主线程投一个空 block, 测排队延迟。
// 延迟 >80ms 即用户可感知的卡顿; 把它和同时间段的「慢帧 breakdown」「recompute
// 开始/结束」日志对照, 即可区分卡顿来自 draw 占满主线程还是 recompute 锁竞争。
- (void)startMainThreadWatchdog {
    if (self.mainThreadWatchdog != nil) {
        return;
    }
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        const CFTimeInterval pingT0 = CACurrentMediaTime();
        dispatch_async(dispatch_get_main_queue(), ^{
            const double latencyMs = (CACurrentMediaTime() - pingT0) * 1000.0;
            if (latencyMs > 80.0) {
                NSLog(@"[perf_diag] 主线程卡顿 %.0fms (任务排队延迟, 对照同时刻慢帧/recompute 日志定位占用者)", latencyMs);
            }
        });
    });
    dispatch_resume(timer);
    self.mainThreadWatchdog = timer;
}

- (void)drawInMTKView:(MTKView *)view {
    if (view != self.videoView || !_mdkPlayer || !self.playbackReady) {
        return;
    }
    // 导出期间预览停手 —— 导出在后台线程用 self.stabilizer(改 output_size +
    // process_frame),draw 在渲染队列也用同一个 stabilizer,不互斥会竞态崩溃 /
    // 尺寸错乱。导出时 return,屏幕停在最后一帧,导出完恢复。
    if (self.exporting) {
        return;
    }

    // [perf_diag] 预览性能打点: drawInMTKView 现已整体跑在专用渲染队列(不占主线程,
    // 实测主线程曾被它吃掉 40%、参数惰性重算等锁时单帧可达 1.2s)。分段计时:
    // 单帧总耗时 >10ms 打 breakdown, 每秒打一条窗口汇总
    // (drawable 等待 / MDK 渲染 / FFI process_frame / recompute 锁竞争)。
    const CFTimeInterval perfFrameT0 = CACurrentMediaTime();
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (drawable == nil) {
        return;
    }
    const CFTimeInterval perfDrawableT = CACurrentMediaTime();
    double perfHudMs = 0.0;
    double perfFFIMs = 0.0;
    double perfFovMs = 0.0;

    BOOL useStabilization = self.stabilizationEnabled && self.gyroflowReady && self.stabilizer != NULL;
    if (useStabilization) {
        // 输入纹理 = 视频原生 (gyroflow FFI 要求 input == params.size)。MDK surface
        // 必须 = 输入纹理尺寸: setVideoSurfaceSize 是「渲染填充区域」(MDK Player.h 明确
        // 写 "Window size, surface size or drawable size" + KeepAspectRatio)。给小于纹理
        // 的 surface, MDK 只把画面渲染进纹理原点的一角、其余留黑 → 预览缩小 + 防抖喂黑帧。
        // 预览分辨率改的是 gyroflow 输出 / drawable(见 applyPreviewOutputSizeToStabilizer),
        // 不在这里动 surface。
        [self makeMDKInputTextureWithWidth:self.videoInfo.width height:self.videoInfo.height];
        if (self.mdkInputTexture == nil) {
            return;
        }
        self.currentMDKRenderTarget = self.mdkInputTexture;
        [self updateMDKSurfaceSizeIfNeededWithWidth:(int)self.videoInfo.width height:(int)self.videoInfo.height];
    } else {
        self.currentMDKRenderTarget = drawable.texture;
        [self updateMDKSurfaceSizeIfNeededWithWidth:(int)drawable.texture.width height:(int)drawable.texture.height];
    }

    const CFTimeInterval perfRenderT0 = CACurrentMediaTime();
    double timestamp = _mdkPlayer->renderVideo();
    const CFTimeInterval perfRenderT1 = CACurrentMediaTime();
    if (timestamp < 0.0) {
        // 诊断: 首帧竞态排查(Sony 4K 107Mbps 首帧解码慢) —— 看 ready 后的补 draw
        // 是否因为首帧未解出而空跑、之后 renderCallback 有没有再来。
        NSLog(@"[draw_diag] renderVideo 无可渲染帧(ts=%.3f ready=%d paused=%d stab=%d)",
              timestamp, (int)self.playbackReady, (int)self.videoPaused, (int)useStabilization);
        return;
    }
    self.hasRenderedAnyMDKFrame = YES;

    // 陀螺仪显示 —— 跟随播放进度刷新（和防抖开关无关，只要视频已加载）：
    //   ① 左上角文字 overlay：当前帧三轴角速度
    //   ② 底部波形时间轴 View 的播放游标
    // gyroflow_get_gyro_at_timestamp 内部已应用同步偏移，直接传播放进度即可。
    if (self.gyroflowReady && self.stabilizer != NULL) {
        const CFTimeInterval perfHudT0 = CACurrentMediaTime();
        int64_t gyroTsUs = (int64_t)llround(timestamp * 1.0e6);
        double g[3] = {0.0, 0.0, 0.0};
        NSString *gyroText = nil;
        if (gyroflow_get_gyro_at_timestamp(self.stabilizer, gyroTsUs, g) == 0) {
            gyroText = [NSString stringWithFormat:
                @" Gyro (°/s)\n  X %+8.1f\n  Y %+8.1f\n  Z %+8.1f ",
                g[0], g[1], g[2]];
        }
        // 逐帧驱动「方向指示器」(对齐官方 quats_at_timestamp): raw + smoothed 姿态
        double quats8[8] = { 1,0,0,0, 1,0,0,0 };
        const BOOL hasQuats = (gyroflow_quats_at_timestamp(self.stabilizer, gyroTsUs, quats8) == 0);
        // block 不能直接捕获 C 数组, 拆成标量带去主线程再组回
        const double q0 = quats8[0], q1 = quats8[1], q2 = quats8[2], q3 = quats8[3];
        const double q4 = quats8[4], q5 = quats8[5], q6 = quats8[6], q7 = quats8[7];
        const double durSec = self.videoInfo.duration_s;
        // FFI 查询留在渲染队列(被锁住也不影响 UI); label/指示器/时间轴刷新回主线程
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gyroText != nil) {
                self.gyroLabel.text = gyroText;
            } else if (hasQuats) {
                // 无原始角速度(DJI/Xtra 等)→ 显示当前帧四元数(x,y,z,w)，与波形一致
                // quats8[0..3] = raw 姿态 [w,x,y,z]
                self.gyroLabel.text = [NSString stringWithFormat:
                    @" Quat\n  X %+6.3f\n  Y %+6.3f\n  Z %+6.3f\n  W %+6.3f ",
                    q1, q2, q3, q0];
            }
            if (hasQuats) {
                double rawQ[4] = { q0, q1, q2, q3 };
                double smQ[4] = { q4, q5, q6, q7 };
                [self.inputTab updateOrientationIndicatorRaw:rawQ smoothed:smQ];
            }
            if (durSec > 0.0) {
                self.gyroTimelineView.progress = timestamp / durSec;
            }
            [self updatePlayInfoLabelAtTime:timestamp];
        });
        perfHudMs = (CACurrentMediaTime() - perfHudT0) * 1000.0;
    }

    if (useStabilization) {
        // MDK renderVideo() 返回的是「秒」(double, microsecond 精度)，
        // 不是微秒整数；必须 *1e6 转成 us 才能喂给 gyroflow。
        // 之前少这一步 → 整个视频的 timestamp 全挤在 0..N us 内、几乎同一时刻
        // → smoothed_quat 不随帧变化 → 看起来像静态裁剪，跟桌面差很多。
        //
        // 预览时间戳 = renderVideo() 返回的纹理内容帧时间, **不加任何补偿**(与导出一致)。
        // 结论依据(GoPro Hero6/Hero10 对照实测, 勿再反复):
        //   精确时间戳机型(Hero8+/Hero10, 原生 quat): 时间戳上加任何补偿(48ms 或 1.5 帧≈25ms)
        //   都会破坏防抖 → renderVideo 的 ts 与纹理内容是配对的, 不存在"渲染队列延迟"。
        //   raw-IMU 机型(Hero5/6/7)无防抖的真因是**相机侧陀螺与视频 ~48ms 错位**
        //   (has_accurate_timestamps=false 本义即时间戳不准), 属于陀螺偏移问题,
        //   应在陀螺偏移层解决(autosync/手动/按机型默认), 不属于预览时间戳问题。
        int64_t timestampUs = (int64_t)llround(timestamp * 1.0e6);
        GyroflowProcessInfo processInfo = {0};

        // 防御性: 现在 output_size = 视频原生固定; 若 MTKView/CAMetalLayer 把
        // drawable 改成别的尺寸, 把 drawable 同步回 output_size, 不反向改算法。
        // (之前反着写: drawable 偏离就改 output_size, 等于让预览侧把算法目标尺寸顶飞 —
        // 跟桌面 set_preview_resolution 不动 params.output_size 的语义相反。)
        const uint32_t drawW = (uint32_t)drawable.texture.width;
        const uint32_t drawH = (uint32_t)drawable.texture.height;
        if (drawW != self.videoInfo.output_width || drawH != self.videoInfo.output_height) {
            NSLog(@"[Gyroflow] drawable size %ux%u != output %ux%u, resync drawable",
                  drawW, drawH, self.videoInfo.output_width, self.videoInfo.output_height);
            // drawableSize 是 view/layer 属性, 回主线程改; 改完再经渲染队列补一次 draw
            // (帧驱动模式下没有"自动的下一帧", 暂停时也要能拿到新尺寸 drawable)
            dispatch_async(dispatch_get_main_queue(), ^{
                self.videoView.drawableSize = CGSizeMake(self.videoInfo.output_width,
                                                         self.videoInfo.output_height);
                [self requestPreviewDraw];
            });
            return; // 这一帧丢掉, 补的那次 drawable 已是新尺寸再 process
        }

        if (!self.hasRenderedStabilizedFrame) {
            NSLog(@"[Gyroflow] first metal frame: in=%lux%lu out=%lux%lu",
                  (unsigned long)self.mdkInputTexture.width,
                  (unsigned long)self.mdkInputTexture.height,
                  (unsigned long)drawable.texture.width,
                  (unsigned long)drawable.texture.height);
        }

        CFTimeInterval ffiT0 = CACurrentMediaTime();
        int32_t result = gyroflow_process_frame_metal_bgra8(
            self.stabilizer,
            timestampUs,
            -1,
            (__bridge void *)self.mdkInputTexture,
            self.mdkInputTexture.width,
            self.mdkInputTexture.height,
            (__bridge void *)drawable.texture,
            drawable.texture.width,
            drawable.texture.height,
            (__bridge void *)self.commandQueue,
            &processInfo
        );
        perfFFIMs = (CACurrentMediaTime() - ffiT0) * 1000.0;
        self.fpsWindowFFIMsSum += perfFFIMs;

        if (result != 0) {
            NSString *err = [self lastGyroflowError];
            NSLog(@"[Gyroflow] process_frame_metal_bgra8 failed: %@", err);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.statusLabel.text = [NSString stringWithFormat:@"Metal 防抖失败：%@", err];
            });
            // 仍然 present 一帧避免 drawable 泄漏
            id<MTLCommandBuffer> fallback = [self.commandQueue commandBuffer];
            [fallback presentDrawable:drawable];
            [fallback commit];
            return;
        }
        // 记录当前帧 fov, 给左上角 HUD 实时显示 zoom% 用。
        // processInfo.fov 是 t-48ms 帧的 fov (process_frame 用了 -48ms 偏移补 MDK 队列延迟,
        // 跟桌面 Stabilization.qml:669 的 current_fov 不对齐)。
        // 单独再调一次 gyroflow_get_fov_at_timestamp(t, no offset) 拿当前 t 对应的 fov,
        // 跟桌面 HUD 对齐。失败 fallback 到 processInfo.fov。
        const int64_t tsForHudUs = (int64_t)llround(timestamp * 1.0e6);
        double hudFov = 0.0;
        double hudMinFov = 0.0;
        const CFTimeInterval perfFovT0 = CACurrentMediaTime();
        if (gyroflow_get_fov_at_timestamp(self.stabilizer, tsForHudUs, &hudFov, &hudMinFov) == 0
            && hudFov > 0.0001) {
            self.currentFrameFov = hudFov;
        } else {
            self.currentFrameFov = processInfo.fov;
        }
        perfFovMs = (CACurrentMediaTime() - perfFovT0) * 1000.0;

        if (!self.hasRenderedStabilizedFrame) {
            self.hasRenderedStabilizedFrame = YES;
            NSString *status = [NSString stringWithFormat:
                @"MDK + Metal 防抖输出中\n输入：%ux%u %.2ffps\n输出：%ux%u",
                self.videoInfo.width,
                self.videoInfo.height,
                self.videoInfo.fps,
                self.videoInfo.output_width,
                self.videoInfo.output_height
            ];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.statusLabel.text = status;
            });
        }
    }

    id<MTLCommandBuffer> present = [self.commandQueue commandBuffer];
    [present presentDrawable:drawable];
    [present commit];

    // [perf_diag] 本帧主线程耗时 breakdown + 每秒窗口汇总。
    // 看法: process_frame 偶发飙到几百 ms 且与 recompute 时间窗重合 → 锁竞争;
    // process_frame 稳定偏高(>16ms) → 单帧 GPU/FFI 成本本身超主线程预算。
    const CFTimeInterval perfEndT = CACurrentMediaTime();
    const double perfDrawableMs = (perfDrawableT - perfFrameT0) * 1000.0;
    const double perfRenderMs = (perfRenderT1 - perfRenderT0) * 1000.0;
    const double perfTotalMs = (perfEndT - perfFrameT0) * 1000.0;
    if (perfTotalMs > 10.0) {
        NSLog(@"[perf_diag] 慢帧 总耗时 %.1fms (stab=%d): drawable等待 %.1f | renderVideo %.1f | HUD查询+刷新 %.1f | process_frame %.1f | fov查询 %.1f | 其余 %.1f",
              perfTotalMs, (int)useStabilization,
              perfDrawableMs, perfRenderMs, perfHudMs, perfFFIMs, perfFovMs,
              perfTotalMs - perfDrawableMs - perfRenderMs - perfHudMs - perfFFIMs - perfFovMs);
    }
    self.fpsWindowFrames += 1;
    self.fpsWindowTotalMsSum += perfTotalMs;
    const CFTimeInterval perfWindowElapsed = perfEndT - self.fpsWindowStart;
    if (perfWindowElapsed >= 1.0) {
        NSLog(@"[perf_diag] 1s汇总: %ld 帧 fps=%.1f | draw 均耗时 %.1fms (占渲染线程 %.0f%%) | process_frame 均耗时 %.1fms (stab=%d)",
              (long)self.fpsWindowFrames,
              (double)self.fpsWindowFrames / perfWindowElapsed,
              self.fpsWindowTotalMsSum / (double)self.fpsWindowFrames,
              self.fpsWindowTotalMsSum / (perfWindowElapsed * 1000.0) * 100.0,
              self.fpsWindowFFIMsSum / (double)self.fpsWindowFrames,
              (int)useStabilization);
        self.fpsWindowStart = perfEndT;
        self.fpsWindowFrames = 0;
        self.fpsWindowFFIMsSum = 0.0;
        self.fpsWindowTotalMsSum = 0.0;
    }

    // 右上角帧率 overlay 已按需关闭, 不再计算/刷新 (fpsLabel.hidden = YES)。
    // 如需恢复, 取消下面注释并把 fpsLabel.hidden 改回 NO。
    // CFTimeInterval now = CACurrentMediaTime();
    // if (!useStabilization) {
    //     self.fpsWindowFrames += 1;
    // }
    // CFTimeInterval windowElapsed = now - self.fpsWindowStart;
    // if (windowElapsed >= 0.5 && self.fpsWindowFrames > 0) {
    //     double fps = (double)self.fpsWindowFrames / windowElapsed;
    //     double avgFFI = (self.fpsWindowFFIMsSum > 0.0)
    //                    ? (self.fpsWindowFFIMsSum / (double)self.fpsWindowFrames)
    //                    : 0.0;
    //     if (useStabilization) {
    //         self.fpsLabel.text = [NSString stringWithFormat:@"  %.1f fps  ffi %.0fms  ", fps, avgFFI];
    //     } else {
    //         self.fpsLabel.text = [NSString stringWithFormat:@"  %.1f fps  (stab off)  ", fps];
    //     }
    //     self.fpsWindowStart = now;
    //     self.fpsWindowFrames = 0;
    //     self.fpsWindowFFIMsSum = 0.0;
    // }
}

- (void)updateMDKSurfaceSizeIfNeededWithWidth:(int)width height:(int)height {
    if (width <= 0 || height <= 0 || !_mdkPlayer) {
        return;
    }
    if (_mdkSurfaceWidth == width && _mdkSurfaceHeight == height) {
        return;
    }
    _mdkSurfaceWidth = width;
    _mdkSurfaceHeight = height;
    _mdkPlayer->setVideoSurfaceSize(width, height);
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
}

- (NSString *)lastGyroflowError {
    const char *message = gyroflow_last_error();
    if (message == NULL) {
        return @"未知错误";
    }
    return [NSString stringWithUTF8String:message] ?: @"未知错误";
}

- (void)updateStatus:(NSString *)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.text = status;
    });
}

- (void)releaseCurrentSecurityScope {
    if (self.hasSecurityScope && self.securityScopedURL != nil) {
        [self.securityScopedURL stopAccessingSecurityScopedResource];
    }
    self.securityScopedURL = nil;
    self.hasSecurityScope = NO;
}

#pragma mark - Stabilized export -> Photos

- (void)exportStabilizedVideo {
    NSLog(@"[Export] tap received  exporting=%d  enabled=%d  gyroflowReady=%d  url=%@",
          (int)self.exporting,
          (int)self.exportButton.enabled,
          (int)self.gyroflowReady,
          self.securityScopedURL.lastPathComponent);
    if (self.exporting) {
        // 二次点击 = 取消导出
        self.exportCancelled = YES;
        self.statusLabel.text = @"正在取消导出…";
        NSLog(@"[Export] cancel requested by user");
        return;
    }
    if (self.securityScopedURL == nil) {
        self.statusLabel.text = @"请先选择视频。";
        return;
    }
    NSURL *src = self.securityScopedURL;

    // 无同步点(且非精确时间戳视频)→ 防抖对齐不准, 结果会不正确。先弹框确认:
    // 「是」直接导出, 「否」取消(关弹框)。
    if (!self.hasAccurateTimestamps && self.syncPointCount == 0) {
        __weak typeof(self) weakSelf = self;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"不存在同步点"
                                    message:@"不存在同步点，您的结果将不正确。您确定要渲染此文件吗？"
                             preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"否" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"是" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [weakSelf proceedExportFromURL:src];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    [self proceedExportFromURL:src];
}

// 通过同步点确认后开始导出。对齐官方:必须先授权目标文件夹(受系统文件访问限制),
// 没授权过就先弹提示 → 确定 → 打开文件夹选择器 → 授权后导出(取消则中止,不回落相册)。
- (void)proceedExportFromURL:(NSURL *)src {
    // 已授权导出存储目录 → 成品写目录, 直接导出
    if (self.exportFolderURL != nil) {
        [self beginExportFromURL:src];
        return;
    }
    // 未授权: 记下待导出的源, 弹"请选择目标文件夹"提示, 确定后打开选择器。
    // 选完目录在 documentPicker:didPickDocumentsAtURLs: 的 pickingExportFolder 分支续导出。
    self.pendingExportSrcURL = src;
    __weak typeof(self) weakSelf = self;
    [GFViewKit showModalOverView:self.view
                         message:@"由于文件访问限制，您需要手动选择目标文件夹。\n单击确定并选择目标文件夹。"
                         success:NO
                dontShowAgainKey:kGFExportFolderHintKey
                       onConfirm:^{
        __strong typeof(weakSelf) sSelf = weakSelf;
        if (sSelf == nil) return;
        [sSelf presentExportFolderPicker];
    }];
}

// 「保持前台」提示的"不再显示"持久化键(对齐官方 settings "dontShowAgain-keep-in-foreground")
static NSString * const kGFKeepForegroundHintKey = @"gf_dontShowAgain_keepInForeground";


// 导出开始时的前台提示(对齐官方 App.qml:374-378, 移动端专属): 非阻塞 —— 弹框悬浮在
// 导出进度之上, 渲染照常进行; 「确定」仅关闭, 勾选「不再显示」持久化后不再弹。
- (void)maybeShowKeepForegroundHint {
    [GFViewKit showModalOverView:self.view
                          message:@"将此 APP 保持在前台运行并不要锁定屏幕。\n受限于系统视频编码器，不支持后台渲染。"
                          success:NO
                 dontShowAgainKey:kGFKeepForegroundHintKey];
}

- (void)beginExportFromURL:(NSURL *)src {
    self.exporting = YES;
    self.exportCancelled = NO;
    [self maybeShowKeepForegroundHint];
    self.stabilizationButton.enabled = NO;
    // 导出期间预览暂停，播放/暂停按钮禁用
    self.playPauseButton.enabled = NO;
    // 导出按钮 *保持* enabled，作为"取消导出"按钮使用
    [self.exportButton setTitle:@"取消导出" forState:UIControlStateNormal];
    self.exportProgress.hidden = NO;
    self.exportProgress.progress = 0.0;
    self.statusLabel.text = @"正在初始化导出…首帧需要编译 GPU shader，可能需要几秒。";

    // 导出进度蒙版(和导入视频时一致): 底部全屏半透明蒙版 analysisMask + 居中进度面板 syncOverlay。
    __weak typeof(self) weakSelfOverlay = self;
    self.analysisMask.hidden = NO;
    [self.view bringSubviewToFront:self.analysisMask];
    [self.syncOverlay showWithTitle:@"渲染中" onCancel:^{
        __strong typeof(weakSelfOverlay) sSelf = weakSelfOverlay;
        if (sSelf == nil) return;
        sSelf.exportCancelled = YES;
        sSelf.statusLabel.text = @"正在取消导出…";
    }];
    [self.view bringSubviewToFront:self.syncOverlay];

    // 释放 MDK 播放器(导出用 AVAssetReader, MDK 用不上), 回收其解码/预览内存。导出完重建。
    self.videoPaused = YES;
    [self.playPauseButton setTitle:@"播放" forState:UIControlStateNormal];
    [self teardownMDKForExport];

    NSString *ext = nil;
    [GFExportUtils codecForIndex:self.paramsModel.exportCodecIndex codecType:NULL fileType:NULL extension:&ext];
    // 文件名取「输出路径」输入框(对齐官方 OutputPathField; 相册条目名跟随临时文件名)。
    // 清掉路径分隔符防穿越; 扩展名强制与编解码器容器一致; 空白时兜底时间戳名。
    NSString *tmpName = [self.exportSection.outputFileName stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    if (tmpName.length == 0) {
        tmpName = [NSString stringWithFormat:@"gyroflow_stabilized_%lld.%@",
                   (long long)[[NSDate date] timeIntervalSince1970], ext];
    } else if (![tmpName.pathExtension.lowercaseString isEqualToString:ext.lowercaseString]) {
        tmpName = [[tmpName stringByDeletingPathExtension] stringByAppendingPathExtension:ext] ?: tmpName;
    }
    NSURL *dst = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:tmpName]];

    [[NSFileManager defaultManager] removeItemAtURL:dst error:nil];

    NSDate *startTime = [NSDate date];
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.exportQueue, ^{
        NSError *err = [weakSelf runExportFromURL:src toURL:dst progress:^(double p, NSInteger frame, NSInteger total) {
            dispatch_async(dispatch_get_main_queue(), ^{
                weakSelf.exportProgress.progress = (float)p;
                NSTimeInterval elapsed = -[startTime timeIntervalSinceNow];
                NSTimeInterval eta = (p > 0.01) ? (elapsed / p) - elapsed : 0.0;
                weakSelf.statusLabel.text = [NSString stringWithFormat:@"导出中 %ld/%ld 帧  已用 %.0fs  剩约 %.0fs",
                                             (long)frame, (long)total, elapsed, eta];
                // 进度蒙版: fps = 已处理帧 / 已用时(编码速度)
                double fps = (elapsed > 0.01) ? (double)frame / elapsed : 0.0;
                [weakSelf.syncOverlay updateProgress:p framesFed:(int)frame framesTotal:(int)total fps:fps];
            });
        }];

        if (err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) sSelf = weakSelf;
                if (sSelf == nil) return;
                sSelf.exporting = NO;
                // 导出时把 self.stabilizer 的 output_size 改成了全分辨率(set_output_size +
                // recompute, 见 runExportFromURL)。导出完要恢复成预览的渲染尺寸: 若启用了
                // 预览分辨率就缩回预览尺寸, 否则缩回逻辑全尺寸 —— 统一走
                // applyPreviewOutputSizeToStabilizer(内部按 paramsModel.outputSize + 预览
                // 分辨率精确还原 + recompute + 重读 videoInfo + 同步 drawable, 内部已判空)。
                [sSelf applyPreviewOutputSizeToStabilizer];
                [sSelf restoreMDKAfterExport];  // 重建导出期间释放的 MDK 播放器, seek 回原位
                sSelf.stabilizationButton.enabled = (sSelf.gyroflowReady ? YES : NO);
                [sSelf updateExportButtonEnabled];
                [sSelf.exportButton setTitle:@"导出" forState:UIControlStateNormal];
                sSelf.exportProgress.hidden = YES;
                [sSelf.syncOverlay hide];  // 关闭导出进度蒙版
                sSelf.analysisMask.hidden = YES;  // 关闭底部半透明蒙版
                // 不自动播放 (按用户要求, 导出结束后保持暂停态)
                sSelf.videoPaused = YES;
                sSelf.playPauseButton.enabled = (sSelf.playbackReady ? YES : NO);
                [sSelf.playPauseButton setTitle:@"播放" forState:UIControlStateNormal];
                if (sSelf.exportCancelled) {
                    sSelf.statusLabel.text = @"已取消导出。";
                } else {
                    sSelf.statusLabel.text = [NSString stringWithFormat:@"导出失败：%@", err.localizedDescription];
                }
            });
            return;
        }

        // 用户通过「…」选了导出存储目录 → 成品直接移入该目录(对齐官方导出到所选目录);
        // 未选则默认存相册。
        if (weakSelf.exportFolderURL != nil) {
            NSURL *folder = weakSelf.exportFolderURL;
            // 同名冲突自动 _X 改名(对齐官方 App.qml:738-748 renameOutput), 不覆盖已有文件
            NSURL *finalURL = [GFExportUtils uniqueURLInFolder:folder forName:dst.lastPathComponent];
            NSError *moveErr = nil;
            BOOL moved = [[NSFileManager defaultManager] moveItemAtURL:dst toURL:finalURL error:&moveErr];
            [[NSFileManager defaultManager] removeItemAtURL:dst error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) sSelf = weakSelf;
                if (sSelf == nil) return;
                [sSelf restoreUIAfterExport];
                NSTimeInterval elapsed = -[startTime timeIntervalSinceNow];
                if (moved) {
                    sSelf.statusLabel.text = [NSString stringWithFormat:@"已保存到 %@（用时 %.1fs）", folder.lastPathComponent, elapsed];
                    [GFViewKit showModalOverView:sSelf.view
                                         message:[NSString stringWithFormat:@"渲染完成。文件已写入: %@/%@。", folder.lastPathComponent, finalURL.lastPathComponent]
                                         success:YES
                                dontShowAgainKey:nil];
                } else {
                    sSelf.statusLabel.text = [NSString stringWithFormat:@"保存到所选目录失败：%@", moveErr.localizedDescription];
                }
            });
            return;
        }

        // Save to Photos
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:dst];
        } completionHandler:^(BOOL success, NSError * _Nullable phErr) {
            [[NSFileManager defaultManager] removeItemAtURL:dst error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) sSelf = weakSelf;
                if (sSelf == nil) return;
                [sSelf restoreUIAfterExport];
                NSTimeInterval elapsed = -[startTime timeIntervalSinceNow];
                if (success) {
                    sSelf.statusLabel.text = [NSString stringWithFormat:@"已保存到相册（用时 %.1fs）", elapsed];
                    // 导出成功弹框(对齐官方 RenderQueue.qml:156-170 Modal.Success / 截图 IMG_1462,
                    // iOS 端官方仅「确定」按钮、无打开文件入口)
                    [GFViewKit showModalOverView:sSelf.view message:@"渲染完成。文件已写入: 相册。" success:YES dontShowAgainKey:nil];
                } else {
                    sSelf.statusLabel.text = [NSString stringWithFormat:@"保存到相册失败：%@", phErr.localizedDescription];
                }
            });
        }];
    });
}

// 文件名查重(输入框提交/默认名设置/换导出目录后调用): 所选导出目录里已有同名 →
// 自增 _X 回写输入框; 无同名保持原名。未选目录(默认存相册)无法按名查询, 不处理。
- (void)resolveOutputFileNameConflict {
    if (self.exportFolderURL == nil) {
        return;
    }
    NSString *name = self.exportSection.outputFileName;
    if (name == nil) {
        return;
    }
    NSString *unique = [GFExportUtils uniqueURLInFolder:self.exportFolderURL forName:name].lastPathComponent;
    if (![unique isEqualToString:name]) {
        [self.exportSection setDefaultOutputFileName:unique];
    }
}

// 导出收尾的公共 UI 恢复(存相册/存目录两路共用): 恢复预览输出尺寸、重建 MDK、
// 还原按钮/蒙版/暂停态。导出时 output_size 被改成了全分辨率(见 runExportFromURL),
// applyPreviewOutputSizeToStabilizer 按 paramsModel + 预览分辨率精确还原。
- (void)restoreUIAfterExport {
    self.exporting = NO;
    [self applyPreviewOutputSizeToStabilizer];
    [self restoreMDKAfterExport];
    self.stabilizationButton.enabled = (self.gyroflowReady ? YES : NO);
    [self updateExportButtonEnabled];
    [self.exportButton setTitle:@"导出" forState:UIControlStateNormal];
    self.exportProgress.hidden = YES;
    [self.syncOverlay hide];
    self.analysisMask.hidden = YES;
    // 不自动播放 (按用户要求)
    self.videoPaused = YES;
    self.playPauseButton.enabled = (self.playbackReady ? YES : NO);
    [self.playPauseButton setTitle:@"播放" forState:UIControlStateNormal];
}

// 核心：用 AVAssetReader 解码 → Metal 防抖 → AVAssetWriter 编码。
// 这里专门 new 一份独立的 GyroflowStabilizer，避免和正在播放的预览实例抢资源。
- (NSError *)runExportFromURL:(NSURL *)srcURL toURL:(NSURL *)dstURL progress:(void (^)(double p, NSInteger frame, NSInteger total))progressBlock {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:srcURL options:nil];
    NSArray<AVAssetTrack *> *vTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    if (vTracks.count == 0) {
        return [NSError errorWithDomain:@"Gyroflow" code:1 userInfo:@{NSLocalizedDescriptionKey: @"视频无视频轨道"}];
    }
    AVAssetTrack *vTrack = vTracks.firstObject;
    // 音频导出：用 requestMediaDataWhenReadyOnQueue: 回调式 API（见下方音频段）。
    // 之前的「先把音频整段灌进 writer」pre-pass 会死锁 —— mp4 muxer 要交错复用，
    // 音频缓冲满了却在等视频提供交错点，而视频还没开始跑。回调式让 AVFoundation
    // 自己按节奏拉音频，writer 内部正确交错，不会死锁。
    AVAssetTrack *aTrack = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    // 「导出设置·导出音频」关闭时不带音频轨 (后续音频 reader/writer 均 gate 在 aTrack 上)。
    if (!self.paramsModel.exportAudio) {
        aTrack = nil;
    }

    CGSize naturalSize = vTrack.naturalSize;
    const uint32_t inW = (uint32_t)llround(naturalSize.width);
    const uint32_t inH = (uint32_t)llround(naturalSize.height);
    // 输出尺寸: 用户在「导出设置·输出大小」里设的值优先; 未设置(<=0)时回退到 16:9 等比。
    // 阈值用 >0.5(对齐输入框 v<=0 回滚 + 官方无最小尺寸限制): 任意正偶数都采用,
    // 不再卡 16; 编码器(VideoToolbox)对过小尺寸的拒绝由其自身决定。
    uint32_t outW, outH;
    CGSize userSize = self.paramsModel.outputSize;
    if (userSize.width > 0.5 && userSize.height > 0.5) {
        outW = (uint32_t)llround(userSize.width);
        outH = (uint32_t)llround(userSize.height);
    } else {
        outW = inW;
        outH = [GFExportUtils stabilizedHeightForWidth:inW];
    }
    if (outW & 1) outW -= 1;   // 编码器要求偶数边
    if (outH & 1) outH -= 1;

    // ===== 关键:导出直接用 self.stabilizer(预览那一份)=====
    // 之前用新建的 exportStab,导致预览≠导出:
    //   - exportStab 只 auto-match 镜头,没用用户上传的镜头档案
    //   - exportStab 没有 autosync 算出的合成 gyro / 每点 offset
    //   - 预览 drawInMTKView 把 output_size 设成屏幕尺寸,exportStab 是另一个尺寸
    // 现在复用 self.stabilizer,它已经有:上传的镜头 + autosync 合成 gyro +
    // ParamsModel 全部参数 + 跟预览相同的插值(Bilinear)。这样导出 1:1 等于预览。
    //
    // 唯一要改的是 output_size(预览是屏幕 drawable 尺寸,导出要全分辨率)。
    // 导出在后台线程跑,期间 drawInMTKView 已被 self.exporting 闸门挡掉,不会
    // 并发改 self.stabilizer。导出完 self.exporting=NO,draw 恢复时会自动把
    // output_size 同步回屏幕尺寸,无需手动还原。
    //
    // 注意:**不调** set_gyro_offset —— 那会 clear_offsets 把 autosync 装的
    // 每点 offset 冲掉。self.stabilizer 的 gyro 状态已经是对的(autosync 或手动)。
    GyroflowStabilizer *exportStab = self.stabilizer;  // 别名,下面沿用,但不 free
    if (exportStab == NULL) {
        return [NSError errorWithDomain:@"Gyroflow" code:2 userInfo:@{NSLocalizedDescriptionKey: @"stabilizer 未就绪"}];
    }
    // 对齐 Android: 稳定按「夹到源内」的尺寸算 → 取景固定(与输出分辨率无关), 再放大到 outW×outH 编码。
    // 夹后尺寸 = gyroflow set_output_size 的缩放规则: scale = min(源/请求), 目标比源大时夹到源内。
    uint32_t clampW = outW, clampH = outH;
    {
        double scale = MIN((double)inW / outW, (double)inH / outH);
        if (scale < 1.0) {
            clampW = ((uint32_t)llround(outW * scale)) & ~1u;
            clampH = ((uint32_t)llround(outH * scale)) & ~1u;
        }
    }
    BOOL needUpscale = (clampW != outW || clampH != outH);
    GF_CALL(gyroflow_set_output_size_exact(exportStab, clampW, clampH));
    GF_CALL(gyroflow_recompute_blocking(exportStab));
    NSLog(@"[Export] 夹后稳定 %ux%u → 放大输出 %ux%u (upscale=%d)", clampW, clampH, outW, outH, needUpscale);

    // 中间稳定纹理(夹后尺寸)+ 放大管线(仅在需要放大时)。不放大则稳定直接渲进 outTex。
    // 放大用一次普通 Metal render pass(全屏三角形 + linear 采样), 只依赖 Metal, 不用 MPS。
    id<MTLTexture> stabTex = nil;
    id<MTLRenderPipelineState> upPipeline = nil;
    id<MTLSamplerState> upSampler = nil;
    if (needUpscale) {
        MTLTextureDescriptor *sd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                      width:clampW height:clampH mipmapped:NO];
        sd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;  // gyroflow 渲进(target) + 放大采样(read)
        sd.storageMode = MTLStorageModePrivate;
        stabTex = [self.metalDevice newTextureWithDescriptor:sd];

        NSString *upSrc =
            @"#include <metal_stdlib>\n"
             "using namespace metal;\n"
             "struct VOut { float4 pos [[position]]; float2 uv; };\n"
             "vertex VOut up_vs(uint vid [[vertex_id]]) {\n"
             "  float2 p[3] = { float2(-1.0,-1.0), float2(3.0,-1.0), float2(-1.0,3.0) };\n"
             "  VOut o; o.pos = float4(p[vid], 0.0, 1.0);\n"
             "  o.uv = float2((p[vid].x + 1.0) * 0.5, (1.0 - p[vid].y) * 0.5);\n"  // 顶左原点, 不翻转
             "  return o;\n"
             "}\n"
             "fragment float4 up_fs(VOut in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {\n"
             "  return t.sample(s, in.uv);\n"
             "}\n";
        NSError *upErr = nil;
        id<MTLLibrary> upLib = [self.metalDevice newLibraryWithSource:upSrc options:nil error:&upErr];
        if (upLib) {
            MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
            pd.vertexFunction = [upLib newFunctionWithName:@"up_vs"];
            pd.fragmentFunction = [upLib newFunctionWithName:@"up_fs"];
            pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
            upPipeline = [self.metalDevice newRenderPipelineStateWithDescriptor:pd error:&upErr];
        }
        if (!upPipeline) {
            NSLog(@"[Export] 放大管线创建失败, 回退到不放大: %@", upErr);
        } else {
            MTLSamplerDescriptor *smp = [[MTLSamplerDescriptor alloc] init];
            smp.minFilter = MTLSamplerMinMagFilterLinear;
            smp.magFilter = MTLSamplerMinMagFilterLinear;
            upSampler = [self.metalDevice newSamplerStateWithDescriptor:smp];
        }
    }
    // [诊断] 导出时引擎里是否还有防抖修正? 0=无修正(画面=原始). 预览端 recompute 日志是 P=6.38。
    double exMaxAng[3] = {0.0, 0.0, 0.0};
    gyroflow_get_max_angles(exportStab, exMaxAng);
    NSLog(@"[Export][diag] after recompute maxAngles P=%.2f Y=%.2f R=%.2f  (0 = 没防抖修正)",
          exMaxAng[0], exMaxAng[1], exMaxAng[2]);

    // ===== Reader =====
    NSError *readerErr = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&readerErr];
    if (reader == nil) {
        // 不 free:exportStab 是 self.stabilizer 的别名,预览还要用
        return readerErr ?: [NSError errorWithDomain:@"Gyroflow" code:4 userInfo:@{NSLocalizedDescriptionKey: @"创建 reader 失败"}];
    }

    NSDictionary *vReaderSettings = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    AVAssetReaderTrackOutput *vReaderOut = [[AVAssetReaderTrackOutput alloc] initWithTrack:vTrack outputSettings:vReaderSettings];
    vReaderOut.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:vReaderOut]) {
        // 不 free:exportStab 是 self.stabilizer 的别名,预览还要用
        return [NSError errorWithDomain:@"Gyroflow" code:5 userInfo:@{NSLocalizedDescriptionKey: @"无法添加视频读入"}];
    }
    [reader addOutput:vReaderOut];

    // 音频用**独立的** AVAssetReader —— 避免和视频 reader 在不同线程并发
    // copyNextSampleBuffer（同一 reader 跨线程读不同 output 不安全）。
    AVAssetReader *audioReader = nil;
    AVAssetReaderTrackOutput *aReaderOut = nil;
    if (aTrack) {
        NSError *aReaderErr = nil;
        audioReader = [AVAssetReader assetReaderWithAsset:asset error:&aReaderErr];
        // 解码为 PCM —— writer 再以 AAC 重编码
        NSDictionary *aReaderSettings = @{
            AVFormatIDKey: @(kAudioFormatLinearPCM),
            AVLinearPCMIsFloatKey: @NO,
            AVLinearPCMIsBigEndianKey: @NO,
            AVLinearPCMBitDepthKey: @16,
            AVLinearPCMIsNonInterleaved: @NO,
        };
        aReaderOut = [[AVAssetReaderTrackOutput alloc] initWithTrack:aTrack outputSettings:aReaderSettings];
        aReaderOut.alwaysCopiesSampleData = NO;
        if (audioReader && [audioReader canAddOutput:aReaderOut]) {
            [audioReader addOutput:aReaderOut];
        } else {
            NSLog(@"[Export] 音频 reader 创建失败，导出将不带音频: %@", aReaderErr);
            audioReader = nil;
            aReaderOut = nil;
        }
    }

    // ===== Writer =====
    // 编解码器 / 容器: 取自「导出设置」(paramsModel)。H.264/HEVC→.mp4, ProRes→.mov。
    AVVideoCodecType codecType; AVFileType fileType;
    [GFExportUtils codecForIndex:self.paramsModel.exportCodecIndex codecType:&codecType fileType:&fileType extension:NULL];
    BOOL isProRes = [codecType isEqual:AVVideoCodecTypeAppleProRes422];

    NSError *writerErr = nil;
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:dstURL fileType:fileType error:&writerErr];
    if (writer == nil) {
        // 不 free:exportStab 是 self.stabilizer 的别名,预览还要用
        return writerErr ?: [NSError errorWithDomain:@"Gyroflow" code:6 userInfo:@{NSLocalizedDescriptionKey: @"创建 writer 失败"}];
    }

    NSMutableDictionary *vWriterSettings = [@{
        AVVideoCodecKey: codecType,
        AVVideoWidthKey: @(outW),
        AVVideoHeightKey: @(outH),
    } mutableCopy];
    if (!isProRes) {
        // H.264/HEVC: 设码率 + 关键帧间隔; H.264 再指定 profile。
        // (ProRes 是帧内编码, 由 profile 决定质量, 不吃 AVVideoAverageBitRateKey。)
        NSInteger bitrateBps = (self.paramsModel.exportBitrateMbps > 0)
            ? (NSInteger)self.paramsModel.exportBitrateMbps * 1000 * 1000
            : 64 * 1000 * 1000;   // 0 = 自动, 默认 64 Mbps
        NSMutableDictionary *compression = [@{
            AVVideoAverageBitRateKey: @(bitrateBps),
            AVVideoMaxKeyFrameIntervalKey: @(30),
        } mutableCopy];
        if ([codecType isEqual:AVVideoCodecTypeH264]) {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel;
        }
        vWriterSettings[AVVideoCompressionPropertiesKey] = compression;
    }
    AVAssetWriterInput *vWriterIn = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:vWriterSettings];
    vWriterIn.expectsMediaDataInRealTime = NO;
    // 写入侧不再做几何变换 —— Gyroflow 已经把帧搞正
    vWriterIn.transform = CGAffineTransformIdentity;

    NSDictionary *adaptorAttrs = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (NSString *)kCVPixelBufferWidthKey: @(outW),
        (NSString *)kCVPixelBufferHeightKey: @(outH),
        (NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    AVAssetWriterInputPixelBufferAdaptor *adaptor =
        [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:vWriterIn
                                                                            sourcePixelBufferAttributes:adaptorAttrs];
    [writer addInput:vWriterIn];

    AVAssetWriterInput *aWriterIn = nil;
    if (aReaderOut) {
        // 用源轨道的常规参数（mono/stereo + 同采样率）
        const AudioStreamBasicDescription *asbd = NULL;
        CMFormatDescriptionRef fmt = (__bridge CMFormatDescriptionRef)aTrack.formatDescriptions.firstObject;
        if (fmt) asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt);

        NSDictionary *aWriterSettings = @{
            AVFormatIDKey: @(kAudioFormatMPEG4AAC),
            AVNumberOfChannelsKey: @(asbd ? asbd->mChannelsPerFrame : 2),
            AVSampleRateKey: @(asbd ? asbd->mSampleRate : 48000),
            AVEncoderBitRateKey: @(192000),
        };
        aWriterIn = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:aWriterSettings];
        aWriterIn.expectsMediaDataInRealTime = NO;
        if ([writer canAddInput:aWriterIn]) {
            [writer addInput:aWriterIn];
        } else {
            aWriterIn = nil;
        }
    }

    // ===== Metal texture cache for input/output CVPixelBuffers =====
    CVMetalTextureCacheRef texCache = NULL;
    CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, self.metalDevice, NULL, &texCache);
    if (texCache == NULL) {
        // 不 free:exportStab 是 self.stabilizer 的别名,预览还要用
        return [NSError errorWithDomain:@"Gyroflow" code:7 userInfo:@{NSLocalizedDescriptionKey: @"创建 MTLTextureCache 失败"}];
    }

    if (![reader startReading]) {
        CVMetalTextureCacheFlush(texCache, 0); CFRelease(texCache);
        // 不 free:exportStab 是 self.stabilizer 的别名,预览还要用
        return reader.error ?: [NSError errorWithDomain:@"Gyroflow" code:8 userInfo:@{NSLocalizedDescriptionKey: @"reader 启动失败"}];
    }
    if (![writer startWriting]) {
        CVMetalTextureCacheFlush(texCache, 0); CFRelease(texCache);
        // 不 free:exportStab 是 self.stabilizer 的别名,预览还要用
        return writer.error ?: [NSError errorWithDomain:@"Gyroflow" code:9 userInfo:@{NSLocalizedDescriptionKey: @"writer 启动失败"}];
    }
    [writer startSessionAtSourceTime:kCMTimeZero];

    // ===== 音频：回调式异步写入 =====
    // requestMediaDataWhenReadyOnQueue: 让 AVFoundation 在 audio input 能收数据时
    // 主动回调，writer 内部正确交错视频/音频，不会死锁。视频主循环照常跑。
    // audioGroup 用来在 finishWriting 之前等音频写完。
    dispatch_group_t audioGroup = dispatch_group_create();
    if (aReaderOut && aWriterIn && audioReader) {
        if (![audioReader startReading]) {
            NSLog(@"[Export] audioReader 启动失败，导出不带音频: %@", audioReader.error);
            [aWriterIn markAsFinished];
        } else {
            dispatch_group_enter(audioGroup);
            dispatch_queue_t audioQueue = dispatch_queue_create("gyroflow.export.audio", DISPATCH_QUEUE_SERIAL);
            __block NSInteger audioSamples = 0;
            __block BOOL audioDone = NO;
            [aWriterIn requestMediaDataWhenReadyOnQueue:audioQueue usingBlock:^{
                while (aWriterIn.isReadyForMoreMediaData) {
                    CMSampleBufferRef s = [aReaderOut copyNextSampleBuffer];
                    if (s == NULL) {
                        if (!audioDone) {
                            audioDone = YES;
                            [aWriterIn markAsFinished];
                            NSLog(@"[Export] 音频写入完成  samples=%ld", (long)audioSamples);
                            dispatch_group_leave(audioGroup);
                        }
                        return;
                    }
                    if (![aWriterIn appendSampleBuffer:s]) {
                        CFRelease(s);
                        if (!audioDone) {
                            audioDone = YES;
                            NSLog(@"[Export] 音频 append 失败，停止音频  status=%ld", (long)writer.status);
                            dispatch_group_leave(audioGroup);
                        }
                        return;
                    }
                    CFRelease(s);
                    audioSamples++;
                }
            }];
        }
    }

    const CMTime durationTime = asset.duration;
    const double durationSec = CMTimeGetSeconds(durationTime);
    const float fps = vTrack.nominalFrameRate;
    const NSInteger totalFrames = (fps > 0.0f && durationSec > 0.0)
        ? (NSInteger)llround((double)fps * durationSec) : 0;
    __block double lastReportedProgress = 0.0;
    NSInteger frameIdx = 0;

    // ===== 视频帧主循环 =====
    BOOL ok = YES;
    NSError *loopErr = nil;
    NSLog(@"[Export] loop start  totalFrames~%ld  fps=%.3f  duration=%.3fs  [mem=%.0f MB 基线]",
          (long)totalFrames, (double)fps, durationSec, gf_footprint_mb());

    NSDate *loopStart = [NSDate date];
    while ([reader status] == AVAssetReaderStatusReading) {
        if (self.exportCancelled) {
            NSLog(@"[Export] cancelled at frame %ld", (long)frameIdx);
            ok = NO;
            loopErr = [NSError errorWithDomain:@"Gyroflow" code:99
                                      userInfo:@{NSLocalizedDescriptionKey: @"已取消"}];
            break;
        }
        @autoreleasepool {
            NSDate *frameT0 = [NSDate date];

            CMSampleBufferRef sample = [vReaderOut copyNextSampleBuffer];
            if (sample == NULL) {
                NSLog(@"[Export] copyNextSampleBuffer returned NULL after %ld frames, reader.status=%ld",
                      (long)frameIdx, (long)reader.status);
                break;
            }
            NSTimeInterval tAfterRead = -[frameT0 timeIntervalSinceNow];

            CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
            CVPixelBufferRef inPB = CMSampleBufferGetImageBuffer(sample);
            if (inPB == NULL) {
                NSLog(@"[Export] frame %ld got NULL pixel buffer, skipping", (long)frameIdx);
                CFRelease(sample);
                continue;
            }

            // 在 adaptor pool 里拿一个输出 PixelBuffer。
            // 用 AllocationThreshold 限制"在途"缓冲数(默认无上限时, reader 预解码 +
            // writer 编码队列会同时持有几十个 W×H×4 大缓冲, 高分辨率下内存破 1GB)。
            // 池满 → 阻塞等 writer 把已编码缓冲归还再创建(背压), 把峰值内存封顶。
            CVPixelBufferRef outPB = NULL;
            if (adaptor.pixelBufferPool) {
                NSDictionary *poolAux = @{ (NSString *)kCVPixelBufferPoolAllocationThresholdKey: @(3) };
                int poolWait = 0;
                while (CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(NULL, adaptor.pixelBufferPool,
                            (__bridge CFDictionaryRef)poolAux, &outPB) == kCVReturnWouldExceedAllocationThreshold) {
                    if (self.exportCancelled || poolWait++ > 2000) break;  // 取消 / 10s 超时兜底
                    [NSThread sleepForTimeInterval:0.005];
                }
            }
            if (outPB == NULL) {
                NSDictionary *attrs = @{
                    (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                    (NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
                };
                CVPixelBufferCreate(kCFAllocatorDefault, outW, outH,
                                    kCVPixelFormatType_32BGRA,
                                    (__bridge CFDictionaryRef)attrs, &outPB);
                if (frameIdx < 3) NSLog(@"[Export] frame %ld used CVPixelBufferCreate fallback (no pool)", (long)frameIdx);
            }
            if (outPB == NULL) {
                NSLog(@"[Export] frame %ld FAILED to allocate outPB (writer.status=%ld error=%@)",
                      (long)frameIdx, (long)writer.status, writer.error);
                CFRelease(sample);
                ok = NO;
                loopErr = [NSError errorWithDomain:@"Gyroflow" code:10 userInfo:@{NSLocalizedDescriptionKey: @"无法分配输出 PixelBuffer"}];
                break;
            }
            NSTimeInterval tAfterAlloc = -[frameT0 timeIntervalSinceNow];

            // 包装为 MTLTexture
            CVMetalTextureRef inMtRef = NULL, outMtRef = NULL;
            CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, texCache, inPB, NULL,
                                                      MTLPixelFormatBGRA8Unorm,
                                                      CVPixelBufferGetWidth(inPB), CVPixelBufferGetHeight(inPB),
                                                      0, &inMtRef);
            CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, texCache, outPB, NULL,
                                                      MTLPixelFormatBGRA8Unorm,
                                                      outW, outH, 0, &outMtRef);
            id<MTLTexture> inTex = inMtRef ? CVMetalTextureGetTexture(inMtRef) : nil;
            id<MTLTexture> outTex = outMtRef ? CVMetalTextureGetTexture(outMtRef) : nil;
            if (inTex == nil || outTex == nil) {
                NSLog(@"[Export] frame %ld FAILED CVMetalTextureCache wrap inTex=%@ outTex=%@",
                      (long)frameIdx, inTex, outTex);
                if (inMtRef) CFRelease(inMtRef);
                if (outMtRef) CFRelease(outMtRef);
                CVPixelBufferRelease(outPB);
                CFRelease(sample);
                ok = NO;
                loopErr = [NSError errorWithDomain:@"Gyroflow" code:11 userInfo:@{NSLocalizedDescriptionKey: @"创建 Metal 纹理失败"}];
                break;
            }
            NSTimeInterval tAfterTex = -[frameT0 timeIntervalSinceNow];

            // 调用 Gyroflow 防抖
            // 导出用 AVAssetReader 读「精确帧 + 精确 PTS」, 没有 MDK 渲染队列延迟, 必须喂这一帧的
            // 真实内容时间(= pts), 不能减任何偏移。gyroflow_process_frame 的语义是「按 ts 处的姿态
            // 校正这一帧」, ts 必须 == 帧内容时间, 否则用错姿态、去抖去错量 → 残余晃动。
            // 之前减 kPreviewLatencyUs 是为「对齐预览所见」, 但那把预览(MDK)的错位也带进了成片。
            // 对齐安卓(喂精确 pts、不减偏移)。
            int64_t ts_us = (int64_t)llround(CMTimeGetSeconds(pts) * 1.0e6);
            GyroflowProcessInfo gfInfo = {0};
            // 稳定渲染进「夹后尺寸」纹理(取景固定); 需放大时是 stabTex, 否则直接 outTex。
            id<MTLTexture> renderTex = needUpscale ? stabTex : outTex;
            int32_t rc = gyroflow_process_frame_metal_bgra8(
                exportStab,
                ts_us, -1,
                (__bridge void *)inTex,
                inTex.width, inTex.height,
                (__bridge void *)renderTex,
                renderTex.width, renderTex.height,
                (__bridge void *)self.commandQueue,
                &gfInfo);
            NSTimeInterval tAfterFFI = -[frameT0 timeIntervalSinceNow];

            // 放大: 夹后稳定纹理 → 目标尺寸 outTex(全屏三角形 + linear 采样, 与 Android GPU Linear 一致)
            if (rc == 0 && needUpscale && upPipeline) {
                MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
                rp.colorAttachments[0].texture = outTex;
                rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
                rp.colorAttachments[0].storeAction = MTLStoreActionStore;
                id<MTLCommandBuffer> ucb = [self.commandQueue commandBuffer];
                id<MTLRenderCommandEncoder> enc = [ucb renderCommandEncoderWithDescriptor:rp];
                [enc setRenderPipelineState:upPipeline];
                [enc setFragmentTexture:stabTex atIndex:0];
                [enc setFragmentSamplerState:upSampler atIndex:0];
                [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                [enc endEncoding];
                [ucb commit];
                [ucb waitUntilCompleted];
            }

            CFRelease(inMtRef);
            CFRelease(outMtRef);

            // [诊断] 看前几帧 + 中间帧的 raw/smoothed 姿态: raw 应逐帧变化, smoothed≠raw 表示有逐帧修正。
            if (frameIdx < 3 || frameIdx == 500) {
                double q8[8] = {1,0,0,0, 1,0,0,0};
                gyroflow_quats_at_timestamp(exportStab, ts_us, q8);
                NSLog(@"[Export][diag] f%ld ts=%.3fs raw=(%.4f,%.4f,%.4f,%.4f) sm=(%.4f,%.4f,%.4f,%.4f) fov=%.4f",
                      (long)frameIdx, ts_us/1.0e6,
                      q8[0],q8[1],q8[2],q8[3], q8[4],q8[5],q8[6],q8[7], gfInfo.fov);
            }

            if (rc != 0) {
                NSLog(@"[Export] frame %ld FFI rc=%d err=%s", (long)frameIdx, rc, gyroflow_last_error());
                CVPixelBufferRelease(outPB);
                CFRelease(sample);
                ok = NO;
                loopErr = [NSError errorWithDomain:@"Gyroflow" code:12
                                          userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"防抖渲染失败：%s", gyroflow_last_error()]}];
                break;
            }

            // CPU bridge 路径下 FFI 内部已 waitUntilCompleted 完成输出 blit，
            // 这里不再加 redundant 的 barrier。

            // 等 writer 准备好接受 — 用循环但每 5ms 打一次 sleep 计数
            int waitTicks = 0;
            while (!vWriterIn.isReadyForMoreMediaData) {
                if (waitTicks % 200 == 0) {
                    NSLog(@"[Export] frame %ld waiting on writer.isReadyForMoreMediaData "
                          @"(writer.status=%ld error=%@)",
                          (long)frameIdx, (long)writer.status, writer.error);
                }
                [NSThread sleepForTimeInterval:0.005];
                waitTicks++;
                if (waitTicks > 2000) { // 10s waited -> bail with diagnostic
                    NSLog(@"[Export] frame %ld writer NEVER became ready in 10s, aborting. "
                          @"writer.status=%ld error=%@",
                          (long)frameIdx, (long)writer.status, writer.error);
                    ok = NO;
                    loopErr = writer.error ?: [NSError errorWithDomain:@"Gyroflow" code:14 userInfo:@{NSLocalizedDescriptionKey: @"writer 长时间不接收"}];
                    break;
                }
            }
            if (!ok) {
                CVPixelBufferRelease(outPB);
                CFRelease(sample);
                break;
            }
            NSTimeInterval tAfterWait = -[frameT0 timeIntervalSinceNow];

            BOOL appendOk = [adaptor appendPixelBuffer:outPB withPresentationTime:pts];
            NSTimeInterval tAfterAppend = -[frameT0 timeIntervalSinceNow];
            if (!appendOk) {
                NSLog(@"[Export] frame %ld appendPixelBuffer FAILED writer.status=%ld error=%@",
                      (long)frameIdx, (long)writer.status, writer.error);
                CVPixelBufferRelease(outPB);
                CFRelease(sample);
                ok = NO;
                loopErr = writer.error ?: [NSError errorWithDomain:@"Gyroflow" code:15 userInfo:@{NSLocalizedDescriptionKey: @"appendPixelBuffer 失败"}];
                break;
            }

            CVPixelBufferRelease(outPB);
            CFRelease(sample);

            // 关键: 每帧 flush Metal 纹理缓存。否则 cache 会一直持有每帧 in/out 纹理
            // 绑定的 IOSurface(各 ~W×H×4), 整段导出累积到 1GB+。FFI 内部已 waitUntilCompleted,
            // 此处 GPU 已用完这两个纹理, flush 安全。
            CVMetalTextureCacheFlush(texCache, 0);

            // 进度
            frameIdx++;
            if (durationSec > 0.0) {
                double p = CMTimeGetSeconds(pts) / durationSec;
                if (p - lastReportedProgress > 0.01) {
                    lastReportedProgress = p;
                    if (progressBlock) progressBlock(MIN(p, 0.99), frameIdx, totalFrames);
                }
            }

            // 每帧时序日志（前 5 帧每帧打印；之后每 10 帧打印一次摘要）
            BOOL shouldLog = (frameIdx <= 5) || (frameIdx % 10 == 0);
            if (shouldLog) {
                NSTimeInterval elapsedTotal = -[loopStart timeIntervalSinceNow];
                double avgPerFrame = (frameIdx > 0) ? (elapsedTotal / (double)frameIdx) : 0.0;
                NSLog(@"[Export] frame %ld/%ld  read=%.0fms alloc=%.0fms tex=%.0fms FFI=%.0fms wait=%.0fms append=%.0fms"
                      @"  | total=%.2fs avg=%.0fms/frame  ETA=%.1fs  mem=%.0fMB",
                      (long)frameIdx, (long)totalFrames,
                      tAfterRead*1000, (tAfterAlloc-tAfterRead)*1000, (tAfterTex-tAfterAlloc)*1000,
                      (tAfterFFI-tAfterTex)*1000, (tAfterWait-tAfterFFI)*1000, (tAfterAppend-tAfterWait)*1000,
                      elapsedTotal, avgPerFrame*1000,
                      avgPerFrame * MAX(0.0, (double)(totalFrames - frameIdx)),
                      gf_footprint_mb());
            }
        }
    }
    NSLog(@"[Export] video loop ended  ok=%d frames=%ld reader.status=%ld writer.status=%ld",
          ok, (long)frameIdx, (long)reader.status, (long)writer.status);
    [vWriterIn markAsFinished];

    CVMetalTextureCacheFlush(texCache, 0);
    CFRelease(texCache);
    // 不 free:exportStab 是 self.stabilizer 的别名,预览还要用

    if (!ok) {
        NSLog(@"[Export] aborting (ok=NO)  err=%@", loopErr);
        [reader cancelReading];
        // 让音频回调尽快收尾（reader 取消后 copyNextSampleBuffer 返回 NULL）
        [audioReader cancelReading];
        dispatch_group_wait(audioGroup, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        [writer cancelWriting];
        return loopErr ?: [NSError errorWithDomain:@"Gyroflow" code:13 userInfo:@{NSLocalizedDescriptionKey: @"导出过程中断"}];
    }

    // 等音频回调写完才能 finishWriting —— 音频在自己的 queue 上异步写，
    // aReaderOut 耗尽后会 markAsFinished 并 leave audioGroup。
    NSLog(@"[Export] 视频写完，等待音频写入完成...");
    dispatch_group_wait(audioGroup, DISPATCH_TIME_FOREVER);

    // 等待 writer flush
    NSLog(@"[Export] calling writer.finishWriting...");
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{
        NSLog(@"[Export] writer.finishWriting completed  status=%ld error=%@",
              (long)writer.status, writer.error);
        dispatch_semaphore_signal(done);
    }];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);

    if (writer.status != AVAssetWriterStatusCompleted) {
        NSLog(@"[Export] writer status != Completed, returning error");
        return writer.error ?: [NSError errorWithDomain:@"Gyroflow" code:14 userInfo:@{NSLocalizedDescriptionKey: @"writer 未完成"}];
    }

    if (progressBlock) progressBlock(1.0, frameIdx, totalFrames > 0 ? totalFrames : frameIdx);
    return nil;
}

#pragma mark - 键盘弹出时把输入框滚到可见区

- (void)keyboardWillShow:(NSNotification *)note {
    CGRect kbFrame = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect kbFrameInView = [self.view convertRect:kbFrame fromView:nil];
    CGFloat kbTopInView = CGRectGetMinY(kbFrameInView);

    UIView *focused = [GFViewKit firstResponderIn:self.view];
    if (focused == nil) return;
    CGRect focusedInView = [focused.superview convertRect:focused.frame toView:self.view];

    CGFloat shift;
    if ([focused.accessibilityIdentifier isEqualToString:@"lensSearch"]) {
        // 镜头搜索框：底部需要留 220pt 给结果列表 + 打开文件/创建新的按钮
        const CGFloat resultsSpace = 220.0;
        CGFloat targetBottom = kbTopInView - resultsSpace;
        shift = MAX(0.0, CGRectGetMaxY(focusedInView) - targetBottom);
    } else {
        // 普通输入框（运动数据 Hz / samples / Pitch 等）：把底边推到键盘上方 12pt 即可
        shift = MAX(0.0, CGRectGetMaxY(focusedInView) - (kbTopInView - 12.0));
    }
    if (shift <= 0.0) return;

    NSNumber *duration = note.userInfo[UIKeyboardAnimationDurationUserInfoKey];
    NSNumber *curve    = note.userInfo[UIKeyboardAnimationCurveUserInfoKey];
    [UIView animateWithDuration:duration.doubleValue
                          delay:0
                        options:(curve.unsignedIntegerValue << 16)
                     animations:^{
        // 只 transform 内容栈 mainStack —— self.view 仍然在原位作为黑色底面，
        // 不会露出窗口背景的纯黑空白（之前 view.transform 的问题）。
        self.mainStack.transform = CGAffineTransformMakeTranslation(0, -shift);
    } completion:nil];
}

- (void)keyboardWillHide:(NSNotification *)note {
    NSNumber *duration = note.userInfo[UIKeyboardAnimationDurationUserInfoKey];
    NSNumber *curve    = note.userInfo[UIKeyboardAnimationCurveUserInfoKey];
    [UIView animateWithDuration:duration.doubleValue
                          delay:0
                        options:(curve.unsignedIntegerValue << 16)
                     animations:^{
        self.mainStack.transform = CGAffineTransformIdentity;
    } completion:nil];
}

// 点击空白处收键盘
- (void)dismissKeyboardOnBackgroundTap {
    [self.view endEditing:YES];
}

// 视频未加载/解析中 → 所有 section 整体不可点 + alpha 0.5;视频 ready → 解锁。
// (按用户要求:视频文件为空时不能操作界面上的按钮)
- (void)setAllSectionsEnabled:(BOOL)enabled {
    UIView *sections[4] = {
        self.syncSection,
        self.stabilizeSection,
        self.advancedSection,
        self.exportSection,
    };
    for (int i = 0; i < 4; i++) {
        UIView *s = sections[i];
        if (s == nil) continue;
        s.userInteractionEnabled = enabled;
        s.alpha = enabled ? 1.0 : 0.5;
    }
}

#pragma mark - 安全区域 overlay

- (void)updateSafeAreaOverlay {
    // 安全区域指示已改为由 gyroflow 渲染 kernel(metal_undistort.metal:draw_safe_area)
    // 按真实 safe_area_rect 压暗框外, 对齐官方。原来 iOS 自画的橙色描边框(固定 90%
    // 近似、且和 shader 重复)已去掉, 这里恒隐藏。
    self.safeAreaLayer.hidden = YES;
}

#pragma mark - AdvancedSectionViewDelegate

- (void)advancedSectionRequestsColorPicker:(UIColor *)current
                                completion:(void(^)(UIColor *picked))completion {
    if (@available(iOS 14.0, *)) {
        UIColorPickerViewController *picker = [[UIColorPickerViewController alloc] init];
        picker.selectedColor = current ?: UIColor.blackColor;
        picker.supportsAlpha = YES;
        picker.delegate = self;
        self.pendingColorCompletion = completion;
        [self presentViewController:picker animated:YES completion:nil];
    } else {
        if (completion) completion(current);
    }
}

#pragma mark - UIColorPickerViewControllerDelegate

- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)viewController API_AVAILABLE(ios(14.0)) {
    if (self.pendingColorCompletion) self.pendingColorCompletion(viewController.selectedColor);
    self.pendingColorCompletion = nil;
}

#pragma mark - Phase β:自动同步

/// 在 stabilizer/video 都就绪后,把 SyncSectionView 的 onAutosyncTapped 接好。
/// loadGyroflowForURL 完成时调一次。
- (void)wireAutosyncHandler {
    __weak typeof(self) weakSelf = self;
    self.syncSection.onAutosyncTapped = ^(BOOL turningOn) {
        __strong typeof(weakSelf) sSelf = weakSelf;
        if (!sSelf) return;
        if (turningOn) {
            [sSelf startAutosync];
        } else {
            [sSelf cancelAutosync];
        }
    };
}

- (void)startAutosync {
    NSLog(@"[Autosync] startAutosync ENTRY  runner=%p  stab=%p  gfReady=%d  url=%@",
          self.autosyncRunner, self.stabilizer, (int)self.gyroflowReady, self.securityScopedURL.lastPathComponent);
    int32_t hasMotion = self.stabilizer ? gyroflow_has_motion_data(self.stabilizer) : -99;
    int32_t hasLens   = self.stabilizer ? gyroflow_has_lens_profile(self.stabilizer) : -99;
    NSLog(@"[Autosync] preconditions  has_motion_data=%d (0=有数据)  has_lens_profile=%d (0=有镜头)",
          hasMotion, hasLens);
    if (self.autosyncRunner != nil) {
        NSLog(@"[Autosync] BAIL: runner already exists");
        return;
    }
    if (self.stabilizer == NULL || !self.gyroflowReady) {
        NSLog(@"[Autosync] BAIL: stab/gfReady not ready");
        [self.syncSection setAutosyncRunning:NO];
        [self showAutosyncAlert:@"还没准备好" message:@"视频或陀螺数据没加载完。"];
        return;
    }
    if (self.securityScopedURL == nil) {
        NSLog(@"[Autosync] BAIL: no video URL");
        [self.syncSection setAutosyncRunning:NO];
        [self showAutosyncAlert:@"没有视频" message:@"先选择一个视频文件。"];
        return;
    }
    // 没 lens profile 不能跑 auto-sync —— Rust 侧 pose_estimator 在做姿态估计时
    // 依赖 lens.distortion_model 把图像点反畸变,distortion_model=None 会在
    // .unwrap()/数学库里直接 panic(rayon worker 里炸,iOS 上表现成进程崩溃,
    // 我们拿不到 panic message)。官方桌面 UX 同样要求先选镜头再做同步,
    // 这是合理硬约束。
    if (gyroflow_has_lens_profile(self.stabilizer) != 0) {
        NSLog(@"[Autosync] BAIL: no lens profile — showing alert");
        [self.syncSection setAutosyncRunning:NO];
        [self showAutosyncAlert:@"需要先上传镜头档案"
                        message:@"自动同步需要镜头矫正信息(否则无法把视频点反畸变去做姿态估计)。\n请先点「上传镜头档案」选一个 .json 镜头文件,再回来点自动同步。"];
        return;
    }
    NSLog(@"[Autosync] preconditions OK, building runner");
    // 没 IMU 时走视觉模式 —— gyroflow autosync.rs:69-73 + 200-215 会用整段视频做光流估姿。
    // 关键:必须用纯 Rust 的 pose 算法(Almeida pose_method=1 或 EightPoint pose_method=2),
    // findEssentialMat(0)和 findHomography(3)需要 OpenCV,我们 iOS .a 没编 use-opencv 会死。
    // ParamsModel 默认 pose_method=1(Almeida)就是为这个改的。
    const BOOL visualOnly = (gyroflow_has_motion_data(self.stabilizer) != 0);

    // 暂停播放(MDK 不要在这期间消耗 CPU,且 stabilizer 会被 autosync 改 gyro offsets,
    // 此时渲染读 stab_data 可能拿到不一致的中间态)
    if (!self.videoPaused) {
        _mdkPlayer->set(mdk::PlaybackState::Paused);
        self.videoPaused = YES;
        [self.playPauseButton setTitle:@"播放" forState:UIControlStateNormal];
    }

    // 用 paramsModel 当前值构造 Runner
    AutosyncRunner *runner = [[AutosyncRunner alloc] initWithVideoURL:self.securityScopedURL
                                                           stabilizer:self.stabilizer];
    runner.initialOffsetMs             = self.paramsModel.gyroOffsetMs;
    runner.searchSizeSec               = self.paramsModel.syncSearchSizeSec;
    runner.maxSyncPoints               = (uint32_t)self.paramsModel.maxSyncPoints;
    runner.everyNthFrame               = (uint32_t)self.paramsModel.everyNthFrame;
    runner.timePerSyncpointSec         = self.paramsModel.timePerSyncpointSec;
    runner.ofMethod                    = (uint32_t)self.paramsModel.ofMethod;
    runner.poseMethod                  = (uint32_t)self.paramsModel.poseMethod;
    runner.offsetMethod                = (uint32_t)self.paramsModel.offsetMethod;
    // 官方 Synchronization.qml 三个开关：calc_initial_fast 在搜索 > 10s 时自动启用
    runner.calcInitialFast             = self.paramsModel.calcInitialFast || (self.paramsModel.syncSearchSizeSec > 10.0);
    runner.checkNegativeInitialOffset  = self.paramsModel.checkNegativeInitialOffset;
    runner.autoSyncPointsExperimental  = self.paramsModel.autoSyncPointsExperimental;
    NSLog(@"[Autosync] params: initialOffsetMs=%.1f searchSize=%.2fs maxPts=%d everyN=%d perPoint=%.2fs of=%d pose=%d offset=%d calcFast=%d negInv=%d autoPts=%d",
          runner.initialOffsetMs, runner.searchSizeSec, runner.maxSyncPoints,
          runner.everyNthFrame, runner.timePerSyncpointSec,
          runner.ofMethod, runner.poseMethod, runner.offsetMethod,
          runner.calcInitialFast, runner.checkNegativeInitialOffset, runner.autoSyncPointsExperimental);

    __weak typeof(self) weakSelf = self;
    runner.onProgress = ^(double progress, int fed, int total) {
        [weakSelf.syncSection updateAutosyncProgress:progress framesFed:fed framesTotal:total];
        // 同时更新视频上的分析浮窗
        double fps = (double)weakSelf.videoInfo.fps;
        [weakSelf.syncOverlay updateProgress:progress framesFed:fed framesTotal:total fps:fps];
    };
    runner.onFinished = ^(double offsetMs, NSArray<NSDictionary<NSString *, NSNumber *> *> *syncPoints) {
        __strong typeof(weakSelf) sSelf = weakSelf;
        if (!sSelf) return;
        // 偏移已由 FFI autosync_finish **逐点写入 gyro.offsets**(对齐安卓 stab.rs:661-683 /
        // 官方 controller.rs:423-447), 这里不再回写「大致偏移」框 —— 该框是同步搜索起点参数
        // (官方 initialOffset 语义), 同步完保持用户输入(默认 0), 三端显示一致。
        // 历史: 曾经"仅显示不应用"(Hero6 无防抖根因)→ "A 方案全局单点应用+回显框"(与官方
        // 显示不一致)→ 现在与官方/安卓同构。
        NSLog(@"[Autosync] 完成 中位 offset=%+.3f 秒  syncPoints=%lu(已在 FFI 内逐点应用)",
              offsetMs / 1000.0, (unsigned long)syncPoints.count);
        for (NSUInteger i = 0; i < syncPoints.count; i++) {
            NSDictionary *p = syncPoints[i];
            NSLog(@"  [%lu] midpoint=%.3fms  offset=%.3fms",
                  (unsigned long)i, [p[@"midpointMs"] doubleValue], [p[@"offsetMs"] doubleValue]);
        }
        // 把 syncPoints 喂给底部时间线视图,画 5 条竖线 + 数字
        [sSelf.gyroTimelineView setSyncPoints:syncPoints];
        sSelf.syncPointCount = (NSInteger)syncPoints.count;  // 导出时判断是否提示无同步点
        [sSelf.syncSection setHasSyncPoints:(syncPoints.count > 0)]; // 有同步点 → usesQuats 时才弹提示(对齐官方)
        // 触发一次 recompute(应用新偏移重新平滑)
        [sSelf.paramsModel scheduleRecompute];
        // 视觉模式时,autosync 跑完会把光流估出的 raw_imu 写回 stabilizer。
        // 重新拉一次 gyro timeline,让波形显示出来(之前是空的)。
        // 真 IMU 模式下也重新拉一次没坏处(只是 offsets 应用后波形会稍微平移)。
        BOOL gyroOK = [sSelf.gyroModel loadFromStabilizer:sSelf.stabilizer sampleCount:600];
        sSelf.gyroTimelineView.model = sSelf.gyroModel;
        NSLog(@"[Autosync] onFinished gyro reload  ok=%d  samples=%ld  maxAbs=%.1f°/s",
              gyroOK, (long)sSelf.gyroModel.sampleCount, sSelf.gyroModel.maxAbsValue);
        [sSelf.syncSection setAutosyncRunning:NO];
        sSelf.autosyncRunner = nil;
        sSelf.analysisMask.hidden = YES;
        [sSelf.syncOverlay hide];  // 关闭分析浮窗 + 蒙版
        // 不自动播放, 不弹偏移量 alert (按用户要求)
    };
    runner.onFailed = ^(NSString *reason) {
        __strong typeof(weakSelf) sSelf = weakSelf;
        if (!sSelf) return;
        [sSelf.syncSection setAutosyncRunning:NO];
        sSelf.autosyncRunner = nil;
        sSelf.analysisMask.hidden = YES;
        [sSelf.syncOverlay hide];  // 关闭分析浮窗 + 蒙版
        // 失败也不自动播放(原本会恢复 autosync 前的播放态),只 log
        NSLog(@"[Autosync] failed: %@", reason);
    };

    self.autosyncRunner = runner;
    [self.syncSection setAutosyncRunning:YES];
    // 显示「分析中」浮窗 + 接通取消按钮(点取消调 cancelAutosync)
    __weak typeof(self) weakSelf2 = self;
    self.analysisMask.hidden = NO;
    [self.syncOverlay showWithTitle:@"分析中" onCancel:^{
        [weakSelf2 cancelAutosync];
    }];
    [runner start];
}

- (void)cancelAutosync {
    if (self.autosyncRunner == nil) {
        [self.syncSection setAutosyncRunning:NO];
        return;
    }
    [self.autosyncRunner cancel];
    // 实际清理在 runner.onFailed 里
}

- (void)showAutosyncAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                               message:message
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark - 左上角播放状态 overlay (时间 / 帧号 / 缩放%)

- (void)updatePlayInfoLabelAtTime:(double)timeSec {
    if (self.playInfoLabel == nil) {
        return;
    }
    double durSec = self.videoInfo.duration_s;
    double fps = self.videoInfo.fps;
    // 时间 mm:ss / mm:ss
    NSString *curT = [GFViewKit formatTimeMmSs:timeSec];
    NSString *totT = (durSec > 0.0) ? [GFViewKit formatTimeMmSs:durSec] : @"--:--";
    // 帧号 current / total
    NSString *curF = (fps > 0.0) ? [NSString stringWithFormat:@"%lld", (long long)llround(timeSec * fps) + 1] : @"--";
    NSString *totF = (fps > 0.0 && durSec > 0.0) ? [NSString stringWithFormat:@"%lld", (long long)llround(durSec * fps)] : @"--";
    // 缩放 % = 100 / 当前帧 fov (= processInfo.fov, 每帧 process_frame 后赋值).
    // 跟桌面 UI 时间轴旁那个跟随帧变化的"缩放: XX.XX%"对齐。
    // 防抖关 / 还没渲染过任何帧时 currentFrameFov=0, fallback 到 paramsModel.minFov (= 全局 max zoom)。
    NSString *zoomStr;
    if (self.currentFrameFov > 0.0001) {
        zoomStr = [NSString stringWithFormat:@"%.2f%%", 100.0 / self.currentFrameFov];
    } else if (self.paramsModel != nil && self.paramsModel.minFov > 0.0001) {
        zoomStr = [NSString stringWithFormat:@"%.2f%%", 100.0 / self.paramsModel.minFov];
    } else {
        zoomStr = @"--%";
    }
    self.playInfoLabel.text = [NSString stringWithFormat:
        @" 时间 %@ / %@\n 帧 %@/%@\n 缩放 %@ ",
        curT, totT, curF, totF, zoomStr];
}

@end
