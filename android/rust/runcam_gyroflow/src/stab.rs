// 阶段 2c: 用 gyroflow 的 Rust 核心做去畸变 + 稳定(CPU 路径),输出 RGBA 显示。
//
// 流程(对齐 iOS,直接调 Rust 核心):
//   open_video: StabilizationManager::default → load_video_file(出元数据+内嵌陀螺+自动镜头)
//               → configure_for_preview → recompute_blocking
//   process_frame: 每帧 YUV→RGBA(复用缓冲) → process_pixels::<RGBA8> → preview::display_rgba
//
// CPU 路径用 BufferSource::Cpu,绕开"gyroflow 设备 vs 预览设备"两套 wgpu。GPU 加速留后。

use jni::EnvUnowned;
use jni::errors::ThrowRuntimeExAndDefault;
use jni::objects::{JByteArray, JClass, JString};
use jni::sys::{jboolean, jdouble, jint, jlong, jstring};
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use gyroflow_core::StabilizationManager;
use gyroflow_core::gpu::{BufferDescription, BufferSource, Buffers};
use gyroflow_core::stabilization::{KernelParams, RGBA8};

/// 取某时间戳的每帧变换(纯 CPU, 不做图像处理), 供 GPU undistort 用。
/// 返回 (kernel_params, matrices, mesh_data, 畸变模型名)。
pub(crate) fn get_transform(ts_us: i64) -> Option<(KernelParams, Vec<[f32; 14]>, Vec<f32>, String, Vec<u8>)> {
    let guard = STAB.lock().unwrap();
    let session = guard.as_ref()?;
    let (iw, ih, ow, oh) = {
        let p = session.manager.params.read();
        (p.size.0, p.size.1, p.output_size.0, p.output_size.1)
    };
    if iw == 0 || ow == 0 {
        return None;
    }

    // 覆盖层: 开了 DRAWING_ENABLED 就先按当前尺寸确保 canvas 已分配 ——
    // get_frame_transform_at 会据 canvas.scale 设 kp.canvas_scale(shader 用它定位), 必须先分配。
    let drawing_enabled = session.manager.stabilization.read().kernel_flags
        .contains(gyroflow_core::stabilization::KernelParamsFlags::DRAWING_ENABLED);
    if drawing_enabled && session.manager.stabilization.read().drawing.get_buffer_len() == 0 {
        let scale = (ih as f64 / 720.0).max(1.0) as usize;
        session.manager.stabilization.write().drawing =
            gyroflow_core::gpu::drawing::DrawCanvas::new(iw, ih, ow, oh, scale);
    }

    let buffers = Buffers {
        input: BufferDescription { size: (iw, ih, iw * 4), data: BufferSource::None, ..Default::default() },
        output: BufferDescription { size: (ow, oh, ow * 4), data: BufferSource::None, ..Default::default() },
    };
    let t = session
        .manager
        .stabilization
        .read()
        .get_frame_transform_at::<RGBA8>(ts_us, None, &buffers);
    // 记录当前帧 fov, 给左上角 HUD 实时算 zoom% = 100/fov 用(对齐桌面 controller.current_fov
    // = FrameTransform.fov, VideoArea.qml:669 / iOS gyroflow_get_fov_at_timestamp)。
    CURRENT_FOV.store(t.fov.to_bits(), Ordering::Relaxed);
    let mut kp = t.kernel_params;
    // 我们的输入/输出纹理是 Rgba8Unorm(归一化 0-1), 像素上限必须为 1.0
    kp.pixel_value_limit = 1.0;
    kp.max_pixel_value = 1.0;
    let dm = session
        .manager
        .lens
        .read()
        .distortion_model
        .clone()
        .unwrap_or_else(|| "opencv_fisheye".to_string());

    // 填充 canvas(特征绿点 / 光流黄线), 返回其 byte buffer 供 GPU shader 合成
    let drawing: Vec<u8> = if drawing_enabled {
        let mut stab = session.manager.stabilization.write();
        session.manager.draw_overlays(&mut stab.drawing, ts_us);
        stab.drawing.get_buffer().to_vec()
    } else {
        Vec::new()
    };

    Some((kp, t.matrices, t.mesh_data, dm, drawing))
}

/// 一次会话: 管理器 + 复用的输入/输出像素缓冲(避免每帧重新分配)。
struct Session {
    manager: StabilizationManager,
}

static STAB: Mutex<Option<Session>> = Mutex::new(None);

/// 最近一帧的 fov(f64 bits), 由 get_transform 每帧写入。供 nativeGetCurrentFov 读。
/// 0.0 表示尚未渲染任何帧。
static CURRENT_FOV: AtomicU64 = AtomicU64::new(0);

/// gyroflow_core 处理后端选择。
///
/// **重要(2026-06-26 修 4K60 黑屏)**:强制 gyroflow_core 走 **CPU**(set_device(-1))。
/// 现架构下预览/导出的逐像素去畸变+稳定**不**走 gyroflow_core 的 GPU kernel —— 而是在
/// `preview.rs` 自建的那块独立 wgpu(Vulkan)设备上用 `crate::undistort` 重新实现;
/// gyroflow_core 这边只做 `get_transform`(`get_frame_transform_at`,BufferSource::None,纯 CPU 矩阵)
/// 与 `recompute_blocking`(纯 CPU)。`process_pixels` 全程没人调。
///
/// 若让 gyroflow_core 选 wgpu,`init_size()` 会在**第二块 Vulkan 设备**上按全分辨率分配一套
/// 稳定纹理 —— 对预览毫无用处,却白占图形/ION 内存。已实测确认:本机硬解 4K60 没问题
/// (系统播放器流畅),但我们进程里这第二块设备 + 其纹理 + 预览设备占满图形内存后,
/// 4K60 硬件解码器 `start()` 拿不到内存 → −12 NO_MEMORY → 黑屏(4K30/1080p 因解码器
/// 预留更小而幸免)。强制 CPU 即释放这块冗余设备,把图形内存让给解码器。
/// 代价:无(预览/导出本就不用 gyroflow_core GPU;recompute/transform 本就 CPU)。
fn ensure_wgpu_device(manager: &StabilizationManager) {
    manager.set_device(-1);
    log::info!("gyroflow_core 强制 CPU(GPU 渲染在 preview.rs 独立设备上;省第二块 Vulkan 设备的图形内存给 4K60 解码器)");
}

fn open_video(url_in: &str) -> Result<String, String> {
    let manager = StabilizationManager::default();
    ensure_wgpu_device(&manager); // 切到 GPU(wgpu)处理

    let url = if url_in.contains("://") {
        url_in.to_string()
    } else {
        gyroflow_core::filesystem::path_to_url(url_in)
    };
    let mut file = gyroflow_core::filesystem::open_file(&url, false, false).map_err(|e| e.to_string())?;
    let size = file.size;
    let md = manager
        .load_video_file(&mut file, size, &url, None, true)
        .map_err(|e| e.to_string())?;

    configure_for_preview(&manager);

    let has_gyro = manager.gyro.read().has_motion();
    let has_lens = {
        let l = manager.lens.read();
        l.calib_dimension.w > 0 && l.calib_dimension.h > 0
    };
    let (w, h, fc, ow, oh) = {
        let p = manager.params.read();
        (p.size.0, p.size.1, p.frame_count, p.output_size.0, p.output_size.1)
    };
    let (max_angle, nquats, im) = {
        let g = manager.gyro.read();
        (g.max_angles, g.quaternions.len(), g.integration_method)
    };
    let dev = manager.params.read().current_device;

    *STAB.lock().unwrap() = Some(Session { manager });
    Ok(format!(
        "opened {w}x{h}->{ow}x{oh} fps={:.3} frames={fc} gyro={has_gyro} lens={has_lens} quats={nquats} intM={im} dev={dev} maxAngle=({:.2},{:.2},{:.2})",
        md.fps, max_angle.0, max_angle.1, max_angle.2
    ))
}

/// 预览用稳定配置(对齐 iOS): 开启稳定、完全镜头矫正、平滑、自适应缩放,
/// 并为 CPU 预览降分辨率 + 最快插值。集中一处,避免散落重复。
fn configure_for_preview(manager: &StabilizationManager) {
    manager.set_stab_enabled(true);
    manager.set_lens_correction_amount(1.0);
    // 注意: smoothing 注册顺序 0=None(无平滑) 1=DefaultAlgo 2=Plain 3=Fixed。
    // 必须用 1(DefaultAlgo), 用 0 会变成"无平滑"→ 完全不稳定。
    manager.set_smoothing_method(1);
    manager.set_smoothing_param("smoothness", 0.5);
    manager.set_adaptive_zoom(4.0);
    manager.set_max_zoom(130.0, 5);

    // 预览用最快插值(Bilinear); 导出阶段再用高质量
    manager.stabilization.write().interpolation = gyroflow_core::stabilization::Interpolation::Bilinear;

    // 输出 16:9, 按**源尺寸**算: 满宽 + 高度裁成 16:9(全分辨率, 不模糊)。
    // 例: 2704×2028 → 2704×1520。只在载入时设一次。
    {
        let (iw, ih) = {
            let p = manager.params.read();
            (p.size.0, p.size.1)
        };
        let ow = (iw & !1).max(2);
        let oh = ((iw * 9 / 16) & !1).min(ih & !1).max(2);
        let mut p = manager.params.write();
        p.output_size = (ow, oh);
    }
    manager.init_size();

    // 陀螺偏移不预设任何默认数值(按需求规定, 与 iOS ParamsModel 一致): 载入时清空。
    // 真实偏移只来自 autosync 计算(见 autosync_finish)或手动输入(nativeSetGyroOffset)。
    manager.gyro.write().clear_offsets();

    // 镜头档案携带的卷帘时间/低通 → 应用(对齐官方 apply_loaded_lens_extras)。
    apply_lens_extras(manager);

    manager.invalidate_smoothing();
    manager.recompute_blocking();
}

/// 应用镜头档案里的"附加项": frame_readout_time(卷帘) + gyro_lpf(低通)。
/// 完全对齐官方 gyroflow_apply_loaded_lens_extras。
fn apply_lens_extras(manager: &StabilizationManager) {
    use gyroflow_core::stabilization_params::ReadoutDirection;
    let (fr, frd, lpf) = {
        let lens = manager.lens.read();
        (lens.frame_readout_time, lens.frame_readout_direction.clone(), lens.gyro_lpf)
    };
    if let Some(fr) = fr {
        let mut p = manager.params.write();
        p.frame_readout_time = fr.abs();
        p.frame_readout_direction = frd.unwrap_or(if fr < 0.0 {
            ReadoutDirection::BottomToTop
        } else {
            ReadoutDirection::TopToBottom
        });
    }
    if let Some(lpf) = lpf {
        if lpf > 0.0 {
            manager.set_imu_lpf(lpf);
        }
    }
}

