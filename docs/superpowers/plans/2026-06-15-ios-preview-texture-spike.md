# 阶段1 iOS 预览 Texture spike 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`).

**Goal:** 在 iOS 把引擎 GPU 渲出的稳定预览零拷贝塞进 Flutter `Texture`,做完整预览页,验证 4K@60 零拷贝是否成立(go/no-go)。

**Architecture:** 新增独立 `PreviewController`(ObjC++,实现 `FlutterTexture`:CVPixelBuffer 池 + CVMetalTextureCache + CADisplayLink + MDK 解码 + `gyroflow_process_frame_metal_bgra8`),Swift `PreviewApiImpl` 实现 Pigeon `PreviewApi` 并注册纹理;复用 `EngineApiImpl` 的 stabilizer 句柄。老 `open()` 全屏页不动。

**Tech Stack:** Flutter `Texture`/`FlutterTexture`、Metal、CVPixelBuffer(IOSurface)、CVMetalTextureCache、CADisplayLink、MDK(`mdk::Player`)、Pigeon、gyroflow FFI。

---

## 前置说明(务必先读)

- **原生 GPU/MDK 代码无法在本机编译/单测**;每个增量(Task)的验收=**真机运行 + 屏上观察**,由你执行。实施 agent 写完代码后产出"真机验收步骤",等人确认再进下一 Task。
- **非 git 仓库**:计划里的「Checkpoint」= 真机构建运行 + 观察(必要时 `flutter analyze`);若已 `git init` 可顺带 commit。
- **MDK 镜像**:Task 4 的解码部分**镜像 `ios/Sources/ViewController.mm`** 的现成 MDK 路径(`makeMDKInputTextureWithWidth:` @2100、`setupMDKPlayer`/`renderVideo` @1551-1633、`drawInMTKView` @2198 的 process 调用),不重造。
- **增量顺序**:A 纹理桥 → B 60Hz 驱动 → C 真解码+稳定 → D seek/生命周期/4K@60/零拷贝。A/B 不碰 MDK,先把"Flutter 纹理路径"和性能验证拿下。
- **不动**:`ViewController.mm`、`open()`、安卓侧、S7 状态层。

## 文件结构

| 文件 | 职责 |
|---|---|
| `pigeons/runcam_gf_api.dart` | 扩展 `PreviewApi`(createPreviewTexture 加 uri、返回 `PreviewInfo`)|
| `lib/src/bridge/engine_api.g.dart` 等 `*.g.*` | pigeon 重新生成(勿手改)|
| `ios/Classes/PreviewController.h` | ObjC 头(纯 ObjC,无 C++,供 Swift 可见):FlutterTexture + 生命周期方法 |
| `ios/Classes/PreviewController.mm` | ObjC++ 实现:CVPB 池/MetalTextureCache/CADisplayLink/MDK/process_frame |
| `ios/Classes/PreviewApiImpl.swift` | 实现 Pigeon `PreviewApi`,注册 FlutterTexture,转发到 PreviewController |
| `ios/Classes/EngineApiImpl.swift` | 暴露 `stabilizerHandle`(只读)供预览共享句柄 |
| `ios/Classes/RuncamGfPlugin.swift` | 注册 PreviewApi(传 `registrar.textures()` + 共享 stabilizer)|
| `example/lib/preview_page.dart` | 预览页:`Texture(textureId)` + 播放控制 + 屏上 FPS |
| `example/lib/main.dart` | 加入口按钮跳预览页 |

---

## Task 1: 扩展 PreviewApi 契约 + 重新生成

**Files:**
- Modify: `pigeons/runcam_gf_api.dart`
- Regenerate: `lib/src/bridge/engine_api.g.dart`、`ios/Classes/EngineApi.g.swift`、`android/.../EngineApi.g.kt`

- [ ] **Step 1: 改契约**

把 `pigeons/runcam_gf_api.dart` 的 `PreviewApi` 段(现为占位)改为:

```dart
/// 预览纹理信息(阶段1)。
class PreviewInfo {
  int textureId;
  int width;
  int height;
  PreviewInfo(this.textureId, this.width, this.height);
}

@HostApi()
abstract class PreviewApi {
  /// 创建外接预览纹理。建解码器+CVPB 池+注册纹理,返回 textureId 与画面尺寸。
  PreviewInfo createPreviewTexture(String uriOrPath);
  void disposePreviewTexture(int textureId);

  void play();
  void pause();
  void seekTo(int timestampUs);

  /// 导出模式:阶段4 用,本轮不实现。
  void setExportMode(bool on);
}
```

