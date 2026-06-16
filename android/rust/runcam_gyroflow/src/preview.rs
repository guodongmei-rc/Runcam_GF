// 阶段 2: GPU 预览 —— native wgpu(Vulkan)渲染到 Android SurfaceView。
//
// 2a: 清屏纯色(验证 wgpu→屏幕)。 ✅
// 2b: MediaCodec 解码出 YUV_420_888 帧 → 上传 GPU → shader YUV→RGB → 显示。
//     (路径 B: 解码后上传,非零拷贝;接口给 2c 仍是 wgpu 纹理,可后续换零拷贝)
//
// 对齐 iOS: iOS 用 MDK→Metal 纹理→MTKView;安卓用 解码→上传→wgpu→SurfaceView。

use jni::EnvUnowned;
use jni::errors::ThrowRuntimeExAndDefault;
use jni::objects::{JByteArray, JClass, JObject};
use jni::sys::{jint, jstring};
use raw_window_handle::{
    AndroidDisplayHandle, AndroidNdkWindowHandle, RawDisplayHandle, RawWindowHandle,
};
use std::ptr::NonNull;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};

/// 防抖开关(对齐 iOS): true=显示稳定后帧, false=显示原始解码帧。
pub(crate) static STAB_ENABLED: AtomicBool = AtomicBool::new(true);
pub(crate) fn set_stab_enabled(e: bool) {
    STAB_ENABLED.store(e, Ordering::Relaxed);
}

/// 导出模式: true 时 process_frame_gpu 跳过上屏(只渲染到 out_tex 供回读), 预览不再随导出"动"且更快。
pub(crate) static EXPORT_MODE: AtomicBool = AtomicBool::new(false);

/// 导出目标分辨率(>0 生效): 回读时 GPU 把稳定输出(夹后尺寸, 取景固定)Linear 放大到此分辨率。
/// 对齐官方: 稳定按夹后尺寸算固定取景, 再放大到用户选的尺寸(如 8K)编码。0=用稳定尺寸。
pub(crate) static EXPORT_TARGET_W: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
pub(crate) static EXPORT_TARGET_H: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);

// ───────────────────────── YUV → RGB 着色器 ─────────────────────────
const YUV_SHADER: &str = r#"
struct VsOut { @builtin(position) pos: vec4<f32>, @location(0) uv: vec2<f32> };
@vertex
fn vs(@builtin(vertex_index) vid: u32) -> VsOut {
    var p = array<vec2<f32>, 3>(vec2<f32>(-1.0, -1.0), vec2<f32>(3.0, -1.0), vec2<f32>(-1.0, 3.0));
    let xy = p[vid];
    var o: VsOut;
    o.pos = vec4<f32>(xy, 0.0, 1.0);
    o.uv = vec2<f32>((xy.x + 1.0) * 0.5, (1.0 - xy.y) * 0.5);
    return o;
}
@group(0) @binding(0) var samp: sampler;
@group(0) @binding(1) var texY: texture_2d<f32>;
@group(0) @binding(2) var texU: texture_2d<f32>;
@group(0) @binding(3) var texV: texture_2d<f32>;
@fragment
fn fs(in: VsOut) -> @location(0) vec4<f32> {
    // Limited range(视频通常 16-235 / 16-240)+ BT.709(HD), 避免发白
    let y = (textureSample(texY, samp, in.uv).r - 0.0627451) * 1.164384;
    let u = (textureSample(texU, samp, in.uv).r - 0.5) * 1.138393;
    let v = (textureSample(texV, samp, in.uv).r - 0.5) * 1.138393;
    let r = y + 1.5748 * v;
    let g = y - 0.187324 * u - 0.468124 * v;
    let b = y + 1.8556 * u;
    return vec4<f32>(r, g, b, 1.0);
}
"#;

struct YuvRenderer {
    pipeline: wgpu::RenderPipeline,
    bgl: wgpu::BindGroupLayout,
    sampler: wgpu::Sampler,
}

fn tex_entry(binding: u32) -> wgpu::BindGroupLayoutEntry {
    wgpu::BindGroupLayoutEntry {
        binding,
        visibility: wgpu::ShaderStages::FRAGMENT,
        ty: wgpu::BindingType::Texture {
            sample_type: wgpu::TextureSampleType::Float { filterable: true },
            view_dimension: wgpu::TextureViewDimension::D2,
            multisampled: false,
        },
        count: None,
    }
}

