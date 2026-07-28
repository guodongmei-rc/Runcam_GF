#pragma once

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Gyroflow 防抖器句柄。
 *
 * 这是 Rust 侧 StabilizationManager 的不透明指针，调用方不应解引用或自行释放。
 * 使用 gyroflow_stabilizer_new 创建，使用 gyroflow_stabilizer_free 释放。
 */
typedef struct StabilizationManager GyroflowStabilizer;

/**
 * 视频/项目基础信息。
 *
 * gyroflow_load_video_file 或 gyroflow_get_video_info 会填充该结构体。
 */
typedef struct GyroflowVideoInfo {
    /** 输入视频宽度，单位：像素。 */
    uint32_t width;
    /** 输入视频高度，单位：像素。 */
    uint32_t height;
    /** 防抖输出宽度，单位：像素。可能会受镜头配置或 gyroflow_set_output_size 影响。 */
    uint32_t output_width;
    /** 防抖输出高度，单位：像素。可能会受镜头配置或 gyroflow_set_output_size 影响。 */
    uint32_t output_height;
    /** 视频帧率。 */
    double fps;
    /** 视频时长，单位：秒。 */
    double duration_s;
    /** 估算帧数。 */
    uint32_t frame_count;
} GyroflowVideoInfo;

/**
 * 单帧处理后的附加信息。
 *
 * gyroflow_process_frame_cpu 成功后会填充该结构体，可用于调试或 UI 展示。
 */
typedef struct GyroflowProcessInfo {
    /** 当前帧使用的视场缩放值。 */
    double fov;
    /** 当前帧的最小安全视场缩放值。 */
    double minimal_fov;
    /** 当前帧估算焦距；未知时为 0。 */
    double focal_length;
} GyroflowProcessInfo;

/**
 * CPU buffer 的像素格式。
 *
 * 这里描述 input/output buffer 的单像素布局。input 和 output 必须使用同一种格式。
 */
typedef enum GyroflowPixelFormat {
    /** 8-bit RGBA，每像素 4 字节，通道顺序 R,G,B,A。 */
    GYROFLOW_PIXEL_FORMAT_RGBA8 = 0,
    /** 8-bit BGRA，每像素 4 字节，通道顺序 B,G,R,A。iOS CVPixelBuffer 常见格式。 */
    GYROFLOW_PIXEL_FORMAT_BGRA8 = 1,
    /** 8-bit RGB，每像素 3 字节，通道顺序 R,G,B。 */
    GYROFLOW_PIXEL_FORMAT_RGB8 = 2,
    /** 8-bit 单通道灰度/亮度，每像素 1 字节。 */
    GYROFLOW_PIXEL_FORMAT_LUMA8 = 3,
} GyroflowPixelFormat;

/**
 * 获取最近一次 FFI 调用失败的错误信息。
 *
 * 返回值由库内部持有，调用方不要 free。该指针在同一线程下一次 FFI 调用后可能失效。
 */
const char *gyroflow_last_error(void);

/**
 * 创建一个 Gyroflow 防抖器实例。
 *
 * 默认使用 CPU 后端，适合直接集成到已有解码/编码链路。
 *
 * @return 成功时返回非空句柄；失败时返回 NULL，可调用 gyroflow_last_error。
 */
GyroflowStabilizer *gyroflow_stabilizer_new(void);

/**
 * 释放 Gyroflow 防抖器实例。
 *
 * 传入 NULL 是安全的。释放后不得继续使用该 handle。
 */
void gyroflow_stabilizer_free(GyroflowStabilizer *handle);

/**
 * 加载视频文件，并从视频中读取元数据、陀螺仪数据和可自动匹配的镜头配置。
 *
 * 调用方仍然负责自己的视频解码/编码；此函数只初始化防抖所需数据。
 *
 * @param handle gyroflow_stabilizer_new 返回的句柄。
 * @param path_or_url 本地路径或 file:// URL。iOS 沙盒文件需确保 App 已有访问权限。
 * @param out_info 可为 NULL；非 NULL 时返回视频和输出尺寸信息。
 * @return 0 表示成功，-1 表示失败；失败详情见 gyroflow_last_error。
 */
int32_t gyroflow_load_video_file(
    GyroflowStabilizer *handle,
    const char *path_or_url,
    GyroflowVideoInfo *out_info
);

/**
 * 加载 .gyroflow 项目文件。
 *
 * 如果你的工作流已经由 Gyroflow 桌面端/其它流程生成项目文件，可以用它恢复参数。
 *
 * @param handle gyroflow_stabilizer_new 返回的句柄。
 * @param path_or_url .gyroflow 文件的本地路径或 file:// URL。
 * @return 0 表示成功，-1 表示失败；失败详情见 gyroflow_last_error。
 */
int32_t gyroflow_import_project_file(
    GyroflowStabilizer *handle,
    const char *path_or_url
);

/**
 * 加载镜头配置。
 *
 * path_or_json_or_id 可以是：
 * - 镜头配置文件路径或 file:// URL
 * - 镜头配置 JSON 字符串
 * - Gyroflow 内置镜头数据库 ID
 *
 * @param handle gyroflow_stabilizer_new 返回的句柄。
 * @param path_or_json_or_id 镜头配置来源。
 * @return 0 表示成功，-1 表示失败；失败详情见 gyroflow_last_error。
 */