/// 按相机身份(camera_id)从内置镜头库自动匹配并加载镜头。
/// 复刻官方 load_video_file 的 camera_id → db.contains_id → load_lens_profile
/// (core/lib.rs:1799-1826), 与 iOS 端 gyroflow_autoload_lens_for_camera 等价。
/// 用途: 相机身份在外挂 .gcsv 里、视频本身无 telemetry 的机型(如 RunCam6),
/// 加载完陀螺 sidecar(camera_id 才有值)后调用。返回是否加载成功。
fn autoload_lens_for_camera(manager: &StabilizationManager) -> bool {
    let has_builtin_profile = {
        let gyro = manager.gyro.read();
        let file_metadata = gyro.file_metadata.read();
        file_metadata.lens_profile.as_ref().map(|y| y.is_object()).unwrap_or_default()
    };
    let id_str = manager.camera_id.read().as_ref().map(|v| v.get_identifier_for_autoload()).unwrap_or_default();
    if id_str.is_empty() || has_builtin_profile {
        return false;
    }
    {
        let db = manager.lens_profile_db.read();
        if !db.loaded {
            drop(db);
            let mut db = manager.lens_profile_db.write();
            db.load_all();
        }
    }
    if !manager.lens_profile_db.read().contains_id(&id_str) {
        return false;
    }
    if let Err(e) = manager.load_lens_profile(&id_str) {
        log::warn!("autoload lens for camera '{id_str}' failed: {e:?}");
        return false;
    }
    log::info!("autoload lens for camera '{id_str}' ok");
    true
}

/// 取当前镜头档案的 sync_settings(同步参数), JSON 串; 无则 "{}"。
/// 官方桌面 LensProfile.qml 加载镜头时用它覆盖同步面板默认值(各机型档案多带 search_size/time_per_syncpoint 等)。
fn lens_sync_settings() -> String {
    let guard = STAB.lock().unwrap();
    if let Some(session) = guard.as_ref() {
        let lens = session.manager.lens.read();
        if let Some(ss) = &lens.sync_settings {
            return ss.to_string();
        }
    }
    "{}".to_string()
}

/// 独立镜头库(搜索不依赖是否已载入视频, 首次解包后常驻缓存)。
static LENS_DB: Mutex<Option<gyroflow_core::lens_profile_database::LensProfileDatabase>> =
    Mutex::new(None);

/// 搜索内置镜头库, 返回 JSON 数组 [{"name","id"}]。id 可传给 load_lens 加载。
fn lens_search(q: &str) -> Result<String, String> {
    let mut guard = LENS_DB.lock().unwrap();
    if guard.is_none() {
        let mut db = gyroflow_core::lens_profile_database::LensProfileDatabase::default();
        db.load_all();
        db.prepare_list_for_ui();
        log::info!("[lens] db loaded, profiles={}", db.get_all_filenames().len());
        *guard = Some(db);
    }
    let db = guard.as_ref().unwrap();
    let results = db.search(q, &std::collections::HashSet::new(), 0, 0);
    log::info!("[lens] search '{}' -> {} hits", q, results.len());
    let arr: Vec<serde_json::Value> = results
        .iter()
        .take(200)
        .map(|t| serde_json::json!({ "name": t.0, "id": t.1 }))
        .collect();
    Ok(serde_json::to_string(&arr).unwrap_or_else(|_| "[]".to_string()))
}

/// 当前已加载镜头库版本号(对应 gyroflow/lens_profiles 的 release 号)。确保 LENS_DB 已加载。
fn lens_db_version() -> i32 {
    let mut guard = LENS_DB.lock().unwrap();
    if guard.is_none() {
        let mut db = gyroflow_core::lens_profile_database::LensProfileDatabase::default();
        db.load_all();
        *guard = Some(db);
    }
    guard.as_ref().unwrap().version as i32
}

/// 安装下载的 profiles.cbor.gz 字节并热重载镜头库, 返回新版本号。
/// 对齐官方桌面 controller.fetch_profiles_from_github 的落盘+重载行为:
/// 落盘到 settings::data_dir()/lens_profiles/(之后 load_all 优先用它),
/// 重置 LENS_DB 搜索缓存, 并热替换活动 session 的 manager.lens_profile_db。
fn install_lens_profiles(data: &[u8]) -> Result<i32, String> {
    let version = gyroflow_core::lens_profile_database::LensProfileDatabase::install_from_bytes(data)?;
    *LENS_DB.lock().unwrap() = None; // 下次 lens_search 重新 load_all
    let guard = STAB.lock().unwrap();
    if let Some(session) = guard.as_ref() {
        let mut db = gyroflow_core::lens_profile_database::LensProfileDatabase::default();
        db.load_all();
        *session.manager.lens_profile_db.write() = db;
    }
    Ok(version as i32)
}

/// 取当前已加载镜头档案信息(字段对齐 iOS LensProfile.qml)。
/// 基础表: camera/lens/camera_setting/note/calib_dimension/calibrated_by
///         + 条件项 focal_length/crop_factor/asymmetrical/distortion_model/digital_lens
/// 高级:   相机矩阵 fx/fy/cx/cy、畸变系数 k1..k4、折射系数(水下镜头状态)。
fn lens_info_full() -> Result<String, String> {
    let guard = STAB.lock().unwrap();
    let session = guard.as_ref().ok_or("未载入视频")?;
    let lens = session.manager.lens.read();
    let has_lens = lens.calib_dimension.w > 0 && lens.calib_dimension.h > 0;
    let camera = format!("{} {}", lens.camera_brand, lens.camera_model);
    let light_refraction = session.manager.params.read().light_refraction_coefficient;

    // camera_matrix 是 Vec<[f64;3]>(3x3)。fx=m[0][0], fy=m[1][1], cx=m[0][2], cy=m[1][2]
    let (fx, fy, cx, cy) = if lens.fisheye_params.camera_matrix.len() >= 2 {
        let m = &lens.fisheye_params.camera_matrix;
        (Some(m[0][0]), Some(m[1][1]), Some(m[0][2]), Some(m[1][2]))
    } else {
        (None, None, None, None)
    };
    let coeffs = &lens.fisheye_params.distortion_coeffs;
    let k = |i: usize| coeffs.get(i).copied();

    let json = serde_json::json!({
        "camera": camera.trim(),
        "lens": lens.lens_model,
        "camera_setting": lens.camera_setting,
        "note": lens.note,                                 // iOS: Additional info
        "calib_dimension": { "w": lens.calib_dimension.w, "h": lens.calib_dimension.h },
        "calibrated_by": lens.calibrated_by,
        "focal_length": lens.focal_length,                 // 条件: > 0 显示 "X.XX mm"
        "crop_factor": lens.crop_factor,                   // 条件: > 0 显示 "X.XXx"
        "asymmetrical": lens.asymmetrical,                 // 条件: true 显示 "是"
        "distortion_model": lens.distortion_model,         // 条件: != opencv_fisheye
        "digital_lens": lens.digital_lens,                 // 条件: 有值
        // —— 高级 ——
        "fx": fx, "fy": fy, "cx": cx, "cy": cy,
        "distortion_coeffs": [k(0), k(1), k(2), k(3)],
        "light_refraction_coefficient": light_refraction,
        "has_lens": has_lens,
    });
    Ok(json.to_string())
}

/// 水下镜头开关(对齐 iOS: light_refraction_coefficient 1.33=水下 / 1.0=空气)并重算。
fn set_underwater(on: bool) -> Result<(), String> {
    let guard = STAB.lock().unwrap();
    let session = guard.as_ref().ok_or("未载入视频")?;
    session
        .manager
        .set_light_refraction_coefficient(if on { 1.33 } else { 1.0 });
    session.manager.recompute_blocking();
    Ok(())
}

/// 编辑相机矩阵/畸变系数(对齐 iOS controller.set_lens_param)。
/// param ∈ {fx,fy,cx,cy,k1,k2,k3,k4}; 内核只在 3x3 矩阵 + 4 系数齐全时生效。
fn set_lens_param(param: &str, value: f64) -> Result<(), String> {
    let guard = STAB.lock().unwrap();
    let session = guard.as_ref().ok_or("未载入视频")?;
    session.manager.set_lens_param(param, value);
    session.manager.recompute_blocking();
    Ok(())
}

// ============================================================================
// 运动数据(对齐 iOS MotionData.qml): 信息 + IMU 滤波/旋转/零偏/朝向/积分方法
// ============================================================================

/// 运动数据当前信息: 检测格式 / 是否含四元数·原始陀螺 / 各 IMU 设置。
fn gyro_info() -> Result<String, String> {
    let guard = STAB.lock().unwrap();
    let session = guard.as_ref().ok_or("未载入视频")?;
    let gyro = session.manager.gyro.read();
    let md = gyro.file_metadata.read();
    let rot = gyro.imu_transforms.imu_rotation_angles.unwrap_or([0.0; 3]);
    let bias = gyro.imu_transforms.gyro_bias.unwrap_or([0.0; 3]);
    let json = serde_json::json!({
        "format": md.detected_source.clone().unwrap_or_default(),
        "has_quaternions": !md.quaternions.is_empty(),
        "has_raw_gyro": !md.raw_imu.is_empty(),
        "has_motion": md.has_motion(),
        "has_accurate_timestamps": md.has_accurate_timestamps, // 有准确时间戳=无需同步(对齐官方自动同步判定)
        "imu_orientation": gyro.imu_transforms.imu_orientation.clone().unwrap_or_else(|| "XYZ".into()),
        "integration_method": gyro.integration_method,
        "lpf": gyro.imu_transforms.imu_lpf,
        "median": gyro.imu_transforms.imu_mf,
        "rotation": [rot[0], rot[1], rot[2]],
        "bias": [bias[0], bias[1], bias[2]],
    });
    Ok(json.to_string())
}

/// 视频内嵌的丰富元数据(相机/镜头 + recording_settings: ISO/快门/白平衡/曝光/焦距/对焦方式等)。
/// 字段对齐官方 VideoInformation.qml + VideoArea.qml(additional_data.recording_settings)。
/// 只透传核心解析到的内容; Kotlin 侧只显示存在的键(不存在不展示)。
fn video_metadata() -> Result<String, String> {
    let guard = STAB.lock().unwrap();
    let session = guard.as_ref().ok_or("未载入视频")?;
    let gyro = session.manager.gyro.read();
    let md = gyro.file_metadata.read();
    let json = serde_json::json!({
        "camera": md.detected_source.clone().unwrap_or_default(), // 如 "Sony ILCE-7SM3"
        "additional_data": md.additional_data.clone(),            // 含 recording_settings / camera_identifier / sample_rate 等
    });
    Ok(json.to_string())
}

/// set_* 之后统一: 重新应用 IMU 变换 + 全量重算(对齐 iOS set_* → recompute_gyro)。
fn gyro_apply(session: &Session) {
    session.manager.recompute_gyro();
    session.manager.recompute_blocking();
}

fn set_gyro_lpf(hz: f64) -> Result<(), String> {
    let guard = STAB.lock().unwrap();
    let session = guard.as_ref().ok_or("未载入视频")?;
    session.manager.set_imu_lpf(hz);
    gyro_apply(session);
    Ok(())
}

fn set_gyro_median(samples: i32) -> Result<(), String> {
    let guard = STAB.lock().unwrap();
    let session = guard.as_ref().ok_or("未载入视频")?;
    session.manager.set_imu_median_filter(samples);
    gyro_apply(session);
    Ok(())
}

