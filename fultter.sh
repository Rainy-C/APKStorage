#!/usr/bin/env bash
set -euo pipefail

FIXED_PROXY="socks5h://18.183.63.49:3233"
FLUTTER_DIR="/opt/flutter"
SDK_DIR="/opt/android-sdk"
SDKMGR_BIN="$SDK_DIR/cmdline-tools/latest/bin/sdkmanager"

ts(){ date "+%Y-%m-%d %H:%M:%S"; }
ok(){ echo "[OK] $*"; }
info(){ echo "[..] $*"; }
err(){ echo "[ERR] $*" >&2; }

write_env(){
  local f="$1"; shift
  sudo mkdir -p "$(dirname "$f")"
  sudo bash -c "cat > '$f' <<'EOF'
$*
EOF"
}

need_root(){
  if [ "$(id -u)" -ne 0 ]; then
    err "请用 root 执行"
    exit 1
  fi
}

proxy_menu(){
  echo "=============================="
  echo "是否启用代理？"
  echo "1) 启用（固定：$FIXED_PROXY）"
  echo "2) 不启用"
  read -rp "请选择 [1/2]: " _p || true
  _p="${_p:-2}"

  if [ "$_p" = "1" ]; then
    export ALL_PROXY="$FIXED_PROXY"
    export HTTPS_PROXY="$FIXED_PROXY"
    export HTTP_PROXY="$FIXED_PROXY"
    write_env /etc/profile.d/proxy.sh \
"export ALL_PROXY=$FIXED_PROXY
export HTTPS_PROXY=$FIXED_PROXY
export HTTP_PROXY=$FIXED_PROXY"
    ok "代理已启用：$FIXED_PROXY"
    ok "已写入 /etc/profile.d/proxy.sh"
  else
    unset ALL_PROXY HTTPS_PROXY HTTP_PROXY || true
    sudo rm -f /etc/profile.d/proxy.sh || true
    ok "不使用代理"
  fi
}

user_setup(){
  if id flutter >/dev/null 2>&1; then
    ok "用户已存在：flutter"
  else
    sudo useradd -m -s /bin/bash flutter
    ok "已创建用户：flutter"
  fi
  sudo mkdir -p /home/flutter/.android /home/flutter/.gradle
  sudo touch /home/flutter/.android/repositories.cfg
  sudo chown -R flutter:flutter /home/flutter/.android /home/flutter/.gradle
  sudo chmod -R u+rwX /home/flutter/.android /home/flutter/.gradle
  ok "用户就绪：flutter"
}

apt_deps(){
  info "安装基础依赖"
  sudo apt-get update -y >/dev/null
  sudo apt-get install -y \
    git unzip zip xz-utils curl ca-certificates \
    openjdk-17-jdk \
    >/dev/null
  ok "依赖安装完成"
}

flutter_install(){
  if [ -x "$FLUTTER_DIR/bin/flutter" ]; then
    ok "Flutter 已存在：$FLUTTER_DIR"
  else
    info "安装 Flutter 到 $FLUTTER_DIR"
    sudo rm -rf "$FLUTTER_DIR"
    sudo git clone https://github.com/flutter/flutter.git -b stable "$FLUTTER_DIR" >/dev/null
    sudo chown -R root:root "$FLUTTER_DIR"
    sudo chmod -R a+rX "$FLUTTER_DIR"
    ok "Flutter 克隆完成"
  fi

  write_env /etc/profile.d/flutter.sh \
"export PATH=$FLUTTER_DIR/bin:\$PATH
export FLUTTER_ROOT=$FLUTTER_DIR"
  ok "已写入 /etc/profile.d/flutter.sh"
}

android_sdk_install(){
  info "安装 Android SDK 到 $SDK_DIR"
  sudo mkdir -p "$SDK_DIR"
  sudo chown -R root:root "$SDK_DIR"

  if [ -x "$SDKMGR_BIN" ]; then
    ok "cmdline-tools 已存在"
  else
    info "安装 cmdline-tools"
    local tmp="/tmp/cmdline-tools.zip"
    curl -fsSL -o "$tmp" https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip
    sudo mkdir -p "$SDK_DIR/cmdline-tools"
    sudo unzip -q -o "$tmp" -d "$SDK_DIR/cmdline-tools"
    sudo mv -f "$SDK_DIR/cmdline-tools/cmdline-tools" "$SDK_DIR/cmdline-tools/latest"
    sudo rm -f "$tmp"
    ok "cmdline-tools 安装完成"
  fi

  sudo mkdir -p "$SDK_DIR/licenses"
  sudo bash -c "yes | env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy \
    '$SDKMGR_BIN' --sdk_root='$SDK_DIR' --licenses >/dev/null" || true
  ok "licenses 已处理"

  info "安装 platforms/build-tools（注意：sdkmanager 不支持 socks5h，运行时临时移除代理环境变量）"
  sudo env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy \
    "$SDKMGR_BIN" --sdk_root="$SDK_DIR" \
      "platform-tools" \
      "platforms;android-36" \
      "build-tools;35.0.1" \
      >/dev/null
  ok "platforms/build-tools 安装完成"

  write_env /etc/profile.d/android-sdk.sh \
"export ANDROID_HOME=$SDK_DIR
export ANDROID_SDK_ROOT=$SDK_DIR
export PATH=$SDK_DIR/platform-tools:$SDK_DIR/cmdline-tools/latest/bin:\$PATH"
  ok "已写入 /etc/profile.d/android-sdk.sh"
}

flutter_config(){
  info "配置 flutter（仅启用 Android，关闭 web/linux）"
  sudo -u flutter -H bash -lc "source /etc/profile.d/flutter.sh && flutter config --no-enable-web --no-enable-linux-desktop >/dev/null || true"
  sudo -u flutter -H bash -lc "source /etc/profile.d/flutter.sh && flutter --no-analytics >/dev/null || true"
  ok "flutter config 完成"
}

doctor(){
  info "flutter doctor -v"
  sudo -u flutter -H bash -lc "source /etc/profile.d/flutter.sh && source /etc/profile.d/android-sdk.sh && flutter doctor -v" || true
}

main(){
  need_root
  proxy_menu
  user_setup
  apt_deps
  flutter_install
  android_sdk_install
  flutter_config
  doctor
  ok "完成 ✅ 重新登录 shell 后 PATH 会自动生效"
  echo "使用：su - flutter"
  echo "然后：source /etc/profile.d/flutter.sh && source /etc/profile.d/android-sdk.sh && flutter doctor"
}

main "$@"
