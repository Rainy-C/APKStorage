#!/usr/bin/env bash
set -euo pipefail

P(){ printf "%s\n" "$*"; }
DIE(){ P "[ERR] $*"; exit 1; }

SDK_DIR="/opt/android-sdk"
FLUTTER_DIR="/opt/flutter"
FLUTTER_USER="flutter"

SDK_API="36"
BUILD_TOOLS="28.0.3"

ensure_root(){
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || DIE "请用 root 运行（sudo -i 后再跑）"
}

ensure_user(){
  if id "$FLUTTER_USER" >/dev/null 2>&1; then
    P "[OK] 用户已存在：$FLUTTER_USER"
  else
    useradd -m -s /bin/bash "$FLUTTER_USER"
    P "[OK] 用户就绪：$FLUTTER_USER"
  fi
}

write_profile(){
  cat >/etc/profile.d/flutter_env.sh <<EOF
export FLUTTER_HOME="$FLUTTER_DIR"
export ANDROID_SDK_ROOT="$SDK_DIR"
export ANDROID_HOME="$SDK_DIR"
export PATH="\$FLUTTER_HOME/bin:\$ANDROID_SDK_ROOT/platform-tools:\$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:\$PATH"
EOF
  chmod 0644 /etc/profile.d/flutter_env.sh
  P "[OK] 已写入 /etc/profile.d/flutter_env.sh"
}

choose_proxy(){
  P ""
  P "=============================="
  P " Flutter 一键部署（交互版）"
  P "=============================="
  P ""
  P "是否启用代理？"
  P "  1) 启用（socks5h/http 代理）"
  P "  2) 不启用"
  P ""
  read -r -p "请输入选项 [1-2]：" opt || true
  opt="${opt:-2}"

  if [[ "$opt" == "1" ]]; then
    read -r -p "请输入代理地址（例：socks5h://18.183.63.49:3233 或 http://127.0.0.1:8118）：" PROXY || true
    PROXY="${PROXY:-}"
    [[ -z "$PROXY" ]] && DIE "你选了启用代理，但没有输入代理地址"

    cat >/etc/profile.d/proxy.sh <<EOF
export ALL_PROXY="$PROXY"
export HTTPS_PROXY="$PROXY"
export HTTP_PROXY="$PROXY"
export NO_PROXY="127.0.0.1,localhost,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
EOF
    chmod 0644 /etc/profile.d/proxy.sh
    P "[OK] 代理已启用：$PROXY"
    P "[OK] 已写入 /etc/profile.d/proxy.sh"

    if [[ "$PROXY" == socks5* ]]; then
      P "[..] 提示：Android sdkmanager 不支持 socks5/socks5h，脚本会在装 SDK 时自动绕开 HTTP(S)_PROXY"
    fi
  else
    rm -f /etc/profile.d/proxy.sh 2>/dev/null || true
    P "[OK] 不启用代理"
  fi
}

install_deps(){
  P "[..] 安装基础依赖"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y --no-install-recommends \
    ca-certificates curl git unzip xz-utils zip \
    openjdk-17-jdk \
    libglu1-mesa \
    >/dev/null
  P "[OK] 依赖安装完成"
}

