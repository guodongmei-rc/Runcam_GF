package com.runcam.runcam_gf_example

import io.flutter.embedding.android.FlutterActivity

/**
 * 纯 FlutterActivity,App 层不再自带 picker 拷贝:文件选择器由 runcam_gf 插件内部
 * 提供(ActivityAware + ActivityResultListener)。此前这里在同名 channel 上后注册
 * 覆盖了插件实现,导致 example 测到的不是宿主实际用到的代码路径。
 */
class MainActivity : FlutterActivity()
