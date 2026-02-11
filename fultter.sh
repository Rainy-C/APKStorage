#!/usr/bin/env bash
set -euo pipefail

TS(){ date '+[%Y-%m-%d %H:%M:%S]'; }
OK(){ echo "$(TS) [OK] $*"; }
IN(){ echo "$(TS) [..] $*"; }
ER(){ echo "$(TS) [ERR] $*" >&2; exit 1; }

PROXY_SOCKS="socks5h://18.183.63.49:3233"
LOCKF="/tmp/flutter_env_install.lock"

USE_PROXY="${USE_PROXY:-}"
if [[ "${1:-}" == "--proxy" ]]; then USE_PROXY="y"; fi
if [[ -z "${USE_PROXY}" ]]; then
  echo "是否启用代理？（SOCKS5: $PROXY_SOCKS）"
  read -r -p "输入 y 启用 / n 不启用 [y/N]: " USE_PROXY
  USE_PROXY="${USE_PROXY:-N}"
fi
USE_PROXY="$(echo "$USE_PROXY" | tr '[:upper:]' '[:lower:]')"

exec 9>"$LOCKF"
flock -x 9

export DEBIAN_FRONTEND=noninteractive

IN "安装依赖：ca-certificates curl unzip git xz-utils zip jq"
apt-get update -y >/dev/null
apt-get install -y ca-certificates curl unzip git xz-utils zip jq >/dev/null
OK "依赖安装完成"

ensure_user(){
  if id flutter >/dev/null 2>&1; then
    OK "用户已存在：flutter"
  else
    useradd -m -s /bin/bash flutter
    OK "用户就绪：flutter"
  fi
  install -d -o flutter -g flutter /home/flutter/.android /home/flutter/.gradle
  touch /home/flutter/.android/repositories.cfg
  chown -R flutter:flutter /home/flutter/.android /home/flutter/.gradle
}

write_profile(){
  cat >/etc/profile.d/flutter-env.sh <<'EOF'
export ANDROID_SDK_ROOT=/opt/android-sdk
export ANDROID_HOME=/opt/android-sdk
export PATH=/opt/flutter/bin:/opt/android-sdk/platform-tools:/opt/android-sdk/cmdline-tools/latest/bin:$PATH
EOF
  chmod 0644 /etc/profile.d/flutter-env.sh
  OK "已写入 /etc/profile.d/flutter-env.sh"
}

setup_proxy(){
  if [[ "$USE_PROXY" != "y" ]]; then
    rm -f /etc/profile.d/proxy.sh || true
    OK "未启用代理"
    return
  fi

  IN "安装并配置 Privoxy（把 SOCKS5 转成 HTTP 代理）"
  apt-get install -y privoxy >/dev/null

  sed -i 's/^[[:space:]]*listen-address .*/listen-address 127.0.0.1:8118/' /etc/privoxy/config || true
  if grep -q '^forward-socks5t' /etc/privoxy/config; then
    sed -i "s#^forward-socks5t .*#forward-socks5t / ${PROXY_SOCKS#socks5h://} .#" /etc/privoxy/config
  else
    echo "forward-socks5t / ${PROXY_SOCKS#socks5h://} ." >> /etc/privoxy/config
  fi

  systemctl enable --now privoxy >/dev/null || true
  systemctl restart privoxy >/dev/null || true

  ss -lntp | grep -q '127.0.0.1:8118' || ER "Privoxy 未监听 127.0.0.1:8118"

  cat >/etc/profile.d/proxy.sh <<EOF
export HTTP_PROXY=http://127.0.0.1:8118
export HTTPS_PROXY=http://127.0.0.1:8118
export http_proxy=http://127.0.0.1:8118
export https_proxy=http://127.0.0.1:8118
export NO_PROXY=127.0.0.1,localhost,::1
export no_proxy=127.0.0.1,localhost,::1
EOF
  chmod 0644 /etc/profile.d/proxy.sh

  curl -I --max-time 8 -x http://127.0.0.1:8118 https://github.com >/dev/null 2>&1 || ER "代理自检失败（Privoxy->SOCKS5 不通）"
  OK "代理已启用：HTTP(S) 走 http://127.0.0.1:8118 （后端 SOCKS5: $PROXY_SOCKS）"
}

