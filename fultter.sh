#!/usr/bin/env bash
set -euo pipefail

L(){ printf "%s %s\n" "$1" "$2"; }
OK(){ L "[OK]" "$*"; }
ERR(){ L "[ERR]" "$*"; exit 1; }
DO(){ L "[..]" "$*"; }

[ "$(id -u)" -eq 0 ] || ERR "请用 root 运行"

SOCKS_REMOTE="socks5h://18.183.63.49:3233"
PRIVOXY_LISTEN="127.0.0.1:8118"
SDK_ROOT="/opt/android-sdk"
FLUTTER_ROOT="/opt/flutter"
FLUTTER_USER="flutter"

USE_PROXY="n"
printf "是否启用代理？（SOCKS5: %s）\n输入 y 启用 / n 不启用 [y/N]: " "$SOCKS_REMOTE"
read -r ans || true
case "${ans:-}" in
  y|Y) USE_PROXY="y" ;;
  *) USE_PROXY="n" ;;
esac

DO "安装基础依赖"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y ca-certificates curl unzip git xz-utils zip jq openjdk-17-jdk-headless >/dev/null
OK "依赖安装完成"

if ! id -u "$FLUTTER_USER" >/dev/null 2>&1; then
  DO "创建用户：$FLUTTER_USER"
  useradd -m -s /bin/bash "$FLUTTER_USER"
  OK "用户就绪：$FLUTTER_USER"
else
  OK "用户已存在：$FLUTTER_USER"
fi