impl YuvRenderer {
    fn new(device: &wgpu::Device, format: wgpu::TextureFormat) -> Self {
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("yuv"),
            source: wgpu::ShaderSource::Wgsl(YUV_SHADER.into()),
        });
        let bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("yuv-bgl"),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                    count: None,
                },
                tex_entry(1),
                tex_entry(2),
                tex_entry(3),
            ],
        });
        let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("yuv-pl"),
            bind_group_layouts: &[Some(&bgl)],
            immediate_size: 0,
        });
        let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("yuv-pipe"),
            layout: Some(&layout),
            vertex: wgpu::VertexState {
                module: &shader,
                entry_point: Some("vs"),
                buffers: &[],
                compilation_options: Default::default(),
            },
            fragment: Some(wgpu::FragmentState {
                module: &shader,
                entry_point: Some("fs"),
                targets: &[Some(wgpu::ColorTargetState {
                    format,
                    blend: None,
                    write_mask: wgpu::ColorWrites::ALL,
                })],
                compilation_options: Default::default(),
            }),
            primitive: wgpu::PrimitiveState::default(),
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            multiview_mask: None,
            cache: None,
        });
        let sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("yuv-samp"),
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            ..Default::default()
        });
        Self { pipeline, bgl, sampler }
    }
}

// 当前帧的三平面纹理 + 绑定组(尺寸变化时重建)
struct YuvFrame {
    w: u32,
    h: u32,
    y: wgpu::Texture,
    u: wgpu::Texture,
    v: wgpu::Texture,
    bind_group: wgpu::BindGroup,
}

fn make_plane(device: &wgpu::Device, w: u32, h: u32, label: &str) -> wgpu::Texture {
    device.create_texture(&wgpu::TextureDescriptor {
        label: Some(label),
        size: wgpu::Extent3d { width: w.max(1), height: h.max(1), depth_or_array_layers: 1 },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: wgpu::TextureFormat::R8Unorm,
        usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
        view_formats: &[],
    })
}

impl YuvFrame {
    fn new(device: &wgpu::Device, yuv: &YuvRenderer, w: u32, h: u32) -> Self {
        let cw = (w + 1) / 2;
        let ch = (h + 1) / 2;
        let y = make_plane(device, w, h, "Y");
        let u = make_plane(device, cw, ch, "U");
        let v = make_plane(device, cw, ch, "V");
        let dv = wgpu::TextureViewDescriptor::default();
        let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("yuv-bg"),
            layout: &yuv.bgl,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::Sampler(&yuv.sampler) },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&y.create_view(&dv)) },
                wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::TextureView(&u.create_view(&dv)) },
                wgpu::BindGroupEntry { binding: 3, resource: wgpu::BindingResource::TextureView(&v.create_view(&dv)) },
            ],
        });
        Self { w, h, y, u, v, bind_group }
    }
}

// ───────────────────────── RGBA 显示(2c: 显示稳定后的帧) ─────────────────────────
const RGBA_SHADER: &str = r#"
struct VsOut { @builtin(position) pos: vec4<f32>, @location(0) uv: vec2<f32> };
@vertex
fn vs(@builtin(vertex_index) vid: u32) -> VsOut {
    var p = array<vec2<f32>, 3>(vec2<f32>(-1.0, -1.0), vec2<f32>(3.0, -1.0), vec2<f32>(-1.0, 3.0));
    let xy = p[vid];
    var o: VsOut;
    o.pos = vec4<f32>(xy, 0.0, 1.0);
    o.uv = vec2<f32>((xy.x + 1.0) * 0.5, (1.0 - xy.y) * 0.5);
    return o;
}
@group(0) @binding(0) var samp: sampler;
@group(0) @binding(1) var tex: texture_2d<f32>;
@fragment
fn fs(in: VsOut) -> @location(0) vec4<f32> { return textureSample(tex, samp, in.uv); }
"#;

struct RgbaRenderer {
    pipeline: wgpu::RenderPipeline,
    bgl: wgpu::BindGroupLayout,
    sampler: wgpu::Sampler,
}

