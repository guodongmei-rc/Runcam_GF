#
# RuncamGF — Flutter 插件 podspec。
# 封装 libgyroflow_core.a + OpenCV + flatbuffers 静态库、MDK 播放器 xcframework,
# 以及 iOS 端预览/同步/导出 Obj-C/Obj-C++ 薄壳 + Flutter 插件入口(Swift)。
# 编辑器 UI 已迁到共享 Dart 层,原生只保留必须项(解码/预览/导出/选择器)。
# 仅支持 arm64 真机。
#
Pod::Spec.new do |s|
  s.name             = 'runcam_gf'
  s.version          = '0.1.0'
  s.summary          = 'RuncamGF — Gyroflow 视频防抖 Flutter 插件(iOS 原生集成)。'
  s.description      = <<-DESC
    封装 Gyroflow core 静态库(libgyroflow_core.a + OpenCV + flatbuffers)、
    MDK 播放器 xcframework,以及 iOS 端的预览/同步/导出 Obj-C/Obj-C++ 薄壳。
    编辑器 UI 在共享 Dart 层,原生经 Pigeon(EngineApi/PreviewApi)转发。
    仅支持 arm64 真机。
  DESC
  s.homepage         = 'https://gyroflow.xyz'
  s.license          = { :type => 'GPL-3.0-or-later' }
  s.author           = { 'Runcam' => 'dev@runcam.com' }
  s.source           = { :path => '.' }

  s.platform         = :ios, '14.0'
  s.requires_arc     = true
  s.swift_version    = '5.0'
  # 模块名必须等于 pod 名,Flutter 的 GeneratedPluginRegistrant 用 `@import runcam_gf;`。
  # 不要设置 header_dir = 'Gyroflow',否则模块会被命名为 Gyroflow 导致 "Module 'runcam_gf' not found"。
  s.module_name      = 'runcam_gf'

  s.dependency 'Flutter'

  # Flutter 插件入口(Swift) + 阶段1 预览 Obj-C++(Classes 下的 .h/.mm)
  # + Gyroflow Obj-C/Obj-C++ 源码 + FFI 头。
  s.source_files     = 'Classes/**/*.{swift,h,mm}', 'Sources/**/*.{h,m,mm}', 'Libs/gyroflow_ffi.h'
  # PreviewController.h 进 public(umbrella)header,Swift 才能 import 到 PreviewController。
  s.public_header_files = 'Libs/gyroflow_ffi.h', 'Sources/AutosyncRunner.h', 'Classes/PreviewController.h', 'Classes/PreviewPlatformView.h', 'Classes/GFExporter.h', 'Sources/GFExportUtils.h'
  s.preserve_paths   = 'Libs/*.a', 'MDK/include/**/*'

  s.vendored_libraries = [
    'Libs/libgyroflow_core.a',
    'Libs/libflatbuffers.a',
    'Libs/libopencv_calib3d4.a',
    'Libs/libopencv_core4.a',
    'Libs/libopencv_features2d4.a',
    'Libs/libopencv_flann4.a',
    'Libs/libopencv_imgproc4.a',
    'Libs/libopencv_stitching4.a',
    'Libs/libopencv_video4.a',
  ]
  s.vendored_frameworks = 'MDK/mdk.xcframework'

  # 导出走系统 AVAssetWriter(VideoToolbox: H.264/HEVC/ProRes)。
  s.frameworks = 'MetalKit', 'Metal', 'AVFoundation', 'CoreVideo', 'CoreMedia', 'VideoToolbox', 'Photos', 'UniformTypeIdentifiers', 'QuartzCore', 'UIKit'
  s.libraries  = 'c++', 'z'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'HEADER_SEARCH_PATHS' => '"${PODS_TARGET_SRCROOT}/Libs" "${PODS_TARGET_SRCROOT}/MDK/include"',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'gnu++17',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'GCC_C_LANGUAGE_STANDARD' => 'gnu11',
    # 仅支持真机 arm64。注意不要用 EXCLUDED_ARCHS[sdk=iphonesimulator*]=arm64:
    # Xcode 26+ 模拟器只剩 arm64,排除它会导致 "excluding the arm64 architecture" 报错。
    # 真机构建只用 arm64 device 切片,不受影响;模拟器因 vendored 库无 sim 切片本就不支持。
    'VALID_ARCHS' => 'arm64',
    'OTHER_LDFLAGS' => '-framework mdk',
  }
end
