package com.runcam.runcam

import android.content.Context
import android.view.Surface

/**
 * 安卓侧 gyroflow 原生入口。
 * 通过 JNI 调进 libruncam_gyroflow.so(桥) -> gyroflow_core 的 Rust 核心(不经 C FFI)。
 * gyroflow 源码不改。
 */
object GyroflowNative {
    init {
        System.loadLibrary("runcam_gyroflow")
    }

    /**
     * 初始化 ndk_context(对齐上游 set_android_context)。
     * 必须在调用任何其它原生方法之前调用一次,传 applicationContext。
     */
    external fun nativeInit(context: Context)

    /** smoke: 直接构造 Rust 核心并读默认参数,返回状态串。能返回即链路通。 */
    external fun nativeSmoke(): String?

    // —— 阶段 2a: GPU 预览(wgpu→SurfaceView) ——
    /** SurfaceView 就绪: 建 wgpu 设备并渲染。返回状态串(成功/错误)。 */
    external fun nativePreviewSurfaceCreated(surface: Surface, width: Int, height: Int): String?

    /** SurfaceView 销毁: 释放 wgpu 资源。 */
    external fun nativePreviewSurfaceDestroyed()

    // —— 阶段 2c: 载入视频(+内嵌陀螺+自动镜头) / 逐帧去畸变+稳定后显示 ——
    /** 载入 content:// 视频, 配置稳定参数并预计算。返回状态串(尺寸/帧率/gyro/lens)。 */
    external fun nativeOpenVideo(uri: String): String?
    /** 处理一帧 YUV(紧凑三平面) → 稳定 → 显示。timestampUs 为帧时间戳(微秒)。 */
    external fun nativeProcessFrame(y: ByteArray, u: ByteArray, v: ByteArray, width: Int, height: Int, timestampUs: Long): String?

    /** 调整陀螺/视频时间偏移(毫秒), 用于消除残留晃动。 */
    external fun nativeSetGyroOffset(offsetMs: Double): String?

    /** 开/关防抖(对齐 iOS 的"开启/关闭防抖")。 */
    external fun nativeSetStabEnabled(enabled: Boolean): String?

    // —— 稳定参数(对齐官方 Stabilization 面板)——
    /** 平滑算法: 0=无 1=默认 2=Plain 3=Fixed。 */
    external fun nativeSetSmoothingMethod(index: Int): Int
    /** 平滑参数: smoothness/per_axis/trim_range_only/max_smoothness/alpha_0_1s/smoothness_pitch|yaw|roll。 */
    external fun nativeSetSmoothingParam(name: String, value: Double): Int
    /**
     * 锁定地平线(全 9 参,对齐 iOS gyroflow_set_horizon_lock):amount %(0=关)、roll 校正°、
     * 锁定俯仰 + pitch°、自动锁定 + 转向阈值 / 转向平滑 ms / 转向倍数 / 倾斜加速限制。
     */
    external fun nativeSetHorizonLock(
        amount: Double,
        roll: Double,
        lockPitch: Boolean,
        pitch: Double,
        automatic: Boolean,
        turnThreshold: Double,
        turnSmoothing: Double,
        turnMultiplier: Double,
        tiltAccelLimit: Double,
    ): Int
    /** 缩放速度(自适应缩放窗口, 秒)。 */
    external fun nativeSetAdaptiveZoom(window: Double): Int
    /** 缩放限额(%)+ 迭代次数。 */
    external fun nativeSetMaxZoom(percent: Double, iters: Int): Int
    /** 缩放方式(adaptive_zoom_method)。 */
    external fun nativeSetZoomingMethod(index: Int): Int
    /** 镜头校正(0.0–1.0)。 */
    external fun nativeSetLensCorrection(amount: Double): Int
    /** 视场角 FOV。 */
    external fun nativeSetFov(fov: Double): Int
    /** 卷帘快门 帧读出时间(毫秒, 0=关)。 */
    external fun nativeSetFrameReadoutTime(ms: Double): Int
    /** 卷帘快门 帧读出方向(0=上到下 1=下到上 2=左到右 3=右到左, 对齐官方 ReadoutDirection)。 */
    external fun nativeSetFrameReadoutDirection(dir: Int): Int
    /** 视频速度(%)+ 三联动(平滑/缩放/缩放限额)。 */
    external fun nativeSetVideoSpeed(speed: Double, linkSmooth: Boolean, linkZoom: Boolean, linkZoomLimit: Boolean): Int
    /** 附加 3D 旋转(度): pitch/yaw/roll。 */
    external fun nativeSetAdditionalRotation(pitch: Double, yaw: Double, roll: Double): Int
    /** 稳定信息: [maxPitch°, maxYaw°, maxRoll°, 最大缩放%]。 */
    external fun nativeGetStabInfo(): DoubleArray?