int32_t gyroflow_load_lens_profile(
    GyroflowStabilizer *handle,
    const char *path_or_json_or_id
);

/**
 * 设置防抖输出尺寸。
 *
 * 通常在 gyroflow_load_video_file 或 gyroflow_import_project_file 后调用。
 * 宽高单位为像素。
 *
 * @return 0 表示成功，-1 表示失败；失败详情见 gyroflow_last_error。
 */
int32_t gyroflow_set_output_size(
    GyroflowStabilizer *handle,
    uint32_t width,
    uint32_t height
);

/**
 * 设置输出尺寸（精确像素）。和 gyroflow_set_output_size 不同：
 * - gyroflow_set_output_size 把 (w,h) 当 *长宽比*，然后等比 scale 到铺满
 *   input size——不能比 input 小。
 * - gyroflow_set_output_size_exact 直接写 params.output_size = (w,h)，
 *   不 auto-scale，可以低于 input。用于预览降采样（CPU 工作量按输出像素
 *   数线性下降）。
 *
 * 注意：输出比 input 小后，相机内参 cx/cy/fx/fy 仍以 input 尺寸做参考，
 *      所以画面会"放大"（虚拟传感器变小）。如果想保持与全分辨率同视野，
 *      还需要调用 gyroflow_set_fov() 缩 fov 补偿。
 *
 * @return 0 表示成功，-1 表示失败；失败详情见 gyroflow_last_error。
 */
int32_t gyroflow_set_output_size_exact(
    GyroflowStabilizer *handle,
    uint32_t width,
    uint32_t height
);

/**
 * 设置插值算法。
 *   0=Bilinear (2x2 采样, 最快)
 *   1=Bicubic (4x4)
 *   2=Lanczos4 (8x8, 最佳, 默认)
 *   3=RobidouxSharp / 4=Robidoux / 5=Mitchell / 6=CatmullRom (EWA, 更慢)
 *
 * 默认 Lanczos4 = 64 samples/px。Bilinear = 4 samples/px。预览端用 Bilinear
 * 可显著降 CPU；导出建议保 Lanczos4 保画质。
 *
 * @return 0 表示成功，-1 表示失败；失败详情见 gyroflow_last_error。
 */
int32_t gyroflow_set_interpolation(GyroflowStabilizer *handle, int32_t method);

/**
 * 设置视场缩放。
 *
 * 值越小通常裁切越少但黑边风险越高；值越大裁切越多。
 *
 * @return 0 表示成功，-1 表示失败；失败详情见 gyroflow_last_error。
 */
int32_t gyroflow_set_fov(GyroflowStabilizer *handle, double fov);

/**
 * 获取当前防抖器的视频/输出信息。
 *
 * @param out_info 不可为 NULL。
 * @return 0 表示成功，-1 表示失败；失败详情见 gyroflow_last_error。
 */
int32_t gyroflow_get_video_info(
    GyroflowStabilizer *handle,
    GyroflowVideoInfo *out_info
);

/**
 * 处理一帧 CPU buffer。
 *
 * 调用方需要先完成视频解码，并准备足够大的 output buffer。
 * input 和 output 可以尺寸不同，但像素格式必须相同。
 *
 * @param handle gyroflow_stabilizer_new 返回的句柄。
 * @param timestamp_us 当前帧时间戳，单位：微秒。通常为 presentation timestamp。
 * @param frame_index 当前帧序号；传 -1 时库会根据 timestamp_us 和 fps 估算。
 * @param pixel_format input/output 的像素格式。
 * @param input 输入帧数据指针。
 * @param input_len 输入 buffer 字节数，至少应为 input_stride * 输入高度。
 * @param input_stride 输入每行字节数。
 * @param output 输出帧数据指针。
 * @param output_len 输出 buffer 字节数，至少应为 output_stride * 输出高度。
 * @param output_stride 输出每行字节数。
 * @param out_info 可为 NULL；非 NULL 时返回当前帧处理信息。
 * @return 0 表示成功，-1 表示失败；失败详情见 gyroflow_last_error。
 */
int32_t gyroflow_process_frame_cpu(
    GyroflowStabilizer *handle,
    int64_t timestamp_us,
    int64_t frame_index,
    GyroflowPixelFormat pixel_format,
    const uint8_t *input,
    size_t input_len,
    size_t input_stride,
    uint8_t *output,
    size_t output_len,
    size_t output_stride,
    GyroflowProcessInfo *out_info
);

/**
 * 使用 iOS/macOS Metal texture 处理一帧 BGRA8 画面。
 *
 * 这是实时预览推荐接口：调用方把 AVPlayer/CVPixelBuffer 转成输入 MTLTexture，
 * 再把 MTKView/currentDrawable.texture 作为输出 MTLTexture，库内部走 Gyroflow 的
 * WGPU/Metal 渲染管线，避免 CPU 重映射和 UIImage 拷贝。
 *
 * 要求：
 * - input_texture、output_texture、command_queue 必须来自同一个 MTLDevice。
 * - texture 像素格式建议为 MTLPixelFormatBGRA8Unorm。
 * - input_width/input_height 必须等于已加载视频的输入尺寸。
 * - output_width/output_height 必须等于 Gyroflow 当前输出尺寸。
 *
 * @param handle gyroflow_stabilizer_new 返回的句柄。
 * @param timestamp_us 当前播放时间戳，单位：微秒。
 * @param frame_index 当前帧序号；传 -1 时库会按 timestamp_us 和 fps 估算。
 * @param input_texture id<MTLTexture> 输入纹理指针。
 * @param input_width 输入纹理宽度。
 * @param input_height 输入纹理高度。
 * @param output_texture id<MTLTexture> 输出纹理指针。
 * @param output_width 输出纹理宽度。
 * @param output_height 输出纹理高度。
 * @param command_queue id<MTLCommandQueue> 指针。
 * @param out_info 可为 NULL；非 NULL 时返回当前帧处理信息。
 * @return 0 表示成功，-1 表示失败；失败详情见 gyroflow_last_error。
 */