impl RgbaRenderer {
    fn new(device: &wgpu::Device, format: wgpu::TextureFormat) -> Self {
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("rgba"),
            source: wgpu::ShaderSource::Wgsl(RGBA_SHADER.into()),
        });
        let bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("rgba-bgl"),
            entries: &[
                wgpu::BindGroupLayoutEntry { binding: 0, visibility: wgpu::ShaderStages::FRAGMENT, ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering), count: None },
                tex_entry(1),
            ],
        });
        let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("rgba-pl"),
            bind_group_layouts: &[Some(&bgl)],
            immediate_size: 0,
        });
        let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("rgba-pipe"),
            layout: Some(&layout),
            vertex: wgpu::VertexState { module: &shader, entry_point: Some("vs"), buffers: &[], compilation_options: Default::default() },
            fragment: Some(wgpu::FragmentState { module: &shader, entry_point: Some("fs"), targets: &[Some(wgpu::ColorTargetState { format, blend: None, write_mask: wgpu::ColorWrites::ALL })], compilation_options: Default::default() }),
            primitive: wgpu::PrimitiveState::default(),
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            multiview_mask: None,
            cache: None,
        });
        let sampler = device.create_sampler(&wgpu::SamplerDescriptor { label: Some("rgba-samp"), mag_filter: wgpu::FilterMode::Linear, min_filter: wgpu::FilterMode::Linear, ..Default::default() });
        Self { pipeline, bgl, sampler }
    }
}

struct RgbaFrame {
    w: u32,
    h: u32,
    tex: wgpu::Texture,
    bind_group: wgpu::BindGroup,
}
impl RgbaFrame {
    fn new(device: &wgpu::Device, r: &RgbaRenderer, w: u32, h: u32) -> Self {
        let tex = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("rgba-tex"),
            size: wgpu::Extent3d { width: w.max(1), height: h.max(1), depth_or_array_layers: 1 },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba8Unorm,
            usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
            view_formats: &[],
        });
        let view = tex.create_view(&wgpu::TextureViewDescriptor::default());
        let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("rgba-bg"),
            layout: &r.bgl,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::Sampler(&r.sampler) },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&view) },
            ],
        });
        Self { w, h, tex, bind_group }
    }
}

struct PreviewState {
    _window: ndk::native_window::NativeWindow,
    surface: wgpu::Surface<'static>,
    device: wgpu::Device,
    queue: wgpu::Queue,
    config: wgpu::SurfaceConfiguration,
    yuv: YuvRenderer,
    frame: Option<YuvFrame>,
    rgba: RgbaRenderer,
    rgba_frame: Option<RgbaFrame>,
    // —— 方案 B: 全 GPU undistort 管线 ——
    undistort: Option<crate::undistort::Undistorter>,
    in_tex: Option<(u32, u32, wgpu::Texture)>,  // 解码帧 YUV→RGBA 后的全分辨率输入纹理
    out_tex: Option<(u32, u32, wgpu::Texture)>, // undistort 输出纹理
    // 导出: GPU 上把 out_tex(RGBA)转 YUV 再回读(对齐官方"GPU 原生 YUV", 免 CPU 逐像素转换)
    yuv_conv: Option<YuvConverter>,
    y_tex: Option<(u32, u32, wgpu::Texture)>,   // 亮度平面 R8(全分辨率)
    uv_tex: Option<(u32, u32, wgpu::Texture)>,  // 色度平面 RG8(半分辨率)
}
// 预览调用均来自 Activity 的回调(单线程)。NativeWindow 非 Send,这里手动声明。
unsafe impl Send for PreviewState {}

static PREVIEW: Mutex<Option<PreviewState>> = Mutex::new(None);