fn set_gyro_rotation(p: f64, r: f64, y: f64) -> Result<(), String> {
    let guard = STAB.lock().unwrap();
    let session = guard.as_ref().ok_or("未载入视频")?;
    session.manager.set_imu_rotation(p, r, y);
    gyro_apply(session);
    Ok(())
}

fn set_gyro_bias(bx: f64, by: f64, bz: f64) -> Result<(), String> {
    let guard = STAB.lock().unwrap();
    let session = guard.as_ref().ok_or("未载入视频")?;
    session.manager.set_imu_bias(bx, by, bz);
    gyro_apply(session);
    Ok(())
}

fn set_gyro_orientation(s: &str) -> Result<(), String> {
    let guard = STAB.lock().unwrap();
    let session = guard.as_ref().ok_or("未载入视频")?;
    session.manager.set_imu_orientation(s.to_string());
    gyro_apply(session);
    Ok(())
}

/// 把整段视频的原始陀螺(角速度 °/s)等间隔重采样成 n 个三轴点(对齐 iOS gyroflow_get_gyro_timeline)。
/// 返回交错 [x0,y0,z0, x1,y1,z1, ...](长度 n*3)。无原始陀螺则 None。
fn gyro_timeline(n: usize) -> Option<Vec<f64>> {
    if n <= 1 {
        return None;
    }
    let guard = STAB.lock().unwrap();
    let session = guard.as_ref()?;
    let gyro = session.manager.gyro.read();
    let md = gyro.file_metadata.read();
    let raw = gyro.raw_imu(&md);
    if raw.len() < 2 {
        return None;
    }
    let dur_ms = gyro.duration_ms;
    if dur_ms <= 0.0 {
        return None;
    }
    let mut out = vec![0.0_f64; n * 3];
    for i in 0..n {
        let video_ts_ms = (i as f64 / (n - 1) as f64) * dur_ms;
        let ts_ms = video_ts_ms - gyro.offset_at_video_timestamp(video_ts_ms);
        let g = sample_raw_gyro(raw, ts_ms);
        out[i * 3] = g[0];
        out[i * 3 + 1] = g[1];
        out[i * 3 + 2] = g[2];
    }
    Some(out)
}

/// 把整段视频的「四元数」(org/积分四元数)等间隔重采样成 n 个点,返回交错
/// [x0,y0,z0,w0, ...](长度 n*4)。用于 DJI/Xtra 等只输出融合姿态、无原始角速度的源:
/// gyro_timeline 返 None 时改用本函数。对齐官方 TimelineGyroChart viewMode 3(Quaternions)
/// 与 iOS gyroflow_get_quaternion_timeline,不做角速度反推。无四元数则 None。
fn quaternion_timeline(n: usize) -> Option<Vec<f64>> {
    if n <= 1 {
        return None;
    }
    let guard = STAB.lock().unwrap();
    let session = guard.as_ref()?;
    let gyro = session.manager.gyro.read();
    let quats = &gyro.quaternions;
    if quats.len() < 2 {
        return None;
    }
    let dur_ms = gyro.duration_ms;
    if dur_ms <= 0.0 {
        return None;
    }
    let mut out = vec![0.0_f64; n * 4];
    for i in 0..n {
        let video_ts_ms = (i as f64 / (n - 1) as f64) * dur_ms;
        let ts_ms = video_ts_ms - gyro.offset_at_video_timestamp(video_ts_ms);
        let ts_us = (ts_ms * 1000.0) as i64;
        // 最近邻：取 <=ts 的最后一个样本，时间早于首样本则取首样本。
        let q = quats.range(..=ts_us).next_back()
            .or_else(|| quats.iter().next())
            .map(|(_, q)| *q);
        if let Some(q) = q {
            let v = q.as_vector();
            out[i * 4] = v[0];
            out[i * 4 + 1] = v[1];
            out[i * 4 + 2] = v[2];
            out[i * 4 + 3] = v[3];
        }
    }
    Some(out)
}

/// 线性插值取 ts_ms 处的三轴角速度(复刻 iOS sample_raw_gyro)。
fn sample_raw_gyro(raw: &[gyroflow_core::gyro_source::TimeIMU], ts_ms: f64) -> [f64; 3] {
    let idx = raw.partition_point(|s| s.timestamp_ms < ts_ms);
    let (a, b) = if idx == 0 {
        (&raw[0], &raw[1])
    } else if idx >= raw.len() {
        (&raw[raw.len() - 2], &raw[raw.len() - 1])
    } else {
        (&raw[idx - 1], &raw[idx])
    };
    let ga = a.gyro.unwrap_or([0.0; 3]);
    let gb = b.gyro.unwrap_or([0.0; 3]);
    let span = (b.timestamp_ms - a.timestamp_ms).max(1e-9);
    let t = ((ts_ms - a.timestamp_ms) / span).clamp(0.0, 1.0);
    [
        ga[0] + (gb[0] - ga[0]) * t,
        ga[1] + (gb[1] - ga[1]) * t,
        ga[2] + (gb[2] - ga[2]) * t,
    ]
}

/// 某时间戳的原始/平滑四元数(对齐 iOS quats_at_timestamp), 供方向指示器绘制。
/// 返回 [q.w,q.i,q.j,q.k, sq.w,sq.i,sq.j,sq.k]。
fn quats_at_timestamp(ts_us: i64) -> Option<[f64; 8]> {
    let guard = STAB.lock().unwrap();
    let session = guard.as_ref()?;
    let gyro = session.manager.gyro.read();
    let ts = ts_us as f64 / 1000.0 - gyro.offset_at_video_timestamp(ts_us as f64 / 1000.0);
    let sq = gyro.smoothed_quat_at_timestamp(ts);
    let q = gyro.org_quat_at_timestamp(ts);
    Some([q.w, q.i, q.j, q.k, sq.w, sq.i, sq.j, sq.k])
}

/// 切换积分方法(对齐 iOS gyroflow_set_integration_method): 重积分后全量重算。
fn set_gyro_integration(index: u32) -> Result<(), String> {
    let guard = STAB.lock().unwrap();
    let session = guard.as_ref().ok_or("未载入视频")?;
    let new_index = index as usize;
    if session.manager.gyro.read().integration_method != new_index {
        session.manager.invalidate_ongoing_computations();
        {
            let mut gyro = session.manager.gyro.write();
            gyro.integration_method = new_index;
            gyro.apply_transforms();
            gyro.integrate();
        }
        session.manager.invalidate_smoothing();
        session.manager.recompute_blocking();
    }
    Ok(())
}

// ============================================================================
// 自动同步(对齐 iOS AutosyncRunner / 官方 Synchronization)。
// 直接用 gyroflow_core::synchronization::AutosyncProcess(Akaze 光流 + 纯 Rust
// 姿态, 不需 OpenCV)。session 式: start → 按 ranges 喂灰度帧 → finish 应用 offset。
// ============================================================================

struct AutosyncState {
    process: gyroflow_core::synchronization::AutosyncProcess,
    cancel_flag: Arc<AtomicBool>,
    final_offsets: Arc<Mutex<Option<Vec<(f64, f64, f64)>>>>, // (midpoint_ms, offset_ms, cost)
}

static AUTOSYNC: Mutex<Option<AutosyncState>> = Mutex::new(None);
// 进度与 session 解耦: 由官方 on_progress 回调持续写入 (percent, ready, total)。
// finish 阶段 session 被 take 出 AUTOSYNC, 但进度仍写在这里, 读取不受影响 ——
// 对齐官方 controller.rs 把 on_progress 当唯一进度源(percent/ready/total)。
static AUTOSYNC_PROG: Mutex<(f64, u32, u32)> = Mutex::new((0.0, 0, 0));

/// 创建自动同步 session, 返回各同步点的解码范围(交错 [from0_ms,to0_ms, from1_ms,to1_ms,...])。
#[allow(clippy::too_many_arguments)]
fn autosync_start(
    initial_offset_ms: f64,
    search_size_sec: f64,
    max_sync_points: u32,
    every_nth_frame: u32,
    time_per_syncpoint_sec: f64,
    of_method: u32,
    pose_method: u32,
    offset_method: u32,
    calc_initial_fast: bool,
    initial_offset_inv: bool,
    auto_sync_points: bool,
    sync_lpf: f64,
) -> Result<Vec<f64>, String> {
    use gyroflow_core::synchronization::{AutosyncProcess, SyncParams};

    if max_sync_points == 0 {
        return Err("max_sync_points 必须 > 0".into());
    }
    let guard = STAB.lock().unwrap();
    let session = guard.as_ref().ok_or("未载入视频")?;
    let manager = &session.manager;

    // 前置检查(无 lens / 视频参数异常时算法会 panic)
    {
        let lens = manager.lens.read();
        if lens.calib_dimension.w == 0 || lens.calib_dimension.h == 0 {
            return Err("自动同步前置失败: 未加载镜头档案".into());
        }
        // 不再拒绝空 distortion_coeffs(官方用 get_distortion_coeffs() 补零=零畸变, 直线镜头如 Sony 合法)。
        if lens.fisheye_params.camera_matrix.is_empty() {
            return Err("自动同步前置失败: 镜头档案缺相机矩阵".into());
        }
    }
    {
        let p = manager.params.read();
        if p.fps <= 0.0 || p.duration_ms <= 0.0 || p.frame_count == 0 {
            return Err("自动同步前置失败: 视频参数异常".into());
        }
    }

    let n = max_sync_points as usize;
    let timestamps_fract: Vec<f64> = (0..n).map(|i| (i as f64 + 0.5) / n as f64).collect();
    let sync_params = SyncParams {
        initial_offset: initial_offset_ms,
        initial_offset_inv,
        search_size: search_size_sec * 1000.0,
        calc_initial_fast,
        max_sync_points: n,
        every_nth_frame: every_nth_frame.max(1) as usize,
        time_per_syncpoint: time_per_syncpoint_sec * 1000.0,
        of_method: of_method as usize,
        offset_method: offset_method as usize,
        pose_method: pose_method as usize,
        custom_sync_pattern: serde_json::Value::Null,
        auto_sync_points,
    };

    let cancel_flag = Arc::new(AtomicBool::new(false));
    let mut process = AutosyncProcess::from_manager(
        manager,
        &timestamps_fract,
        sync_params,
        "synchronize".to_string(),
        cancel_flag.clone(),
    )
    .map_err(|_| "AutosyncProcess 创建失败(视频时长/帧数过小?)".to_string())?;

    // 同步低通滤波器(对齐官方 controller.set_sync_lpf → estimator.lowpass_filter)。
    // autosync 用的是 manager.pose_estimator(共享), 在喂帧前设好 lpf(Hz; 0=关)即可。
    {
        let fps = manager.params.read().fps;
        manager.pose_estimator.lowpass_filter(sync_lpf, fps);
    }

    *AUTOSYNC_PROG.lock().unwrap() = (0.0, 0, 0);
    process.on_progress(move |p, ready, total| {
        *AUTOSYNC_PROG.lock().unwrap() = (p, ready as u32, total as u32);
    });
    let final_offsets = Arc::new(Mutex::new(None));
    let offsets_cb = final_offsets.clone();
    process.on_finished(move |either| {
        if let itertools::Either::Left(offsets) = either {
            *offsets_cb.lock().unwrap() = Some(offsets);
        }
    });

    let ranges = process.get_ranges(); // Vec<(f64,f64)> ms
    let mut flat = Vec::with_capacity(ranges.len() * 2);
    for (from_ms, to_ms) in ranges {
        flat.push(from_ms);
        flat.push(to_ms);
    }

    {
        let p = manager.params.read();
        log::info!(
            "[autosync_diag] dur_ms={:.1} fps={:.3} frames={} fps_scale={:?} n={} fract={:?} ranges_ms={:?}",
            p.duration_ms, p.fps, p.frame_count, p.fps_scale, n, timestamps_fract, flat
        );
    }
    drop(guard);
    *AUTOSYNC.lock().unwrap() = Some(AutosyncState { process, cancel_flag, final_offsets });
    log::info!("[autosync] started, {} ranges", flat.len() / 2);
    Ok(flat)
}