    /** 当前帧 fov(对齐桌面 controller.current_fov)。左上角 HUD 用 zoom% = 100/fov。0=还没渲染过帧。 */
    external fun nativeGetCurrentFov(): Double

    /** 取当前已加载镜头信息(基础 + 高级: 相机矩阵/畸变系数等), 返回 JSON。 */
    external fun nativeGetLensInfo(): String?

    /** 取镜头档案携带的同步参数 sync_settings(search_size/max_sync_points/time_per_syncpoint 等), JSON; 无则 "{}"。 */
    external fun nativeGetSyncSettings(): String?

    /** 水下镜头开关(调整折射系数并重算)。 */
    external fun nativeSetUnderwater(on: Boolean): String?

    /** 显示/隐藏检测到的特征点覆盖层(对齐官方 show_detected_features)。 */
    external fun nativeSetShowDetectedFeatures(show: Boolean): Int

    /** 显示/隐藏光流覆盖层(对齐官方 show_optical_flow)。 */
    external fun nativeSetShowOpticalFlow(show: Boolean): Int

    // —— 高级模块(对齐桌面 Advanced.qml)——
    /** 渲染背景颜色(RGBA, 各通道 0–1)。 */
    external fun nativeSetBackgroundColor(r: Double, g: Double, b: Double, a: Double): Int
    /** 背景填充模式(0=纯色 1=边缘拉伸 2=边缘镜像 3=羽化留边)。 */
    external fun nativeSetBackgroundMode(mode: Int): Int
    /** 羽化留边: 留边宽度(占比 0.0–0.5)。 */
    external fun nativeSetBackgroundMargin(margin: Double): Int
    /** 羽化留边: 羽化宽度(占比 0.0–0.5)。 */
    external fun nativeSetBackgroundMarginFeather(feather: Double): Int
    /** 安全区域指示开关(FOV=1 矩形, 仅视觉提示)。 */
    external fun nativeSetShowSafeArea(show: Boolean): Int
    /** 预览分辨率(目标高度: -1=原始, 否则 2160/1080/720/480)。 */
    external fun nativeSetPreviewResolution(targetHeight: Int): Int

    // —— 导出(逐帧 readback → MediaCodec 编码)——
    /** 设输出尺寸(预览用: W×H 当目标比例缩放到源内)。 */
    external fun nativeSetOutputSize(width: Int, height: Int): Int
    /** 设精确输出尺寸(按 W×H 精确设, 可上采样)。 */
    external fun nativeSetOutputSizeExact(width: Int, height: Int): Int
    /** 导出目标分辨率: 回读时把稳定输出(夹后, 取景固定)放大到此分辨率。0=关闭。 */
    external fun nativeSetExportTarget(width: Int, height: Int): Int
    /** 当前实际输出尺寸 [w, h](经缩放后的真实值)。 */
    external fun nativeGetOutputSize(): IntArray
    /** 导出模式: 开启后逐帧只渲染输出供回读, 不上屏(预览不随导出"动" + 更快)。 */
    external fun nativeSetExportMode(on: Boolean): Int
    /**
     * 导出逐帧(流水线/双缓冲):输入本帧紧凑 YUV → 稳定 → 提交本帧回读,**返回上一帧**的 I420
     * (首帧返回空数组)。把回读的同步等待藏到下一帧,显著提速。收尾用 nativeRenderFlushI420 取最后一帧。
     */
    external fun nativeRenderFrameI420(y: ByteArray, u: ByteArray, v: ByteArray, width: Int, height: Int, timestampUs: Long): ByteArray
    /** 导出收尾:排空流水线滞留的最后一帧 I420(无则空数组)。 */
    external fun nativeRenderFlushI420(): ByteArray

    /** 编辑相机矩阵/畸变系数(param ∈ fx,fy,cx,cy,k1..k4)并重算。 */
    external fun nativeSetLensParam(param: String, value: Double): String?

    /** 搜索内置镜头库, 返回 JSON 数组 [{"name","id"}]。 */
    external fun nativeLensSearch(query: String): String?

    /** 当前已加载镜头库版本号(对应 gyroflow/lens_profiles 的 release 号)。 */
    external fun nativeGetLensDbVersion(): Int

    /** 安装下载的 profiles.cbor.gz 字节并热重载镜头库, 返回新版本号; 失败 -1。 */
    external fun nativeInstallLensProfiles(data: ByteArray): Int

    /** 加载镜头配置文件(content:// 或路径 或 内置 id)。 */
    external fun nativeLoadLens(uri: String): String?