fn setup(window: ndk::native_window::NativeWindow, width: u32, height: u32) -> Result<PreviewState, String> {
    let mut idesc = wgpu::InstanceDescriptor::new_without_display_handle();
    idesc.backends = wgpu::Backends::VULKAN;
    let instance = wgpu::Instance::new(idesc);

    let raw_window = RawWindowHandle::AndroidNdk(AndroidNdkWindowHandle::new(
        NonNull::new(window.ptr().as_ptr() as *mut _).ok_or("null ANativeWindow")?,
    ));
    let raw_display = RawDisplayHandle::Android(AndroidDisplayHandle::new());

    let surface = unsafe {
        instance.create_surface_unsafe(wgpu::SurfaceTargetUnsafe::RawHandle {
            raw_display_handle: Some(raw_display),
            raw_window_handle: raw_window,
        })
    }
    .map_err(|e| format!("create_surface: {e}"))?;

    let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
        power_preference: wgpu::PowerPreference::HighPerformance,
        compatible_surface: Some(&surface),
        force_fallback_adapter: false,
    }))
    .map_err(|e| format!("request_adapter: {e}"))?;

    let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor::default()))
        .map_err(|e| format!("request_device: {e}"))?;

    let caps = surface.get_capabilities(&adapter);
    // 选非 sRGB 格式: 我们的像素已是 sRGB 编码值, sRGB surface 会二次 gamma → 发白
    let format = caps.formats.iter().copied().find(|f| !f.is_srgb()).unwrap_or(caps.formats[0]);
    let config = wgpu::SurfaceConfiguration {
        usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
        format,
        width: width.max(1),
        height: height.max(1),
        present_mode: wgpu::PresentMode::Fifo,
        alpha_mode: caps.alpha_modes[0],
        view_formats: vec![],
        desired_maximum_frame_latency: 2,
    };
    surface.configure(&device, &config);

    // YUV 渲染目标为 Rgba8Unorm(undistort 的输入纹理); RGBA 渲染目标为 surface 格式(最终显示)
    let yuv = YuvRenderer::new(&device, wgpu::TextureFormat::Rgba8Unorm);
    let rgba = RgbaRenderer::new(&device, format);

    Ok(PreviewState {
        _window: window, surface, device, queue, config,
        yuv, frame: None, rgba, rgba_frame: None,
        undistort: None, in_tex: None, out_tex: None,
        yuv_conv: None, y_tex: None, uv_tex: None,
    })
}

fn acquire(surface: &wgpu::Surface<'static>) -> Result<wgpu::SurfaceTexture, String> {
    match surface.get_current_texture() {
        wgpu::CurrentSurfaceTexture::Success(t) | wgpu::CurrentSurfaceTexture::Suboptimal(t) => Ok(t),
        other => Err(format!("get_current_texture: {other:?}")),
    }
}

// 清屏(2a 路径, 无帧时)
fn render_clear(state: &PreviewState) -> Result<(), String> {
    let frame = acquire(&state.surface)?;
    let view = frame.texture.create_view(&wgpu::TextureViewDescriptor::default());
    let mut encoder = state.device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("clear") });
    {
        let _pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("clear"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: &view,
                resolve_target: None,
                depth_slice: None,
                ops: wgpu::Operations {
                    load: wgpu::LoadOp::Clear(wgpu::Color::BLACK),
                    store: wgpu::StoreOp::Store,
                },
            })],
            depth_stencil_attachment: None,
            timestamp_writes: None,
            occlusion_query_set: None,
            multiview_mask: None,
        });
    }
    state.queue.submit(Some(encoder.finish()));
    frame.present();
    Ok(())
}


fn write_plane(queue: &wgpu::Queue, tex: &wgpu::Texture, data: &[u8], w: u32, h: u32) {
    queue.write_texture(
        wgpu::TexelCopyTextureInfo { texture: tex, mip_level: 0, origin: wgpu::Origin3d::ZERO, aspect: wgpu::TextureAspect::All },
        data,
        wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(w), rows_per_image: Some(h) },
        wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
    );
}

fn ensure_rgba_tex(opt: &mut Option<(u32, u32, wgpu::Texture)>, device: &wgpu::Device, w: u32, h: u32, label: &str) {
    if opt.as_ref().map(|t| t.0 != w || t.1 != h).unwrap_or(true) {
        let t = device.create_texture(&wgpu::TextureDescriptor {
            label: Some(label),
            size: wgpu::Extent3d { width: w.max(1), height: h.max(1), depth_or_array_layers: 1 },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba8Unorm,
            // COPY_SRC: 导出时把稳定输出(out_tex)回读到 CPU(readback_output_i420)。
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_SRC,
            view_formats: &[],
        });
        *opt = Some((w, h, t));
    }
}