/// 喂一帧灰度(Y 平面紧凑, stride=width)。
fn autosync_feed(ts_us: i64, frame_no: u32, width: u32, height: u32, y: &[u8]) {
    let guard = AUTOSYNC.lock().unwrap();
    if let Some(state) = guard.as_ref() {
        state.process.feed_frame(ts_us, frame_no as usize, width, height, width as usize, y);
    }
}

/// 待处理帧数(背压用): read - detected。
fn autosync_pending() -> i32 {
    let guard = AUTOSYNC.lock().unwrap();
    if let Some(state) = guard.as_ref() {
        let read = state.process.read_frames_count();
        let detected = state.process.detected_frames_count();
        read.saturating_sub(detected) as i32
    } else {
        -1
    }
}

fn autosync_progress() -> f64 {
    AUTOSYNC_PROG.lock().unwrap().0
}

/// 进度三元组 [percent, ready, total] —— 对齐官方 on_progress(percent, ready, total)。
/// 读自独立 static, finish 阶段(session 已 take 出)仍可读, 不会冻住。
fn autosync_stat() -> [f64; 3] {
    let (p, ready, total) = *AUTOSYNC_PROG.lock().unwrap();
    [p, ready as f64, total as f64]
}

fn autosync_cancel() {
    let guard = AUTOSYNC.lock().unwrap();
    if let Some(state) = guard.as_ref() {
        state.cancel_flag.store(true, Ordering::SeqCst);
    }
}

/// 喂完所有帧后调: 阻塞跑光流+找偏移, 应用 offset 到 gyro 并重算。
/// 返回 JSON {"median":ms, "points":[[mid_ms,off_ms],...]}; 失败 Err。
fn autosync_finish() -> Result<String, String> {
    // 取出 session(结束后释放)
    let state = AUTOSYNC.lock().unwrap().take().ok_or("无进行中的同步")?;
    state.process.finished_feeding_frames(); // 阻塞

    let offsets = state
        .final_offsets
        .lock()
        .unwrap()
        .take()
        .filter(|v| !v.is_empty())
        .ok_or("自动同步未找到偏移")?;

    // 应用 offset 到 gyro —— 完全对齐官方 controller.rs set_offsets:
    // ts = (midpoint_ms - offset_ms)*1000(us); remove_offsets_near 100ms; set_offset;
    // 最后 adjust_offsets + keyframes.update_gyro + invalidate_zooming + recompute。
    {
        let guard = STAB.lock().unwrap();
        let session = guard.as_ref().ok_or("未载入视频")?;
        let manager = &session.manager;
        {
            let mut gyro = manager.gyro.write();
            gyro.prevent_recompute = true;
            for (mid_ms, off_ms, cost) in &offsets {
                log::info!("[autosync] offset @{:.4}: {:.4} (cost {:.4})", mid_ms, off_ms, cost);
                let new_ts = ((mid_ms - off_ms) * 1000.0) as i64;
                gyro.remove_offsets_near(new_ts, 100.0);
                gyro.set_offset(new_ts, *off_ms);
            }
            gyro.prevent_recompute = false;
            gyro.adjust_offsets();
            manager.keyframes.write().update_gyro(&gyro);
        }
        manager.invalidate_zooming();
        manager.recompute_blocking();
    }

    let mut sorted: Vec<f64> = offsets.iter().map(|(_, o, _)| *o).collect();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let median = sorted[sorted.len() / 2];
    let points: Vec<serde_json::Value> = offsets
        .iter()
        .map(|(mid, off, _)| serde_json::json!([mid, off]))
        .collect();
    Ok(serde_json::json!({ "median": median, "points": points }).to_string())
}

/// 手动加载镜头配置(文件 content:// / 路径 / JSON / 内置 id)并重算。
fn load_lens(value_in: &str) -> Result<(), String> {
    let mut guard = STAB.lock().unwrap();
    let session = guard.as_mut().ok_or("未载入视频")?;
    let mut value = value_in.to_string();
    if !value.starts_with('{') && !session.manager.lens_profile_db.read().loaded {
        let mut db = session.manager.lens_profile_db.write();
        db.load_all();
        db.prepare_list_for_ui();
    }
    if !value.starts_with('{') && !value.contains("://") && (value.starts_with('/') || value.starts_with('\\')) {
        value = gyroflow_core::filesystem::path_to_url(&value);
    }
    session.manager.load_lens_profile(&value).map_err(|e| e.to_string())?;
    apply_lens_extras(&session.manager); // 卷帘/低通来自镜头档案(对齐官方)
    session.manager.recompute_blocking();
    Ok(())
}

/// 手动加载陀螺/IMU 数据(.gcsv/.csv/.bbl 等, content:// 或路径)并重算。
///
/// `load_all_metadata` 对齐官方 MotionData.qml 的「Load all metadata」勾选框
/// (官方把它作为 is_main_video 传给 load_gyro_data, MotionData.qml:40):
/// - false(官方默认): 只取陀螺/四元数流, 不动镜头档案/fps/卷帘快门;
/// - true: 按主视频完整解析(带入文件内嵌镜头档案、fps 覆盖、卷帘参数)。
fn load_gyro(url_in: &str, load_all_metadata: bool) -> Result<(), String> {
    let mut guard = STAB.lock().unwrap();
    let session = guard.as_mut().ok_or("未载入视频")?;
    let url = if url_in.contains("://") {
        url_in.to_string()
    } else {
        gyroflow_core::filesystem::path_to_url(url_in)
    };
    let mut file = gyroflow_core::filesystem::open_file(&url, false, false).map_err(|e| e.to_string())?;
    let size = file.size;
    session
        .manager
        .load_gyro_data(&mut file, size, &url, load_all_metadata, &Default::default(), |_| (), Arc::new(AtomicBool::new(false)))
        .map_err(|e| e.to_string())?;
    // 相机身份随外挂 gcsv 加载才确定(视频本身无 telemetry, 如 RunCam6) → 按它自动配镜头
    // (对齐官方 controller.rs:822-830 telemetry_loaded → 自动加载镜头; iOS 同款时机)。
    // 仅在当前尚无镜头时尝试, 不覆盖用户手动加载的镜头。
    let has_lens = {
        let l = session.manager.lens.read();
        l.calib_dimension.w > 0 && l.calib_dimension.h > 0
    };
    if !has_lens && autoload_lens_for_camera(&session.manager) {
        apply_lens_extras(&session.manager);
    }
    session.manager.recompute_blocking();
    Ok(())
}

/// 设置整帧粒度的视频/陀螺对齐偏移(单位: 帧, 可负)并重算。
/// 对齐官方 MotionData.qml 的「Frame offset」: 渲染前把视频时间戳整帧平移后再查陀螺。
/// 与毫秒级 gyro offset(set_gyro_offset)是两套独立机制, 可叠加。默认 0。
fn set_frame_offset(frames: i32) -> Result<(), String> {
    let mut guard = STAB.lock().unwrap();
    let session = guard.as_mut().ok_or("未载入视频")?;
    session.manager.set_frame_offset(frames);
    session.manager.recompute_blocking();
    Ok(())
}

/// 开/关防抖(对齐 iOS 的"开启/关闭防抖"按钮)并重算。
fn set_stab_enabled(enabled: bool) -> Result<(), String> {
    let mut guard = STAB.lock().unwrap();
    let session = guard.as_mut().ok_or("未载入视频")?;
    session.manager.set_stab_enabled(enabled);
    session.manager.invalidate_smoothing();
    session.manager.recompute_blocking();
    Ok(())
}

/// 调整陀螺/视频时间偏移(毫秒)并重算。用于消除残留晃动(不同机型偏移不同)。
fn set_gyro_offset(ms: f64) -> Result<(), String> {
    let mut guard = STAB.lock().unwrap();
    let session = guard.as_mut().ok_or("未载入视频")?;
    {
        let mut gyro = session.manager.gyro.write();
        gyro.clear_offsets();
        if ms != 0.0 {
            gyro.set_offset(0, ms);
        }
    }
    session.manager.invalidate_smoothing();
    session.manager.recompute_blocking();
    Ok(())
}


// ───────────────────────── JNI 入口 ─────────────────────────

/// 载入视频(content:// URI 或路径)+ 内嵌陀螺 + 自动镜头 + 配参 + recompute。返回状态串。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeOpenVideo<'local>(
    mut env: EnvUnowned<'local>,
    _class: JClass<'local>,
    uri: JString<'local>,
) -> jstring {
    env.with_env(|env| -> jni::errors::Result<jstring> {
        let url: String = env.get_string(&uri)?.into();
        let msg = match open_video(&url) {
            Ok(s) => s,
            Err(e) => format!("open FAIL: {e}"),
        };
        Ok(env.new_string(msg)?.into_raw())
    })
    .resolve::<ThrowRuntimeExAndDefault>()
}

/// 调整陀螺时间偏移(毫秒)。用于现场微调消除残留晃动。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeSetGyroOffset<'local>(
    mut env: EnvUnowned<'local>,
    _class: JClass<'local>,
    offset_ms: jdouble,
) -> jstring {
    env.with_env(|env| -> jni::errors::Result<jstring> {
        let msg = match set_gyro_offset(offset_ms) {
            Ok(()) => "offset ok".to_string(),
            Err(e) => format!("offset FAIL: {e}"),
        };
        Ok(env.new_string(msg)?.into_raw())
    })
    .resolve::<ThrowRuntimeExAndDefault>()
}

/// 取当前已加载镜头信息(基础 + 高级), 返回 JSON。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeGetLensInfo<'local>(
    mut env: EnvUnowned<'local>,
    _class: JClass<'local>,
) -> jstring {
    env.with_env(|env| -> jni::errors::Result<jstring> {
        let msg = lens_info_full().unwrap_or_else(|_| "{}".to_string());
        Ok(env.new_string(msg)?.into_raw())
    })
    .resolve::<ThrowRuntimeExAndDefault>()
}

/// 取当前镜头档案的 sync_settings(同步参数)JSON。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeGetSyncSettings<'local>(
    mut env: EnvUnowned<'local>,
    _class: JClass<'local>,
) -> jstring {
    env.with_env(|env| -> jni::errors::Result<jstring> {
        Ok(env.new_string(lens_sync_settings())?.into_raw())
    })
    .resolve::<ThrowRuntimeExAndDefault>()
}