(若 pigeon 不支持位置构造参数,用具名字段 + 默认构造:`PreviewInfo({required this.textureId, required this.width, required this.height});`——以本仓库现有数据类写法为准,见 `VideoInfo` 的生成风格。)

- [ ] **Step 2: 重新生成**

Run: `cd /Users/gdm/Desktop/RuncamGF && flutter pub get && dart run pigeon --input pigeons/runcam_gf_api.dart`
Expected: 三端 `*.g.*` 重新生成无报错;`PreviewInfo` 与新 `createPreviewTexture(String)` 出现在 `lib/src/bridge/engine_api.g.dart` 与 `ios/Classes/EngineApi.g.swift`。

- [ ] **Step 3: Checkpoint**

Run: `cd /Users/gdm/Desktop/RuncamGF && flutter analyze`
Expected: No issues found.（生成代码不报错;安卓/iOS 的 PreviewApi setUp 暂未接实现也不影响 analyze)

---

## Task 2(增量 A):纹理桥通路 —— 纯色 CVPixelBuffer 上屏

**Files:**
- Create: `ios/Classes/PreviewController.h`、`ios/Classes/PreviewController.mm`
- Create: `ios/Classes/PreviewApiImpl.swift`
- Modify: `ios/Classes/EngineApiImpl.swift`(暴露句柄)、`ios/Classes/RuncamGfPlugin.swift`(注册)
- Create: `example/lib/preview_page.dart`
- Modify: `example/lib/main.dart`(入口按钮)

目标:`createPreviewTexture` 返回一个 textureId,`copyPixelBuffer` 返回一张**填死纯色**的 CVPixelBuffer,Flutter `Texture` 显示它。**不接 MDK/Metal 渲染**,先证外部纹理链路。

- [ ] **Step 1: PreviewController.h(纯 ObjC,供 Swift 可见)**

```objc
#import <Foundation/Foundation.h>
#import <Flutter/Flutter.h>

NS_ASSUME_NONNULL_BEGIN

/// 阶段1 预览渲染控制器。实现 FlutterTexture,把 CVPixelBuffer 交给 Flutter 合成器。
/// 增量 A:仅纯色 CVPixelBuffer;后续增量接 CADisplayLink / MDK / process_frame。
@interface PreviewController : NSObject <FlutterTexture>

/// stabilizer 由调用方注入(与 EngineApiImpl 共享同一句柄)。可为 NULL(增量 A/B 不用)。
- (instancetype)initWithStabilizer:(void *_Nullable)stabilizer;

/// 建解码/CVPB 池,返回画面尺寸(增量 A:固定一个测试尺寸)。
- (CGSize)setupWithUri:(NSString *)uri;

- (void)play;
- (void)pause;
- (void)seekToUs:(int64_t)timestampUs;
- (void)dispose;

@end

NS_ASSUME_NONNULL_END
```

- [ ] **Step 2: PreviewController.mm(增量 A:纯色 CVPB)**