int32_t gyroflow_process_frame_metal_bgra8(
    GyroflowStabilizer *handle,
    int64_t timestamp_us,
    int64_t frame_index,
    void *input_texture,
    size_t input_width,
    size_t input_height,
    void *output_texture,
    size_t output_width,
    size_t output_height,
    void *command_queue,
    GyroflowProcessInfo *out_info
);

/*
 * --------------------------------------------------------------------------
 * 桌面端「同步 / 稳定 / 镜头 / IMU」面板对应的参数设置接口。
 *
 * 调用顺序建议：
 *   gyroflow_load_video_file ->
 *   gyroflow_set_imu_orientation / gyroflow_set_integration_method ->
 *   gyroflow_set_smoothing_method / gyroflow_set_smoothing_param ->
 *   gyroflow_set_horizon_lock ->
 *   gyroflow_set_zooming_method / gyroflow_set_max_zoom / gyroflow_set_adaptive_zoom ->
 *   gyroflow_set_lens_correction_amount ->
 *   gyroflow_set_output_size ->
 *   gyroflow_set_stab_enabled(1) ->
 *   gyroflow_recompute_blocking ->
 *   逐帧 gyroflow_process_frame_metal_bgra8 / cpu。
 *
 * 所有 setter 在写完所有想改的字段后再调用一次 gyroflow_recompute_blocking
 * 即可，单独调用并不会阻塞计算线程。返回值约定与其它 FFI 一致：0=成功，
 * -1=失败（详情见 gyroflow_last_error）。
 * --------------------------------------------------------------------------
 */

/** 总开关。enabled=0 关闭防抖（直通输入帧），非 0 开启。 */
int32_t gyroflow_set_stab_enabled(GyroflowStabilizer *handle, int32_t enabled);

/**
 * 设置 gyro / 视频 的全局时间同步偏移（毫秒）。
 * GoPro 等相机的陀螺仪数据流和视频帧之间有固有恒定错位（Hero 6 实测约 +48ms）。
 * 不补偿会导致 correction 用错时刻的姿态、反向叠加抖动（"开防抖比不开还抖"）。
 * 桌面版用 auto-sync 自动算；iOS demo 需显式设。改完需 recompute。
 * offset_ms>0 = 陀螺仪超前视频。设 0 = 清除偏移。
 */
int32_t gyroflow_set_gyro_offset(GyroflowStabilizer *handle, double offset_ms);

/**
 * 读取指定视频时间戳处的陀螺仪原始角速度（单位 °/s）。
 * out 必须指向长度 >= 3 的 double 数组，依次写入陀螺仪 x/y/z 三轴角速度。
 * 已自动应用 gyroflow_set_gyro_offset 的同步偏移，timestamp_us 直接传播放进度即可。
 * 返回 0 成功；找不到陀螺仪数据返回 -1 并把 out 清零。
 */
int32_t gyroflow_get_gyro_at_timestamp(GyroflowStabilizer *handle, int64_t timestamp_us, double *out);

/**
 * 把整段视频的陀螺仪角速度等间隔重采样成 sample_count 个点，一次性取出。
 * out 必须指向长度 >= sample_count*3 的 double 数组，交错布局 [x0,y0,z0, x1,y1,z1, ...]，
 * 单位 °/s。第 i 个点对应视频时间 i/(sample_count-1)*duration。已自动应用同步偏移。
 * 用于一次性绘制 gyro 波形时间轴。返回 0 成功；找不到数据返回 -1 并把 out 清零。
 */
int32_t gyroflow_get_gyro_timeline(GyroflowStabilizer *handle, double *out, int32_t sample_count);

/**
 * 把整段视频的「四元数」(org/积分四元数)等间隔重采样成 sample_count 个点。
 * 用于 DJI / Xtra 这类相机端只输出融合姿态四元数、不含原始陀螺角速度的源:
 * 此时 gyroflow_get_gyro_timeline 会返回 -1，应改调本函数。对齐官方
 * TimelineGyroChart 的 viewMode 3 (Quaternions)，不做角速度反推。
 * out 必须指向长度 >= sample_count*4 的 double 数组，交错布局
 * [x0,y0,z0,w0, x1,y1,z1,w1, ...]（UnitQuaternion::as_vector() = i,j,k,w）。
 * 时间映射与 gyroflow_get_gyro_timeline 一致(已应用同步偏移)。
 * 返回 0 成功；找不到四元数返回 -1 并把 out 清零。
 */
int32_t gyroflow_get_quaternion_timeline(GyroflowStabilizer *handle, double *out, int32_t sample_count);

/**
 * 读取当前 smoothing 算出的最大修正旋转 (pitch, yaw, roll) °。
 * out 必须指向长度 >= 3 的 double 数组。
 */