/// 全 GPU 一帧: YUV→RGBA(in_tex) → gyroflow undistort(out_tex) → 显示。全程我们的 wgpu 设备。
pub(crate) fn process_frame_gpu(
    y: &[u8], u: &[u8], v: &[u8],
    kp: &gyroflow_core::stabilization::KernelParams,
    matrices: &[[f32; 14]],
    mesh: &[f32],
    drawing: &[u8],
    dm: &str,
) -> Result<(), String> {
    let mut guard = PREVIEW.lock().unwrap();
    let state = guard.as_mut().ok_or("无预览状态(先创建 surface)")?;

    let iw = kp.width.max(1) as u32;
    let ih = kp.height.max(1) as u32;
    let ow = kp.output_width.max(1) as u32;
    let oh = kp.output_height.max(1) as u32;
    let cw = (iw + 1) / 2;
    let ch = (ih + 1) / 2;

    // 资源(尺寸变化时重建)
    if state.frame.as_ref().map(|f| f.w != iw || f.h != ih).unwrap_or(true) {
        state.frame = Some(YuvFrame::new(&state.device, &state.yuv, iw, ih));
    }
    ensure_rgba_tex(&mut state.in_tex, &state.device, iw, ih, "in_tex");
    ensure_rgba_tex(&mut state.out_tex, &state.device, ow, oh, "out_tex");
    // flags 变化(尤其 DRAWING_ENABLED 位 8)时必须重建管线 —— shader 的 flags 是管线常量(@id103)。
    if state.undistort.as_ref().map(|ud| ud.flags != kp.flags).unwrap_or(true) {
        state.undistort = Some(crate::undistort::Undistorter::new(&state.device, wgpu::TextureFormat::Rgba8Unorm, dm, kp));
    }

    // 上传 YUV 平面到 GPU
    {
        let f = state.frame.as_ref().unwrap();
        write_plane(&state.queue, &f.y, y, iw, ih);
        write_plane(&state.queue, &f.u, u, cw, ch);
        write_plane(&state.queue, &f.v, v, cw, ch);
    }

    let stab_on = STAB_ENABLED.load(Ordering::Relaxed);
    let in_view = state.in_tex.as_ref().unwrap().2.create_view(&wgpu::TextureViewDescriptor::default());
    let out_view = state.out_tex.as_ref().unwrap().2.create_view(&wgpu::TextureViewDescriptor::default());
    // 显示源: 开防抖→稳定后 out_tex; 关防抖→原始 in_tex(对齐 iOS"原始画面")
    let (disp_view, dw, dh) = if stab_on { (&out_view, ow, oh) } else { (&in_view, iw, ih) };
    let disp_bg = state.device.create_bind_group(&wgpu::BindGroupDescriptor {
        label: Some("disp-bg"),
        layout: &state.rgba.bgl,
        entries: &[
            wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::Sampler(&state.rgba.sampler) },
            wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(disp_view) },
        ],
    });

    let mut encoder = state.device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("gpu") });

    // pass1: YUV → in_tex(全分辨率 RGBA)
    {
        let f = state.frame.as_ref().unwrap();
        let mut p = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("yuv2rgba"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: &in_view, resolve_target: None, depth_slice: None,
                ops: wgpu::Operations { load: wgpu::LoadOp::Clear(wgpu::Color::BLACK), store: wgpu::StoreOp::Store },
            })],
            depth_stencil_attachment: None, timestamp_writes: None, occlusion_query_set: None, multiview_mask: None,
        });
        p.set_pipeline(&state.yuv.pipeline);
        p.set_bind_group(0, &f.bind_group, &[]);
        p.draw(0..3, 0..1);
    }

    // pass2: undistort in_tex → out_tex(仅开防抖时)
    if stab_on {
        state.undistort.as_ref().unwrap().render(&state.device, &state.queue, &mut encoder, kp, matrices, mesh, drawing, &in_view, &out_view);
    }

    // 导出模式: 只渲染 out_tex(供回读), 跳过上屏 —— 预览不随导出"动", 且省掉每帧 acquire/present。
    if EXPORT_MODE.load(Ordering::Relaxed) {
        state.queue.submit(Some(encoder.finish()));
        return Ok(());
    }

    // pass3: 显示源 → surface(letterbox, 按显示源比例)
    let surf = acquire(&state.surface)?;
    let surf_view = surf.texture.create_view(&wgpu::TextureViewDescriptor::default());
    let sw = state.config.width as f32;
    let sh = state.config.height as f32;
    let fa = dw as f32 / dh as f32;
    let sa = sw / sh;
    let (vw, vh) = if fa > sa { (sw, sw / fa) } else { (sh * fa, sh) };
    let vx = (sw - vw) * 0.5;
    let vy = (sh - vh) * 0.5;
    {
        let mut p = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("disp"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: &surf_view, resolve_target: None, depth_slice: None,
                ops: wgpu::Operations { load: wgpu::LoadOp::Clear(wgpu::Color::BLACK), store: wgpu::StoreOp::Store },
            })],
            depth_stencil_attachment: None, timestamp_writes: None, occlusion_query_set: None, multiview_mask: None,
        });
        p.set_viewport(vx, vy, vw, vh, 0.0, 1.0);
        p.set_pipeline(&state.rgba.pipeline);
        p.set_bind_group(0, &disp_bg, &[]);
        p.draw(0..3, 0..1);
    }

    state.queue.submit(Some(encoder.finish()));
    surf.present();
    Ok(())
}

