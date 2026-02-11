#!/usr/bin/env bash
set -euo pipefail

P_SOCKS="socks5h://18.183.63.49:3233"
SDK_DIR="/opt/android-sdk"
FLUTTER_DIR="/opt/flutter"
USER_NAME="flutter"

ts(){ date +"%Y-%m-%d %H:%M:%S"; }
ok(){ echo "[$(ts)] [OK] $*"; }
info(){ echo "[$(ts)] [..] $*"; }
err(){ echo "[$(ts)] [ERR] $*" >&2; }
die(){ err "$*"; exit 1; }

need_root(){
  if [ "$(id -u)" -ne 0 ]; then
    die "请用 root 运行：sudo -i 后再执行"
  fi
}

apt_install(){
  local pkgs=("$@")
  DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" >/dev/null
}

ensure_user(){
  if id "$USER_NAME" >/dev/null 2>&1; then
    ok "用户已存在：$USER_NAME"
  else
    useradd -m -s /bin/bash "$USER_NAME"
    ok "已创建用户：$USER_NAME"
  fi
}

write_profile(){
  local path="$1"
  local content="$2"
  printf "%s\n" "$content" > "$path"
  chmod 0644 "$path"
  ok "已写入 $path"
}

setup_privoxy_for_socks(){
  info "启用代理：$P_SOCKS（用 Privoxy 转为 HTTP 代理，兼容 sdkmanager/pub）"
  apt_install privoxy >/dev/null || true

  mkdir -p /etc/privoxy
  cat > /etc/privoxy/config <<'EOF'
user-manual /usr/share/doc/privoxy/user-manual
confdir /etc/privoxy
logdir /var/log/privoxy
listen-address  127.0.0.1:8118
toggle  1
enable-remote-toggle  0
enable-remote-http-toggle 0
enable-edit-actions 0
enforce-blocks 0
buffer-limit 4096
forwarded-connect-retries 1
accept-intercepted-requests 1
EOF

  printf "\nforward-socks5t / %s .\n" "$P_SOCKS" >> /etc/privoxy/config

  systemctl enable --now privoxy >/dev/null || true
  systemctl restart privoxy >/dev/null || true

  if ! ss -lntp | grep -q ":8118"; then
    systemctl status privoxy --no-pager -l | head -n 80 || true
    die "Privoxy 启动失败（8118 未监听）"
  fi

  write_profile /etc/profile.d/proxy.sh "export HTTP_PROXY=http://127.0.0.1:8118
export HTTPS_PROXY=http://127.0.0.1:8118
export NO_PROXY=127.0.0.1,localhost,::1
"
  ok "代理已启用：HTTP_PROXY=http://127.0.0.1:8118"
}

disable_proxy_env_temporarily(){
  export _OLD_HTTP_PROXY="${HTTP_PROXY-}"
  export _OLD_HTTPS_PROXY="${HTTPS_PROXY-}"
  export _OLD_ALL_PROXY="${ALL_PROXY-}"
  unset HTTP_PROXY HTTPS_PROXY ALL_PROXY
}

restore_proxy_env(){
  if [ -n "${_OLD_HTTP_PROXY-}" ]; then export HTTP_PROXY="$_OLD_HTTP_PROXY"; else unset HTTP_PROXY; fi
  if [ -n "${_OLD_HTTPS_PROXY-}" ]; then export HTTPS_PROXY="$_OLD_HTTPS_PROXY"; else unset HTTPS_PROXY; fi
  if [ -n "${_OLD_ALL_PROXY-}" ]; then export ALL_PROXY="$_OLD_ALL_PROXY"; else unset ALL_PROXY; fi
  unset _OLD_HTTP_PROXY _OLD_HTTPS_PROXY _OLD_ALL_PROXY
}

ensure_flutter_repo(){
  if [ -x "$FLUTTER_DIR/bin/flutter" ]; then
    ok "Flutter 已存在：$FLUTTER_DIR"
    return
  fi
  info "clone Flutter stable 到 $FLUTTER_DIR"
  rm -rf "$FLUTTER_DIR"
  git clone -b stable https://github.com/flutter/flutter.git "$FLUTTER_DIR" >/dev/null
  chown -R root:root "$FLUTTER_DIR"
  ok "Flutter clone 完成"
}

