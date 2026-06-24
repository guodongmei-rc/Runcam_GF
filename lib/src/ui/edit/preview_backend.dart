/// 预览渲染后端。Texture=经 Flutter 合成器;PlatformView=嵌原生 MTKView 直出。
/// 二者共享同一 engine stabilizer,可一键切换,参数面板不感知。
enum PreviewBackend { texture, platformView }

extension PreviewBackendX on PreviewBackend {
  String get label => this == PreviewBackend.texture ? 'Texture' : 'PlatformView';
  PreviewBackend get other =>
      this == PreviewBackend.texture ? PreviewBackend.platformView : PreviewBackend.texture;
}