setup_proxy(){
  apt-get install -y privoxy >/dev/null

  mkdir -p /etc/privoxy
  cat >/etc/privoxy/config <<EOF
user-manual /usr/share/doc/privoxy/user-manual
confdir /etc/privoxy
logdir /var/log/privoxy
listen-address  ${PRIVOXY_LISTEN}
toggle  1
enable-remote-toggle  0
enable-remote-http-toggle  0
enable-edit-actions 0
enforce-blocks 0
forward-socks5t / ${SOCKS_REMOTE#socks5h://}
EOF

  systemctl enable --now privoxy >/dev/null
  ss -lntp | grep -q "${PRIVOXY_LISTEN}" || ERR "privoxy 未监听 ${PRIVOXY_LISTEN}"

  cat >/etc/profile.d/proxy.sh <<EOF
export NO_PROXY="127.0.0.1,localhost,::1"
export HTTP_PROXY="http://${PRIVOXY_LISTEN}"
export HTTPS_PROXY="http://${PRIVOXY_LISTEN}"
export http_proxy="\$HTTP_PROXY"
export https_proxy="\$HTTPS_PROXY"
unset ALL_PROXY all_proxy
EOF
  chmod 644 /etc/profile.d/proxy.sh

  export NO_PROXY="127.0.0.1,localhost,::1"
  export HTTP_PROXY="http://${PRIVOXY_LISTEN}"
  export HTTPS_PROXY="http://${PRIVOXY_LISTEN}"
  export http_proxy="$HTTP_PROXY"
  export https_proxy="$HTTPS_PROXY"
  unset ALL_PROXY all_proxy

  OK "代理已启用：HTTP(S) -> http://${PRIVOXY_LISTEN}  (由 ${SOCKS_REMOTE} 中转)"
}

disable_proxy_env(){
  unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy
  export NO_PROXY="127.0.0.1,localhost,::1"
}

if [ "$USE_PROXY" = "y" ]; then
  DO "配置代理（privoxy: HTTP->SOCKS 转换）"
  setup_proxy
else
  disable_proxy_env
  OK "代理未启用"
fi

DO "安装/更新 Flutter 到 ${FLUTTER_ROOT}"
if [ -d "${FLUTTER_ROOT}/.git" ]; then
  OK "Flutter 已存在：${FLUTTER_ROOT}"
else
  rm -rf "${FLUTTER_ROOT}"
  git clone -b stable https://github.com/flutter/flutter.git "${FLUTTER_ROOT}" >/dev/null
  OK "Flutter clone 完成"
fi

cat >/etc/profile.d/flutter.sh <<EOF
export FLUTTER_HOME="${FLUTTER_ROOT}"
export PATH="\$FLUTTER_HOME/bin:\$PATH"
EOF
chmod 644 /etc/profile.d/flutter.sh
OK "已写入 /etc/profile.d/flutter.sh"

DO "安装 Android SDK 到 ${SDK_ROOT}"
mkdir -p "${SDK_ROOT}"

if [ ! -x "${SDK_ROOT}/cmdline-tools/latest/bin/sdkmanager" ]; then
  DO "下载 cmdline-tools"
  tmpd="$(mktemp -d)"
  cd "$tmpd"
  curl -fsSL -o cmdline-tools.zip https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip
  rm -rf "${SDK_ROOT}/cmdline-tools"
  mkdir -p "${SDK_ROOT}/cmdline-tools"
  unzip -q cmdline-tools.zip
  mv cmdline-tools "${SDK_ROOT}/cmdline-tools/latest"
  cd /
  rm -rf "$tmpd"
  OK "cmdline-tools 安装完成"
else
  OK "cmdline-tools 已存在"
fi

cat >/etc/profile.d/android-sdk.sh <<EOF
export ANDROID_HOME="${SDK_ROOT}"
export ANDROID_SDK_ROOT="${SDK_ROOT}"
export PATH="\$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:\$ANDROID_SDK_ROOT/platform-tools:\$PATH"
EOF
chmod 644 /etc/profile.d/android-sdk.sh
OK "已写入 /etc/profile.d/android-sdk.sh"

export ANDROID_HOME="${SDK_ROOT}"
export ANDROID_SDK_ROOT="${SDK_ROOT}"
export PATH="${SDK_ROOT}/cmdline-tools/latest/bin:${SDK_ROOT}/platform-tools:${PATH}"

DO "接受 Android licenses"
yes | sdkmanager --sdk_root="${SDK_ROOT}" --licenses >/dev/null || true
OK "licenses 处理完成"

DO "安装 platforms/build-tools/ndk/cmake"
sdkmanager --sdk_root="${SDK_ROOT}" \
  "platform-tools" \
  "platforms;android-36" \
  "build-tools;35.0.1" \
  "ndk;28.2.13676358" \
  "cmake;3.22.1" >/dev/null || true
OK "SDK 组件安装完成"

chown -R "${FLUTTER_USER}:${FLUTTER_USER}" /home/"${FLUTTER_USER}"
chown -R root:root "${SDK_ROOT}" "${FLUTTER_ROOT}"
chmod -R a+rX "${SDK_ROOT}" "${FLUTTER_ROOT}"

run_flutter(){
  su - "${FLUTTER_USER}" -c "bash -lc 'source /etc/profile.d/flutter.sh; source /etc/profile.d/android-sdk.sh; ${1}'"
}

DO "配置 flutter（只启用 Android，关闭 web/linux），并关闭 analytics"
run_flutter "flutter config --android-sdk '${SDK_ROOT}' --no-enable-web --no-enable-linux-desktop >/dev/null || true"
run_flutter "flutter config --no-analytics >/dev/null || true"
run_flutter "flutter --disable-analytics >/dev/null || true"
OK "flutter config 完成"

DO "接受 flutter 的 android licenses"
run_flutter "yes | flutter doctor --android-licenses >/dev/null || true"
OK "flutter licenses 完成"

DO "检查 flutter doctor（简洁输出）"
run_flutter "flutter doctor" | sed -n '1,120p'
OK "完成 ✅"

echo
echo "使用方式："
echo "  su - ${FLUTTER_USER}"
echo "  source /etc/profile.d/flutter.sh"
echo "  source /etc/profile.d/android-sdk.sh"
echo "  flutter --version"
echo "  flutter create hello && cd hello && flutter build apk --release"