ensure_android_sdk(){
  mkdir -p "$SDK_DIR"
  chown -R root:root "$SDK_DIR"

  info "安装 Android SDK cmdline-tools（强制修正 latest 路径，避免 latest-2）"
  rm -rf "$SDK_DIR/cmdline-tools/latest" "$SDK_DIR/cmdline-tools/latest-2" "$SDK_DIR/cmdline-tools/cmdline-tools" "$SDK_DIR/.temp" >/dev/null 2>&1 || true
  mkdir -p "$SDK_DIR/cmdline-tools"

  local url="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
  local zip="/tmp/cmdline-tools.zip"
  curl -fsSL -o "$zip" "$url"

  local tmp="/tmp/cmdline-tools-unzip"
  rm -rf "$tmp"
  mkdir -p "$tmp"
  unzip -q "$zip" -d "$tmp"
  mv "$tmp/cmdline-tools" "$SDK_DIR/cmdline-tools/latest"
  rm -rf "$tmp" "$zip"

  ok "cmdline-tools 已就位：$SDK_DIR/cmdline-tools/latest"

  write_profile /etc/profile.d/android-sdk.sh "export ANDROID_SDK_ROOT=$SDK_DIR
export ANDROID_HOME=$SDK_DIR
export PATH=\$PATH:$SDK_DIR/cmdline-tools/latest/bin:$SDK_DIR/platform-tools
"
}

sdkmanager_run(){
  local args=("$@")
  local sm="$SDK_DIR/cmdline-tools/latest/bin/sdkmanager"
  if [ ! -x "$sm" ]; then
    die "sdkmanager 不存在：$sm"
  fi

  disable_proxy_env_temporarily
  yes | "$sm" --sdk_root="$SDK_DIR" "${args[@]}" >/dev/null
  restore_proxy_env
}

accept_licenses(){
  info "接受 Android licenses（临时移除代理变量以兼容 sdkmanager）"
  local sm="$SDK_DIR/cmdline-tools/latest/bin/sdkmanager"
  disable_proxy_env_temporarily
  yes | "$sm" --sdk_root="$SDK_DIR" --licenses >/dev/null || true
  restore_proxy_env
  ok "licenses 已处理"
}

install_android_components(){
  info "安装 platforms/build-tools（临时移除代理变量，避免 socks5h 报错）"
  sdkmanager_run "platform-tools" "platforms;android-36" "build-tools;35.0.1" || die "platform/build-tools 安装失败"
  ok "platforms/build-tools 安装完成"

  info "安装 NDK/CMake（失败不阻断）"
  set +e
  sdkmanager_run "ndk;28.2.13676358" "cmake;3.22.1"
  set -e
  ok "NDK/CMake 处理完成（如有警告可忽略）"
}

setup_flutter_env(){
  write_profile /etc/profile.d/flutter.sh "export FLUTTER_HOME=$FLUTTER_DIR
export PATH=\$PATH:$FLUTTER_DIR/bin
export FLUTTER_SUPPRESS_ANALYTICS=true
"
  ok "已写入 Flutter 环境变量"
}

flutter_config_for_user(){
  info "配置 flutter（仅启用 Android，关闭 web/linux，关闭 analytics）"
  su - "$USER_NAME" -c "mkdir -p ~/.android ~/.gradle && touch ~/.android/repositories.cfg && chmod -R u+rwX ~/.android ~/.gradle" >/dev/null 2>&1 || true

  su - "$USER_NAME" -c "source /etc/profile.d/flutter.sh && source /etc/profile.d/android-sdk.sh && flutter config --no-enable-web --no-enable-linux-desktop >/dev/null" || true

  set +e
  su - "$USER_NAME" -c "source /etc/profile.d/flutter.sh && flutter config --no-analytics >/dev/null" >/dev/null 2>&1
  su - "$USER_NAME" -c "source /etc/profile.d/flutter.sh && dart --disable-analytics >/dev/null" >/dev/null 2>&1
  set -e

  ok "flutter config 完成"
}

mini_check(){
  info "快速自检（不跑 flutter doctor，避免你说的“卡/刷屏”）"
  su - "$USER_NAME" -c "source /etc/profile.d/flutter.sh && flutter --version | head -n 1" || true
  ok "完成 ✅"
  echo
  echo "使用方式："
  echo "  su - $USER_NAME"
  echo "  source /etc/profile.d/flutter.sh"
  echo "  source /etc/profile.d/android-sdk.sh"
  echo "  flutter doctor --android-licenses    # 可选"
}

main(){
  need_root

  echo "是否启用代理？（固定 SOCKS5：$P_SOCKS）"
  read -r -p "输入 y 启用 / n 不启用 [y/N]: " ans || true
  ans="${ans:-N}"

  info "安装基础依赖"
  apt_install ca-certificates curl unzip git xz-utils zip jq >/dev/null
  ok "依赖安装完成"

  ensure_user

  if [[ "$ans" =~ ^[Yy]$ ]]; then
    setup_privoxy_for_socks
  else
    rm -f /etc/profile.d/proxy.sh >/dev/null 2>&1 || true
    ok "代理未启用"
  fi

  ensure_flutter_repo
  ensure_android_sdk
  accept_licenses
  install_android_components
  setup_flutter_env
  flutter_config_for_user
  mini_check
}

main "$@"
