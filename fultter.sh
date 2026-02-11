#!/usr/bin/env bash
set -euo pipefail

MODE_PROXY=""
for a in "${@:-}"; do
  case "$a" in
    --proxy)
      shift || true
      MODE_PROXY="${1:-}"
      ;;
    --proxy=*)
      MODE_PROXY="${a#*=}"
      ;;
  esac
done

say() { printf "%s\n" "$*"; }
ok() { say "[OK] $*"; }
err() { say "[ERR] $*" >&2; }
step() { say "[..] $*"; }

need_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    err "请用 root 执行：sudo bash $0 ..."
    exit 1
  fi
}

write_proxy_profile() {
  local p="$1"
  mkdir -p /etc/profile.d
  cat >/etc/profile.d/proxy.sh <<EOF
export ALL_PROXY="$p"
export HTTPS_PROXY="$p"
export HTTP_PROXY="$p"
export NO_PROXY="localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
EOF
  chmod 0644 /etc/profile.d/proxy.sh
  ok "已写入 /etc/profile.d/proxy.sh"
}

enable_proxy_now() {
  local p="$1"
  export ALL_PROXY="$p"
  export HTTPS_PROXY="$p"
  export HTTP_PROXY="$p"
  export NO_PROXY="localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
  ok "代理已启用：$p"
}

apt_install() {
  step "安装基础依赖"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y \
    ca-certificates curl git unzip zip xz-utils jq \
    python3 python3-venv python3-pip \
    clang cmake ninja-build pkg-config \
    libglu1-mesa \
    >/dev/null
  ok "依赖安装完成"
}

ensure_user_flutter() {
  if id flutter >/dev/null 2>&1; then
    ok "用户已存在：flutter"
  else
    useradd -m -s /bin/bash flutter
    ok "用户就绪：flutter"
  fi
  mkdir -p /home/flutter/.android /home/flutter/.gradle
  touch /home/flutter/.android/repositories.cfg || true
  chown -R flutter:flutter /home/flutter/.android /home/flutter/.gradle
}

write_flutter_profile() {
  mkdir -p /etc/profile.d
  cat >/etc/profile.d/flutter.sh <<'EOF'
export FLUTTER_HOME="/opt/flutter"
export PATH="$FLUTTER_HOME/bin:$PATH"
EOF
  chmod 0644 /etc/profile.d/flutter.sh
  ok "已写入 /etc/profile.d/flutter.sh"
}

ensure_android_sdk() {
  local SDK_DIR="/opt/android-sdk"
  local SM="$SDK_DIR/cmdline-tools/latest/bin/sdkmanager"

  if [ -x "$SM" ]; then
    ok "Android SDK 已存在：$SDK_DIR"
  else
    step "安装 Android SDK 到 $SDK_DIR"
    mkdir -p "$SDK_DIR"
    cd /tmp

    local ZIP="commandlinetools-linux-11076708_latest.zip"
    local URL="https://dl.google.com/android/repository/${ZIP}"

    step "下载 cmdline-tools"
    curl -fL --retry 5 --retry-delay 2 -o "$ZIP" "$URL"

    step "解压 cmdline-tools"
    rm -rf "$SDK_DIR/cmdline-tools"
    mkdir -p "$SDK_DIR/cmdline-tools"
    unzip -q "$ZIP" -d "$SDK_DIR/cmdline-tools"
    mv "$SDK_DIR/cmdline-tools/cmdline-tools" "$SDK_DIR/cmdline-tools/latest"

    ok "cmdline-tools 就绪"
  fi

  step "配置 Android 环境变量"
  cat >/etc/profile.d/androidsdk.sh <<'EOF'
export ANDROID_HOME="/opt/android-sdk"
export ANDROID_SDK_ROOT="/opt/android-sdk"
export PATH="$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$PATH"
EOF
  chmod 0644 /etc/profile.d/androidsdk.sh
  export ANDROID_HOME="/opt/android-sdk"
  export ANDROID_SDK_ROOT="/opt/android-sdk"
  export PATH="$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$PATH"
  ok "Android 环境变量就绪"

  step "接受 licenses"
  yes | "$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$ANDROID_SDK_ROOT" --licenses >/dev/null 2>&1 || true
  ok "licenses 完成"

  step "安装 platforms/build-tools"
  "$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$ANDROID_SDK_ROOT" \
    "platform-tools" \
    "platforms;android-36" \
    "build-tools;28.0.3" \
    >/dev/null
  ok "Android SDK 组件安装完成"
}

ensure_flutter() {
  local FL="/opt/flutter"

  if [ -x "$FL/bin/flutter" ]; then
    ok "Flutter 已存在：$FL"
  else
    step "安装 Flutter stable 到 $FL"
    rm -rf "$FL.tmp" >/dev/null 2>&1 || true
    git clone -b stable https://github.com/flutter/flutter.git "$FL.tmp"
    mv "$FL.tmp" "$FL"
    ok "Flutter 拉取完成"
  fi

  chown -R flutter:flutter "$FL"
  write_flutter_profile
}

run_as_flutter() {
  local cmd="$1"
  su - flutter -c "set -e; source /etc/profile.d/flutter.sh; source /etc/profile.d/androidsdk.sh; ${cmd}"
}

configure_flutter() {
  step "Flutter 关闭无用平台"
  run_as_flutter "flutter config --no-enable-web --no-enable-linux-desktop >/dev/null"
  ok "flutter config 完成"

  step "Flutter precache (android)"
  run_as_flutter "flutter precache --android"
  ok "precache 完成"

  step "flutter doctor"
  run_as_flutter "flutter doctor -v || true"
  ok "doctor 输出完成"
}

main() {
  need_root

  if [ -n "$MODE_PROXY" ]; then
    enable_proxy_now "$MODE_PROXY"
    write_proxy_profile "$MODE_PROXY"
  fi

  apt_install
  ensure_user_flutter

  ensure_android_sdk
  ensure_flutter
  configure_flutter

  ok "全部完成"
  say ""
  say "使用方式："
  say "  source /etc/profile.d/flutter.sh"
  say "  source /etc/profile.d/androidsdk.sh"
  say "  su - flutter"
  say "  flutter --version"
}

main