```objc
#import "PreviewController.h"
#import <CoreVideo/CoreVideo.h>

@implementation PreviewController {
  void *_stabilizer;            // 共享句柄,增量 C 才用
  CVPixelBufferRef _latest;     // copyPixelBuffer 返回它
  NSObject<FlutterTextureRegistry> *_registry; // 暂不用,占位
  int _w; int _h;
}

- (instancetype)initWithStabilizer:(void *)stabilizer {
  if (self = [super init]) { _stabilizer = stabilizer; }
  return self;
}

- (CGSize)setupWithUri:(NSString *)uri {
  _w = 1280; _h = 720; // 增量 A:固定测试尺寸
  [self makeSolidPixelBuffer];
  return CGSizeMake(_w, _h);
}

// 建一张 IOSurface 背书、Metal-compatible、BGRA 的 CVPixelBuffer,填纯色(青色)。
- (void)makeSolidPixelBuffer {
  if (_latest) { CVPixelBufferRelease(_latest); _latest = NULL; }
  NSDictionary *attrs = @{
    (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    (id)kCVPixelBufferMetalCompatibilityKey: @YES,
    (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
  };
  CVPixelBufferRef pb = NULL;
  CVPixelBufferCreate(kCFAllocatorDefault, _w, _h,
                      kCVPixelFormatType_32BGRA,
                      (__bridge CFDictionaryRef)attrs, &pb);
  if (!pb) { return; }
  CVPixelBufferLockBaseAddress(pb, 0);
  uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
  size_t stride = CVPixelBufferGetBytesPerRow(pb);
  for (int y = 0; y < _h; y++) {
    uint8_t *row = base + y * stride;
    for (int x = 0; x < _w; x++) {
      row[x*4+0] = 200; // B
      row[x*4+1] = 200; // G
      row[x*4+2] = 0;   // R  → 青色
      row[x*4+3] = 255; // A
    }
  }
  CVPixelBufferUnlockBaseAddress(pb, 0);
  _latest = pb;
}

#pragma mark - FlutterTexture
- (CVPixelBufferRef _Nullable)copyPixelBuffer {
  if (!_latest) { return NULL; }
  return CVPixelBufferRetain(_latest); // Flutter 拿走后会 release
}

- (void)play {}
- (void)pause {}
- (void)seekToUs:(int64_t)timestampUs {}
- (void)dispose {
  if (_latest) { CVPixelBufferRelease(_latest); _latest = NULL; }
}

@end
```

- [ ] **Step 3: EngineApiImpl 暴露句柄**

`ios/Classes/EngineApiImpl.swift` 在 `private var handle: OpaquePointer?` 下加:

```swift
    /// 供 PreviewController 共享同一引擎句柄(阶段1 预览)。
    var stabilizerHandle: OpaquePointer? { handle }
```

- [ ] **Step 4: PreviewApiImpl.swift(实现 Pigeon 协议 + 注册纹理)**

```swift
import Foundation
import Flutter

/// 实现 Pigeon PreviewApi:持有 PreviewController,注册 FlutterTexture。
final class PreviewApiImpl: NSObject, PreviewApi {
  private let textures: FlutterTextureRegistry
  private let stabilizer: () -> OpaquePointer?
  private var controller: PreviewController?
  private var textureId: Int64 = -1

  init(textures: FlutterTextureRegistry, stabilizer: @escaping () -> OpaquePointer?) {
    self.textures = textures
    self.stabilizer = stabilizer
  }

  func createPreviewTexture(uriOrPath: String) throws -> PreviewInfo {
    let ctrl = PreviewController(stabilizer: stabilizer().map { UnsafeMutableRawPointer($0) })
    let size = ctrl.setup(withUri: uriOrPath)
    let tid = textures.register(ctrl)
    controller = ctrl
    textureId = tid
    return PreviewInfo(textureId: tid, width: Int64(size.width), height: Int64(size.height))
  }

  func disposePreviewTexture(textureId: Int64) throws {
    if textureId >= 0 { textures.unregisterTexture(textureId) }
    controller?.dispose()
    controller = nil
    self.textureId = -1
  }

  func play() throws { controller?.play() }
  func pause() throws { controller?.pause() }
  func seekTo(timestampUs: Int64) throws { controller?.seek(toUs: timestampUs) }
  func setExportMode(on: Bool) throws { /* 阶段4 */ }
}
```

(注:`PreviewInfo` 的初始化形参名以 Task 1 生成的 `EngineApi.g.swift` 为准;若生成为位置参数则用 `PreviewInfo(textureId: tid, width: ..., height: ...)` 的对应形式。)

- [ ] **Step 5: RuncamGfPlugin 注册 PreviewApi**

`ios/Classes/RuncamGfPlugin.swift` 的 `register(with:)` 末尾、`engineApi = engine` 之后加:

```swift
        // 阶段1:注册预览 API(共享 engine 的 stabilizer 句柄 + 插件纹理注册表)。
        let preview = PreviewApiImpl(
            textures: registrar.textures(),
            stabilizer: { [weak engine] in engine?.stabilizerHandle }
        )
        PreviewApiSetup.setUp(binaryMessenger: registrar.messenger(), api: preview)
        previewApi = preview
```

并在静态属性区(`engineApi`/`engineEvents` 旁)加 `private static var previewApi: PreviewApiImpl?`。

- [ ] **Step 6: 把 PreviewController.h 加入 umbrella(让 Swift 可见)**