int32_t gyroflow_get_max_angles(GyroflowStabilizer *handle, double *out);

/**
 * 读取 recompute 后的全局 min_fov, 用于显示 zoom % = 100 / min_fov。
 * recompute 之前为 0。out 必须非空。
 */
int32_t gyroflow_get_min_fov(GyroflowStabilizer *handle, double *out);

/**
 * 按 timestamp 查 per-frame fov / minimal_fov。不写纹理 / 不动 stabilizer 状态。
 * iOS HUD 用: process_frame 因 MDK 队列延迟用 ts-48ms, 但 HUD 显示要按当前 ts
 * 才能跟桌面 controller.current_fov 对齐。
 * 找不到对应 timestamp 的 undistortion data 返回 -1, 不写 out_*。
 */
int32_t gyroflow_get_fov_at_timestamp(GyroflowStabilizer *handle,
                                      int64_t timestamp_us,
                                      double *out_fov,
                                      double *out_minimal_fov);

/**
 * 设置视频播放速度倍率 (默认 1.0)。affects_* 为联动开关(非0=开,对齐桌面默认全开):
 * affects_smoothing=链接平滑, affects_zooming=链接缩放速度, affects_zooming_limit=链接缩放限额。
 * 范围常用 0.1..10.0。
 */
int32_t gyroflow_set_video_speed(GyroflowStabilizer *handle, double speed,
                                 int32_t affects_smoothing,
                                 int32_t affects_zooming,
                                 int32_t affects_zooming_limit);

/**
 * 设置附加 3D 旋转(°)。pitch/yaw/roll 任一非 0 都会乘进 smoothed quat。
 */
int32_t gyroflow_set_additional_rotation(GyroflowStabilizer *handle,
                                         double pitch_deg,
                                         double yaw_deg,
                                         double roll_deg);

/**
 * 设置 undistort 越界区域填充色(RGBA 0-1)。
 */
int32_t gyroflow_set_background_color(GyroflowStabilizer *handle,
                                      double r, double g, double b, double a);

/**
 * 设置背景填充模式: 0=纯色 1=边缘拉伸 2=边缘镜像 3=羽化留边。
 * 对齐桌面 BackgroundMode; 防抖露边空白区按此模式填充。
 */
int32_t gyroflow_set_background_mode(GyroflowStabilizer *handle, int32_t mode);

/**
 * 显示 / 隐藏安全区域指示。show 非 0 显示。
 * core 只改 params 字段;实际边框由 iOS 端用 CAShapeLayer 叠加。
 */
int32_t gyroflow_set_show_safe_area(GyroflowStabilizer *handle, int32_t show);

/**
 * 切换是否在输出帧上叠加 autosync 检测到的特征点（绿色 3px 像素点）。
 * 数据源：AutosyncRunner 跑完后 pose estimator 缓存的 features per timestamp;
 * 未跑同步前 get_features_pixels 返回空, 画面无变化(与桌面端一致)。
 * 设置后下一帧 draw_overlays 直接读 flag, 不触发 recompute。
 */
int32_t gyroflow_set_show_detected_features(GyroflowStabilizer *handle, int32_t show);

/**
 * 切换是否在输出帧上叠加光学流向量（黄色 1px 线段, 长度 = OF 位移）。
 * 数据源 / 生效时机同 gyroflow_set_show_detected_features。
 */
int32_t gyroflow_set_show_optical_flow(GyroflowStabilizer *handle, int32_t show);

/** 选择平滑算法。0=None, 1=Default(默认), 2=Plain 3D, 3=Fixed。 */
int32_t gyroflow_set_smoothing_method(GyroflowStabilizer *handle, uint32_t method_index);

/**
 * 设置当前平滑算法的参数。常用：
 *   "smoothness" -> 0.0..1.0，对应桌面「平滑度」滑块（默认 0.5）
 *   "smoothness_pitch" / "smoothness_yaw" / "smoothness_roll"
 *   "per_axis" -> 0/1
 *   "max_smoothness"
 */
int32_t gyroflow_set_smoothing_param(GyroflowStabilizer *handle, const char *name, double value);

/**
 * 锁定地平线。lock_percent=0 表示关闭（桌面默认）。lock_pitch 非 0 表示同时锁俯仰。
 * 高级（自动锁定）参数对齐官方 set_horizon_lock 全 9 参：
 *   automatic_lock 非 0 启用自动锁定；turn_threshold(°/s) / turn_smoothing_ms /
 *   turn_multiplier / tilt_accel_limit(°/s²) 为其子参数(关闭自动锁定时桌面默认
 *   0 / 0 / 1.0 / 0)。
 */
int32_t gyroflow_set_horizon_lock(
    GyroflowStabilizer *handle,
    double lock_percent,
    double roll_deg,
    int32_t lock_pitch,
    double pitch_deg,
    int32_t automatic_lock,
    double turn_threshold,
    double turn_smoothing_ms,
    double turn_multiplier,
    double tilt_accel_limit
);

/** 动态缩放：缩放速度，单位秒，桌面默认 4.0。 */
int32_t gyroflow_set_adaptive_zoom(GyroflowStabilizer *handle, double window_seconds);

/** 缩放限额（百分比）+ 迭代次数，桌面默认 (130.0, 5)。 */
int32_t gyroflow_set_max_zoom(GyroflowStabilizer *handle, double percent, uint32_t iterations);

