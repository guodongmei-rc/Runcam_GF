# 设计:安卓 4K 解码黑屏(NO_MEMORY)→ 零拷贝预览,对齐官方

> **✅ 已解决(2026-06-26),零拷贝未实施、无需实施。**
> 实际根因:同分辨率(3840×2160)下 **4K30 正常、4K60 黑屏**,差异 100% 在解码器对 4K60
> 的高吞吐资源预留;在被 wgpu+Flutter 占用的进程里 `MediaCodec.start()` OOM。
> **修法**:预览两个解码器(`VideoDecoder`/`GlVideoDecoder`)configure 前加
> `KEY_OPERATING_RATE=30` + `KEY_PRIORITY=1`,降低资源预留即让出内存 → 4K60 出画面。
> 下文的零拷贝/M0–M5 仅作排查与备选方案留档(若将来遇到"降预留也不够"的机型可参考)。

---


> 日期:2026-06-26
> 阶段:GF 功能 Flutter 化 — 阶段1 安卓补齐(预览 Texture 已 go,本轮修 4K60 黑屏)
> 触发:华为(EMUI/Android 12)+ 高通 Adreno 机型,打开 **4K60 H.264/HEVC** 视频
> 预览全程黑屏;`MediaCodec.start()` 抛 `err 0xfffffff4`(= **−12 `NO_MEMORY`**)。
> 依据:官方 `Gyroflow_fork/src/rendering/ffmpeg_android.rs`、
> `src/core/gpu/wgpu_interop_android.rs`(**注意:官方该路是未完成的 TODO 草稿**)。

## 现象与证据

- `0xfffffff4` = `-12` = `NO_MEMORY`(`<utils/Errors.h>` 的 `NO_MEMORY = -ENOMEM`)。
- 对**每一个** 4K 硬件解码器都失败:一次是 `c2.qti.avc.decoder`,一次是 `c2.qti.hevc.decoder`。
- **线性路**(`VideoDecoder`,`configure(null surface)` + `COLOR_FormatYUV420Flexible`)和
  **Surface 路**(`GlVideoDecoder`,ImageReader)**都失败**——所以不是"4K 只支持 Surface 输出"的能力问题。
- **音频 AAC 解码器起得来**(`AudioTrack start` → 有声),失败的只有 4K 视频硬解。
- 已验证 `GlVideoDecoder` 缓冲数 16→10 + 去掉 `CPU_READ_OFTEN`(对齐官方 `GPU_SAMPLED,10`)
  **不解决**(行号位移确认新包已部署,仍 −12)。⟹ **不是 ImageReader 缓冲配置问题。**

## 根因判断(待里程碑 0 证实)

`−12` 是硬件解码器**拿不到它那份 4K 图形/ION 内存**。本 App 与官方的关键架构差异:

| | 我们 | 官方(desktop/ffmpeg) |
|---|---|---|
| 解码输出 | MediaCodec → `getPlanes()` 取 CPU YUV | FFmpeg-MediaCodec hwaccel |
| 喂给 GPU | `nativeProcessFrame(y,u,v)` → wgpu `write_texture` **另分**一份输入纹理 | AHardwareBuffer **零拷贝**直接给 wgpu |
| 4K 时图形内存峰值 | 解码器缓冲(~150-250MB) **+** wgpu 输入/输出纹理(下表) | 解码器缓冲与 GPU 采样**共享同一块** |

我们 `preview.rs::process_frame_gpu` 在 4K(3840×2160)时的 wgpu 分配(每帧/尺寸变化时):
- `YuvFrame`:Y(R8 ~8MB)+ U + V(各 ~2MB)≈ 12MB
- `in_tex`:RGBA 全分辨率 ≈ 33MB
- `out_tex`:RGBA 输出尺寸 ≈ 最多 33MB
- undistort 中间纹理若干

