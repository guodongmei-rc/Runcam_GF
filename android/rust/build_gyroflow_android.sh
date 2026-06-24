#!/usr/bin/env bash
# 构建安卓 JNI 桥 runcam_gyroflow → libruncam_gyroflow.so → android/src/main/jniLibs/<abi>/
#
# 桥 crate 依赖 gyroflow-core(只读), core(含 OpenCV use-opencv)静态链入。只产出一个 .so。
# 不走 cargo-ndk —— cargo-ndk 会硬编码 CLANG_PATH=NDK clang, 覆盖下面的设置, 导致 opencv-rust
# 解析头时把 NDK 内建头摆到 c++/v1 之前(<cstddef> 报错)。改直接 cargo + 自配 NDK 工具链。
#
# 用法:
#   android/rust/build_gyroflow_android.sh                       # 默认编 arm64-v8a + armeabi-v7a 两个
#   ABIS="armeabi-v7a" android/rust/build_gyroflow_android.sh    # 只编指定 ABI
#   BUILD_PROFILE=release android/rust/build_gyroflow_android.sh
set -euo pipefail

export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$HOME/Library/Android/sdk/ndk/26.3.11579264}"
API="${API:-26}"
PROFILE="${BUILD_PROFILE:-release}"
SO_NAME="libruncam_gyroflow.so"
# 要构建的 ABI 列表(空格分隔)。两个全编以同时支持 64/32 位设备。
ABIS="${ABIS:-arm64-v8a armeabi-v7a}"

# PROJECT_DIR = 插件的 android/ 目录(本脚本在 android/rust/ 下)。
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE_DIR="$PROJECT_DIR/rust/runcam_gyroflow"
# Flutter 插件打包的就是 android/src/main/jniLibs/<abi>/(Gradle 无 cargo 步,只装预编译 .so)。
JNILIBS="$PROJECT_DIR/src/main/jniLibs"

GYROFLOW_SRC="${GYROFLOW_SRC:-/Users/gdm/Desktop/Gyroflow_fork}"
OCV_SDK="${OCV_SDK:-$GYROFLOW_SRC/ext/OpenCV-android-sdk}"

NDK_TC="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64"
SYSROOT="$NDK_TC/sysroot"

[ -d "$BRIDGE_DIR" ] || { echo "✗ 找不到桥 crate: $BRIDGE_DIR"; exit 1; }
[ -d "$NDK_TC" ]     || { echo "✗ 找不到 NDK 工具链: $NDK_TC"; exit 1; }
command -v cargo >/dev/null || { echo "✗ 未装 cargo"; exit 1; }

# ── 每个 ABI 的工具链/链接参数映射 ──
abi_rust_target() { case "$1" in
  arm64-v8a)   echo "aarch64-linux-android";;
  armeabi-v7a) echo "armv7-linux-androideabi";;
  *) echo ""; return 1;; esac; }
abi_clang_triple() { case "$1" in
  arm64-v8a)   echo "aarch64-linux-android";;
  armeabi-v7a) echo "armv7a-linux-androideabi";;   # 注意 32 位 clang 前缀是 armv7a(带 a)
  *) echo ""; return 1;; esac; }
abi_libcxx_dir() { case "$1" in
  arm64-v8a)   echo "aarch64-linux-android";;
  armeabi-v7a) echo "arm-linux-androideabi";;       # libc++_shared.so 所在目录(非 v7a)
  *) echo ""; return 1;; esac; }
# kleidicv*(ARM KleidiCV)只有 arm64 提供; armeabi-v7a 的 OpenCV SDK 不含, 否则链接报缺库。
abi_ocv_libs() {
  local base="opencv_stitching,opencv_calib3d,opencv_features2d,opencv_imgproc,opencv_video,opencv_flann,opencv_core,tegra_hal,tbb,ittnotify,z"
  case "$1" in
    arm64-v8a)   echo "${base},kleidicv,kleidicv_hal,kleidicv_thread";;
    armeabi-v7a) echo "${base}";;
  esac; }

echo "→ 桥    : $BRIDGE_DIR"
echo "→ NDK   : $ANDROID_NDK_HOME (api $API)"
echo "→ ABIS  : $ABIS  profile=$PROFILE"
[ -d "$OCV_SDK" ] && echo "→ OpenCV: $OCV_SDK (use-opencv)" || echo "⚠ 未找到 OpenCV SDK ($OCV_SDK), 将不带 OpenCV 编译(autosync 不可用)"
echo