/** 缩放方法：0=禁用, 1=动态, 2=静态等。桌面默认 1（动态缩放）。 */
int32_t gyroflow_set_zooming_method(GyroflowStabilizer *handle, int32_t method);

/** 镜头校正比例 0.0..1.0，桌面默认 1.0（100%）。 */
int32_t gyroflow_set_lens_correction_amount(GyroflowStabilizer *handle, double amount);

/** 视频整体旋转角度（度）。 */
int32_t gyroflow_set_video_rotation(GyroflowStabilizer *handle, double deg);

/** 卷帘快门读出时间，单位毫秒。0 表示无卷帘补偿。 */
int32_t gyroflow_set_frame_readout_time(GyroflowStabilizer *handle, double ms);

/** 卷帘快门读出方向。0=TopToBottom(默认) 1=BottomToTop 2=LeftToRight 3=RightToLeft。
 *  加载视频时已从 telemetry 自动识别, 此接口用于用户手动覆盖。 */
int32_t gyroflow_set_frame_readout_direction(GyroflowStabilizer *handle, int32_t dir);

/**
 * 读取当前帧读出方向 (0=上→下 1=下→上 2=左→右 3=右→左)。加载时引擎已从
 * telemetry/镜头自动识别, 读回以回显 UI。出错返回 -1。
 */
int32_t gyroflow_get_frame_readout_direction(GyroflowStabilizer *handle);

/** 把当前已加载镜头档案自带的额外设置(frame_readout_time+方向 / gyro_lpf)应用到引擎。
 *  对齐官方 LensProfile.qml；iOS 在每条镜头加载路径加载完后调用一次。0=成功，-1=出错。 */
int32_t gyroflow_apply_loaded_lens_extras(GyroflowStabilizer *handle);

/** IMU 朝向，例如 "ZyX"（桌面 GoPro 默认值）。 */
int32_t gyroflow_set_imu_orientation(GyroflowStabilizer *handle, const char *orientation);

/**
 * 取自动检测到的 IMU 朝向(轴向映射, 如 "XYZ"/"Yxz"; GoPro 常见 "ZyX")写进 out_buf。
 * 数据源 = load_video_file 从 telemetry 自动识别的 imu_orientation；None 时写空串。
 * out_buf 建议 >= 8 字节。成功 0，失败 -1。用于把真实朝向显示到 UI(对齐官方)。
 */
int32_t gyroflow_get_imu_orientation(GyroflowStabilizer *handle, char *out_buf, size_t out_buf_len);

/** 陀螺仪低通滤波（Hz）。0 表示关闭。 */
int32_t gyroflow_set_imu_lpf(GyroflowStabilizer *handle, double hz);

/* —— 运动数据高级项(符号已在 libgyroflow_core.a 内,对齐官方 ffi.rs;此前头文件未声明)——
 * 三个 setter 内部已 recompute_gyro;调用方仍需 recompute_blocking 刷 max angles/minFov。 */
/** 中值滤波采样数。0=关闭。 */
int32_t gyroflow_set_imu_median_filter(GyroflowStabilizer *handle, int32_t samples);
/** IMU 旋转(度):pitch/roll/yaw。三者全 0=不旋转。 */
int32_t gyroflow_set_imu_rotation(GyroflowStabilizer *handle, double pitch, double roll, double yaw);
/** 陀螺仪 bias(°/s):x/y/z。三者全 0=无偏置。 */
int32_t gyroflow_set_imu_bias(GyroflowStabilizer *handle, double bx, double by, double bz);
/** 读当前 IMU 低通(Hz)。0=未启用。出错返回 0.0。 */
double  gyroflow_get_imu_lpf(GyroflowStabilizer *handle);
/** 读当前中值滤波采样数。0=未启用。 */
int32_t gyroflow_get_imu_median_filter(GyroflowStabilizer *handle);
/** 读 IMU 旋转角(度):out[0]=pitch out[1]=roll out[2]=yaw。out 长度 >=3。成功 0,失败 -1。 */
int32_t gyroflow_get_imu_rotation(GyroflowStabilizer *handle, double *out);
/** 读陀螺仪 bias(°/s):out[0]=x out[1]=y out[2]=z。out 长度 >=3。成功 0,失败 -1。 */
int32_t gyroflow_get_imu_bias(GyroflowStabilizer *handle, double *out);

/** 积分方法。0=None, 1=Complementary, 2=VQF（桌面默认）, 3=Madgwick, 4=Mahony, 5=GyroOnly。 */
int32_t gyroflow_set_integration_method(GyroflowStabilizer *handle, uint32_t index);

/**
 * 强制按当前参数把陀螺数据→平滑→缩放→畸变全部计算一遍。
 * 在改完一组 setter 后调一次。
 */
int32_t gyroflow_recompute_blocking(GyroflowStabilizer *handle);

/**
 * 选中第一个可用的 wgpu/Metal 设备并绑定到防抖管线。
 * 在 process_frame_metal_bgra8 之前调用一次即可（仅 macOS/iOS 提供）。
 * 失败（无 wgpu 设备）返回 -1。
 */
int32_t gyroflow_use_default_gpu(GyroflowStabilizer *handle);

/** 当前是否有可用的运动数据（陀螺/光流估计）。0=有，-1=没有。 */
int32_t gyroflow_has_motion_data(GyroflowStabilizer *handle);