合计 ~80MB+,**叠加**解码器自己的 ~200MB + Flutter `SurfaceProducer`(Android<33 是 ImageReader 背书)。
官方零拷贝则**没有**那份 ~33MB 输入纹理,且解码器输出即采样源 → 峰值低 → 在该机能起来,我们起不来。

## 里程碑 0(必须先做,5 分钟,否则后面可能白做)

**在写任何零拷贝代码之前**,证实"−12 = 4K 图形内存峰值":

1. **换 1080p 视频**打开:
   - 仍黑屏 → **根因不是 4K 内存峰值**,零拷贝无用,停止本设计,改查"该 App 内任何 HW 解码器都起不来"(如 wgpu 占用 / codec 实例残留 / EMUI 限制)。
   - 正常出画面 → 坐实内存峰值假设,继续。
2. grep 日志确认 autosync 解码器(`GyroflowAutosync` 的 `MediaCodec start`)是否与预览解码器**时序重叠**:
   - 重叠 → 是"两个 4K 解码器并存"问题(`_startAutosync` 的 `setExportMode(true)` 释放预览解码器未生效/未串行)。**这条修法更便宜:串行化,不用零拷贝。** 见附录 A。
   - 不重叠 → 预览解码器**独自**失败,内存峰值假设进一步成立。

> 只有里程碑 0 第 1 步为"1080p 正常"且第 2 步为"不重叠"时,才进入下面的零拷贝实现。

## 零拷贝目标架构

```
MediaCodec(HW) ──解码到──▶ ImageReader(YUV_420_888, GPU_SAMPLED, 10)
                                  │ acquireNextImage()
                                  ▼
                         AHardwareBuffer(厂商 YUV 格式)
                                  │ JNI 传指针(新增 nativeProcessHwBuffer)
                                  ▼
   VkImage(VK_ANDROID_external_memory_android_hardware_buffer)
        + VkSamplerYcbcrConversion(厂商 external_format)
                                  │ wgpu-hal 包回 wgpu::Texture
                                  ▼
        现有 undistort 管线(in_tex 改为外部 YCbCr 采样源)──▶ out_tex ──▶ surface
                                  │ GPU 用完
                                  ▼
                         Image.close() 归还解码器(10 缓冲轮转)
```

**不改**:`gyroflow_core`(Rust core)、`GyroflowNative.kt` 既有签名、`gyroflow_ffi.h`、iOS 侧。
**可改**(本仓自有壳):`android/rust/runcam_gyroflow/src/{preview,lib}.rs`(JNI 实现是项目自己的,
非 core)、`PreviewController.kt`、`GlVideoDecoder.kt`、新增一个 `nativeProcessHwBuffer` JNI。

## 主要难点(为什么官方留 TODO)

1. **YCbCr 采样器**:AHB 是厂商 YUV(非 RGBA),Vulkan 必须用不可变
   `VkSamplerYcbcrConversion` 的 combined-image-sampler。**wgpu 安全 API 不暴露 Ycbcr 转换** →
   必须经 `device.as_hal::<Vulkan>()` 手搓 `VkImage`/`VkImageView`/`VkSampler`/绑定组,
   再用 `wgpu_hal::vulkan` 包回 `wgpu::Texture`/`TextureView`。参考官方注释列的 ALVR/mpv/Teleport 实现。
2. **同步**:AHB acquire fence 要导入成 `VkSemaphore` 等待;本机 **Android < 33**,
   `ImageReader` 的 fence 取不到(Flutter 已打印 `can't wait on the fence on Android < 33`)→
   需退化为 `device.poll(Wait)` 全栅栏或 `glFinish` 式硬等(掉帧但正确)。
3. **格式探测**:`VkAndroidHardwareBufferFormatPropertiesANDROID` 拿
   `external_format` / `suggested_ycbcr_model` / `suggested_ycbcr_range`,喂给
   `ExternalFormatANDROID` + `SamplerYcbcrConversionCreateInfo`(官方草稿里的
   `self.input_format_properties` 就是这个,但它没写获取逻辑)。