/// 水下镜头开关(对齐 iOS, 调整折射系数并重算)。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeSetUnderwater<'local>(
    mut env: EnvUnowned<'local>,
    _class: JClass<'local>,
    on: jboolean,
) -> jstring {
    env.with_env(|env| -> jni::errors::Result<jstring> {
        let msg = match set_underwater(on) {
            Ok(()) => "underwater ok".to_string(),
            Err(e) => format!("underwater FAIL: {e}"),
        };
        Ok(env.new_string(msg)?.into_raw())
    })
    .resolve::<ThrowRuntimeExAndDefault>()
}

// ── 显示检测特征 / 光流覆盖层(对齐官方 controller.show_detected_features / show_optical_flow)──
// 复刻官方 ffi sync_drawing_master_flag: 翻 DRAWING_ENABLED + 必要时分配 drawing canvas。
// 安卓预览走 process_pixels::<RGBA8>(CPU, draw_overlays 路径), 覆盖层能画出来。
fn sync_drawing_master_flag(manager: &StabilizationManager) {
    let any_show = {
        let p = manager.params.read();
        p.show_detected_features || p.show_optical_flow || p.show_safe_area
    };
    let mut stab = manager.stabilization.write();
    stab.kernel_flags.set(gyroflow_core::stabilization::KernelParamsFlags::DRAWING_ENABLED, any_show);
    // wgpu kernel 在创建时就按 DRAWING_ENABLED 定死了 drawing buffer 大小, 只翻标志不重建
    // kernel 不会合成覆盖层。init_size 会 drop wgpu kernel(下帧重建) + 按当前 flag 分配 canvas。
    let sz = stab.size;
    let osz = stab.output_size;
    if sz.0 > 0 && sz.1 > 0 && osz.0 > 0 && osz.1 > 0 {
        stab.init_size(sz, osz);
    }
}

fn set_show_features(show: bool) -> Result<(), String> {
    let guard = STAB.lock().unwrap();
    let s = guard.as_ref().ok_or("未载入视频")?;
    s.manager.set_show_detected_features(show);
    sync_drawing_master_flag(&s.manager);
    Ok(())
}

fn set_show_of(show: bool) -> Result<(), String> {
    let guard = STAB.lock().unwrap();
    let s = guard.as_ref().ok_or("未载入视频")?;
    s.manager.set_show_optical_flow(show);
    sync_drawing_master_flag(&s.manager);
    Ok(())
}

/// 显示/隐藏检测到的特征点覆盖层。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeSetShowDetectedFeatures<'local>(
    mut env: EnvUnowned<'local>,
    _class: JClass<'local>,
    show: jboolean,
) -> jint {
    env.with_env(|_env| -> jni::errors::Result<jint> {
        let _ = set_show_features(show);
        Ok(0)
    })
    .resolve::<ThrowRuntimeExAndDefault>()
}

/// 显示/隐藏光流覆盖层。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeSetShowOpticalFlow<'local>(
    mut env: EnvUnowned<'local>,
    _class: JClass<'local>,
    show: jboolean,
) -> jint {
    env.with_env(|_env| -> jni::errors::Result<jint> {
        let _ = set_show_of(show);
        Ok(0)
    })
    .resolve::<ThrowRuntimeExAndDefault>()
}

// ── 高级模块: 预览分辨率 / 渲染背景 / 背景模式 / 安全区域(对齐桌面 Advanced.qml)──

/// 渲染背景颜色(RGBA, 各通道 0–1)。对齐桌面 set_background_color。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeSetBackgroundColor<'local>(
    mut env: EnvUnowned<'local>, _class: JClass<'local>,
    r: jdouble, g: jdouble, b: jdouble, a: jdouble,
) -> jint {
    env.with_env(|_e| -> jni::errors::Result<jint> {
        stab_apply(|m| m.set_background_color(nalgebra::Vector4::new(r as f32, g as f32, b as f32, a as f32)));
        Ok(0)
    }).resolve::<ThrowRuntimeExAndDefault>()
}

/// 背景填充模式(0=纯色 1=边缘拉伸 2=边缘镜像 3=羽化留边)。对齐桌面 BackgroundMode。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeSetBackgroundMode<'local>(
    mut env: EnvUnowned<'local>, _class: JClass<'local>, mode: jint,
) -> jint {
    env.with_env(|_e| -> jni::errors::Result<jint> {
        stab_apply(|m| m.set_background_mode(mode));
        Ok(0)
    }).resolve::<ThrowRuntimeExAndDefault>()
}

/// 羽化留边: 留边宽度(占比 0.0–0.5, 即桌面 0–50%)。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeSetBackgroundMargin<'local>(
    mut env: EnvUnowned<'local>, _class: JClass<'local>, margin: jdouble,
) -> jint {
    env.with_env(|_e| -> jni::errors::Result<jint> {
        stab_apply(|m| m.set_background_margin(margin));
        Ok(0)
    }).resolve::<ThrowRuntimeExAndDefault>()
}

/// 羽化留边: 羽化宽度(占比 0.0–0.5, 即桌面 0–50%)。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeSetBackgroundMarginFeather<'local>(
    mut env: EnvUnowned<'local>, _class: JClass<'local>, feather: jdouble,
) -> jint {
    env.with_env(|_e| -> jni::errors::Result<jint> {
        stab_apply(|m| m.set_background_margin_feather(feather));
        Ok(0)
    }).resolve::<ThrowRuntimeExAndDefault>()
}

fn set_safe_area_impl(show: bool) -> Result<(), String> {
    let guard = STAB.lock().unwrap();
    let s = guard.as_ref().ok_or("未载入视频")?;
    s.manager.set_show_safe_area(show);
    s.manager.recompute_blocking();      // safe_area_rect 据 compute_params.show_safe_area 每帧算, 需重算
    sync_drawing_master_flag(&s.manager); // 翻 DRAWING_ENABLED(shader 仅在该标志下画覆盖层)
    Ok(())
}

/// 安全区域指示开关(FOV>1 时画出 FOV=1 矩形, 仅视觉提示, 不影响渲染)。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeSetShowSafeArea<'local>(
    mut env: EnvUnowned<'local>, _class: JClass<'local>, show: jboolean,
) -> jint {
    env.with_env(|_e| -> jni::errors::Result<jint> {
        let _ = set_safe_area_impl(show);
        Ok(0)
    }).resolve::<ThrowRuntimeExAndDefault>()
}

fn set_preview_resolution_impl(target_height: i32) -> Result<(), String> {
    let guard = STAB.lock().unwrap();
    let s = guard.as_ref().ok_or("未载入视频")?;
    let (iw, ih) = { let p = s.manager.params.read(); (p.size.0, p.size.1) };
    if iw == 0 || ih == 0 { return Err("无尺寸".into()); }
    // 原始输出: 满宽 + 16:9(同 configure_for_preview)
    let base_ow = (iw & !1).max(2);
    let base_oh = ((iw * 9 / 16) & !1).min(ih & !1).max(2);
    let (ow, oh) = if target_height > 0 && (target_height as usize) < base_oh {
        let scale = base_oh as f64 / target_height as f64;
        (((base_ow as f64 / scale) as usize & !1).max(2),
         ((base_oh as f64 / scale) as usize & !1).max(2))
    } else {
        (base_ow, base_oh) // Full / 目标比原始还大 → 原始
    };
    { let mut p = s.manager.params.write(); p.output_size = (ow, oh); }
    s.manager.init_size();
    s.manager.recompute_blocking();
    Ok(())
}

/// 预览分辨率(目标高度: -1=原始, 否则如 2160/1080/720/480)。降低=处理更快但更糊。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeSetPreviewResolution<'local>(
    mut env: EnvUnowned<'local>, _class: JClass<'local>, target_height: jint,
) -> jint {
    env.with_env(|_e| -> jni::errors::Result<jint> {
        let _ = set_preview_resolution_impl(target_height);
        Ok(0)
    }).resolve::<ThrowRuntimeExAndDefault>()
}

/// 编辑相机矩阵/畸变系数(param + 值)。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeSetLensParam<'local>(
    mut env: EnvUnowned<'local>,
    _class: JClass<'local>,
    param: JString<'local>,
    value: jdouble,
) -> jstring {
    env.with_env(|env| -> jni::errors::Result<jstring> {
        let p: String = env.get_string(&param)?.into();
        let msg = match set_lens_param(&p, value) {
            Ok(()) => "param ok".to_string(),
            Err(e) => format!("param FAIL: {e}"),
        };
        Ok(env.new_string(msg)?.into_raw())
    })
    .resolve::<ThrowRuntimeExAndDefault>()
}

/// 运动数据信息 JSON。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeGetGyroInfo<'local>(
    mut env: EnvUnowned<'local>,
    _class: JClass<'local>,
) -> jstring {
    env.with_env(|env| -> jni::errors::Result<jstring> {
        let msg = gyro_info().unwrap_or_else(|_| "{}".to_string());
        Ok(env.new_string(msg)?.into_raw())
    })
    .resolve::<ThrowRuntimeExAndDefault>()
}

/// 视频内嵌丰富元数据 JSON(相机 + recording_settings 等, 对齐官方视频信息)。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeGetVideoMetadata<'local>(
    mut env: EnvUnowned<'local>,
    _class: JClass<'local>,
) -> jstring {
    env.with_env(|env| -> jni::errors::Result<jstring> {
        let msg = video_metadata().unwrap_or_else(|_| "{}".to_string());
        Ok(env.new_string(msg)?.into_raw())
    })
    .resolve::<ThrowRuntimeExAndDefault>()
}

/// 低通滤波(Hz, 0=关)。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeSetImuLpf<'local>(
    mut env: EnvUnowned<'local>,
    _class: JClass<'local>,
    hz: jdouble,
) -> jstring {
    env.with_env(|env| -> jni::errors::Result<jstring> {
        let msg = match set_gyro_lpf(hz) {
            Ok(()) => "lpf ok".to_string(),
            Err(e) => format!("lpf FAIL: {e}"),
        };
        Ok(env.new_string(msg)?.into_raw())
    })
    .resolve::<ThrowRuntimeExAndDefault>()
}

/// 中值滤波(采样数, 0=关)。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeSetImuMedian<'local>(
    mut env: EnvUnowned<'local>,
    _class: JClass<'local>,
    samples: jint,
) -> jstring {
    env.with_env(|env| -> jni::errors::Result<jstring> {
        let msg = match set_gyro_median(samples) {
            Ok(()) => "median ok".to_string(),
            Err(e) => format!("median FAIL: {e}"),
        };
        Ok(env.new_string(msg)?.into_raw())
    })
    .resolve::<ThrowRuntimeExAndDefault>()
}

/// IMU 旋转(Pitch/Roll/Yaw 度, 全 0=关)。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeSetImuRotation<'local>(
    mut env: EnvUnowned<'local>,
    _class: JClass<'local>,
    pitch: jdouble,
    roll: jdouble,
    yaw: jdouble,
) -> jstring {
    env.with_env(|env| -> jni::errors::Result<jstring> {
        let msg = match set_gyro_rotation(pitch, roll, yaw) {
            Ok(()) => "rot ok".to_string(),
            Err(e) => format!("rot FAIL: {e}"),
        };
        Ok(env.new_string(msg)?.into_raw())
    })
    .resolve::<ThrowRuntimeExAndDefault>()
}