install_flutter(){
  if [[ -x /opt/flutter/bin/flutter ]]; then
    OK "Flutter 已存在：/opt/flutter（跳过 clone）"
    return
  fi
  IN "拉取 Flutter stable 到 /opt/flutter"
  rm -rf /opt/flutter || true
  git clone -b stable https://github.com/flutter/flutter.git /opt/flutter
  OK "Flutter clone 完成"
}

sdk_cmdline_fix(){
  local SDK=/opt/android-sdk
  local LATEST="$SDK/cmdline-tools/latest"
  local BAD="$SDK/cmdline-tools/latest-2"

  if [[ -d "$BAD" && ! -d "$LATEST" ]]; then
    IN "检测到 cmdline-tools 在 latest-2，归位到 latest"
    mkdir -p "$SDK/cmdline-tools"
    mv "$BAD" "$LATEST"
  fi

  if [[ -d "$BAD" ]]; then
    IN "检测到残留 latest-2，清理避免 sdkmanager 警告"
    rm -rf "$BAD"
  fi

  if [[ -x "$LATEST/bin/sdkmanager" ]]; then
    OK "cmdline-tools 正常：$LATEST"
    return
  fi

  IN "安装 Android cmdline-tools 到 $LATEST"
  mkdir -p "$SDK/cmdline-tools"
  rm -rf "$LATEST"
  mkdir -p "$LATEST"

  local TMP="/tmp/ct.$RANDOM"
  mkdir -p "$TMP"
  curl -fsSL -o "$TMP/ct.zip" https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip
  unzip -q "$TMP/ct.zip" -d "$TMP"
  mv "$TMP/cmdline-tools/"* "$LATEST/"
  rm -rf "$TMP"

  [[ -x "$LATEST/bin/sdkmanager" ]] || ER "cmdline-tools 安装失败"
  OK "cmdline-tools 安装完成"
}

install_android_sdk(){
  local SDK=/opt/android-sdk
  mkdir -p "$SDK"
  sdk_cmdline_fix

  local SM="$SDK/cmdline-tools/latest/bin/sdkmanager"
  IN "接受 Android licenses"
  yes | "$SM" --sdk_root="$SDK" --licenses >/dev/null 2>&1 || true
  OK "licenses 已处理"

  IN "安装 platforms/build-tools"
  "$SM" --sdk_root="$SDK" "platform-tools" "platforms;android-36" "build-tools;35.0.1" >/dev/null
  OK "platforms/build-tools 安装完成"

  IN "安装 NDK/CMake（失败不阻断）"
  set +e
  "$SM" --sdk_root="$SDK" "ndk;28.2.13676358" "cmake;3.22.1" >/dev/null
  set -e
  OK "NDK/CMake 处理完成"

  write_profile
}

flutter_configure(){
  IN "初始化 flutter 工具（以 flutter 用户运行）"
  chown -R flutter:flutter /opt/flutter || true
  chown -R flutter:flutter /opt/android-sdk || true

  su - flutter -c 'source /etc/profile.d/flutter-env.sh >/dev/null 2>&1 || true; mkdir -p ~/.android ~/.gradle; touch ~/.android/repositories.cfg; chmod -R u+rwX ~/.android ~/.gradle; true'

  IN "flutter config（只启用 Android，关闭 web/linux）"
  su - flutter -c 'source /etc/profile.d/flutter-env.sh; flutter config --no-enable-web --no-enable-linux-desktop >/dev/null'
  OK "flutter config 完成"

  IN "flutter doctor --android-licenses（自动接受）"
  su - flutter -c 'source /etc/profile.d/flutter-env.sh; yes | flutter doctor --android-licenses >/dev/null 2>&1 || true'
  OK "android licenses 已处理"

  IN "flutter doctor（简洁输出）"
  su - flutter -c 'source /etc/profile.d/flutter-env.sh; flutter doctor -v | sed -n "1,80p"'
  OK "完成 ✅"
}

ensure_user
setup_proxy
install_flutter
install_android_sdk
flutter_configure

OK "使用方式："
echo "  su - flutter"
echo "  source /etc/profile.d/flutter-env.sh"
echo "  flutter --version"