// ───────────────────────── JNI 入口 ─────────────────────────

/// SurfaceView 就绪: 建 wgpu 设备 + 配置 + 清屏一帧。返回状态串。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativePreviewSurfaceCreated<'local>(
    mut env: EnvUnowned<'local>,
    _class: JClass<'local>,
    surface: JObject<'local>,
    width: jint,
    height: jint,
) -> jstring {
    env.with_env(|env| -> jni::errors::Result<jstring> {
        let env_raw = env.get_raw();
        let result = (|| -> Result<(), String> {
            let window = unsafe {
                ndk::native_window::NativeWindow::from_surface(env_raw.cast(), surface.as_raw().cast())
            }
            .ok_or("ANativeWindow_fromSurface 返回 None")?;
            let state = setup(window, width as u32, height as u32)?;
            render_clear(&state)?;
            *PREVIEW.lock().unwrap() = Some(state);
            Ok(())
        })();
        let msg = match result {
            Ok(()) => "preview ok (clear)".to_string(),
            Err(e) => format!("preview FAIL: {e}"),
        };
        Ok(env.new_string(msg)?.into_raw())
    })
    .resolve::<ThrowRuntimeExAndDefault>()
}

/// SurfaceView 销毁。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativePreviewSurfaceDestroyed<'local>(
    _env: EnvUnowned<'local>,
    _class: JClass<'local>,
) {
    *PREVIEW.lock().unwrap() = None;
}

// ── 导出: GPU 把 out_tex(RGBA) 转 YUV(对齐官方"GPU 原生 YUV", 免 CPU 逐像素转换)──
const YUV_CONV_SHADER: &str = r#"
struct VsOut { @builtin(position) pos: vec4<f32>, @location(0) uv: vec2<f32> };
@vertex
fn vs(@builtin(vertex_index) vid: u32) -> VsOut {
    var p = array<vec2<f32>, 3>(vec2<f32>(-1.0,-1.0), vec2<f32>(3.0,-1.0), vec2<f32>(-1.0,3.0));
    let xy = p[vid];
    var o: VsOut;
    o.pos = vec4<f32>(xy, 0.0, 1.0);
    o.uv = vec2<f32>((xy.x + 1.0) * 0.5, (1.0 - xy.y) * 0.5);
    return o;
}
@group(0) @binding(0) var samp: sampler;
@group(0) @binding(1) var tex: texture_2d<f32>;
// BT.601 limited(与预览 YUV→RGB 互逆): 16/255=0.0627451, 128/255=0.5019608
@fragment
fn fs_y(in: VsOut) -> @location(0) f32 {
    let c = textureSample(tex, samp, in.uv).rgb;
    return 0.257*c.r + 0.504*c.g + 0.098*c.b + 0.0627451;
}
@fragment
fn fs_uv(in: VsOut) -> @location(0) vec2<f32> {
    let c = textureSample(tex, samp, in.uv).rgb;   // 半分辨率 + Linear 采样 → 2x2 平均(色度下采样)
    let u = -0.148*c.r - 0.291*c.g + 0.439*c.b + 0.5019608;
    let v =  0.439*c.r - 0.368*c.g - 0.071*c.b + 0.5019608;
    return vec2<f32>(u, v);
}
"#;

