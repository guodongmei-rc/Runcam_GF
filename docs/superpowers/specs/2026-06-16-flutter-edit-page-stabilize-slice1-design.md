# 阶段3 切片1 设计:Flutter 编辑页骨架 + 可切换预览 + Stabilize 面板

> 日期:2026-06-16
> 阶段:GF 功能 Flutter 化 — 阶段3(搬 UI 面板)第 1 个垂直切片
> 项目:`/Users/gdm/Desktop/GFRuncam`
> 前置:S7 `ParamsModel`(68 参数,14 单测绿)已完成;Texture 预览 + PlatformView 预览均已落地并存。
> 决策依据:`~/Desktop/迁移步骤/阶段1-预览性能调查与Texture-vs-PlatformView结论.md`(Texture 为预览终态)。

## 目标与闭环判据

把原生 `StabilizeSectionView` 搬成 Flutter `StabilizePanel`,接到已完成的 `ParamsModel`,跑通**完整调参闭环**:

> **Flutter 拖面板 → `ParamsModel` → 引擎 → recompute → 预览实时反映。**

并验证**预览渲染与面板解耦**:一键把预览后端从 **Texture** 切到 **PlatformView**,**同一套面板继续调、效果一致**。

**总原则**:在现有「预览 Texture spike (dev)」页上扩展;**不动老 `open()` 全屏原生页**(随时回退);其余面板(Sync/Advanced/Export/Motion)与"替换 open()"不在本切片。

## 三层解耦架构(核心)

```
编辑页(preview_page.dart 扩展而来,dev 按钮进)
├─ 预览区  PreviewView ── 可切后端(只负责"显示共享 stabilizer 的输出")
│    ├─ Texture 后端:Texture(textureId)        ← 现有 PreviewController
│    └─ PlatformView 后端:UiKitView            ← 现有 PreviewPlatformView
│    AppBar 开关「Texture⇄PlatformView」一键切
├─ 控制条:选视频 / play-pause / 预览后端开关
└─ 参数区  StabilizePanel(本切片唯一面板)
        │ 拖动控件 → 调 ParamsModel setter
        ▼
   ParamsModel ─→ EngineBridge ─→ 引擎 ─→ recompute ─→ 预览(任一后端)自动反映
```

**解耦不变量(本切片必须成立):**
1. **`StabilizePanel` 与 `EditController` 的参数部分只依赖 `ParamsModel` / `EngineBridge`,绝不引用预览后端**(不 import PreviewApi / UiKitView)。
2. **`PreviewView` 只依赖"显示句柄"(textureId / viewType),不碰参数**。
3. 两后端**共享同一个 engine stabilizer**;参数改动经引擎 recompute,**两后端都会反映**(因为都对同一句柄 `process_frame`)。

## 组件

| 组件 | 文件(新增/改) | 职责 |
|---|---|---|
| `PreviewBackend` enum | `example/lib/edit/preview_backend.dart`(新) | `{ texture, platformView }` |
| `PreviewView` | `example/lib/edit/preview_view.dart`(新) | 按当前后端渲染 `Texture(textureId)` 或 `UiKitView`;不含任何参数逻辑 |
| `EditController` | `example/lib/edit/edit_controller.dart`(新,`ChangeNotifier`) | 视频生命周期、引擎初始化(一次)、`ParamsModel` 持有、当前预览后端 + 切换、play/pause、dispose。页面与面板听它 |
| `StabilizePanel` | `example/lib/edit/panels/stabilize_panel.dart`(新) | Stabilize 控件 → `ParamsModel` setter;只读回填(maxAngle/minFov)显示 |
| 编辑页 | `example/lib/preview_page.dart`(扩展) | Scaffold:AppBar(标题+后端开关)+ Column[ PreviewView(Expanded/AspectRatio) + 控制条 + StabilizePanel(可滚动) ] |

> 引擎初始化序列复用现有:`createStabilizer → openVideo → setStabEnabled → setGyroOffset(48, raw-IMU 默认) → pushAllDefaultsAndRecompute`,由 `EditController` 做**一次**;两预览后端共用。