4. **生命周期**:`Image`/`AHardwareBuffer` 在 GPU 采样完成前不能 `close()`;10 缓冲,
   渲染滞后几帧时要保证不耗尽(否则解码器 `dequeueOutputBuffer` 拿不到 buffer 卡住)。
5. **wgpu 版本**:确认本仓 wgpu 版本的 `as_hal` / `wgpu_hal::vulkan::Device::texture_from_raw`
   API 形态(官方草稿基于某版 ash/wgpu,签名可能不一致)。

## 里程碑拆解(每步真机可单独验证)

- **M0 — 前提验证**(上文):1080p 测 + autosync 时序。**门禁:不过则不进 M1。**
- **M1 — Kotlin AHB 管线**:`GlVideoDecoder` 改为 `acquireNextImage()` → 取
  `image.hardwareBuffer`(API 28+)→ 经新增 `nativeProcessHwBuffer(hwBufferPtr, w, h, ptsUs)`
  传原生;原生**先只打印** AHB 格式属性(`external_format` 等)并立即 `image.close()`。
  *验证*:logcat 看到每帧 AHB 格式日志、解码不卡、不崩(画面仍黑,正常)。
- **M2 — Vulkan 导入单张静态帧**:原生把 1 个 AHB 导入成 `VkImage`(无 YCbCr,先用
  `ExternalFormatANDROID` + 占位采样),拷到一张 RGBA `in_tex` 并直接上屏(不接 undistort)。
  *验证*:屏幕出现该帧画面(可能颜色错乱,只验证"导入+采样链路通")。
- **M3 — YCbCr 转换正确成像**:接 `VkSamplerYcbcrConversion`,颜色正确;接成连续帧。
  *验证*:原始视频画面正常滚动播放(未防抖)。
- **M4 — 接 undistort + 同步 + 缓冲轮转**:`in_tex` 换成外部 YCbCr 源喂现有 undistort;
  补 fence/poll 同步;校准 10 缓冲不耗尽。
  *验证*:防抖预览正常、play/pause/seek 正常、长播不卡不掉帧、内存稳定。
- **M5 — 回归**:1080p、2.7K、4K30、4K60 各机型;导出路不受影响(导出仍走 CPU readback,
  与预览解耦);autosync 共存。

## 风险与回退

- **wgpu-hal YCbCr 在本 wgpu 版本不可行** → 回退方案:M1 的 AHB 取不到 CPU 可读时,
  仍可让 `GlVideoDecoder` 用 `GPU_SAMPLED` 解码、但**继续 `getPlanes()` CPU 回读**
  (不零拷贝),仅靠"10 缓冲 + 无 CPU_READ 影子"降一半占用 + **同时降低 wgpu 输入纹理**
  (按预览降采样尺寸解码不行,但可让 `process_frame_gpu` 不建全 4K `in_tex`)——
  即用户未选的"降 wgpu 峰值"方案兜底。
- **官方草稿不可直接编译**(`cuda_mem`/`self.*` 等)——只能当 Vulkan 调用序列的**参考**,
  逐行重写,不能 copy-paste。

## 附录 A:若 M0 发现 autosync 并存(更便宜的修法)

`EditController.openAndStart`:`_startBackend()`(起预览解码器,异步在自己线程
configure+start)→ `_startAutosync()` → `setExportMode(true)` → `PreviewController.pauseForExport()`
→ `decoder.stop()`(join 800ms 释放预览解码器)→ `autosyncStart`(起 autosync 解码器)。

预览解码器在**自己线程**异步 configure+start,`_startBackend` 提前返回;若 `decoder.stop()`
的 join(800ms) 在预览 4K `start()` 完成前超时,二者短暂并存 → −12。修法:让预览解码器
**起好后再返回**(或 `pauseForExport` 等待预览 codec 进入已知态),保证任一时刻只有一个 4K 解码器。
这条不需要零拷贝,**若 M0 命中应优先做**。