/** 当前是否已加载有效镜头配置。0=有，-1=没有。 */
int32_t gyroflow_has_lens_profile(GyroflowStabilizer *handle);

/**
 * 视频是否含「精确时间戳」(GoPro/Insta360 自带高精度 quaternion)。
 * 对齐官方 Synchronization.qml:69 —— 精确时间戳视频 **不应** 跑 autosync。
 * 1=有，0=没有，-1=错误。
 */
int32_t gyroflow_has_accurate_timestamps(GyroflowStabilizer *handle);

/**
 * 视频/telemetry 是否自带厂商高精度四元数 (GoPro CORI / Insta360 等)。
 * 对齐官方 MotionData.qml 的 contains_quats，用于选积分方法：
 *   有四元数 → method 0(原生 quat)；无四元数 → 按时长 Complementary/VQF。
 * 比 has_accurate_timestamps 精确(后者是时间戳标志, 不等价于"有四元数")。
 * 1=有，0=没有，-1=错误。
 */
int32_t gyroflow_has_quaternions(GyroflowStabilizer *handle);

/**
 * 按当前已识别的相机身份(camera_id)自动从内置库匹配并加载镜头档案。
 * 用于「相机身份在外挂 .gcsv 里、视频本身无 telemetry」的机型(如 RunCam 6):
 * 加载完陀螺 sidecar 后调用, 对齐桌面端「打开视频自动加载镜头」。
 * 0=已加载; -2=无可匹配(相机未知/库里没有/已有内嵌档案); -1=出错。
 */
int32_t gyroflow_autoload_lens_for_camera(GyroflowStabilizer *handle);

/**
 * 取指定视频时间戳处的姿态四元数, 供「方向指示器」逐帧动态绘制。
 * out 必须指向长度 >= 8 的 double 数组:
 *   out[0..4] = 原始姿态 (w,i,j,k)  out[4..8] = 平滑姿态 (w,i,j,k)  // scalar first
 * 内部已扣掉 gyro/video 同步偏移。成功 0，失败 -1。
 */
int32_t gyroflow_quats_at_timestamp(GyroflowStabilizer *handle, int64_t timestamp_us, double *out);

/**
 * 手动加载陀螺/IMU sidecar 数据（.gcsv/.csv/.bbl 等）。0=成功，-1=失败。
 *
 * 注意：同名 sidecar 的自动加载已内置——gyroflow_load_video_file 在视频格式
 * 未被识别时会自动试同目录同名的 gcsv/bbl/bfl/csv（telemetry-parser 行为）。
 * 视频在 App 沙盒内（从相机下载）时自动加载直接生效；本函数用于
 * UIDocumentPicker 选入的外部目录文件（scope 只覆盖被选文件）或非同名文件。
 *
 * load_all_metadata 对齐官方 MotionData.qml「Load all metadata」勾选框
 * （官方把它作为 is_main_video 传入，MotionData.qml:40）：
 *   0（官方默认）= 只取陀螺/四元数流，不动镜头档案/fps/卷帘快门；
 *   非 0 = 按主视频完整解析（带入文件内嵌镜头档案、fps 覆盖、卷帘参数）。
 */
int32_t gyroflow_load_gyro_data(GyroflowStabilizer *handle, const char *path, int32_t load_all_metadata);

/**
 * 注册「已获授权的目录」到 gyroflow 文件系统白名单（ALLOWED_FOLDERS）。
 * iOS 沙盒下 get_folder() 只认白名单目录，不注册则同名 sidecar 自动加载
 * （视频格式未识别时自动试同目录同名 gcsv/bbl/bfl/csv）永远查不到文件。
 * - 加载视频前用视频父目录调用 → App 容器内的同名陀螺文件自动加载生效；
 * - Files 选的外部目录：需先经系统目录选择器拿到 security scope（调用方持有），再注册。
 * 传 file:// URL；纯路径会自动加前缀。幂等。0=成功，-1=失败。
 */
int32_t gyroflow_folder_access_granted(const char *folder_url);

/**
 * 设置整帧粒度的视频/陀螺对齐偏移（单位：帧，可负）。
 * 对齐官方 MotionData.qml「Frame offset」：渲染前把视频时间戳整帧平移后再查陀螺。
 * 与毫秒级 gyro offset 是两套独立机制，可叠加。官方仅在加载了外挂运动数据文件时
 * 暴露此项，默认 0。0=成功，-1=失败。
 */
int32_t gyroflow_set_frame_offset(GyroflowStabilizer *handle, int32_t frames);

/**
 * 内置镜头库关键字搜索。结果 JSON 写进 out_buf：[{"name":"显示名","id":"加载用ID"},...]
 * id 可直接传给 gyroflow_load_lens_profile 从内置库加载（不用文件）。
 * 返回匹配条数（>=0），出错 -1。
 */
int32_t gyroflow_lens_search(GyroflowStabilizer *handle, const char *query, char *out_buf, size_t out_buf_len);

/**
 * 当前已加载镜头库版本号（对应 gyroflow/lens_profiles 的 release 号，
 * 内置库或 data_dir/lens_profiles 里已安装的更新包）。出错 -1。
 */
int32_t gyroflow_get_lens_db_version(GyroflowStabilizer *handle);

/**
 * 安装下载的 profiles.cbor.gz 字节并热重载镜头库，返回新版本号；出错 -1。
 * 落盘到 app 数据目录 lens_profiles/，之后 load_all 优先使用。
 */