/// 陀螺零偏(X/Y/Z 度/秒, 全 0=关)。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeSetImuBias<'local>(
    mut env: EnvUnowned<'local>,
    _class: JClass<'local>,
    bx: jdouble,
    by: jdouble,
    bz: jdouble,
) -> jstring {
    env.with_env(|env| -> jni::errors::Result<jstring> {
        let msg = match set_gyro_bias(bx, by, bz) {
            Ok(()) => "bias ok".to_string(),
            Err(e) => format!("bias FAIL: {e}"),
        };
        Ok(env.new_string(msg)?.into_raw())
    })
    .resolve::<ThrowRuntimeExAndDefault>()
}

/// IMU 朝向(轴向映射串, 如 "XYZ"/"zYX")。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeSetImuOrientation<'local>(
    mut env: EnvUnowned<'local>,
    _class: JClass<'local>,
    orientation: JString<'local>,
) -> jstring {
    env.with_env(|env| -> jni::errors::Result<jstring> {
        let s: String = env.get_string(&orientation)?.into();
        let msg = match set_gyro_orientation(&s) {
            Ok(()) => "orient ok".to_string(),
            Err(e) => format!("orient FAIL: {e}"),
        };
        Ok(env.new_string(msg)?.into_raw())
    })
    .resolve::<ThrowRuntimeExAndDefault>()
}

/// 陀螺时间轴: 整段视频重采样成 count 个三轴角速度点, 返回 double[count*3](交错 xyz)。空=无数据。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeGyroTimeline<'local>(
    mut env: EnvUnowned<'local>,
    _class: JClass<'local>,
    count: jint,
) -> jni::sys::jdoubleArray {
    env.with_env(|env| -> jni::errors::Result<jni::sys::jdoubleArray> {
        let data = gyro_timeline(count.max(0) as usize).unwrap_or_default();
        let arr = env.new_double_array(data.len())?;
        env.set_double_array_region(&arr, 0, &data)?;
        Ok(arr.into_raw())
    })
    .resolve::<ThrowRuntimeExAndDefault>()
}

/// 四元数时间轴: 整段视频重采样成 count 个点, 返回 double[count*4](交错 xyzw)。
/// 用于 DJI/Xtra 等无原始角速度的源(nativeGyroTimeline 返空时改调本函数)。空=无数据。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeQuaternionTimeline<'local>(
    mut env: EnvUnowned<'local>,
    _class: JClass<'local>,
    count: jint,
) -> jni::sys::jdoubleArray {
    env.with_env(|env| -> jni::errors::Result<jni::sys::jdoubleArray> {
        let data = quaternion_timeline(count.max(0) as usize).unwrap_or_default();
        let arr = env.new_double_array(data.len())?;
        env.set_double_array_region(&arr, 0, &data)?;
        Ok(arr.into_raw())
    })
    .resolve::<ThrowRuntimeExAndDefault>()
}

/// 某时间戳的原始/平滑四元数, 返回 double[8]([q wxyz, sq wxyz])。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeQuatsAtTimestamp<'local>(
    mut env: EnvUnowned<'local>,
    _class: JClass<'local>,
    ts_us: jlong,
) -> jni::sys::jdoubleArray {
    env.with_env(|env| -> jni::errors::Result<jni::sys::jdoubleArray> {
        let q = quats_at_timestamp(ts_us).unwrap_or([0.0; 8]);
        let arr = env.new_double_array(8)?;
        env.set_double_array_region(&arr, 0, &q)?;
        Ok(arr.into_raw())
    })
    .resolve::<ThrowRuntimeExAndDefault>()
}

/// 积分方法(0=None(用四元数)/1=Complementary/2=VQF/3=Simple/4=Simple+accel/5=Mahony/6=Madgwick)。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeSetIntegrationMethod<'local>(
    mut env: EnvUnowned<'local>,
    _class: JClass<'local>,
    index: jint,
) -> jstring {
    env.with_env(|env| -> jni::errors::Result<jstring> {
        let msg = match set_gyro_integration(index.max(0) as u32) {
            Ok(()) => "integ ok".to_string(),
            Err(e) => format!("integ FAIL: {e}"),
        };
        Ok(env.new_string(msg)?.into_raw())
    })
    .resolve::<ThrowRuntimeExAndDefault>()
}

/// 自动同步: 创建 session, 返回各同步点范围 double[](交错 from_ms,to_ms)。失败返回空数组。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeAutosyncStart<'local>(
    mut env: EnvUnowned<'local>,
    _class: JClass<'local>,
    initial_offset_ms: jdouble,
    search_size_sec: jdouble,
    max_sync_points: jint,
    every_nth_frame: jint,
    time_per_syncpoint_sec: jdouble,
    of_method: jint,
    pose_method: jint,
    offset_method: jint,
    calc_initial_fast: jboolean,
    initial_offset_inv: jboolean,
    auto_sync_points: jboolean,
    sync_lpf: jdouble,
) -> jni::sys::jdoubleArray {
    env.with_env(|env| -> jni::errors::Result<jni::sys::jdoubleArray> {
        let ranges = autosync_start(
            initial_offset_ms,
            search_size_sec,
            max_sync_points.max(0) as u32,
            every_nth_frame.max(0) as u32,
            time_per_syncpoint_sec,
            of_method.max(0) as u32,
            pose_method.max(0) as u32,
            offset_method.max(0) as u32,
            calc_initial_fast,
            initial_offset_inv,
            auto_sync_points,
            sync_lpf,
        )
        .unwrap_or_else(|e| {
            log::error!("[autosync] start FAIL: {e}");
            Vec::new()
        });
        let arr = env.new_double_array(ranges.len())?;
        env.set_double_array_region(&arr, 0, &ranges)?;
        Ok(arr.into_raw())
    })
    .resolve::<ThrowRuntimeExAndDefault>()
}

/// 自动同步: 喂一帧灰度(Y 平面紧凑, stride=width)。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeAutosyncFeed<'local>(
    mut env: EnvUnowned<'local>,
    _class: JClass<'local>,
    ts_us: jlong,
    frame_no: jint,
    width: jint,
    height: jint,
    y: JByteArray<'local>,
) -> jint {
    env.with_env(|env| -> jni::errors::Result<jint> {
        let buf = env.convert_byte_array(&y)?;
        autosync_feed(ts_us, frame_no.max(0) as u32, width.max(0) as u32, height.max(0) as u32, &buf);
        Ok(0)
    })
    .resolve::<ThrowRuntimeExAndDefault>()
}

/// 自动同步: 待处理帧数(背压)。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeAutosyncPending<'local>(
    mut env: EnvUnowned<'local>,
    _class: JClass<'local>,
) -> jint {
    env.with_env(|_env| -> jni::errors::Result<jint> { Ok(autosync_pending()) })
        .resolve::<ThrowRuntimeExAndDefault>()
}

/// 自动同步: 进度 0.0–1.0。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeAutosyncProgress<'local>(
    mut env: EnvUnowned<'local>,
    _class: JClass<'local>,
) -> jdouble {
    env.with_env(|_env| -> jni::errors::Result<jdouble> { Ok(autosync_progress()) })
        .resolve::<ThrowRuntimeExAndDefault>()
}

/// 自动同步: 进度三元组 [percent, ready, total](对齐官方 on_progress)。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeAutosyncStat<'local>(
    mut env: EnvUnowned<'local>,
    _class: JClass<'local>,
) -> jni::sys::jdoubleArray {
    env.with_env(|env| -> jni::errors::Result<jni::sys::jdoubleArray> {
        let s = autosync_stat();
        let arr = env.new_double_array(3)?;
        env.set_double_array_region(&arr, 0, &s)?;
        Ok(arr.into_raw())
    })
    .resolve::<ThrowRuntimeExAndDefault>()
}

/// 自动同步: 取消。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeAutosyncCancel<'local>(
    mut env: EnvUnowned<'local>,
    _class: JClass<'local>,
) -> jint {
    env.with_env(|_env| -> jni::errors::Result<jint> {
        autosync_cancel();
        Ok(0)
    })
    .resolve::<ThrowRuntimeExAndDefault>()
}

/// 自动同步: 结束并应用 offset, 返回 JSON {median, points}。失败返回以 "FAIL" 开头的串。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeAutosyncFinish<'local>(
    mut env: EnvUnowned<'local>,
    _class: JClass<'local>,
) -> jstring {
    env.with_env(|env| -> jni::errors::Result<jstring> {
        let msg = autosync_finish().unwrap_or_else(|e| format!("FAIL: {e}"));
        Ok(env.new_string(msg)?.into_raw())
    })
    .resolve::<ThrowRuntimeExAndDefault>()
}

/// 搜索内置镜头库, 返回 JSON [{name,id}]。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeLensSearch<'local>(
    mut env: EnvUnowned<'local>,
    _class: JClass<'local>,
    query: JString<'local>,
) -> jstring {
    env.with_env(|env| -> jni::errors::Result<jstring> {
        let q: String = env.get_string(&query)?.into();
        let msg = lens_search(&q).unwrap_or_else(|_| "[]".to_string());
        Ok(env.new_string(msg)?.into_raw())
    })
    .resolve::<ThrowRuntimeExAndDefault>()
}

/// 当前已加载镜头库版本号(内置库或已安装更新包)。出错默认 0。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeGetLensDbVersion<'local>(
    mut env: EnvUnowned<'local>,
    _class: JClass<'local>,
) -> jint {
    env.with_env(|_env| -> jni::errors::Result<jint> { Ok(lens_db_version()) })
        .resolve::<ThrowRuntimeExAndDefault>()
}

/// 安装下载的 profiles.cbor.gz 字节并热重载镜头库, 返回新版本号; 失败返回 -1。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeInstallLensProfiles<'local>(
    mut env: EnvUnowned<'local>,
    _class: JClass<'local>,
    data: JByteArray<'local>,
) -> jint {
    env.with_env(|env| -> jni::errors::Result<jint> {
        let bytes = env.convert_byte_array(&data)?;
        Ok(install_lens_profiles(&bytes).unwrap_or_else(|e| {
            log::warn!("[lens] install profiles failed: {e}");
            -1
        }))
    })
    .resolve::<ThrowRuntimeExAndDefault>()
}

/// 加载镜头配置文件(content:// / 路径)。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeLoadLens<'local>(
    mut env: EnvUnowned<'local>,
    _class: JClass<'local>,
    uri: JString<'local>,
) -> jstring {
    env.with_env(|env| -> jni::errors::Result<jstring> {
        let url: String = env.get_string(&uri)?.into();
        let msg = match load_lens(&url) {
            Ok(()) => "lens ok".to_string(),
            Err(e) => format!("lens FAIL: {e}"),
        };
        Ok(env.new_string(msg)?.into_raw())
    })
    .resolve::<ThrowRuntimeExAndDefault>()
}

/// 加载陀螺/运动数据文件(content:// / 路径)。load_all_metadata 见 load_gyro。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeLoadGyro<'local>(
    mut env: EnvUnowned<'local>,
    _class: JClass<'local>,
    uri: JString<'local>,
    load_all_metadata: jboolean,
) -> jstring {
    env.with_env(|env| -> jni::errors::Result<jstring> {
        let url: String = env.get_string(&uri)?.into();
        let msg = match load_gyro(&url, load_all_metadata) {
            Ok(()) => "gyro ok".to_string(),
            Err(e) => format!("gyro FAIL: {e}"),
        };
        Ok(env.new_string(msg)?.into_raw())
    })
    .resolve::<ThrowRuntimeExAndDefault>()
}

