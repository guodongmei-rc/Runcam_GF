import Flutter
import UIKit

/// RuncamGF Flutter 插件 — iOS 入口。
///
/// Channel: `com.runcam/gyroflow`
/// 方法:
///   - `open`: 全屏 modal 呈现 Gyroflow 防抖界面(GyroflowLauncher),返回 nil。
///
/// 原样从原 App 的 GyroflowBridge 抽离: 行为不变(仍是拉起原生全屏页)。
/// Gyroflow 的 Obj-C/Obj-C++ 源码、libgyroflow_core.a、MDK 都在同一个 pod 里。
public class RuncamGfPlugin: NSObject, FlutterPlugin {

    /// 阶段2:引擎转发壳与回调通道。强引用持有,避免被释放。
    private static var engineApi: EngineApiImpl?
    private static var engineEvents: EngineEvents?
    /// 阶段1:预览 API 转发壳。强引用持有,避免被释放。
    private static var previewApi: PreviewApiImpl?
    /// PlatformView 预览工厂。强引用持有。
    private static var previewPVFactory: PreviewPlatformViewFactory?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "com.runcam/gyroflow",
            binaryMessenger: registrar.messenger()
        )
        let instance = RuncamGfPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)

        // 阶段2:注册 Pigeon 引擎桥(与旧 `open` channel 并存,互不影响)。
        let events = EngineEvents(binaryMessenger: registrar.messenger())
        let engine = EngineApiImpl(events: events)
        EngineApiSetup.setUp(binaryMessenger: registrar.messenger(), api: engine)
        engineEvents = events
        engineApi = engine

        // 阶段1:注册预览 API(共享 engine 的 stabilizer 句柄 + 插件纹理注册表)。
        let preview = PreviewApiImpl(
            textures: registrar.textures(),
            stabilizer: { [weak engine] in engine?.stabilizerHandle },
            events: events
        )
        PreviewApiSetup.setUp(binaryMessenger: registrar.messenger(), api: preview)
        previewApi = preview

        // PlatformView 预览(对照 Texture):嵌原生 MTKView 直出,共享同一 engine stabilizer。
        let pvFactory = PreviewPlatformViewFactory(
            messenger: registrar.messenger(),
            stabilizer: { [weak engine] in engine?.stabilizerHandle }
        )
        registrar.register(pvFactory, withId: "runcam_gf/preview_platformview")
        previewPVFactory = pvFactory
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "open":
            #if targetEnvironment(simulator)
            result(FlutterError(code: "SIMULATOR_UNSUPPORTED",
                                message: "Gyroflow 仅支持真机",
                                details: nil))
            #else
            guard let rootVC = Self.topViewController() else {
                result(FlutterError(code: "NO_CONTROLLER",
                                    message: "找不到可呈现的 rootViewController",
                                    details: nil))
                return
            }
            let vc = GyroflowLauncher.makeRootViewController()
            // iOS push 风格右→左滑入, 对齐 Flutter 路由过渡观感
            if let window = rootVC.view.window {
                let transition = CATransition()
                transition.duration = 0.3
                transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                transition.type = .push
                transition.subtype = .fromRight
                window.layer.add(transition, forKey: kCATransition)
                rootVC.present(vc, animated: false) { result(nil) }
            } else {
                rootVC.present(vc, animated: true) { result(nil) }
            }
            #endif
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// 取当前最顶层可用于 present 的 VC。
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
        let windowScene = scenes.first { $0.activationState == .foregroundActive } as? UIWindowScene
        let keyWindow = windowScene?.windows.first { $0.isKeyWindow }
            ?? windowScene?.windows.first
        var top = keyWindow?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