    /**
     * 加载陀螺/运动数据文件(.gcsv 等, content:// 或路径)。
     * loadAllMetadata 对齐官方「Load all metadata」勾选框(默认 false):
     * false=只取陀螺流; true=按主视频完整解析(镜头档案/fps/卷帘)。
     */
    external fun nativeLoadGyro(uri: String, loadAllMetadata: Boolean): String?

    /** 整帧粒度的视频/陀螺对齐偏移(帧, 可负, 默认 0)。对齐官方「Frame offset」。 */
    external fun nativeSetFrameOffset(frames: Int): String?

    /**
     * 注册已获 SAF 授权的目录(tree URI)到 gyroflow 文件系统白名单。
     * content:// 单文件视频的同名 sidecar 自动检测只有在其所在目录被授权+注册后才能生效
     * (授权后需重载视频)。真实文件路径无需注册。
     */
    external fun nativeFolderAccessGranted(url: String): String?

    // —— 运动数据(对齐 iOS MotionData) ——
    /** 运动数据信息 JSON: format/has_quaternions/has_raw_gyro/imu_orientation/integration_method/lpf/median/rotation/bias。 */
    external fun nativeGetGyroInfo(): String?

    /** 视频内嵌丰富元数据 JSON: {camera, additional_data{recording_settings, camera_identifier, sample_rate,...}}(对齐官方视频信息)。 */
    external fun nativeGetVideoMetadata(): String?

    /** 低通滤波(Hz, 0=关)。 */
    external fun nativeSetImuLpf(hz: Double): String?

    /** 中值滤波(采样数, 0=关)。 */
    external fun nativeSetImuMedian(samples: Int): String?

    /** IMU 旋转(Pitch/Roll/Yaw 度, 全 0=关)。 */
    external fun nativeSetImuRotation(pitch: Double, roll: Double, yaw: Double): String?

    /** 陀螺零偏(X/Y/Z 度/秒, 全 0=关)。 */
    external fun nativeSetImuBias(bx: Double, by: Double, bz: Double): String?

    /** IMU 朝向(如 "XYZ"/"zYX")。 */
    external fun nativeSetImuOrientation(orientation: String): String?

    /** 积分方法索引(0=None…6=Madgwick)。 */
    external fun nativeSetIntegrationMethod(index: Int): String?

    /** 某时间戳的原始/平滑四元数, double[8] = [q.w,q.i,q.j,q.k, sq.w,sq.i,sq.j,sq.k]。 */
    external fun nativeQuatsAtTimestamp(timestampUs: Long): DoubleArray?

    /** 陀螺时间轴: 整段重采样成 count 个三轴角速度点, double[count*3] 交错 xyz(°/s)。空=无数据。 */
    external fun nativeGyroTimeline(count: Int): DoubleArray?

    /** 四元数时间轴: 整段重采样成 count 个点, double[count*4] 交错 xyzw。
     *  用于 DJI/Xtra 等无原始角速度的源(nativeGyroTimeline 返空时改调本函数)。空=无数据。 */
    external fun nativeQuaternionTimeline(count: Int): DoubleArray?

    // —— 自动同步(对齐官方 Synchronization, Akaze 光流, 不需 OpenCV) ——
    /** 创建同步 session, 返回各同步点范围 double[](交错 from_ms,to_ms)。空=失败。 */
    external fun nativeAutosyncStart(
        initialOffsetMs: Double,
        searchSizeSec: Double,
        maxSyncPoints: Int,
        everyNthFrame: Int,
        timePerSyncpointSec: Double,
        ofMethod: Int,
        poseMethod: Int,
        offsetMethod: Int,
        calcInitialFast: Boolean,
        initialOffsetInv: Boolean,
        autoSyncPoints: Boolean,
        syncLpf: Double,
    ): DoubleArray?

    /** 喂一帧灰度(Y 平面紧凑, stride=width)。 */
    external fun nativeAutosyncFeed(timestampUs: Long, frameNo: Int, width: Int, height: Int, y: ByteArray): Int

    /** 待处理帧数(背压)。 */
    external fun nativeAutosyncPending(): Int

    /** 进度 0.0–1.0。 */
    external fun nativeAutosyncProgress(): Double

    /** 进度三元组 [percent, ready, total](对齐官方 on_progress)。 */
    external fun nativeAutosyncStat(): DoubleArray?

    /** 取消。 */
    external fun nativeAutosyncCancel(): Int

    /** 结束并应用 offset, 返回 JSON {median, points} 或 "FAIL:..."。 */
    external fun nativeAutosyncFinish(): String?
}