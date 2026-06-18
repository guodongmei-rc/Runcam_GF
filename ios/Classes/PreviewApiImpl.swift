import Foundation
import Flutter

/// 实现 Pigeon `PreviewApi`:持有 `PreviewController`,注册 FlutterTexture,转发控制。
///
/// 增量 A:`createPreviewTexture` 建一个返回纯色 CVPixelBuffer 的 controller,
/// 注册到插件纹理表拿 textureId,返回给 Flutter `Texture(textureId:)` 显示。
/// stabilizer 句柄经闭包从 `EngineApiImpl` 共享(增量 A 不用,占位)。
final class PreviewApiImpl: NSObject, PreviewApi {
  private let textures: FlutterTextureRegistry
  private let stabilizer: () -> OpaquePointer?
  private let events: EngineEvents?
  private var controller: PreviewController?
  private var textureId: Int64 = -1
  private var exporter: GFExporter?
  // 专用串行队列、显式 Default QoS —— 对齐原生 self.exportQueue。显式 .default 避免 async
  // 块从调用方(高 QoS)继承 user-initiated 后去等核心 Default QoS 线程,造成优先级反转 + 卡顿。
  private let exportQueue = DispatchQueue(label: "com.runcam.gf.export", qos: .default)

  init(textures: FlutterTextureRegistry,
       stabilizer: @escaping () -> OpaquePointer?,
       events: EngineEvents?) {
    self.textures = textures
    self.stabilizer = stabilizer
    self.events = events
  }

  func createPreviewTexture(uriOrPath: String) throws -> PreviewInfo {
    // 已有纹理先清理,避免重复进页时泄漏。
    if textureId >= 0 {
      textures.unregisterTexture(textureId)
    }
    controller?.dispose()

    let ctrl = PreviewController(stabilizer: stabilizer().map { UnsafeMutableRawPointer($0) })
    let size = ctrl.setup(withUri: uriOrPath)
    let tid = textures.register(ctrl)
    // 增量 B:把纹理注册表与 textureId 回传给 controller,
    // 供 CADisplayLink 每帧 textureFrameAvailable:。必须在 play() 前完成。
    ctrl.attach(registry: textures, textureId: tid)
    controller = ctrl
    textureId = tid
    return PreviewInfo(textureId: tid,
                       width: Int64(size.width),
                       height: Int64(size.height))
  }

  func disposePreviewTexture(textureId: Int64) throws {
    if textureId >= 0 {
      textures.unregisterTexture(textureId)
    }
    controller?.dispose()
    controller = nil
    self.textureId = -1
  }

  func play() throws { controller?.play() }
  func pause() throws { controller?.pause() }
  func seekTo(timestampUs: Int64) throws { controller?.seek(toUs: timestampUs) }
  func renderOnce() throws { controller?.renderOnce() }
  func takeCompositedFrameCount() throws -> Int64 { controller?.takeCompositedFrameCount() ?? 0 }
  func setExportMode(on: Bool) throws { /* 导出走 startExport,这里不再单独用 */ }

  // 导出:复用共享 stabilizer 在后台队列逐帧编码,进度经 EngineEvents.onExportProgress 回报。
  // 返回约定:成功 ""、失败错误信息、取消 "已取消"(对齐 Dart startExport 解析)。
  func startExport(req: ExportRequest, completion: @escaping (Result<String, Error>) -> Void) {
    guard let stab = stabilizer() else { completion(.success("stabilizer 未就绪")); return }
    // 导出必须复用预览的 Metal device/queue(对齐原生共用 self.metalDevice/self.commandQueue):
    // 核心 GPU 上下文绑在预览 queue 上,另建 queue 会不匹配而崩溃。
    guard let ctrl = controller,
          let dev = ctrl.metalDevicePtr(),
          let q = ctrl.commandQueuePtr() else {
      completion(.success("预览未就绪,无法导出"))
      return
    }
    // 关键:导出前暂停并排空预览渲染队列,确保导出不与预览渲染循环并发访问同一 stabilizer
    // (核心非线程安全,并发 process_frame 会崩溃)。
    ctrl.pauseAndDrain()
    let src = req.srcUri ?? ""
    guard !src.isEmpty else { completion(.success("源视频为空")); return }
    let srcURL = src.hasPrefix("file://") ? (URL(string: src) ?? URL(fileURLWithPath: src))
                                          : URL(fileURLWithPath: src)
    let fileName = (req.fileName?.isEmpty == false) ? req.fileName! : "gyroflow_stabilized.mp4"

    // 输出目录:已选则用(security-scoped best-effort),否则落临时目录。
    var folderURL: URL? = nil
    let outUri = req.outputUri ?? ""
    if !outUri.isEmpty {
      folderURL = outUri.hasPrefix("file://") ? URL(string: outUri) : URL(fileURLWithPath: outUri)
    }
    let scoped = folderURL?.startAccessingSecurityScopedResource() ?? false
    // 同名文件自动改名 _1.._999(对齐官方 renameOutput / GFExportUtils.uniqueURLInFolder),
    // 不覆盖已有文件。
    let baseFolder = folderURL ?? URL(fileURLWithPath: NSTemporaryDirectory())
    let dstURL = GFExportUtils.uniqueURL(inFolder: baseFolder, forName: fileName)

    let exp = GFExporter(stabilizer: UnsafeMutableRawPointer(stab), device: dev, queue: q)
    exporter = exp
    let ev = events
    let capturedFolder = folderURL
    exportQueue.async { [weak self] in
      let err = exp.export(fromURL: srcURL, toURL: dstURL,
                           codecIndex: Int32(req.codecIndex ?? 0),
                           bitrateMbps: Int32(req.bitrateMbps ?? 0),
                           exportAudio: req.exportAudio ?? true,
                           outW: UInt32(max(0, req.width ?? 0)),
                           outH: UInt32(max(0, req.height ?? 0))) { p, frame, total in
        DispatchQueue.main.async {
          ev?.onExportProgress(progress: p, frame: Int64(frame), total: Int64(total)) { _ in }
        }
      }
      if scoped { capturedFolder?.stopAccessingSecurityScopedResource() }
      DispatchQueue.main.async {
        self?.exporter = nil
        if let err = err as NSError? {
          completion(.success(err.code == 99 ? "已取消" : err.localizedDescription))
        } else {
          completion(.success(""))
        }
      }
    }
  }

  func cancelExport() throws { exporter?.cancelled = true }
}
