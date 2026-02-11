#!/usr/bin/env bash
set -euo pipefail

p() { echo -e "[$(date +'%F %T')] $*"; }
die() { echo -e "[ERR] $*" >&2; exit 1; }

PROXY=""
ANDROID_SDK_ROOT_DEFAULT="/opt/android-sdk"
FLUTTER_DIR_DEFAULT="/opt/flutter"
CHANNEL="stable"
SDK_API="36"
BUILD_TOOLS="35.0.1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --proxy)
      PROXY="${2:-}"
      shift 2
      ;;
    --android-sdk)
      ANDROID_SDK_ROOT_DEFAULT="${2:-}"
      shift 2
      ;;
    --flutter-dir)
      FLUTTER_DIR_DEFAULT="${2:-}"
      shift 2
      ;;
    --channel)
      CHANNEL="${2:-stable}"
      shift 2
      ;;
    --sdk-api)
      SDK_API="${2:-36}"
      shift 2
      ;;
    --build-tools)
      BUILD_TOOLS="${2:-35.0.1}"
      shift 2
      ;;
    *)
      die "未知参数：$1"
      ;;
  esac
done

ANDROID_SDK_ROOT="$ANDROID_SDK_ROOT_DEFAULT"
FLUTTER_DIR="$FLUTTER_DIR_DEFAULT"

if [[ $EUID -ne 0 ]]; then
  die "请用 root 执行（sudo -i 后再跑）"
fi

apply_proxy() {
  if [[ -z "$PROXY" ]]; then
    p "代理未启用"
    return 0
  fi

  p "代理已启用：$PROXY"
  cat >/etc/profile.d/proxy.sh <<EOF
export ALL_PROXY="$PROXY"
export HTTPS_PROXY="$PROXY"
export HTTP_PROXY="$PROXY"
export NO_PROXY="127.0.0.1,localhost,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
EOF
  chmod 0644 /etc/profile.d/proxy.sh
  p "已写入 /etc/profile.d/proxy.sh"
}

install_deps() {
  p "安装基础依赖"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends \
    ca-certificates curl unzip xz-utils zip git openssh-client \
    python3 python3-venv \
    openjdk-17-jdk \
    libstdc++6 libgcc-s1 \
    rsync \
    procps
  p "依赖安装完成"
}

ensure_user_flutter() {
  if id flutter >/dev/null 2>&1; then
    p "用户已存在：flutter"
  else
    useradd -m -s /bin/bash flutter
    p "已创建用户：flutter"
  fi
  install -d -o flutter -g flutter /home/flutter/.android /home/flutter/.gradle
  : > /home/flutter/.android/repositories.cfg || true
  chown -R flutter:flutter /home/flutter/.android /home/flutter/.gradle
  p "用户就绪：flutter"
}

install_android_sdk() {
  if [[ -d "$ANDROID_SDK_ROOT" && -x "$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager" ]]; then
    p "Android SDK 已存在：$ANDROID_SDK_ROOT"
  else
    p "安装 Android SDK 到：$ANDROID_SDK_ROOT"
    mkdir -p "$ANDROID_SDK_ROOT"
    cd /tmp

    local URL
    URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"

    p "下载 cmdline-tools"
    curl -fL --retry 3 --retry-delay 2 -o cmdline-tools.zip "$URL"

    rm -rf "$ANDROID_SDK_ROOT/cmdline-tools"
    mkdir -p "$ANDROID_SDK_ROOT/cmdline-tools"
    unzip -q cmdline-tools.zip -d "$ANDROID_SDK_ROOT/cmdline-tools"
    rm -f cmdline-tools.zip

    if [[ -d "$ANDROID_SDK_ROOT/cmdline-tools/cmdline-tools" ]]; then
      mv "$ANDROID_SDK_ROOT/cmdline-tools/cmdline-tools" "$ANDROID_SDK_ROOT/cmdline-tools/latest"
    elif [[ -d "$ANDROID_SDK_ROOT/cmdline-tools/latest" ]]; then
      :
    else
      die "cmdline-tools 解压结构异常"
    fi
  fi

  mkdir -p "$ANDROID_SDK_ROOT/licenses"
  chmod -R a+rX "$ANDROID_SDK_ROOT"
  chown -R root:root "$ANDROID_SDK_ROOT"

  p "安装 platforms/build-tools"
  yes | "$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$ANDROID_SDK_ROOT" --licenses >/dev/null || true
  "$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$ANDROID_SDK_ROOT" \
    "platform-tools" \
    "platforms;android-${SDK_API}" \
    "build-tools;${BUILD_TOOLS}" >/dev/null

  p "Android SDK 安装完成"
}

install_flutter() {
  if [[ -d "$FLUTTER_DIR/.git" && -x "$FLUTTER_DIR/bin/flutter" ]]; then
    p "Flutter 已存在：$FLUTTER_DIR"
  else
    p "安装 Flutter（$CHANNEL）到：$FLUTTER_DIR"
    rm -rf "$FLUTTER_DIR"
    git clone -b "$CHANNEL" https://github.com/flutter/flutter.git "$FLUTTER_DIR"
  fi

  cat >/etc/profile.d/flutter.sh <<EOF
export ANDROID_SDK_ROOT="$ANDROID_SDK_ROOT"
export ANDROID_HOME="$ANDROID_SDK_ROOT"
export PATH="$FLUTTER_DIR/bin:$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:\$PATH"
EOF
  chmod 0644 /etc/profile.d/flutter.sh
  p "已写入 /etc/profile.d/flutter.sh"
}

flutter_warmup() {
  p "初始化 Flutter（用 flutter 用户跑，避免 root 警告/权限乱套）"
  su - flutter -c "bash -lc 'source /etc/profile.d/flutter.sh; source /etc/profile.d/proxy.sh 2>/dev/null || true; flutter --no-analytics'"

  su - flutter -c "bash -lc 'source /etc/profile.d/flutter.sh; source /etc/profile.d/proxy.sh 2>/dev/null || true; flutter config --no-enable-web --no-enable-linux-desktop >/dev/null || true'"

  su - flutter -c "bash -lc 'source /etc/profile.d/flutter.sh; source /etc/profile.d/proxy.sh 2>/dev/null || true; flutter doctor -v || true'"

  p "Flutter 初始化完成"
}

print_usage() {
  echo
  p "完成 ✅"
  echo
  echo "新开 shell 后："
  echo "  source /etc/profile.d/flutter.sh"
  echo "  source /etc/profile.d/proxy.sh   # 如果你启用了 --proxy"
  echo
  echo "用 flutter 用户："
  echo "  su - flutter"
  echo "  flutter doctor"
  echo
}

apply_proxy
install_deps
ensure_user_flutter
install_android_sdk
install_flutter
flutter_warmup
print_usage
