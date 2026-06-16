package com.runcam.runcam_gf

import android.app.Activity
import android.content.Intent
import com.runcam.runcam.GyroflowActivity
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/**
 * RuncamGF Flutter 插件 — Android 入口。
 *
 * Channel: `com.runcam/gyroflow`
 *   - `open`: startActivity 拉起 [GyroflowActivity](原生全屏防抖页),返回 null。
 *
 * 原样从原 App 的 MainActivity 抽离: 行为不变。Gyroflow 的 Kotlin 源码、
 * libruncam_gyroflow.so 都在本插件模块里。
 */
class RuncamGfPlugin :
    FlutterPlugin,
    MethodCallHandler,
    ActivityAware {

    private lateinit var channel: MethodChannel
    private var activity: Activity? = null
    private var engineEvents: EngineEvents? = null // 阶段2:原生→Dart 回调通道

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "com.runcam/gyroflow")
        channel.setMethodCallHandler(this)

        // 阶段2:注册 Pigeon 引擎桥(与旧 `open` channel 并存,互不影响)。
        val events = EngineEvents(binding.binaryMessenger)
        engineEvents = events
        EngineApi.setUp(
            binding.binaryMessenger,
            EngineApiImpl(binding.applicationContext, events),
        )
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "open" -> {
                val act = activity
                if (act == null) {
                    result.error("NO_ACTIVITY", "插件未附着到 Activity", null)
                    return
                }
                act.startActivity(Intent(act, GyroflowActivity::class.java))
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        EngineApi.setUp(binding.binaryMessenger, null)
        engineEvents = null
    }

    // —— ActivityAware: 拿到宿主 Activity 用于 startActivity ——
    override fun onAttachedToActivity(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onDetachedFromActivityForConfigChanges() { activity = null }
    override fun onDetachedFromActivity() { activity = null }
}
