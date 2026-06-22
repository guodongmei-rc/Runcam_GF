// 方案 B: 全 GPU undistort —— 在我们自己的 wgpu 设备上复刻 gyroflow 的去畸变渲染管线。
//
// gyroflow 只负责算每帧的 FrameTransform(kernel_params + matrices, 纯 CPU, 很快);
// 我们用 gyroflow 的 undistort shader(wgpu_undistort.wgsl)在**我们的 GPU**上把变换
// 应用到输入纹理 → 输出纹理 → 直接显示。全程单设备、无 CPU 全分辨率搬运(对齐 iOS)。
//
// shader 用 include_str! 直接引用 gyroflow 源码(不复制、不改源)。

use gyroflow_core::stabilization::distortion_models::DistortionModel;
use gyroflow_core::stabilization::{KernelParams, COEFFS};
use wgpu::util::DeviceExt;

const UNDISTORT_WGSL: &str =
    include_str!("/Users/gdm/Desktop/Gyroflow_fork/src/core/gpu/wgpu_undistort.wgsl");

/// 按镜头畸变模型构建 WGSL(替换 LENS_MODEL_FUNCTIONS / SCALAR, 删 buffer_input 块, 保留 texture 路径)。
fn build_kernel(distortion_name: &str) -> String {
    let dm = DistortionModel::from_name(distortion_name);
    let mut lens = dm.wgsl_functions().to_string();
    lens.push_str(
        "\nfn digital_undistort_point(uv: vec2<f32>) -> vec2<f32> { return uv; }\n\
         fn digital_distort_point(uv: vec2<f32>) -> vec2<f32> { return uv; }\n",
    );
    let mut k = UNDISTORT_WGSL.to_string();
    k = k.replace("LENS_MODEL_FUNCTIONS;", &lens);
    k = k.replace("SCALAR", "f32");
    // 走纹理输入: 删掉 {buffer_input}..{/buffer_input} 块(texture_input 标记是注释, 留着无害)
    while let Some(pos) = k.find("{buffer_input}") {
        let end = k.find("{/buffer_input}").unwrap() + "{/buffer_input}".len();
        k.replace_range(pos..end, "");
    }
    k
}

pub struct Undistorter {
    pipeline: wgpu::RenderPipeline,
    bgl: wgpu::BindGroupLayout,
    coeffs_buf: wgpu::Buffer,
    pub flags: i32,   // 创建时的 kp.flags(含 DRAWING_ENABLED 位); 变化时需重建管线
}