/// 注册已获 SAF 授权的目录(tree URI)到 gyroflow 文件系统白名单。
/// content:// 单文件 URI 的 get_folder 只能在白名单 tree 里匹配
/// (core/filesystem/mod.rs:232-247) —— 用户授权目录并注册后重载视频,
/// telemetry-parser 的同名 sidecar(gcsv/bbl/bfl/csv)自动加载才能生效。
/// 真实文件路径不需要注册(get_folder 通用分支直接取父目录)。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeFolderAccessGranted<'local>(
    mut env: EnvUnowned<'local>,
    _class: JClass<'local>,
    url: JString<'local>,
) -> jstring {
    env.with_env(|env| -> jni::errors::Result<jstring> {
        let u: String = env.get_string(&url)?.into();
        gyroflow_core::filesystem::folder_access_granted(&u);
        Ok(env.new_string("folder ok")?.into_raw())
    })
    .resolve::<ThrowRuntimeExAndDefault>()
}

/// 设置整帧粒度的视频/陀螺对齐偏移(帧, 可负)。对齐官方「Frame offset」。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeSetFrameOffset<'local>(
    mut env: EnvUnowned<'local>,
    _class: JClass<'local>,
    frames: jint,
) -> jstring {
    env.with_env(|env| -> jni::errors::Result<jstring> {
        let msg = match set_frame_offset(frames) {
            Ok(()) => "frame offset ok".to_string(),
            Err(e) => format!("frame offset FAIL: {e}"),
        };
        Ok(env.new_string(msg)?.into_raw())
    })
    .resolve::<ThrowRuntimeExAndDefault>()
}

/// 开/关防抖。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeSetStabEnabled<'local>(
    mut env: EnvUnowned<'local>,
    _class: JClass<'local>,
    enabled: jboolean,
) -> jstring {
    env.with_env(|env| -> jni::errors::Result<jstring> {
        // 真正的开关在显示层(开=稳定后, 关=原始帧); gyroflow 的 stab_enabled 字段在本 fork 没被消费。
        crate::preview::set_stab_enabled(enabled);
        let _ = set_stab_enabled;
        Ok(env.new_string(format!("stab={enabled}"))?.into_raw())
    })
    .resolve::<ThrowRuntimeExAndDefault>()
}

// ─────────────── 稳定参数 setter / getter(对齐官方 Stabilization 面板)───────────────
fn stab_apply<F: FnOnce(&StabilizationManager)>(f: F) {
    if let Some(s) = STAB.lock().unwrap().as_ref() {
        f(&s.manager);
        s.manager.recompute_blocking();
    }
}

/// 平滑算法(0=无 1=默认 2=Plain 3=Fixed)。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeSetSmoothingMethod<'local>(
    mut env: EnvUnowned<'local>, _class: JClass<'local>, index: jint,
) -> jint {
    env.with_env(|_e| -> jni::errors::Result<jint> {
        stab_apply(|m| { m.set_smoothing_method(index.max(0) as usize); });
        Ok(0)
    }).resolve::<ThrowRuntimeExAndDefault>()
}

/// 平滑参数(smoothness / per_axis / trim_range_only / max_smoothness / alpha_0_1s / smoothness_pitch|yaw|roll)。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeSetSmoothingParam<'local>(
    mut env: EnvUnowned<'local>, _class: JClass<'local>, name: JString<'local>, value: jdouble,
) -> jint {
    env.with_env(|env| -> jni::errors::Result<jint> {
        let n: String = env.get_string(&name)?.into();
        stab_apply(|m| m.set_smoothing_param(&n, value));
        Ok(0)
    }).resolve::<ThrowRuntimeExAndDefault>()
}

/// 锁定地平线 —— 全 9 参,对齐 iOS gyroflow_set_horizon_lock / 桌面 set_horizon_lock:
/// amount %(0=关)、roll 校正°、锁定俯仰 + pitch°、自动锁定 + 转向阈值/平滑 ms/倍数/倾斜加速限制。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeSetHorizonLock<'local>(
    mut env: EnvUnowned<'local>, _class: JClass<'local>,
    amount: jdouble, roll: jdouble,
    lock_pitch: jboolean, pitch: jdouble,
    automatic: jboolean, turn_threshold: jdouble,
    turn_smoothing: jdouble, turn_multiplier: jdouble, tilt_accel_limit: jdouble,
) -> jint {
    env.with_env(|_e| -> jni::errors::Result<jint> {
        stab_apply(|m| m.set_horizon_lock(
            amount, roll,
            lock_pitch, pitch,
            automatic, turn_threshold,
            turn_smoothing, turn_multiplier, tilt_accel_limit,
        ));
        Ok(0)
    }).resolve::<ThrowRuntimeExAndDefault>()
}

/// 缩放速度(自适应缩放窗口, 秒)。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeSetAdaptiveZoom<'local>(
    mut env: EnvUnowned<'local>, _class: JClass<'local>, window: jdouble,
) -> jint {
    env.with_env(|_e| -> jni::errors::Result<jint> {
        stab_apply(|m| m.set_adaptive_zoom(window));
        Ok(0)
    }).resolve::<ThrowRuntimeExAndDefault>()
}

/// 缩放限额(%)+ 迭代次数。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeSetMaxZoom<'local>(
    mut env: EnvUnowned<'local>, _class: JClass<'local>, percent: jdouble, iters: jint,
) -> jint {
    env.with_env(|_e| -> jni::errors::Result<jint> {
        stab_apply(|m| m.set_max_zoom(percent, iters.max(1) as usize));
        Ok(0)
    }).resolve::<ThrowRuntimeExAndDefault>()
}

/// 缩放方式(adaptive_zoom_method)。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeSetZoomingMethod<'local>(
    mut env: EnvUnowned<'local>, _class: JClass<'local>, index: jint,
) -> jint {
    env.with_env(|_e| -> jni::errors::Result<jint> {
        stab_apply(|m| m.set_zooming_method(index.max(0)));
        Ok(0)
    }).resolve::<ThrowRuntimeExAndDefault>()
}

/// 镜头校正(0.0–1.0)。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeSetLensCorrection<'local>(
    mut env: EnvUnowned<'local>, _class: JClass<'local>, amount: jdouble,
) -> jint {
    env.with_env(|_e| -> jni::errors::Result<jint> {
        stab_apply(|m| m.set_lens_correction_amount(amount));
        Ok(0)
    }).resolve::<ThrowRuntimeExAndDefault>()
}

/// 视场角 FOV。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeSetFov<'local>(
    mut env: EnvUnowned<'local>, _class: JClass<'local>, fov: jdouble,
) -> jint {
    env.with_env(|_e| -> jni::errors::Result<jint> {
        stab_apply(|m| m.set_fov(fov));
        Ok(0)
    }).resolve::<ThrowRuntimeExAndDefault>()
}

/// 卷帘快门 帧读出时间(毫秒, 0=关)。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeSetFrameReadoutTime<'local>(
    mut env: EnvUnowned<'local>, _class: JClass<'local>, ms: jdouble,
) -> jint {
    env.with_env(|_e| -> jni::errors::Result<jint> {
        stab_apply(|m| m.set_frame_readout_time(ms));
        Ok(0)
    }).resolve::<ThrowRuntimeExAndDefault>()
}

/// 卷帘快门 帧读出方向(0=上到下 1=下到上 2=左到右 3=右到左, 对齐官方 ReadoutDirection)。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeSetFrameReadoutDirection<'local>(
    mut env: EnvUnowned<'local>, _class: JClass<'local>, dir: jint,
) -> jint {
    env.with_env(|_e| -> jni::errors::Result<jint> {
        stab_apply(|m| m.set_frame_readout_direction(dir as i32));
        Ok(0)
    }).resolve::<ThrowRuntimeExAndDefault>()
}

/// 视频速度(%)+ 三个联动开关(平滑/缩放/缩放限额)。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeSetVideoSpeed<'local>(
    mut env: EnvUnowned<'local>, _class: JClass<'local>,
    speed: jdouble, link_smooth: jboolean, link_zoom: jboolean, link_zoom_limit: jboolean,
) -> jint {
    env.with_env(|_e| -> jni::errors::Result<jint> {
        stab_apply(|m| m.set_video_speed(speed, link_smooth, link_zoom, link_zoom_limit));
        Ok(0)
    }).resolve::<ThrowRuntimeExAndDefault>()
}

/// 附加 3D 旋转(度): pitch / yaw / roll。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeSetAdditionalRotation<'local>(
    mut env: EnvUnowned<'local>, _class: JClass<'local>, pitch: jdouble, yaw: jdouble, roll: jdouble,
) -> jint {
    env.with_env(|_e| -> jni::errors::Result<jint> {
        stab_apply(|m| { m.set_additional_rotation_x(pitch); m.set_additional_rotation_y(yaw); m.set_additional_rotation_z(roll); });
        Ok(0)
    }).resolve::<ThrowRuntimeExAndDefault>()
}

/// 稳定信息: [maxPitch°, maxYaw°, maxRoll°, 最大缩放%]。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeGetStabInfo<'local>(
    mut env: EnvUnowned<'local>, _class: JClass<'local>,
) -> jni::sys::jdoubleArray {
    env.with_env(|env| -> jni::errors::Result<jni::sys::jdoubleArray> {
        let v: [f64; 4] = if let Some(s) = STAB.lock().unwrap().as_ref() {
            let a = s.manager.gyro.read().max_angles;
            [a.0, a.1, a.2, s.manager.get_min_fov() * 100.0]
        } else { [0.0; 4] };
        let arr = env.new_double_array(4)?;
        env.set_double_array_region(&arr, 0, &v)?;
        Ok(arr.into_raw())
    }).resolve::<ThrowRuntimeExAndDefault>()
}

/// 当前帧的 fov(最近一次 process_frame 写入)。左上角 HUD 用 zoom% = 100/fov 显示。
/// 返回 0.0 表示尚未渲染任何帧(调用方应 fallback 到 "--")。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeGetCurrentFov<'local>(
    mut env: EnvUnowned<'local>, _class: JClass<'local>,
) -> jdouble {
    env.with_env(|_env| -> jni::errors::Result<jdouble> {
        Ok(f64::from_bits(CURRENT_FOV.load(Ordering::Relaxed)))
    }).resolve::<ThrowRuntimeExAndDefault>()
}