build_one() {
  local ABI="$1"
  local TRIPLE CLANG_TRI LIBCXX_DIR
  TRIPLE="$(abi_rust_target "$ABI")"    || { echo "✗ 不支持的 ABI: $ABI"; exit 1; }
  CLANG_TRI="$(abi_clang_triple "$ABI")"
  LIBCXX_DIR="$(abi_libcxx_dir "$ABI")"

  echo "════════ 构建 $ABI ($TRIPLE, api $API) ════════"
  rustup target add "$TRIPLE" >/dev/null 2>&1 || true

  # ── NDK 工具链(替代 cargo-ndk); cc/cargo 读 target 名下划线大写形式 ──
  local TUP; TUP="$(echo "$TRIPLE" | tr 'a-z-' 'A-Z_')"   # e.g. ARMV7_LINUX_ANDROIDEABI
  local CC="$NDK_TC/bin/${CLANG_TRI}${API}-clang"
  local CXX="$NDK_TC/bin/${CLANG_TRI}${API}-clang++"
  [ -x "$CC" ] || { echo "✗ 找不到 NDK clang: $CC"; exit 1; }
  export CC_${TRIPLE//-/_}="$CC"
  export CXX_${TRIPLE//-/_}="$CXX"
  export AR_${TRIPLE//-/_}="$NDK_TC/bin/llvm-ar"
  export RANLIB_${TRIPLE//-/_}="$NDK_TC/bin/llvm-ranlib"
  export CARGO_TARGET_${TUP}_LINKER="$CC"

  # ── libclang(opencv-rust 解析 C++ 头) ──
  local NDK_LIBCLANG="$NDK_TC/lib"
  [ -f "$NDK_LIBCLANG/libclang.dylib" ] || NDK_LIBCLANG="$NDK_TC/lib64"
  export LIBCLANG_PATH="$NDK_LIBCLANG"

  if [ -d "$OCV_SDK" ]; then
    export OPENCV_LINK_LIBS="$(abi_ocv_libs "$ABI")"
    export OPENCV_LINK_PATHS="$OCV_SDK/sdk/native/staticlibs/$ABI,$OCV_SDK/sdk/native/3rdparty/libs/$ABI"
    export OPENCV_INCLUDE_PATHS="$OCV_SDK/sdk/native/jni/include"
    # opencv 生成器探测 CLANG_PATH 的 clang 取 C++ 搜索路径; 用带 --target/--sysroot 的 NDK clang
    # 包装, 保证顺序(c++/v1→内建→C库), <cstddef> 才能找对 libc++ 的 stddef.h。
    local CLANG_WRAP="$BRIDGE_DIR/.ndk-clang-wrap-$ABI"
    cat > "$CLANG_WRAP" <<WRAP
#!/bin/sh
exec "$NDK_TC/bin/clang" --target=${CLANG_TRI}${API} --sysroot="$SYSROOT" "\$@"
WRAP
    chmod +x "$CLANG_WRAP"
    export CLANG_PATH="$CLANG_WRAP"
    export OPENCV_CLANG_ARGS="--target=${CLANG_TRI}${API} --sysroot=$SYSROOT"
  fi

  ( cd "$BRIDGE_DIR" && cargo build --target "$TRIPLE" --profile "$PROFILE" )

  local OUT_SUBDIR="$PROFILE"; [ "$PROFILE" = "dev" ] && OUT_SUBDIR="debug"
  local SRC_SO="$BRIDGE_DIR/target/$TRIPLE/$OUT_SUBDIR/$SO_NAME"
  [ -f "$SRC_SO" ] || { echo "✗ 未生成 $SO_NAME ($SRC_SO)"; exit 1; }

  mkdir -p "$JNILIBS/$ABI"
  cp -f "$SRC_SO" "$JNILIBS/$ABI/$SO_NAME"
  # 桥静态链入 OpenCV(C++) → 运行期需 libc++_shared.so; 随对应 ABI 一并装入。
  cp -f "$SYSROOT/usr/lib/$LIBCXX_DIR/libc++_shared.so" "$JNILIBS/$ABI/libc++_shared.so"
  local STRIP="$NDK_TC/bin/llvm-strip"
  [ -x "$STRIP" ] && "$STRIP" --strip-unneeded "$JNILIBS/$ABI/$SO_NAME"
  echo "✅ $ABI 完成: $(ls -lh "$JNILIBS/$ABI/$SO_NAME" | awk '{print $5}') → $JNILIBS/$ABI/"
  echo
}

for abi in $ABIS; do
  build_one "$abi"
done
echo "全部完成。jniLibs:"
ls -R "$JNILIBS"
