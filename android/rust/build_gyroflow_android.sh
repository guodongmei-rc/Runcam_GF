#!/usr/bin/env bash
# 构建安卓 JNI 桥 runcam_gyroflow → libruncam_gyroflow.so → android/app/src/main/jniLibs/<abi>/
#
# 桥 crate 依赖 gyroflow-core(只读), core(含 OpenCV use-opencv)静态链入。只产出一个 .so。
# 不走 cargo-ndk —— cargo-ndk 会硬编码 CLANG_PATH=NDK clang, 覆盖下面的设置, 导致 opencv-rust
# 解析头时把 NDK 内建头摆到 c++/v1 之前(<cstddef> 报错)。改直接 cargo + 自配 NDK 工具链。
#
# 用法:
#   scripts/build_gyroflow_android.sh
#   BUILD_PROFILE=release scripts/build_gyroflow_android.sh
set -euo pipefail

export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$HOME/Library/Android/sdk/ndk/26.3.11579264}"
ABI="arm64-v8a"
TRIPLE="aarch64-linux-android"
API="${API:-26}"
PROFILE="${BUILD_PROFILE:-release}"
SO_NAME="libruncam_gyroflow.so"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE_DIR="$PROJECT_DIR/android/rust/runcam_gyroflow"
JNILIBS="$PROJECT_DIR/android/app/src/main/jniLibs"

GYROFLOW_SRC="${GYROFLOW_SRC:-/Users/gdm/Desktop/gyroflow-master5.6ios}"
OCV_SDK="${OCV_SDK:-$GYROFLOW_SRC/ext/OpenCV-android-sdk}"

NDK_TC="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64"
SYSROOT="$NDK_TC/sysroot"

[ -d "$BRIDGE_DIR" ] || { echo "✗ 找不到桥 crate: $BRIDGE_DIR"; exit 1; }
[ -d "$NDK_TC" ]     || { echo "✗ 找不到 NDK 工具链: $NDK_TC"; exit 1; }
command -v cargo >/dev/null || { echo "✗ 未装 cargo"; exit 1; }
rustup target add "$TRIPLE" >/dev/null 2>&1 || true

echo "→ 桥    : $BRIDGE_DIR"
echo "→ NDK   : $ANDROID_NDK_HOME"
echo "→ ABI   : $ABI (api $API), profile=$PROFILE"

# ── NDK 工具链(替代 cargo-ndk) ──
export CC_aarch64_linux_android="$NDK_TC/bin/${TRIPLE}${API}-clang"
export CXX_aarch64_linux_android="$NDK_TC/bin/${TRIPLE}${API}-clang++"
export AR_aarch64_linux_android="$NDK_TC/bin/llvm-ar"
export RANLIB_aarch64_linux_android="$NDK_TC/bin/llvm-ranlib"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$NDK_TC/bin/${TRIPLE}${API}-clang"

# ── libclang(opencv-rust 解析 C++ 头) ──
NDK_LIBCLANG="$NDK_TC/lib"
[ -f "$NDK_LIBCLANG/libclang.dylib" ] || NDK_LIBCLANG="$NDK_TC/lib64"
export LIBCLANG_PATH="$NDK_LIBCLANG"

if [ -d "$OCV_SDK" ]; then
  export OPENCV_LINK_LIBS="opencv_stitching,opencv_calib3d,opencv_features2d,opencv_imgproc,opencv_video,opencv_flann,opencv_core,tegra_hal,tbb,ittnotify,z,kleidicv,kleidicv_hal,kleidicv_thread"
  export OPENCV_LINK_PATHS="$OCV_SDK/sdk/native/staticlibs/$ABI,$OCV_SDK/sdk/native/3rdparty/libs/$ABI"
  export OPENCV_INCLUDE_PATHS="$OCV_SDK/sdk/native/jni/include"
  # opencv 生成器探测 CLANG_PATH 的 clang 取其 C++ 搜索路径; 指向带 --target/--sysroot 的 NDK clang
  # 包装, 探测到的就是正确的 android 顺序(c++/v1→内建→C库), <cstddef> 才能找对 libc++ 的 stddef.h。
  CLANG_WRAP="$PROJECT_DIR/scripts/.ndk-clang-wrap"
  cat > "$CLANG_WRAP" <<WRAP
#!/bin/sh
exec "$NDK_TC/bin/clang" --target=${TRIPLE}${API} --sysroot="$SYSROOT" "\$@"
WRAP
  chmod +x "$CLANG_WRAP"
  export CLANG_PATH="$CLANG_WRAP"
  # opencv-rust 生成器只读 OPENCV_CLANG_ARGS(非 BINDGEN_EXTRA_CLANG_ARGS)
  export OPENCV_CLANG_ARGS="--target=${TRIPLE}${API} --sysroot=$SYSROOT"
  echo "→ OpenCV: $OCV_SDK (use-opencv)"
else
  echo "⚠ 未找到 OpenCV SDK ($OCV_SDK), 将不带 OpenCV 编译(autosync 不可用)"
fi
echo

cd "$BRIDGE_DIR"
cargo build --target "$TRIPLE" --profile "$PROFILE"

OUT_SUBDIR="$PROFILE"; [ "$PROFILE" = "dev" ] && OUT_SUBDIR="debug"
SRC_SO="$BRIDGE_DIR/target/$TRIPLE/$OUT_SUBDIR/$SO_NAME"
echo
if [ -f "$SRC_SO" ]; then
  mkdir -p "$JNILIBS/$ABI"
  cp -f "$SRC_SO" "$JNILIBS/$ABI/$SO_NAME"
  STRIP="$NDK_TC/bin/llvm-strip"
  [ -x "$STRIP" ] && "$STRIP" --strip-unneeded "$JNILIBS/$ABI/$SO_NAME" && echo "已 strip"
  echo "✅ 完成: $(ls -lh "$JNILIBS/$ABI/$SO_NAME" | awk '{print $5}') → $JNILIBS/$ABI/$SO_NAME"
else
  echo "✗ 未生成 $SO_NAME ($SRC_SO)"; exit 1
fi