install_android_sdk(){
  if [[ -d "$SDK_DIR" && -x "$SDK_DIR/cmdline-tools/latest/bin/sdkmanager" ]]; then
    P "[OK] Android SDK 已存在：$SDK_DIR"
  else
    P "[..] 安装 Android SDK 到：$SDK_DIR"
    mkdir -p "$SDK_DIR"
    cd /tmp

    URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
    P "[..] 下载 cmdline-tools"
    curl -fL --retry 3 --retry-delay 2 -o cmdline-tools.zip "$URL"

    rm -rf "$SDK_DIR/cmdline-tools"
    mkdir -p "$SDK_DIR/cmdline-tools"
    unzip -q cmdline-tools.zip -d "$SDK_DIR/cmdline-tools"
    rm -f cmdline-tools.zip

    if [[ -d "$SDK_DIR/cmdline-tools/cmdline-tools" ]]; then
      mv "$SDK_DIR/cmdline-tools/cmdline-tools" "$SDK_DIR/cmdline-tools/latest"
    elif [[ -d "$SDK_DIR/cmdline-tools/latest" ]]; then
      :
    else
      DIE "cmdline-tools 解压结构异常"
    fi

    P "[OK] cmdline-tools 已安装"
  fi

  SDKM="$SDK_DIR/cmdline-tools/latest/bin/sdkmanager"

  mkdir -p "$SDK_DIR/licenses"
  chmod -R a+rX "$SDK_DIR"
  chown -R root:root "$SDK_DIR"

  P "[..] 接受 licenses"
  if [[ "${HTTPS_PROXY:-}" == socks5* || "${HTTP_PROXY:-}" == socks5* ]]; then
    ( unset HTTP_PROXY HTTPS_PROXY; yes | "$SDKM" --sdk_root="$SDK_DIR" --licenses >/dev/null || true )
  else
    yes | "$SDKM" --sdk_root="$SDK_DIR" --licenses >/dev/null || true
  fi

  P "[..] 安装 platforms/build-tools"
  if [[ "${HTTPS_PROXY:-}" == socks5* || "${HTTP_PROXY:-}" == socks5* ]]; then
    ( unset HTTP_PROXY HTTPS_PROXY; "$SDKM" --sdk_root="$SDK_DIR" \
      "platform-tools" \
      "platforms;android-${SDK_API}" \
      "build-tools;${BUILD_TOOLS}" >/dev/null )
  else
    "$SDKM" --sdk_root="$SDK_DIR" \
      "platform-tools" \
      "platforms;android-${SDK_API}" \
      "build-tools;${BUILD_TOOLS}" >/dev/null
  fi

  P "[OK] Android SDK 安装完成：$SDK_DIR"
}

install_flutter(){
  if [[ -x "$FLUTTER_DIR/bin/flutter" ]]; then
    P "[OK] Flutter 已存在：$FLUTTER_DIR"
  else
    P "[..] 安装 Flutter 到：$FLUTTER_DIR"
    cd /opt

    if [[ -d flutter/.git ]]; then
      rm -rf flutter
    fi

    git clone https://github.com/flutter/flutter.git -b stable flutter
    mv flutter "$FLUTTER_DIR"
    P "[OK] Flutter clone 完成"
  fi

  chown -R "$FLUTTER_USER":"$FLUTTER_USER" "$FLUTTER_DIR"
  P "[OK] Flutter 权限修正完成"
}

flutter_config_pre(){
  P "[..] 配置 Flutter（禁用 web/linux-desktop，减少依赖）"
  su - "$FLUTTER_USER" -c "source /etc/profile.d/flutter_env.sh >/dev/null 2>&1 || true; flutter config --no-enable-web --no-enable-linux-desktop >/dev/null 2>&1 || true"
  P "[OK] Flutter config 完成"
}

flutter_preflight(){
  P "[..] 初始化 flutter 用户目录"
  su - "$FLUTTER_USER" -c "mkdir -p ~/.android ~/.gradle && touch ~/.android/repositories.cfg && chmod -R u+rwX ~/.android ~/.gradle"
  P "[OK] flutter 用户目录就绪"
}

flutter_doctor(){
  P "[..] flutter doctor"
  su - "$FLUTTER_USER" -c "source /etc/profile.d/flutter_env.sh >/dev/null 2>&1 || true; flutter --version"
  su - "$FLUTTER_USER" -c "source /etc/profile.d/flutter_env.sh >/dev/null 2>&1 || true; flutter doctor -v || true"
  P "[OK] doctor 已执行"
}

main(){
  ensure_root
  choose_proxy
  install_deps
  ensure_user
  write_profile
  install_android_sdk
  install_flutter
  flutter_preflight
  flutter_config_pre
  flutter_doctor

  P ""
  P "=============================="
  P "[OK] Flutter 环境部署完成"
  P "Flutter：$FLUTTER_DIR"
  P "Android SDK：$SDK_DIR"
  P "用户：$FLUTTER_USER"
  P "=============================="
  P ""
  P "以后编译建议："
  P "  su - flutter"
  P "  cd 你的项目目录"
  P "  flutter pub get"
  P "  flutter build apk --release"
}

main "$@"
