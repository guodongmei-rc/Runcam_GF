import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    // 只注册插件,App 层不再自带 picker 拷贝:文件选择器由插件内部的
    // VideoPickerChannel 提供。此前这里在同名 channel 上后注册覆盖了插件实现,
    // 导致 example 测到的不是宿主实际用到的代码路径(插件路径的问题只在宿主暴露)。
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