struct YuvConverter {
    y_pipeline: wgpu::RenderPipeline,
    uv_pipeline: wgpu::RenderPipeline,
    bgl: wgpu::BindGroupLayout,
    sampler: wgpu::Sampler,
}
impl YuvConverter {
    fn new(device: &wgpu::Device) -> Self {
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("yuv-conv"), source: wgpu::ShaderSource::Wgsl(YUV_CONV_SHADER.into()),
        });
        let bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("yuv-conv-bgl"),
            entries: &[
                wgpu::BindGroupLayoutEntry { binding: 0, visibility: wgpu::ShaderStages::FRAGMENT, ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering), count: None },
                tex_entry(1),
            ],
        });
        let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("yuv-conv-pl"), bind_group_layouts: &[Some(&bgl)], immediate_size: 0,
        });
        let make = |entry: &str, fmt: wgpu::TextureFormat| device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("yuv-conv-pipe"),
            layout: Some(&layout),
            vertex: wgpu::VertexState { module: &shader, entry_point: Some("vs"), buffers: &[], compilation_options: Default::default() },
            fragment: Some(wgpu::FragmentState { module: &shader, entry_point: Some(entry), targets: &[Some(wgpu::ColorTargetState { format: fmt, blend: None, write_mask: wgpu::ColorWrites::ALL })], compilation_options: Default::default() }),
            primitive: wgpu::PrimitiveState::default(),
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            multiview_mask: None,
            cache: None,
        });
        let y_pipeline = make("fs_y", wgpu::TextureFormat::R8Unorm);
        let uv_pipeline = make("fs_uv", wgpu::TextureFormat::Rg8Unorm);
        let sampler = device.create_sampler(&wgpu::SamplerDescriptor { label: Some("yuv-conv-samp"), mag_filter: wgpu::FilterMode::Linear, min_filter: wgpu::FilterMode::Linear, ..Default::default() });
        Self { y_pipeline, uv_pipeline, bgl, sampler }
    }
}

fn ensure_tex(opt: &mut Option<(u32, u32, wgpu::Texture)>, device: &wgpu::Device, w: u32, h: u32, format: wgpu::TextureFormat, label: &str) {
    if opt.as_ref().map(|t| t.0 != w || t.1 != h).unwrap_or(true) {
        let t = device.create_texture(&wgpu::TextureDescriptor {
            label: Some(label),
            size: wgpu::Extent3d { width: w.max(1), height: h.max(1), depth_or_array_layers: 1 },
            mip_level_count: 1, sample_count: 1, dimension: wgpu::TextureDimension::D2,
            format,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
            view_formats: &[],
        });
        *opt = Some((w, h, t));
    }
}

#[inline]
fn align256(v: u32) -> u32 { ((v + 255) / 256) * 256 }