确认 `ios/Classes/` 的 `.h` 会进 pod modulemap(本仓库 ObjC 头默认对 Swift 可见,见 EngineApi 的用法)。若 Swift 报找不到 `PreviewController`,在 pod 的 umbrella header(`runcam_gf-umbrella.h` 或 podspec 配置)确认包含 `PreviewController.h`。

- [ ] **Step 7: example 预览页 + 入口**

新建 `example/lib/preview_page.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:runcam_gf/runcam_gf.dart';

class PreviewPage extends StatefulWidget {
  const PreviewPage({super.key});
  @override
  State<PreviewPage> createState() => _PreviewPageState();
}

class _PreviewPageState extends State<PreviewPage> {
  static const MethodChannel _picker = MethodChannel('runcam_gf_example/picker');
  final PreviewApi _api = PreviewApi();
  int? _textureId;
  double _aspect = 16 / 9;
  String _status = '';

  Future<void> _start() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final uri = await _picker.invokeMethod<String>('pickVideo');
      if (uri == null) return;
      final info = await _api.createPreviewTexture(uri);
      if (!mounted) return;
      setState(() {
        _textureId = info.textureId;
        if (info.height > 0) _aspect = info.width / info.height;
        _status = 'tex=${info.textureId} ${info.width}x${info.height}';
      });
      await _api.play();
    } on PlatformException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('预览失败: ${e.code} ${e.message}')));
    }
  }

  @override
  void dispose() {
    final id = _textureId;
    if (id != null) _api.disposePreviewTexture(id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('预览 Texture spike')),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: _textureId == null
                  ? const Text('点下方按钮选视频')
                  : AspectRatio(aspectRatio: _aspect, child: Texture(textureId: _textureId!)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(children: [
              Text(_status),
              const SizedBox(height: 8),
              Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                ElevatedButton(onPressed: _start, child: const Text('选视频并预览')),
                ElevatedButton(onPressed: () => _api.play(), child: const Text('播放')),
                ElevatedButton(onPressed: () => _api.pause(), child: const Text('暂停')),
              ]),
            ]),
          ),
        ],
      ),
    );
  }
}
```

`example/lib/main.dart` 在两个按钮下加跳转入口(在 `Run Engine Smoke` 按钮后):

```dart
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PreviewPage()),
              ),
              child: const Text('预览 Texture spike (dev)'),
            ),
```

并在 main.dart 顶部 import `import 'preview_page.dart';`。

- [ ] **Step 8: 真机验收(增量 A)**

Run: `cd /Users/gdm/Desktop/RuncamGF/example && flutter run -d <iOS设备> --release`
操作:进「预览 Texture spike」页 → 点「选视频并预览」(随便选)。
Expected:预览区出现一块**青色**矩形(纯色 CVPixelBuffer 经 FlutterTexture 显示)。出现即证外部纹理链路通。
若编译报 `PreviewController` 不可见 → 见 Step 6;若黑屏 → 检查 `copyPixelBuffer` 是否被调(加 `NSLog`)。

- [ ] **Step 9: Checkpoint** — `flutter analyze` 干净 + 上述真机现象达成,记录后进 Task 3。

---

## Task 3(增量 B):CADisplayLink 60Hz 驱动 + 屏上 FPS

**Files:**
- Modify: `ios/Classes/PreviewController.mm`
- Modify: `example/lib/preview_page.dart`(显示 FPS)

目标:CADisplayLink 每帧改纯色为**滚动渐变**,每帧 `textureFrameAvailable`;Flutter 端测并显示 FPS。证 60Hz 合成节奏。

- [ ] **Step 1: PreviewController.mm 加 CADisplayLink + 注册表**

改造:`initWithStabilizer` 增加保存 `FlutterTextureRegistry` 与 textureId(由 PreviewApiImpl 在 register 后回传),`play` 启 CADisplayLink,回调里更新像素 + `[_registry textureFrameAvailable:_textureId]`。

