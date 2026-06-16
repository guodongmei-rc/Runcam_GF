import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var videoPicker: VideoPickerChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "VideoPickerChannel") {
      videoPicker = VideoPickerChannel(messenger: registrar.messenger())
    }
  }
}

/// dev-only:给 example 的 smoke 用的「文档选择器」通道,对齐安卓 ACTION_OPEN_DOCUMENT
/// 与老原生页的 UIDocumentPicker。asCopy:true → 返回原始文件在 app 沙盒里的临时副本
/// 路径(陀螺/GPMF 轨道完整,且无需 security-scope),直接喂给 load_video_file。
/// 不走相册(image_picker),避免 Photos 导出转码剥掉陀螺遥测。
final class VideoPickerChannel: NSObject, UIDocumentPickerDelegate {
  private var pendingResult: FlutterResult?

  init(messenger: FlutterBinaryMessenger) {
    super.init()
    let channel = FlutterMethodChannel(name: "runcam_gf_example/picker", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "pickVideo" else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.present(result: result)
    }
  }

  private func present(result: @escaping FlutterResult) {
    if pendingResult != nil {
      result(FlutterError(code: "BUSY", message: "picker already active", details: nil))
      return
    }
    pendingResult = result
    DispatchQueue.main.async {
      // 用 iOS 8+ 的老 API(不依赖 iOS 14 的 UTType),.import 模式把文件拷进
      // 沙盒临时目录(陀螺轨道完整、无需 security-scope),delegate 返回该副本路径。
      let picker = UIDocumentPickerViewController(
        documentTypes: ["public.movie"], in: .import)
      picker.delegate = self
      picker.allowsMultipleSelection = false
      self.rootViewController()?.present(picker, animated: true)
    }
  }

  private func rootViewController() -> UIViewController? {
    let scene = UIApplication.shared.connectedScenes
      .first { $0.activationState == .foregroundActive } as? UIWindowScene
    var vc = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
    while let presented = vc?.presentedViewController { vc = presented }
    return vc
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    let r = pendingResult
    pendingResult = nil
    r?(urls.first?.path)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    let r = pendingResult
    pendingResult = nil
    r?(nil)
  }
}