impl Undistorter {
    /// 创建管线。`kp` 提供 override 常量(interpolation/pix_element_count/bytes_per_pixel/flags)。
    pub fn new(
        device: &wgpu::Device,
        out_format: wgpu::TextureFormat,
        distortion_name: &str,
        kp: &KernelParams,
    ) -> Self {
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("undistort"),
            source: wgpu::ShaderSource::Wgsl(build_kernel(distortion_name).into()),
        });

        let buf = |binding: u32| wgpu::BindGroupLayoutEntry {
            binding,
            visibility: wgpu::ShaderStages::FRAGMENT,
            ty: wgpu::BindingType::Buffer {
                ty: wgpu::BufferBindingType::Storage { read_only: true },
                has_dynamic_offset: false,
                min_binding_size: None,
            },
            count: None,
        };
        let bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("undistort-bgl"),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Uniform,
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                    count: None,
                },
                buf(1), // matrices
                buf(2), // coeffs
                buf(3), // mesh_data
                buf(4), // drawing
                wgpu::BindGroupLayoutEntry {
                    binding: 5,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Texture {
                        sample_type: wgpu::TextureSampleType::Float { filterable: false },
                        view_dimension: wgpu::TextureViewDimension::D2,
                        multisampled: false,
                    },
                    count: None,
                },
            ],
        });

        let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("undistort-pl"),
            bind_group_layouts: &[Some(&bgl)],
            immediate_size: 0,
        });

        let constants: &[(&str, f64)] = &[
            ("100", kp.interpolation as f64),
            ("101", kp.pix_element_count as f64),
            ("102", kp.bytes_per_pixel as f64),
            ("103", kp.flags as f64),
        ];
        let comp = wgpu::PipelineCompilationOptions {
            constants,
            ..Default::default()
        };

        let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("undistort-pipe"),
            layout: Some(&layout),
            vertex: wgpu::VertexState {
                module: &shader,
                entry_point: Some("undistort_vertex"),
                buffers: &[],
                compilation_options: comp.clone(),
            },
            fragment: Some(wgpu::FragmentState {
                module: &shader,
                entry_point: Some("undistort_fragment"),
                targets: &[Some(wgpu::ColorTargetState {
                    format: out_format,
                    blend: None,
                    write_mask: wgpu::ColorWrites::ALL,
                })],
                compilation_options: comp,
            }),
            primitive: wgpu::PrimitiveState {
                topology: wgpu::PrimitiveTopology::TriangleList,
                ..Default::default()
            },
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            multiview_mask: None,
            cache: None,
        });

        // COEFFS 颜色区(索引 448..484, 9 色×RGBA)是 0–255 值; shader 用 colorf = coeffs×max_pixel_value,
        // 归一化纹理下 max_pixel_value=1.0, 不除会让黄/青等含部分通道(如黄的 B=71)钳到 1 → 偏白。
        // 故把颜色区 ÷255 归一化(权重 0..448 与 alpha 484..488 保持不变)。对齐官方 CPU 渲染的颜色。
        let mut coeffs = COEFFS;
        for c in coeffs.iter_mut().take(484).skip(448) { *c /= 255.0; }
        let coeffs_buf = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("coeffs"),
            contents: bytemuck::cast_slice(&coeffs),
            usage: wgpu::BufferUsages::STORAGE,
        });
        Self { pipeline, bgl, coeffs_buf, flags: kp.flags }
    }

    /// 应用一帧: input_view(去畸变前的源帧纹理) → output_view(去畸变+稳定后)。
    pub fn render(
        &self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        encoder: &mut wgpu::CommandEncoder,
        kp: &KernelParams,
        matrices: &[[f32; 14]],
        mesh: &[f32],
        drawing: &[u8],
        input_view: &wgpu::TextureView,
        output_view: &wgpu::TextureView,
    ) {
        let params_buf = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("params"),
            contents: bytemuck::bytes_of(kp),
            usage: wgpu::BufferUsages::UNIFORM,
        });
        let matrices_buf = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("matrices"),
            contents: bytemuck::cast_slice(matrices),
            usage: wgpu::BufferUsages::STORAGE,
        });
        let mesh_slice: &[f32] = if mesh.is_empty() { &[0.0; 4] } else { mesh };
        let mesh_buf = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("mesh"),
            contents: bytemuck::cast_slice(mesh_slice),
            usage: wgpu::BufferUsages::STORAGE,
        });
        // drawing 覆盖层 buffer(byte 网格, shader 按 array<u32> 读); 空时给最小占位。
        // 长度补齐到 4 的倍数(storage<u32>)。
        let mut draw_bytes: Vec<u8> = if drawing.is_empty() { vec![0u8; 16] } else { drawing.to_vec() };
        while draw_bytes.len() % 4 != 0 { draw_bytes.push(0); }
        let drawing_buf = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("drawing-frame"),
            contents: &draw_bytes,
            usage: wgpu::BufferUsages::STORAGE,
        });

        let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("undistort-bg"),
            layout: &self.bgl,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: params_buf.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 1, resource: matrices_buf.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 2, resource: self.coeffs_buf.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 3, resource: mesh_buf.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 4, resource: drawing_buf.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 5, resource: wgpu::BindingResource::TextureView(input_view) },
            ],
        });

        let _ = queue;
        let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("undistort"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: output_view,
                resolve_target: None,
                depth_slice: None,
                ops: wgpu::Operations { load: wgpu::LoadOp::Clear(wgpu::Color::BLACK), store: wgpu::StoreOp::Store },
            })],
            depth_stencil_attachment: None,
            timestamp_writes: None,
            occlusion_query_set: None,
            multiview_mask: None,
        });
        pass.set_pipeline(&self.pipeline);
        pass.set_bind_group(0, &bind_group, &[]);
        pass.draw(0..6, 0..1);
    }
}