```objc
// 头文件加:
- (void)attachRegistry:(NSObject<FlutterTextureRegistry> *)registry textureId:(int64_t)textureId;
```
```objc
// .mm 增加成员:CADisplayLink *_link; int _phase;
//   NSObject<FlutterTextureRegistry> *_registry; int64_t _textureId;
- (void)attachRegistry:(NSObject<FlutterTextureRegistry> *)registry textureId:(int64_t)textureId {
  _registry = registry; _textureId = textureId;
}
- (void)play {
  if (_link) { _link.paused = NO; return; }
  _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(onFrame)];
  if (@available(iOS 15.0, *)) { _link.preferredFrameRateRange = CAFrameRateRangeMake(60, 60, 60); }
  [_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}
- (void)pause { _link.paused = YES; }
- (void)onFrame {
  _phase = (_phase + 4) % 256;
  [self fillGradientWithPhase:_phase];        // 把 makeSolidPixelBuffer 改成可带相位的渐变
  [_registry textureFrameAvailable:_textureId];
}
```
`dispose` 里 `[_link invalidate]; _link = nil;`。

- [ ] **Step 2: PreviewApiImpl 在 register 后回传注册表**

`createPreviewTexture` 里 `let tid = textures.register(ctrl)` 之后加 `ctrl.attach(registry: textures, textureId: tid)`。

- [ ] **Step 3: Flutter 端测 FPS**

`preview_page.dart` 用 `Ticker`/`WidgetsBinding.instance.addPersistentFrameCallback` 统计每秒帧数显示(或简单用 `SchedulerBinding.instance.addTimingsCallback` 读 `FrameTiming`)。最小实现:

```dart
// 在 State 加:
int _frames = 0; double _fps = 0; Duration _last = Duration.zero;
void _onTimings(List<FrameTiming> t) {
  _frames += t.length;
  final now = t.last.timestampInMicroseconds(FramePhase.rasterFinish);
  // 每约 1s 刷新一次(用墙钟近似)
}
```
（最简可行:`Timer.periodic(1s)` 里把 `_frames` 转成 fps 并 `setState`,`_frames` 在 `addTimingsCallback` 里累加;实现 agent 取最简稳妥写法,目标是屏上有个跳动的 FPS 数。)

- [ ] **Step 4: 真机验收(增量 B)**

进预览页 → 点预览 → 画面应是**滚动的渐变**、屏上 FPS **≈60**。
Expected:画面流畅滚动、FPS 贴 60 → Flutter 外部纹理在 60Hz 驱动下合成 OK。

- [ ] **Step 5: Checkpoint** — 真机现象达成,记录后进 Task 4。

---

## Task 4(增量 C):接 MDK 解码 + process_frame 稳定 → CVPB

**Files:**
- Modify: `ios/Classes/PreviewController.mm`(加 MDK + Metal 渲染目标 + process_frame + 三缓冲)

目标:真实视频经 MDK 解码 → `mdkInputTexture` → `gyroflow_process_frame_metal_bgra8` 输出到 **CVPixelBuffer 背书的 MTLTexture** → 上屏。play/pause 生效。

> **镜像来源(逐函数照搬并改输出目标)**:`ios/Sources/ViewController.mm`
> - MDK 创建/媒体/回调/RenderAPI:`setupMDKPlayer` 区 @1551-1633(`std::make_unique<mdk::Player>()`、`setRenderCallback`、`setMedia`、`prepare`、`setRenderAPI(&_mdkRenderAPI)`、`setVideoSurfaceSize`、`setAspectRatio(KeepAspectRatio)`)。
> - 输入纹理:`makeMDKInputTextureWithWidth:height:` @2100(BGRA8Unorm + RenderTarget|ShaderRead|ShaderWrite + Private)。
> - MDK 渲染目标回调:`currentMDKRenderTarget` 经 C 回调返回(@152 `(__bridge const void *)controller.currentMDKRenderTarget`)。
> - process 调用与时间戳:`drawInMTKView` @2243-2313(`renderVideo()` 返回秒→`*1e6` 转 us;`gyroflow_process_frame_metal_bgra8(stab, ts_us, -1, inputTex, in_w, in_h, outputTex, out_w, out_h, commandQueue, &info)`)。

- [ ] **Step 1: PreviewController.mm 引入 Metal + MDK + CVMetalTextureCache**

