import Flutter

/// PlatformView 工厂:按 creationParams 的 uri 建一个 `PreviewPlatformView`(原生直出预览),
/// 注入共享 stabilizer 闭包(与 Texture 预览同一个 engine 句柄)。
final class PreviewPlatformViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger
  private let stabilizer: () -> OpaquePointer?

  init(messenger: FlutterBinaryMessenger, stabilizer: @escaping () -> OpaquePointer?) {
    self.messenger = messenger
    self.stabilizer = stabilizer
  }

  func create(withFrame frame: CGRect,
              viewIdentifier viewId: Int64,
              arguments args: Any?) -> FlutterPlatformView {
    return PreviewPlatformView(frame: frame,
                               viewIdentifier: viewId,
                               arguments: args,
                               messenger: messenger,
                               stabilizer: stabilizer().map { UnsafeMutableRawPointer($0) })
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }
}
