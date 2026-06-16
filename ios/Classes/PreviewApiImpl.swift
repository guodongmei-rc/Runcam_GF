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
  private var controller: PreviewController?
  private var textureId: Int64 = -1

  init(textures: FlutterTextureRegistry, stabilizer: @escaping () -> OpaquePointer?) {
    self.textures = textures
    self.stabilizer = stabilizer
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
  func takeCompositedFrameCount() throws -> Int64 { controller?.takeCompositedFrameCount() ?? 0 }
  func setExportMode(on: Bool) throws { /* 阶段4 */ }
}