要点(在 `.mm` 实现,头文件保持纯 ObjC):
- 成员:`id<MTLDevice> _device; id<MTLCommandQueue> _queue; CVMetalTextureCacheRef _texCache; id<MTLTexture> _mdkInput; std::unique_ptr<mdk::Player> _player;` 以及 CVPB 三缓冲数组 `CVPixelBufferRef _pool[3]; int _next; CVPixelBufferRef _latest; NSLock *_lock;`。
- `setupWithUri:`:建 `_device`/`_queue`;`gyroflow_use_default_gpu(_stabilizer)`(若句柄非空);按 `gyroflow_get_video_info`(或 openVideo 已填的 output_size)取 in/out 尺寸;建三张 CVPB(同增量 A 的属性,尺寸=output_size)+ `CVMetalTextureCacheCreate`;镜像 `setupMDKPlayer` 建 MDK 并 `setMedia(uri)`;返回 output 尺寸。
- 渲染目标:每帧从 `_pool[_next]` 经 `CVMetalTextureCacheCreateTextureFromImage` 得到 `id<MTLTexture> outputTex`。

- [ ] **Step 2: onFrame 真渲染(替换增量 B 的渐变)**

```objc
- (void)onFrame {
  if (!_player || !_stabilizer) return;
  // 1) MDK 渲到输入纹理(currentMDKRenderTarget = _mdkInput,经 C 回调提供给 MDK)
  _currentRenderTarget = _mdkInput;           // 供 mdk render callback 的 C 函数返回
  double ts = _player->renderVideo();          // 秒
  if (ts < 0) return;
  int64_t tsUs = (int64_t)llround(ts * 1.0e6);
  // 2) 取一张 CVPB → MTLTexture 作输出
  CVPixelBufferRef pb = _pool[_next];
  CVMetalTextureRef cvtex = NULL;
  CVMetalTextureCacheCreateTextureFromImage(
      kCFAllocatorDefault, _texCache, pb, NULL,
      MTLPixelFormatBGRA8Unorm, _outW, _outH, 0, &cvtex);
  id<MTLTexture> outputTex = CVMetalTextureGetTexture(cvtex);
  // 3) 稳定:input=_mdkInput → output=outputTex
  GyroflowProcessInfo info = {0};
  int rc = gyroflow_process_frame_metal_bgra8(
      (GyroflowStabilizer *)_stabilizer, tsUs, -1,
      (__bridge void *)_mdkInput, _inW, _inH,
      (__bridge void *)outputTex, _outW, _outH,
      (__bridge void *)_queue, &info);
  // 4) 等 GPU 完成再标 frame available(用一个 command buffer 的 completed handler;
  //    process_frame 内部用的是传入的 _queue,可另起一个空 command buffer 排在其后做栅栏)
  id<MTLCommandBuffer> cb = [_queue commandBuffer];
  __weak typeof(self) ws = self;
  [cb addCompletedHandler:^(id<MTLCommandBuffer> _) {
    __strong typeof(ws) ss = ws; if (!ss) return;
    [ss->_lock lock];
    ss->_latest = pb;
    ss->_next = (ss->_next + 1) % 3;
    [ss->_lock unlock];
    dispatch_async(dispatch_get_main_queue(), ^{ [ss->_registry textureFrameAvailable:ss->_textureId]; });
  }];
  [cb commit];
  CFRelease(cvtex);
  (void)rc;
}
```

`copyPixelBuffer` 改为加锁返回 `_latest`:
```objc
- (CVPixelBufferRef)copyPixelBuffer {
  [_lock lock]; CVPixelBufferRef pb = _latest ? CVPixelBufferRetain(_latest) : NULL; [_lock unlock];
  return pb;
}
```

> 同步说明:`process_frame_metal_bgra8` 在 `_queue` 上编码 GPU 工作;随后空 command buffer 的 completed handler 作为"这帧渲完"的栅栏,确保 Flutter 拿到的是完成帧。3 张池保证读写不撞。

- [ ] **Step 3: 共享 stabilizer 必须已 openVideo**

预览页流程需保证引擎已加载该视频:`createPreviewTexture` 前,Flutter 侧先 `EngineApi.createStabilizer()` + `openVideo(uri)` + `setStabEnabled(true)` + `pushAllDefaultsAndRecompute()`(复用 S8 那套),再 `createPreviewTexture(uri)`。在 `preview_page.dart` 的 `_start()` 里补这几步(用 `EngineBridgeImpl`/`ParamsModel`,同 smoke)。

- [ ] **Step 4: 真机验收(增量 C)**