/// 处理一帧(YUV 三平面紧凑) → 去畸变+稳定 → 显示。返回状态串。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeProcessFrame<'local>(
    mut env: EnvUnowned<'local>,
    _class: JClass<'local>,
    y: JByteArray<'local>,
    u: JByteArray<'local>,
    v: JByteArray<'local>,
    width: jint,
    height: jint,
    timestamp_us: jlong,
) -> jstring {
    env.with_env(|env| -> jni::errors::Result<jstring> {
        let _ = (width, height);
        let yd = env.convert_byte_array(&y)?;
        let ud = env.convert_byte_array(&u)?;
        let vd = env.convert_byte_array(&v)?;
        // ── [draw_diag] 覆盖层诊断(活路径) ──
        {
            use std::sync::atomic::{AtomicU32, Ordering as O};
            static DN: AtomicU32 = AtomicU32::new(0);
            if DN.fetch_add(1, O::Relaxed) % 30 == 0 {
                if let Some(s) = STAB.lock().unwrap().as_ref() {
                    let m = &s.manager;
                    let de = m.stabilization.read().kernel_flags
                        .contains(gyroflow_core::stabilization::KernelParamsFlags::DRAWING_ENABLED);
                    let (sf, sof, size) = { let p = m.params.read(); (p.show_detected_features, p.show_optical_flow, p.size) };
                    let feats = m.get_features_pixels(timestamp_us, size).map(|v| v.len()).unwrap_or(0);
                    let sc = m.pose_estimator.sync_results.try_read().map(|l| l.len()).unwrap_or(usize::MAX);
                    let delta = m.pose_estimator.sync_results.try_read()
                        .and_then(|l| l.keys().min_by_key(|k| (**k - timestamp_us).abs()).copied().map(|k| k - timestamp_us));
                    log::info!("[draw_diag] ACTIVE=process_frame_gpu(undistort.rs 无 overlay 合成) ts={timestamp_us} DRAWING_ENABLED={de} show_feat={sf} show_of={sof} feats@ts={feats} sync_entries={sc} nearest_delta_us={delta:?}");
                }
            }
        }
        // 全 GPU 路径: gyroflow 算每帧变换(CPU) → 我们的 wgpu 设备 undistort + 显示
        let msg = match get_transform(timestamp_us) {
            Some((mut kp, matrices, mesh, dm, drawing)) => {
                // [关键提速] 预览跳过逐像素镜头网格样条(interpolate_mesh)。带"畸变网格"的镜头档案
                // (如此 Sony 视频)每个输出像素要做 ~20 次三次样条求解 → 1080P ~199ms = 唯一卡顿源;
                // 不带网格的镜头(别的视频)走解析模型, 每像素很便宜 → 不卡。预览传空 mesh + 清 512 标志
                // → 着色器跳过它 → 1080P 也不卡。预览畸变略降精度; 导出走 nativeRenderFrameI420 仍用
                // 完整 mesh(全分辨率 + 全精度, 不受影响)。
                {
                    use std::sync::atomic::{AtomicBool, Ordering as O};
                    static L: AtomicBool = AtomicBool::new(false);
                    if !L.swap(true, O::Relaxed) {
                        log::info!("[mesh-skip] 预览跳过镜头网格样条: mesh_len={} flag512={}",
                            mesh.len(), (kp.flags & 512) != 0);
                    }
                }
                kp.flags &= !512;
                let empty_mesh: Vec<f32> = Vec::new();
                match crate::preview::process_frame_gpu(&yd, &ud, &vd, &kp, &matrices, &empty_mesh, &drawing, &dm) {
                    Ok(()) => "frame ok (gpu)".to_string(),
                    Err(e) => format!("frame FAIL: {e}"),
                }
            }
            None => "frame FAIL: 无变换(未载入?)".to_string(),
        };
        Ok(env.new_string(msg)?.into_raw())
    })
    .resolve::<ThrowRuntimeExAndDefault>()
}

// ── 导出(逐帧 readback → Kotlin MediaCodec 编码)──

/// 设输出尺寸(对齐官方 set_output_size): 把 W×H 当**目标比例**, 缩放到源分辨率内并保持比例。
/// 同比例不同分辨率(如 8K 7680×4320 与 1080p)会夹到同一个 output_size → 画面框选一致。
/// 实际输出尺寸用 nativeGetOutputSize 取(导出编码器按实际尺寸配置)。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeSetOutputSize<'local>(
    mut env: EnvUnowned<'local>, _class: JClass<'local>, width: jint, height: jint,
) -> jint {
    env.with_env(|_e| -> jni::errors::Result<jint> {
        if let Some(s) = STAB.lock().unwrap().as_ref() {
            // set_output_size 内部按比例缩放 + init_size; 真变了才重算
            if s.manager.set_output_size(width.max(2) as usize, height.max(2) as usize) {
                s.manager.recompute_blocking();
            }
        }
        Ok(0)
    }).resolve::<ThrowRuntimeExAndDefault>()
}

/// 设精确输出尺寸(导出用): 直接按 W×H 设 output_size(可大于源, 即上采样)。
/// 取景与缩放版一致(gyroflow 投影随 output_size 同比例缩放); 故 8K 出真 8K, 画面取景不变。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeSetOutputSizeExact<'local>(
    mut env: EnvUnowned<'local>, _class: JClass<'local>, width: jint, height: jint,
) -> jint {
    env.with_env(|_e| -> jni::errors::Result<jint> {
        if let Some(s) = STAB.lock().unwrap().as_ref() {
            let w = (width.max(2) as usize) & !1;
            let h = (height.max(2) as usize) & !1;
            { let mut p = s.manager.params.write(); p.output_size = (w, h); }
            s.manager.init_size();
            s.manager.recompute_blocking();
        }
        Ok(0)
    }).resolve::<ThrowRuntimeExAndDefault>()
}

/// 导出目标分辨率: 回读时把稳定输出(夹后, 取景固定)放大到此分辨率(对齐官方)。w/h<=0 关闭。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeSetExportTarget<'local>(
    mut env: EnvUnowned<'local>, _class: JClass<'local>, width: jint, height: jint,
) -> jint {
    env.with_env(|_e| -> jni::errors::Result<jint> {
        let o = std::sync::atomic::Ordering::Relaxed;
        crate::preview::EXPORT_TARGET_W.store(width.max(0) as u32, o);
        crate::preview::EXPORT_TARGET_H.store(height.max(0) as u32, o);
        Ok(0)
    }).resolve::<ThrowRuntimeExAndDefault>()
}

/// 导出模式开关: 开启后 process_frame_gpu 只渲染 out_tex 供回读, 不上屏(预览不随导出"动" + 更快)。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeSetExportMode<'local>(
    mut env: EnvUnowned<'local>, _class: JClass<'local>, on: jboolean,
) -> jint {
    env.with_env(|_e| -> jni::errors::Result<jint> {
        crate::preview::EXPORT_MODE.store(on, std::sync::atomic::Ordering::Relaxed);
        Ok(0)
    }).resolve::<ThrowRuntimeExAndDefault>()
}

/// 当前实际输出尺寸 [w, h](经 set_output_size 缩放后的真实值)。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeGetOutputSize<'local>(
    mut env: EnvUnowned<'local>, _class: JClass<'local>,
) -> jni::sys::jintArray {
    env.with_env(|env| -> jni::errors::Result<jni::sys::jintArray> {
        let v: [i32; 2] = if let Some(s) = STAB.lock().unwrap().as_ref() {
            let p = s.manager.params.read();
            [p.output_size.0 as i32, p.output_size.1 as i32]
        } else { [0, 0] };
        let arr = env.new_int_array(2)?;
        env.set_int_array_region(&arr, 0, &v)?;
        Ok(arr.into_raw())
    }).resolve::<ThrowRuntimeExAndDefault>()
}

/// 导出逐帧: 输入 YUV(紧凑三平面) → 去畸变+稳定 → 回读稳定输出为 I420 字节返回。
/// I420 尺寸 = 当前 output_size(用 nativeGetOutputSize 取实际值)。空数组=失败。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeRenderFrameI420<'local>(
    mut env: EnvUnowned<'local>, _class: JClass<'local>,
    y: JByteArray<'local>, u: JByteArray<'local>, v: JByteArray<'local>,
    width: jint, height: jint, timestamp_us: jlong,
) -> jni::sys::jbyteArray {
    let _ = (width, height);
    env.with_env(|env| -> jni::errors::Result<jni::sys::jbyteArray> {
        let yd = env.convert_byte_array(&y)?;
        let ud = env.convert_byte_array(&u)?;
        let vd = env.convert_byte_array(&v)?;
        use std::time::Instant;
        use std::sync::atomic::AtomicU64;
        static T_TR: AtomicU64 = AtomicU64::new(0);   // get_transform 累计 us
        static T_GPU: AtomicU64 = AtomicU64::new(0);  // process_frame_gpu 累计 us
        static T_RB: AtomicU64 = AtomicU64::new(0);   // 回读累计 us
        static N: AtomicU64 = AtomicU64::new(0);

        let t0 = Instant::now();
        let tr = get_transform(timestamp_us);
        let t1 = Instant::now();
        if let Some((mut kp, matrices, _mesh, dm, drawing)) = tr {
            // [关键提速] 导出同样跳过逐像素镜头网格样条(interpolate_mesh)。带"畸变网格"的镜头档案
            // (如此 Sony 视频)每个输出像素要做 GRID_SIZE=9 的二元三次样条求解; 导出跑在用户选的全
            // 分辨率(最高 8K)→ 逐像素全跑 = 导出超级慢的唯一来源。预览已清 512 + 传空 mesh, 这里对齐:
            // 清 512 标志 + 传空 mesh → 着色器跳过它 → 导出贴到 GPU 吞吐而非每像素样条。代价: 镜头畸变
            // 校正略降精度(仅丢网格的细微修正, 解析模型仍保留), 与预览观感一致。
            kp.flags &= !512;
            let empty_mesh: Vec<f32> = Vec::new();
            let _ = crate::preview::process_frame_gpu(&yd, &ud, &vd, &kp, &matrices, &empty_mesh, &drawing, &dm);
        }
        let t2 = Instant::now();
        // 流水线回读:返回的是**上一帧**的 I420(首帧为空);收尾用 nativeRenderFlushI420 取最后一帧。
        let bytes = crate::preview::readback_pipelined().map(|(_, _, b)| b).unwrap_or_default();
        let t3 = Instant::now();

        let o = Ordering::Relaxed;
        T_TR.fetch_add((t1 - t0).as_micros() as u64, o);
        T_GPU.fetch_add((t2 - t1).as_micros() as u64, o);
        T_RB.fetch_add((t3 - t2).as_micros() as u64, o);
        let n = N.fetch_add(1, o) + 1;
        if n % 60 == 0 {
            log::info!("[export native] avg ms/帧: transform={:.1} gpu={:.1} readback={:.1}",
                T_TR.load(o) as f64 / n as f64 / 1000.0,
                T_GPU.load(o) as f64 / n as f64 / 1000.0,
                T_RB.load(o) as f64 / n as f64 / 1000.0);
        }
        Ok(env.byte_array_from_slice(&bytes)?.into_raw())
    }).resolve::<ThrowRuntimeExAndDefault>()
}

/// 导出收尾:排空流水线滞留的最后一帧,返回其 I420(无则空数组)。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeRenderFlushI420<'local>(
    mut env: EnvUnowned<'local>, _class: JClass<'local>,
) -> jni::sys::jbyteArray {
    env.with_env(|env| -> jni::errors::Result<jni::sys::jbyteArray> {
        let bytes = crate::preview::readback_flush().map(|(_, _, b)| b).unwrap_or_default();
        Ok(env.byte_array_from_slice(&bytes)?.into_raw())
    }).resolve::<ThrowRuntimeExAndDefault>()
}
