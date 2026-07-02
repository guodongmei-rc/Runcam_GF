## 0.2.0

**破坏性变更**

* 移除旧的原生全屏编辑器及其入口:`RuncamGF.open()`、`com.runcam/gyroflow` channel、
  iOS `ViewController`/`Views/*`/`ParamsModel.m`、Android `GyroflowActivity` 及各原生面板。
  宿主改用 `Navigator.push` 打开 Dart 编辑器 `PreviewPage`(参数状态/预览/导出功能等价)。

**修复与改进**

* 文件选择器内聚进插件(宿主无需任何原生配置),并针对宿主环境加固:
  弹出失败自动回收占位(不再永久 BUSY)、Activity 重建后结果不丢、错误统一本地化透出。
* 竖屏键盘弹起时预览/波形自动减半,输入面板不再被压出溢出;镜头搜索改为底部弹窗
  (键盘之上保留大半屏结果区)。
* 导出进度按整百分比节流通知,导出期间不再以编码帧率整页重建。

## 0.0.1

* 初始版本:Gyroflow 防抖引擎的 iOS/Android 封装 + 原生编辑器入口。