## StabilizePanel 控件(镜像 `StabilizeSectionView`,接 `params_model_stabilize` + `_zoom`)

| 控件 | ParamsModel 字段 | 类型 |
|---|---|---|
| 平滑度 | `smoothness` | 滑块 0–100% |
| 每轴平滑(开关 + P/Y/R) | `perAxis` / `smoothnessPitch/Yaw/Roll` | 开关 + 3 滑块(展开) |
| 地平线锁定 | `horizonLock`(9 参聚合,经 `pushHorizonLock`) | 开关 + amount/roll 滑块 |
| 最大缩放 | `maxZoomPercent` / `maxZoomIterations` | 滑块 |
| 裁切模式 | `croppingMode`(→ adaptiveZoom 映射) | 分段 none/adaptive/static |
| 镜头校正 | `lensCorrection` | 滑块 |

> 本切片以**主控件 + 调参闭环**为准;每个控件改值即走 `ParamsModel` 既有 setter(clamp→推引擎→200ms 防抖→recompute→回填),**无需新增引擎逻辑**。地平线/缩放的全部高级子参数照搬,但 UI 可先放主参数,子参数随 Advanced 切片补——以"闭环跑通 + 主参数齐"为完成线。

## 数据流 / 预览后端切换

- **调参**:控件 onChanged → `ParamsModel.xxx = v` → 既有链路 → 200ms 后 recompute → `EditController` 收到回填(maxAngle/minFov)→ notify → 面板只读区刷新;预览后端因共享句柄自动显示新结果。
- **切后端(一键)**:`EditController.switchBackend(other)` → 拆当前后端(Texture:`disposePreviewTexture` + 注销;PlatformView:`pv.dispose`)→ 起另一后端(**会重新解码**,因两后端各自有独立 MDK)。**`ParamsModel` 状态全程不动**,切完面板继续调。两后端不能同时开(共享句柄 + 双 4K 解码过重)。

## 错误处理

- 引擎调用错误已被 `ParamsModel.send` 吞掉(阶段0+2 桥可能未 createStabilizer 时被调)。
- 选视频失败 / 切后端失败 → SnackBar 提示,保持当前状态可用。
- 页面 dispose:停 ticker、拆预览后端、`freeStabilizer`。

## 测试

- **已有**:`ParamsModel` 14 单测(覆盖 setter→引擎→recompute 链路)。
- **本切片新增**:`StabilizePanel` widget 测——用 `FakeEngineBridge` + `ParamsModel`,验证"拖平滑度滑块 → `smoothness` setter 被调、值正确";`croppingMode` 分段 → 对应 setter。**不测预览渲染**(原生 GPU,真机回归)。
- **真机验收(闭环)**:选片 → 拖平滑度/地平线/缩放 → 预览实时变;一键切 PlatformView,同面板继续调,效果一致。

## 产物

**新增**:`example/lib/edit/{preview_backend,preview_view,edit_controller}.dart`、`example/lib/edit/panels/stabilize_panel.dart`、对应 widget 测。
**改动(非删除)**:`example/lib/preview_page.dart`(扩成编辑页:接 `EditController` + `PreviewView` + `StabilizePanel`);现有 Texture 初始化/play-pause/seek 逻辑迁进 `EditController`。
**不动**:`ParamsModel` 与引擎桥(只调用)、`PreviewController.mm` / `PreviewPlatformView.mm`(只复用)、老 `open()` / 安卓侧。

## 明确不在本切片范围(YAGNI)

Sync / Advanced / Export / Motion 面板;替换正式 `open()` 入口;autosync;导出;方向指示器/陀螺时间轴;地平线/缩放的全部高级子参数(主参数先行);新旧数值对账(可在面板齐后作可选强校验)。

## 风险与回滚

- **最大风险=解耦没做干净**:面板里不小心引用了预览后端 → 切后端时连锁坏。**验收专门测"切后端后面板照常工作"**。
- **切后端重解码延迟**:一键切会黑一下再起(重新解码 4K),可接受;加 loading 态。
- **回滚**:全程在 dev 页新增/扩展,老 `open()` 不动;切片失败弃这页即可,不影响已完成成果。
