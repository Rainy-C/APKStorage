#!/usr/bin/env bash
set -euo pipefail

ts(){ date "+[%Y-%m-%d %H:%M:%S]"; }
ok(){ echo "$(ts) [OK] $*"; }
info(){ echo "$(ts) [..] $*"; }
err(){ echo "$(ts) [ERR] $*" >&2; exit 1; }

PROXY_URL="socks5h://18.183.63.49:3233"
USE_PROXY="n"

printf "是否启用代理？（SOCKS5: %s）\n输入 y 启用 / n 不启用 [y/N]: " "$PROXY_URL"
read -r ans || ans=""
if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
  USE_PROXY="y"
else
  USE_PROXY="n"
fi

if [ "$USE_PROXY" = "y" ]; then
  export ALL_PROXY="$PROXY_URL"
  export HTTPS_PROXY="$PROXY_URL"
  export HTTP_PROXY="$PROXY_URL"
  export NO_PROXY="127.0.0.1,localhost,::1"
  cat >/etc/profile.d/proxy.sh <<EOF
export ALL_PROXY="$PROXY_URL"
export HTTPS_PROXY="$PROXY_URL"
export HTTP_PROXY="$PROXY_URL"
export NO_PROXY="127.0.0.1,localhost,::1"
EOF
  chmod 0644 /etc/profile.d/proxy.sh
  ok "代理已启用：$PROXY_URL"
else
  rm -f /etc/profile.d/proxy.sh >/dev/null 2>&1 || true
  unset ALL_PROXY HTTPS_PROXY HTTP_PROXY || true
  export NO_PROXY="127.0.0.1,localhost,::1"
  ok "代理未启用"
fi

info "安装依赖：ca-certificates curl unzip git xz-utils zip jq"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y ca-certificates curl unzip git xz-utils zip jq >/dev/null
ok "依赖安装完成"

if ! id flutter >/dev/null 2>&1; then
  useradd -m -s /bin/bash flutter
  ok "已创建用户：flutter"
else
  ok "用户已存在：flutter"
fi

mkdir -p /home/flutter/.android /home/flutter/.gradle
touch /home/flutter/.android/repositories.cfg
chown -R flutter:flutter /home/flutter/.android /home/flutter/.gradle

FLUTTER_DIR="/opt/flutter"
if [ ! -d "$FLUTTER_DIR/.git" ]; then
  info "克隆 Flutter stable 到 $FLUTTER_DIR"
  rm -rf "$FLUTTER_DIR" >/dev/null 2>&1 || true
  git clone -b stable https://github.com/flutter/flutter.git "$FLUTTER_DIR" >/dev/null
  ok "Flutter clone 完成"
else
  ok "Flutter 已存在：$FLUTTER_DIR（跳过 clone）"
fi

cat >/etc/profile.d/flutter.sh <<'EOF'
export FLUTTER_HOME=/opt/flutter
export PATH="$FLUTTER_HOME/bin:$PATH"
EOF
chmod 0644 /etc/profile.d/flutter.sh

SDK="/opt/android-sdk"
CMDLINE_URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
CMDLINE_ZIP="/tmp/cmdline-tools.zip"

info "安装 Android SDK 到 $SDK"
mkdir -p "$SDK"
chown -R flutter:flutter "$SDK"

if [ ! -x "$SDK/cmdline-tools/latest/bin/sdkmanager" ]; then
  info "下载 cmdline-tools"
  rm -f "$CMDLINE_ZIP" >/dev/null 2>&1 || true
  curl -fsSL -o "$CMDLINE_ZIP" "$CMDLINE_URL"
  rm -rf "$SDK/cmdline-tools" >/dev/null 2>&1 || true
  mkdir -p "$SDK/cmdline-tools/latest"
  unzip -q "$CMDLINE_ZIP" -d /tmp/cmdline-tools-unzip
  mv /tmp/cmdline-tools-unzip/cmdline-tools/* "$SDK/cmdline-tools/latest/"
  rm -rf /tmp/cmdline-tools-unzip >/dev/null 2>&1 || true
  ok "cmdline-tools 安装完成"
else
  ok "cmdline-tools 已存在"
fi

cat >/etc/profile.d/android-sdk.sh <<EOF
export ANDROID_HOME="$SDK"
export ANDROID_SDK_ROOT="$SDK"
export PATH="\$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:\$ANDROID_SDK_ROOT/platform-tools:\$PATH"
EOF
chmod 0644 /etc/profile.d/android-sdk.sh

SDKMANAGER="$SDK/cmdline-tools/latest/bin/sdkmanager"

sdk_no_proxy(){
  env -u ALL_PROXY -u HTTPS_PROXY -u HTTP_PROXY -u all_proxy -u https_proxy -u http_proxy \
    "$SDKMANAGER" --sdk_root="$SDK" "$@"
}

info "接受 licenses"
yes | sdk_no_proxy --licenses >/dev/null || true
ok "licenses 已处理"

info "安装 platforms/build-tools（sdkmanager 不支持 socks5h，运行时临时移除代理环境变量）"
sdk_no_proxy "platform-tools" "platforms;android-36" "build-tools;35.0.1" >/dev/null
ok "platforms/build-tools 安装完成"

info "安装 NDK/CMake（如失败不阻断）"
set +e
sdk_no_proxy "ndk;28.2.13676358" "cmake;3.22.1" >/dev/null
set -e
ok "NDK/CMake 步骤结束"

chown -R flutter:flutter "$SDK"

info "配置 flutter（仅启用 Android，关闭 web/linux），并关闭 analytics"
su - flutter -c "source /etc/profile.d/flutter.sh && source /etc/profile.d/android-sdk.sh && flutter config --no-enable-web --no-enable-linux-desktop >/dev/null 2>&1 || true"
su - flutter -c "source /etc/profile.d/flutter.sh && flutter config --no-analytics >/dev/null 2>&1 || true"
ok "flutter config 完成"

info "补一次 flutter doctor --android-licenses（无代理环境，避免乱报）"
su - flutter -c "source /etc/profile.d/flutter.sh && source /etc/profile.d/android-sdk.sh && env -u ALL_PROXY -u HTTPS_PROXY -u HTTP_PROXY flutter doctor --android-licenses >/dev/null 2>&1 || true"
ok "android licenses 步骤结束"

info "快速检查：flutter --version"
su - flutter -c "source /etc/profile.d/flutter.sh && flutter --version" | head -n 3 || true

ok "完成 ✅"
echo "用法："
echo "  su - flutter"
echo "  source /etc/profile.d/flutter.sh"
echo "  source /etc/profile.d/android-sdk.sh"
echo "  flutter doctor"