/// 导出回读: GPU 上把 out_tex 转 Y(R8 全分辨率) + UV(RG8 半分辨率), 回读后组装 I420。
/// CPU 只做去填充/拆分(memcpy, 无浮点), 大幅快于原 CPU 逐像素转换。返回 (w, h, i420)。
pub(crate) fn readback_output_i420() -> Option<(u32, u32, Vec<u8>)> {
    let mut guard = PREVIEW.lock().unwrap();
    let state = guard.as_mut()?;
    let (ow, oh) = { let t = state.out_tex.as_ref()?; (t.0, t.1) };  // 稳定输出(夹后)尺寸 = 采样源
    if ow == 0 || oh == 0 { return None; }
    // 目标尺寸: 导出选了更大分辨率(如 8K)则按目标输出, GPU Linear 放大 out_tex(取景不变); 否则用稳定尺寸
    let tw0 = EXPORT_TARGET_W.load(Ordering::Relaxed);
    let th0 = EXPORT_TARGET_H.load(Ordering::Relaxed);
    let (tw, th) = if tw0 >= 2 && th0 >= 2 { (tw0 & !1, th0 & !1) } else { (ow, oh) };
    let cw = (tw + 1) / 2;
    let ch = (th + 1) / 2;

    if state.yuv_conv.is_none() { state.yuv_conv = Some(YuvConverter::new(&state.device)); }
    ensure_tex(&mut state.y_tex, &state.device, tw, th, wgpu::TextureFormat::R8Unorm, "y_tex");
    ensure_tex(&mut state.uv_tex, &state.device, cw, ch, wgpu::TextureFormat::Rg8Unorm, "uv_tex");

    let conv = state.yuv_conv.as_ref().unwrap();
    let out_view = state.out_tex.as_ref().unwrap().2.create_view(&wgpu::TextureViewDescriptor::default());
    let y_view = state.y_tex.as_ref().unwrap().2.create_view(&wgpu::TextureViewDescriptor::default());
    let uv_view = state.uv_tex.as_ref().unwrap().2.create_view(&wgpu::TextureViewDescriptor::default());
    let bg = state.device.create_bind_group(&wgpu::BindGroupDescriptor {
        label: Some("yuv-conv-bg"), layout: &conv.bgl,
        entries: &[
            wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::Sampler(&conv.sampler) },
            wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&out_view) },
        ],
    });

    let y_pad = align256(tw);        // R8: 1 字节/像素
    let uv_pad = align256(cw * 2);   // RG8: 2 字节/像素
    let y_buf = state.device.create_buffer(&wgpu::BufferDescriptor { label: Some("y-read"), size: (y_pad as u64) * (th as u64), usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ, mapped_at_creation: false });
    let uv_buf = state.device.create_buffer(&wgpu::BufferDescriptor { label: Some("uv-read"), size: (uv_pad as u64) * (ch as u64), usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ, mapped_at_creation: false });

    let mut enc = state.device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("yuv-conv-enc") });
    {
        let mut p = enc.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("y-pass"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment { view: &y_view, resolve_target: None, depth_slice: None, ops: wgpu::Operations { load: wgpu::LoadOp::Clear(wgpu::Color::BLACK), store: wgpu::StoreOp::Store } })],
            depth_stencil_attachment: None, timestamp_writes: None, occlusion_query_set: None, multiview_mask: None,
        });
        p.set_pipeline(&conv.y_pipeline); p.set_bind_group(0, &bg, &[]); p.draw(0..3, 0..1);
    }
    {
        let mut p = enc.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("uv-pass"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment { view: &uv_view, resolve_target: None, depth_slice: None, ops: wgpu::Operations { load: wgpu::LoadOp::Clear(wgpu::Color::BLACK), store: wgpu::StoreOp::Store } })],
            depth_stencil_attachment: None, timestamp_writes: None, occlusion_query_set: None, multiview_mask: None,
        });
        p.set_pipeline(&conv.uv_pipeline); p.set_bind_group(0, &bg, &[]); p.draw(0..3, 0..1);
    }
    enc.copy_texture_to_buffer(
        wgpu::TexelCopyTextureInfo { texture: &state.y_tex.as_ref().unwrap().2, mip_level: 0, origin: wgpu::Origin3d::ZERO, aspect: wgpu::TextureAspect::All },
        wgpu::TexelCopyBufferInfo { buffer: &y_buf, layout: wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(y_pad), rows_per_image: Some(th) } },
        wgpu::Extent3d { width: tw, height: th, depth_or_array_layers: 1 },
    );
    enc.copy_texture_to_buffer(
        wgpu::TexelCopyTextureInfo { texture: &state.uv_tex.as_ref().unwrap().2, mip_level: 0, origin: wgpu::Origin3d::ZERO, aspect: wgpu::TextureAspect::All },
        wgpu::TexelCopyBufferInfo { buffer: &uv_buf, layout: wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(uv_pad), rows_per_image: Some(ch) } },
        wgpu::Extent3d { width: cw, height: ch, depth_or_array_layers: 1 },
    );
    state.queue.submit(Some(enc.finish()));

    let ys = y_buf.slice(..); ys.map_async(wgpu::MapMode::Read, |_| {});
    let uvs = uv_buf.slice(..); uvs.map_async(wgpu::MapMode::Read, |_| {});
    let _ = state.device.poll(wgpu::PollType::wait_indefinitely());
    let ydata = ys.get_mapped_range();
    let uvdata = uvs.get_mapped_range();

    // 组装 I420: Y(tw*th) + U(cw*ch) + V(cw*ch), 仅去行填充 + RG 拆分(无浮点)
    let (w, h, cwz, chz) = (tw as usize, th as usize, cw as usize, ch as usize);
    let (yp, uvp) = (y_pad as usize, uv_pad as usize);
    let mut out = vec![0u8; w * h + cwz * chz * 2];
    for r in 0..h {
        out[r * w .. r * w + w].copy_from_slice(&ydata[r * yp .. r * yp + w]);
    }
    let (u_off, v_off) = (w * h, w * h + cwz * chz);
    for r in 0..chz {
        let src = &uvdata[r * uvp .. r * uvp + cwz * 2];
        for c in 0..cwz {
            out[u_off + r * cwz + c] = src[c * 2];
            out[v_off + r * cwz + c] = src[c * 2 + 1];
        }
    }
    drop(ydata); drop(uvdata);
    y_buf.unmap(); uv_buf.unmap();
    Some((tw, th, out))
}

