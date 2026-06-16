// 安卓 JNI 桥: Kotlin/JVM → gyroflow_core 的 Rust 核心(方案 Y)
//
// 原则:
// - 所有功能/UI 对齐 iOS;ffi.rs 仅作参考蓝本。
// - 安卓桥直接调 gyroflow 的 Rust 核心(StabilizationManager 等),不经 C FFI。
// - gyroflow 源码一字不改,只把 src/core 当只读依赖。
//
// 平台初始化(对齐上游 set_android_context):
// - gyroflow 核心在安卓上用 app_dirs2 的安卓实现取数据目录,该实现通过
//   `ndk_context::android_context()` 拿 Android Context 再调 getFilesDir()。
// - 上游在启动时 `ndk_context::initialize_android_context(jvm, activity)`;
//   我们必须复刻这一步,否则 android_context() 未初始化会 panic。
// - 因此 Kotlin 必须先调 `nativeInit(context)`,再调任何其它原生方法。

mod preview;
mod stab;
mod undistort;

use jni::EnvUnowned;
use jni::errors::ThrowRuntimeExAndDefault;
use jni::objects::{JClass, JObject};
use jni::sys::jstring;
use std::os::raw::c_void;
use std::sync::atomic::{AtomicBool, Ordering};

static INITED: AtomicBool = AtomicBool::new(false);

/// 初始化 ndk_context(对齐上游 set_android_context)。
/// Kotlin 传入 applicationContext;必须在其它原生调用之前调用一次。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeInit<'local>(
    mut env: EnvUnowned<'local>,
    _class: JClass<'local>,
    context: JObject<'local>,
) {
    env.with_env(|env| -> jni::errors::Result<()> {
        // 只初始化一次(initialize_android_context 内部 assert 不可重复)
        if !INITED.swap(true, Ordering::SeqCst) {
            // 把 gyroflow 的 log 输出接到 logcat(tag=Gyroflow), 便于诊断
            android_logger::init_once(
                android_logger::Config::default()
                    .with_max_level(log::LevelFilter::Info)
                    .with_tag("Gyroflow"),
            );
            let vm = env.get_java_vm()?;
            let global = env.new_global_ref(&context)?; // 全局引用,进程内长存
            unsafe {
                ndk_context::initialize_android_context(
                    vm.get_raw() as *mut c_void,
                    global.into_raw() as *mut c_void, // into_raw 转移所有权,不释放引用
                );
            }
        }
        Ok(())
    })
    .resolve::<ThrowRuntimeExAndDefault>()
}

/// smoke: 直接构造 gyroflow 的 Rust 核心并读取真实字段,验证
/// Kotlin → JNI → gyroflow_core(纯 Rust)整条链路。需先调过 nativeInit。
#[no_mangle]
pub extern "system" fn Java_com_runcam_runcam_GyroflowNative_nativeSmoke<'local>(
    mut env: EnvUnowned<'local>,
    _class: JClass<'local>,
) -> jstring {
    env.with_env(|env| -> jni::errors::Result<jstring> {
      let mgr = gyroflow_core::StabilizationManager::default();
        let params = mgr.params.read();
        let msg = format!(
            "gyroflow core ok: fov={} fps={} frames={}",
            params.fov, params.fps, params.frame_count
        );
        Ok(env.new_string(msg)?.into_raw())
    })
    .resolve::<ThrowRuntimeExAndDefault>()
}