int32_t gyroflow_install_lens_profiles(GyroflowStabilizer *handle, const uint8_t *data, size_t data_len);

/**
 * 取当前已加载镜头的显示信息，JSON 写进 out_buf：
 * {"name":"...","camera":"品牌 型号","lens":"镜头型号","has_lens":true}
 * 成功 0，失败 -1。
 */
int32_t gyroflow_get_lens_info(GyroflowStabilizer *handle, char *out_buf, size_t out_buf_len);

/**
 * 取已加载镜头档案的「完整」JSON，写进 out_buf：
 * {
 *   "name":..., "camera":..., "lens":...,
 *   "camera_brand":..., "camera_model":..., "lens_model":...,
 *   "camera_setting":..., "note":..., "calibrated_by":...,
 *   "official": bool, "asymmetrical": bool,
 *   "calib_dimension": {"w":..., "h":...},
 *   "orig_dimension":  {"w":..., "h":...},
 *   "fps": double,
 *   "fx":..., "fy":..., "cx":..., "cy":...,        // null 表示没有
 *   "distortion_coeffs": [k1, k2, k3, k4],          // 元素可能为 null
 *   "distortion_model":..., "digital_lens":...,
 *   "frame_readout_time":...,
 *   "identifier":..., "calibrator_version":..., "date":...,
 *   "has_lens": bool
 * }
 * 与 gyroflow_get_lens_info 的区别：calib_dimension 已 swap 到视频实际分辨率，
 * camera_matrix / distortion_coeffs 是已缩放的标定数值。out_buf 建议 8192+。
 * 成功 0，失败 -1。
 */
int32_t gyroflow_get_lens_info_full(GyroflowStabilizer *handle, char *out_buf, size_t out_buf_len);

/**
 * 视频内嵌丰富元数据，JSON 写入 out_buf：
 * {
 *   "camera": "Sony ILCE-7SM3",
 *   "additional_data": { "recording_settings": { "ISO": "...", "Shutter speed": "...", ... }, ... }
 * }
 * 字段对齐官方 VideoInformation.qml + VideoArea.qml(additional_data.recording_settings)。
 * 只透传核心解析到的内容；调用方只显示存在的键。out_buf 建议 8192+。成功 0，失败 -1。
 */
int32_t gyroflow_get_video_metadata(GyroflowStabilizer *handle, char *out_buf, size_t out_buf_len);

/**
 * 设置水下镜头折射系数。1.0 = 空气（默认），1.33 = 水下。
 * 启用水下时，stab 渲染会按水的折射率补偿光线弯曲。
 * 0 = 成功，-1 = 失败。
 */
int32_t gyroflow_set_light_refraction_coefficient(GyroflowStabilizer *handle, double value);

// ============================================================================
// Auto-sync（自动同步）—— 找出陀螺数据相对视频帧的时间偏移
//
// 流程：
//   1) _start：传入参数 → 拿到 session 指针 + 一组待解码的时间范围
//   2) _get_ranges：拿到 N 对 [from_ms, to_ms]，调用方按范围去解码视频帧
//   3) 对每一帧解码出 Y 平面后调 _feed_frame（非阻塞，内部 rayon 并行）
//   4) _finish：阻塞，跑光流+find_offsets，把结果应用到 gyro，返回中位 offset_ms
//   5) _free：释放 session
//   中途可 _cancel；可随时 _get_progress（0..1）
// ============================================================================

/** Auto-sync session 不透明句柄。 */
typedef struct GyroflowAutosyncSession GyroflowAutosyncSession;

/**
 * 创建 auto-sync session。max_sync_points 决定在视频上等距采样几个点。
 * search_size_sec、time_per_syncpoint_sec 都是**秒**，内部转 ms。
 * of_method: 0=AKAZE, 1=OpenCV PyrLK, 2=OpenCV DIS
 * pose_method: 0=findEssentialMat, 1=Almeida, 2=EightPoint, 3=findHomography
 * offset_method: 0=Essential matrix（本质矩阵）, 1=Visual features（视觉功能）, 2=rs-sync（卷帘快门同步）
 *
 * 三个 bool（传 0/非 0）对齐官方 Synchronization.qml：
 *   calc_initial_fast   先用 essential_matrix 粗算 offset → 再用 rs_sync 精修
 *                       （offsetMethod=2 且搜索窗口大时官方自动启用）
 *   initial_offset_inv  双向搜索（同时分析 +offset 和 -offset），耗时翻倍
 *   auto_sync_points    让 Rust 自动从画面里挑最佳采样点（覆盖等距采样）
 * 失败返回 NULL。
 */
GyroflowAutosyncSession *gyroflow_autosync_start(
    GyroflowStabilizer *handle,
    double initial_offset_ms,
    double search_size_sec,
    uint32_t max_sync_points,
    uint32_t every_nth_frame,
    double time_per_syncpoint_sec,
    uint32_t of_method,
    uint32_t pose_method,
    uint32_t offset_method,
    int32_t calc_initial_fast,
    int32_t initial_offset_inv,
    int32_t auto_sync_points
);

/**
 * 取同步点 ms 范围。out 必须指向长度 ≥ max_pairs*2 的 double 数组，
 * 写入交错的 [from0_ms, to0_ms, from1_ms, to1_ms, ...]。
 * 返回实际写入的 pair 个数（< 0 = 错）。
 */