进预览页 → 选带陀螺的片子 → 应出现**真实的、防抖后的视频画面**,能播/停。
Expected:画面是稳定后的视频(对比老 `open()` 页同片子,稳定效果一致);播放流畅。
若黑屏/花屏 → 多半是 in/out 尺寸不匹配或 input 纹理未被 MDK 写入(对照 ViewController.mm 的 surface size 设定 @2226-2236)。

- [ ] **Step 5: Checkpoint** — 真机出真实防抖画面,记录后进 Task 5。

---

## Task 5(增量 D):seek + 生命周期 + 4K@60 + 零拷贝验收

**Files:**
- Modify: `ios/Classes/PreviewController.mm`(seek/生命周期)
- Modify: `example/lib/preview_page.dart`(seek 滑块)

- [ ] **Step 1: seekTo + 生命周期**

- `seekToUs:`:`_player->set(mdk::State::Paused)`?→`_player->seek(timestampUs/...)`(MDK seek 单位对照 ViewController.mm 的 seek 用法);seek 后补一帧 `onFrame`。
- `dispose`:停 `_link`、`_player.reset()`、释放三张 CVPB、`CVMetalTextureCacheFlush`+`CFRelease(_texCache)`、注销纹理(PreviewApiImpl 已做)。
- 前后台:`AppDelegate`/页面 `didEnterBackground` 时 `pause`,回前台 `play`(可在 `preview_page.dart` 用 `WidgetsBindingObserver`)。

- [ ] **Step 2: preview_page seek 滑块**

加一个 `Slider`(0..1)→ `_api.seekTo((value * durationUs).toInt())`。duration 可从 `EngineApi`/videoInfo 拿(openVideo 返回的 `durationS`)。

- [ ] **Step 3: 真机验收 —— 4K@60 + 零拷贝(go/no-go)**

1. 用 **4K@60 样片**:进预览页播放,屏上 FPS 应 **贴 60**、画面流畅不掉帧。
2. seek 多次、页面进出多次、切前后台:不崩、不泄漏(Xcode 内存不持续涨)。
3. **Instruments 验零拷贝**:Xcode → Product → Profile → 选 **Metal System Trace**(或 Game Performance / GPU)→ 录一段预览 → 看 GPU 时间线**有没有整帧 `MTLBlitCommandEncoder` copy 或 CPU 端 memcpy**;`copyPixelBuffer` 路径应只传 IOSurface 句柄。(步骤:连真机→Profile→Metal System Trace→Record→操作预览几秒→Stop→查 encoder 列表。)
4. 对照老 `open()` 同片子目测流畅度相当。

**go 判据**:4K@60 持住 + Instruments 无整帧拷贝 + 生命周期稳。达成 → Texture 终态可行,进阶段 3。
**no-go**:掉帧/有整帧拷贝/无法稳定 → 记录瓶颈,按总方案退 PlatformView/三明治。

- [ ] **Step 4: 记录结论**

把 go/no-go 结论 + 实测 FPS/Instruments 截图要点,写回 `~/Desktop/迁移步骤/进度与续接.md`。

---

## 自检结论(写计划时已核对)

- **Spec 覆盖**:架构(Task 2)、PreviewApi 扩展(Task 1)、增量 A/B/C/D(Task 2/3/4/5)、三缓冲同步(Task 4 Step 2)、4K@60+Instruments 零拷贝(Task 5 Step 3)、共享 stabilizer(Task 2 Step 3 + Task 4 Step 3)、不动老页(全程)均有对应。
- **占位扫描**:无 TBD。**已知弱项**:MDK 解码(Task 4)与 seek 单位(Task 5)依赖镜像 `ViewController.mm`,因 MDK 为 C++/无法本机验证,实施时以该文件现成代码为准;FPS 统计给了最简方向由实施 agent 取稳妥写法——这两处是真机迭代点,非占位省略。
- **类型一致**:`PreviewInfo{textureId,width,height}`、`PreviewController` 方法名(`setupWithUri:`/`play`/`pause`/`seekToUs:`/`dispose`/`attachRegistry:textureId:`)、`stabilizerHandle` 在各 Task 一致;`copyPixelBuffer` 返回 retain 后的 CVPB 贯穿 A→C。
- **风险**:原生 GPU 代码盲写,A/B 先验纹理路径与性能、最早暴露 go/no-go 风险;每增量真机独立验收、可弃。
