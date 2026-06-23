import 'package:flutter/material.dart';
import 'package:toastification/toastification.dart';

/// 统一吐司(对齐项目用法):warning 样式 + flat、顶部居中、上滑关闭、3 秒自动消失,
/// 先 dismissAll 清旧的不堆叠。依赖 main.dart 的 ToastificationWrapper 提供全局 overlay,
/// 故无需传 context。
/// 注:本项目无相机场景旋转,rotateAngle 恒 0(顶部居中),translateOffsetX/Y 不处理。
void showAppToast(String message) {
  toastification.dismissAll();
  toastification.show(
    type: ToastificationType.warning,
    style: ToastificationStyle.flat,
    title: Text(message),
    autoCloseDuration: const Duration(seconds: 3),
    alignment: Alignment.topCenter,
    dismissDirection: DismissDirection.up,
  );
}
