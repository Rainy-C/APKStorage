cat > flutter_full.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail

ts(){ date "+%Y-%m-%d %H:%M:%S"; }
ok(){ echo "[OK] $*"; }
info(){ echo "[..] $*"; }
err(){ echo "[ERR] $*" >&2; }
die(){ err "$*"; exit 1; }

require_root(){
  [ "$(id -u)" -eq 0 ] || die "请用 root 执行：sudo bash $0"
}

ensure_user(){
  local u="$1"
  if ! id "$u" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$u"
    ok "用户就绪：$u"
  else
    ok "用户已存在：$u"
  fi
}

write_env(){
  local f="$1"
  shift
  mkdir -p "$(dirname "$f")"
  : > "$f"
  for line in "$@"; do
    echo "$line" >> "$f"
  done
}

proxy_menu(){
  echo "=============================="
  echo "是否启用代理？"
  echo "1) 启用（SOCKS5：socks5h://IP:PORT）"
  echo "2) 不启用"
  read -rp "请选择 [1/2]: " _p || true
  _p="${_p:-2}"

  if [ "$_p" = "1" ]; then
    read -rp "请输入代理地址（例：socks5h://18.183.63.49:3233）: " PROXY_URL || true
    [ -n "${PROXY_URL:-}" ] || die "代理地址为空"
    export ALL_PROXY="$PROXY_URL"
    export HTTPS_PROXY="$PROXY_URL"
    export HTTP_PROXY="$PROXY_URL"
    write_env /etc/profile.d/proxy.sh \
      "export ALL_PROXY=$PROXY_URL" \
      "export HTTPS_PROXY=$PROXY_URL" \
      "export HTTP_PROXY=$PROXY_URL"
    ok "代理已启用：$PROXY_URL"
    ok "已写入 /etc/profile.d/proxy.sh"
  else
    unset ALL_PROXY HTTPS_PROXY HTTP_PROXY || true
    rm -f /etc/profile.d/proxy.sh || true
    ok "不使用代理"
  fi
}

apt_install(){
  info "安装基础依赖"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y --no-install-recommends \
    ca-certificates curl git unzip zip xz-utils \
    libglu1-mesa openjdk-17-jdk-headless \
    python3 python3-venv \
    >/dev/null
  ok "依赖安装完成"
}

setup_flutter(){
  local FLUTTER_DIR="/opt/flutter"
  local u="flutter"

  if [ ! -d "$FLUTTER_DIR/.git" ]; then
    info "拉取 Flutter stable 到 $FLUTTER_DIR"
    rm -rf "$FLUTTER_DIR" || true
    git clone -b stable https://github.com/flutter/flutter.git "$FLUTTER_DIR"
    ok "Flutter 源码已就绪"
  else
    ok "Flutter 已存在：$FLUTTER_DIR"
  fi

  chown -R "$u:$u" "$FLUTTER_DIR"

  write_env /etc/profile.d/flutter.sh \
    "export PATH=/opt/flutter/bin:\$PATH" \
    "export FLUTTER_ROOT=/opt/flutter"
  ok "已写入 /etc/profile.d/flutter.sh"
}

android_sdk_install(){
  local SDK="/opt/android-sdk"
  local u="flutter"

  if [ ! -d "$SDK" ]; then
    info "安装 Android SDK 到 $SDK"
    mkdir -p "$SDK"
    chown -R "$u:$u" "$SDK"
  else
    ok "Android SDK 目录已存在：$SDK"
  fi

  write_env /etc/profile.d/android-sdk.sh \
    "export ANDROID_SDK_ROOT=$SDK" \
    "export ANDROID_HOME=$SDK" \
    "export PATH=$SDK/platform-tools:$SDK/cmdline-tools/latest/bin:\$PATH"
  ok "已写入 /etc/profile.d/android-sdk.sh"

  info "安装 cmdline-tools"
  local url="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
  local z="/tmp/cmdline-tools.zip"
  curl -fsSL "$url" -o "$z"
  rm -rf "$SDK/cmdline-tools/latest" || true
  mkdir -p "$SDK/cmdline-tools"
  unzip -q -o "$z" -d "$SDK/cmdline-tools"
  mv "$SDK/cmdline-tools/cmdline-tools" "$SDK/cmdline-tools/latest"
  chown -R "$u:$u" "$SDK"
  ok "cmdline-tools 已安装"

  info "接受 licenses"
  yes | "$SDK/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$SDK" --licenses >/dev/null || true
  ok "licenses 已处理"

  info "安装 platforms/build-tools（注意：sdkmanager 不支持 socks5h 环境变量，自动关闭代理）"
  HTTP_PROXY= HTTPS_PROXY= ALL_PROXY= \
  "$SDK/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$SDK" \
    "platform-tools" \
    "platforms;android-36" \
    "build-tools;35.0.1" \
    >/dev/null
  ok "platforms/build-tools 安装完成"
}

flutter_bootstrap(){
  local u="flutter"
  local SDK="/opt/android-sdk"

  info "初始化 flutter 用户目录权限"
  su - "$u" -c 'mkdir -p ~/.android ~/.gradle && touch ~/.android/repositories.cfg && chmod -R u+rwX ~/.android ~/.gradle' >/dev/null || true
  ok "用户目录就绪"

  info "配置 flutter（禁用 web/linux-desktop）"
  su - "$u" -c 'source /etc/profile.d/flutter.sh && flutter config --no-enable-web --no-enable-linux-desktop' >/dev/null
  ok "flutter config 完成"

  info "指向 Android SDK"
  su - "$u" -c "source /etc/profile.d/flutter.sh && flutter config --android-sdk $SDK" >/dev/null
  ok "flutter config --android-sdk 完成"

  info "预下载 Android 相关缓存（可能较久）"
  su - "$u" -c 'source /etc/profile.d/flutter.sh && flutter precache --android' || die "flutter precache 失败"
  ok "precache 完成"

  info "flutter doctor"
  su - "$u" -c 'source /etc/profile.d/flutter.sh && flutter doctor' || true
  ok "doctor 已输出（若无设备提示正常）"
}

main(){
  require_root
  echo "[`ts`] Flutter 一键部署开始"

  proxy_menu
  apt_install
  ensure_user flutter
  setup_flutter
  android_sdk_install
  flutter_bootstrap

  echo "=============================="
  ok "完成 ✅"
  echo "使用方式："
  echo "  1) 重新登录一次 shell（让 /etc/profile.d 生效）"
  echo "  2) 用 flutter 用户执行："
  echo "     su - flutter"
  echo "     flutter --version"
  echo "     flutter doctor"
}

main "$@"
SH

chmod +x flutter_full.sh
echo "[OK] 已生成 ./flutter_full.sh"
echo "运行：sudo bash ./flutter_full.sh"