int32_t gyroflow_autosync_get_ranges(
    GyroflowAutosyncSession *session,
    double *out,
    uint32_t max_pairs
);

/**
 * 喂一帧灰度像素（Y 平面）给 auto-sync。
 * timestamp_us 是帧在视频时间轴上的时间戳（微秒）。
 * 调用**非阻塞**（内部 spawn 到 rayon 线程池）。
 */
int32_t gyroflow_autosync_feed_frame(
    GyroflowAutosyncSession *session,
    int64_t timestamp_us,
    uint32_t frame_no,
    uint32_t width,
    uint32_t height,
    uint32_t stride,
    const uint8_t *pixels,
    size_t pixels_len
);

/**
 * 喂完所有帧后调。**阻塞**，跑光流 + find_offsets，然后把算出的 offsets
 * **逐点写入 gyro.offsets 并 recompute**（remove_offsets_near 100ms → set_offset →
 * adjust_offsets → keyframes.update_gyro → invalidate_zooming，对齐安卓
 * stab.rs:661-683 / 官方 controller.rs:423-447）。
 * （历史"A方案 2026-05-27 不应用"已废弃——"Metal 已内部消化时间差"的判断被实测推翻。）
 * 同时把结果填给 UI 显示:
 *   - out_offset_ms: 写 median offset (ms)（仅显示用，引擎用的是逐点值）
 *   - out_sync_points: 长度 >= cap*2 的 double 数组, 交错 [mid_ms_0, off_ms_0, mid_ms_1, off_ms_1, ...]
 *   - out_sync_points_cap: caller 给的容量(以 pair 为单位)
 *   - out_sync_points_count: 实际写入的 pair 数,可为 NULL
 * 无可用 offsets(同步全失败)时返回 -1。
 */
int32_t gyroflow_autosync_finish(
    GyroflowAutosyncSession *session,
    GyroflowStabilizer *handle,
    double *out_offset_ms,
    double *out_sync_points,
    uint32_t out_sync_points_cap,
    uint32_t *out_sync_points_count
);

/** 仍在队列里待处理的帧数(已 feed - 已检测)。背压控制用。session 无效返回 -1。 */
int32_t gyroflow_autosync_pending_count(GyroflowAutosyncSession *session);

/** 设置取消标志。调用方应在 _finish 完成后再 _free。 */
int32_t gyroflow_autosync_cancel(GyroflowAutosyncSession *session);

/** 返回 0.0–1.0 之间的进度。 */
double gyroflow_autosync_get_progress(GyroflowAutosyncSession *session);

/** 取核心 on_progress 的 (ready/detected, total) 帧数 —— 对齐官方分子/分母, 不溢出。out 可为 NULL。 */
void gyroflow_autosync_get_frames(GyroflowAutosyncSession *session, uint32_t *out_ready, uint32_t *out_total);

/** 释放 session。与 _start 配对。 */
void gyroflow_autosync_free(GyroflowAutosyncSession *session);

/**
 * 导出进度回调。progress ∈ [0,1]，frame/total 为已处理/总帧数，user 为透传指针。
 * 回调在渲染线程被调用（非主线程）。
 */
typedef void (*GyroflowRenderProgress)(double progress, int64_t frame, int64_t total, void *user);

/**
 * 用 FFmpeg 渲染（导出）一个稳定后的视频文件。
 *
 * 复用官方 rendering::render() 管线：FFmpeg 解码输入 → 逐帧 gyroflow 防抖 → FFmpeg 编码写出。
 * 支持 H.264/HEVC/ProRes/DNxHD/CineForm/PNG/EXR。
 *
 * @param handle           已 load_video + 配置参数 + recompute 过的 stabilizer。
 * @param input_path       输入视频路径或 URL（FFmpeg 重新打开解码）。
 * @param output_folder    输出目录（路径或 URL）。
 * @param output_filename  输出文件名（扩展名决定容器：.mp4/.mov/.mkv；png/exr 序列形如 name_%05d.png）。
 * @param codec            "H.264/AVC" | "H.265/HEVC" | "ProRes" | "DNxHD" | "CineForm" | "PNG Sequence" | "EXR Sequence" | "AV1"。
 * @param codec_options    profile 字符串（ProRes "HQ" / DNxHD "DNxHR HQ" / png "16-bit" 等），可为 NULL。
 * @param output_width     输出像素宽（应与 stabilizer 的 output_size 一致）。
 * @param output_height    输出像素高。
 * @param bitrate_mbps     码率（Mbps）。0 = 自动。
 * @param use_gpu          1 = 优先硬件编码器（iOS = VideoToolbox）。
 * @param audio            1 = 保留源音频轨。
 * @param progress_cb      进度回调，可为 NULL。
 * @param progress_user    透传给回调的指针，可为 NULL。
 * @return 0 表示成功，-1 表示失败；失败详情见 gyroflow_last_error。
 */
int32_t gyroflow_render_to_file(
    GyroflowStabilizer *handle,
    const char *input_path,
    const char *output_folder,
    const char *output_filename,
    const char *codec,
    const char *codec_options,
    uint32_t output_width,
    uint32_t output_height,
    double bitrate_mbps,
    int32_t use_gpu,
    int32_t audio,
    GyroflowRenderProgress progress_cb,
    void *progress_user
);

#ifdef __cplusplus
}
#endif
