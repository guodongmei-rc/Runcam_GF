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
  // true → 当前弹出的是「目录授权」选择器(.open 模式),回调里要返回 file:// 串并保持安全作用域;
  // false → 普通文件 .import 拷贝,回调返回沙盒副本路径。
  private var pendingIsFolder = false
  // 已授权目录的原始 scoped URL 强引用(进程级安全作用域,全程不 stopAccessing,
  // 这样后续 FFI(gyroflow_load_gyro_data 等)与同名 sidecar 扫描都能读该目录下文件)。
  private var grantedFolderURLs: [URL] = []

  // 跨会话恢复用:把授权目录的 security-scoped bookmark 存进 UserDefaults。
  private static let folderBookmarksKey = "gf_example_granted_folder_bookmarks"

  init(messenger: FlutterBinaryMessenger) {
    super.init()
    restoreGrantedFolders()
    let channel = FlutterMethodChannel(name: "runcam_gf_example/picker", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      switch call.method {
      // —— 普通文件:用 .import 拷进沙盒返回副本路径 ——
      case "pickVideo":      self.present(types: ["public.movie"], result: result)
      case "pickLensFile":   self.present(types: ["public.json", "public.data"], result: result)      // 镜头档案 .json
      case "pickMotionFile": self.present(types: ["public.data", "public.item"], result: result)      // 陀螺 sidecar .gcsv/.csv/.bbl…
      // —— 目录授权:用 .open 模式拿到目录的 security-scoped URL ——
      case "pickFolder":
        self.presentFolder(result: result)
      // —— 在已授权目录里递归扫描同名 sidecar(运动数据 / 镜头 json)——
      case "scanFolderForSidecars":
        self.scanFolderForSidecars(args: call.arguments, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func present(types: [String], result: @escaping FlutterResult) {
    if pendingResult != nil {
      result(FlutterError(code: "BUSY", message: "picker already active", details: nil))
      return
    }
    pendingResult = result
    pendingIsFolder = false
    DispatchQueue.main.async {
      // 用 iOS 8+ 的老 API(不依赖 iOS 14 的 UTType),.import 模式把文件拷进
      // 沙盒临时目录(轨道完整、无需 security-scope),delegate 返回该副本路径。
      let picker = UIDocumentPickerViewController(
        documentTypes: types, in: .import)
      picker.delegate = self
      picker.allowsMultipleSelection = false
      self.rootViewController()?.present(picker, animated: true)
    }
  }

  // 弹系统目录选择器,授权目录后返回其 file:// 绝对串。对齐原生 ViewController.selectMotionFolder。
  private func presentFolder(result: @escaping FlutterResult) {
    if pendingResult != nil {
      result(FlutterError(code: "BUSY", message: "picker already active", details: nil))
      return
    }
    pendingResult = result
    pendingIsFolder = true
    DispatchQueue.main.async {
      // 用老 API(documentTypes + .open),不依赖 iOS 14 的 UTType.folder;"public.folder" 即目录 UTI。
      let picker = UIDocumentPickerViewController(
        documentTypes: ["public.folder"], in: .open)
      picker.delegate = self
      picker.allowsMultipleSelection = false
      self.rootViewController()?.present(picker, animated: true)
    }
  }

  // —— 同名 sidecar 扫描:参考 ViewController.scanGrantedFolder: 的扩展名集合与同名匹配逻辑 ——
  private func scanFolderForSidecars(args: Any?, result: @escaping FlutterResult) {
    guard let dict = args as? [String: Any],
          let folderStr = dict["folder"] as? String,
          let base = dict["base"] as? String,
          let folderURL = URL(string: folderStr) else {
      result(nil)
      return
    }
    // 优先用第 1 步保存的同路径原始 scoped URL(作用域才有效);否则退回传入 URL。
    let scanRoot = grantedFolderURLs.first { $0.standardizedFileURL == folderURL.standardizedFileURL } ?? folderURL

    let motionExts: Set<String> = ["gcsv", "bbl", "bfl", "csv"]
    var motionPath: String? = nil
    var lensPath: String? = nil

    let fm = FileManager.default
    if let files = fm.enumerator(
      at: scanRoot,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles],
      errorHandler: nil) {
      for case let f as URL in files {
        guard f.deletingPathExtension().lastPathComponent == base else { continue }
        let ext = f.pathExtension.lowercased()
        if motionPath == nil && motionExts.contains(ext) {
          motionPath = f.path
        } else if lensPath == nil && ext == "json" {
          lensPath = f.path
        }
        if motionPath != nil && lensPath != nil { break }
      }
    }

    // 返回 JSON 字符串;Dart 把路径喂给 gyroflow_load_gyro_data / gyroflow_load_lens_profile(吃文件系统路径)。
    let payload: [String: Any] = [
      "motionPath": motionPath as Any,   // nil → NSNull → JSON null
      "lensPath": lensPath as Any,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
       let json = String(data: data, encoding: .utf8) {
      result(json)
    } else {
      result(nil)
    }
  }

  // 持有授权目录:开启进程级安全作用域(不 stop),强引用保存,并存 bookmark 以便跨会话恢复。
  private func retainGrantedFolder(_ url: URL) {
    _ = url.startAccessingSecurityScopedResource()
    if !grantedFolderURLs.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
      grantedFolderURLs.append(url)
    }
    persistGrantedFolderBookmark(url)
  }

  private func persistGrantedFolderBookmark(_ url: URL) {
    guard let data = try? url.bookmarkData(
      options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) else {
      return
    }
    let defaults = UserDefaults.standard
    var stored = defaults.array(forKey: VideoPickerChannel.folderBookmarksKey) as? [Data] ?? []
    stored.append(data)
    defaults.set(stored, forKey: VideoPickerChannel.folderBookmarksKey)
  }

  // 启动时恢复上次授权的目录,重新开启安全作用域,使本会话也能直接读这些目录。
  private func restoreGrantedFolders() {
    let defaults = UserDefaults.standard
    guard let stored = defaults.array(forKey: VideoPickerChannel.folderBookmarksKey) as? [Data] else {
      return
    }
    for data in stored {
      var stale = false
      if let url = try? URL(
        resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
        _ = url.startAccessingSecurityScopedResource()
        grantedFolderURLs.append(url)
      }
    }
  }

  // 把 .import 临时副本移到 Caches 持久子目录,避免被系统回收。返回稳定路径(失败回退原路径)。
  // 不清空整个目录(否则选镜头/运动文件时会误删已导入的视频);仅覆盖同名。
  private func persistImportedFile(_ src: URL) -> URL? {
    let fm = FileManager.default
    guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
    let dir = caches.appendingPathComponent("gf_imports", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let dst = dir.appendingPathComponent(src.lastPathComponent)
    try? fm.removeItem(at: dst)
    do {
      try fm.moveItem(at: src, to: dst) // .import 副本归我们所有,move 走即可
      return dst
    } catch {
      if (try? fm.copyItem(at: src, to: dst)) != nil { return dst }
      return nil
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
    let wasFolder = pendingIsFolder
    pendingResult = nil
    pendingIsFolder = false
    guard let url = urls.first else { r?(nil); return }
    if wasFolder {
      // 目录授权:持有 scoped URL(进程级作用域,全程不 stop),返回 file:// 绝对串。
      retainGrantedFolder(url)
      r?(url.absoluteString)
    } else {
      // .import 副本落在系统临时位置(tmp/Inbox),内存/磁盘压力下会被系统回收 ——
      // 多次改参数(大量 recompute/GPU/内存抖动)后副本被清掉,导出 AVURLAsset 读不到轨道
      // → 「视频无视频轨道,文件存在=0」。移到 Caches 持久子目录,返回稳定路径。
      r?(persistImportedFile(url)?.path ?? url.path)
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    let r = pendingResult
    pendingResult = nil
    pendingIsFolder = false
    r?(nil)
  }
}
