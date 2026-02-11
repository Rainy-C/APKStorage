#!/usr/bin/env bash
set -euo pipefail

ok(){ printf "[OK] %s\n" "$*"; }
info(){ printf "[..] %s\n" "$*"; }
err(){ printf "[ERR] %s\n" "$*" >&2; exit 1; }

need_root(){
  if [ "$(id -u)" -ne 0 ]; then
    err "请用 root 执行：sudo bash $0"
  fi
}

have_cmd(){ command -v "$1" >/dev/null 2>&1; }

ensure_pkg(){
  local pkgs=("$@")
  info "安装依赖：${pkgs[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y "${pkgs[@]}" >/dev/null
}

prompt_proxy(){
  echo
  echo "是否启用代理？（SOCKS5: socks5h://18.183.63.49:3233）"
  read -r -p "输入 y 启用 / n 不启用 [y/N]: " ans || true
  ans="${ans,,}"
  if [ "$ans" = "y" ] || [ "$ans" = "yes" ]; then
    PROXY_ON=1
  else
    PROXY_ON=0
  fi
}

write_proxy_env(){
  cat >/etc/profile.d/proxy.sh <<'EOF'
export ALL_PROXY="socks5h://18.183.63.49:3233"
export HTTPS_PROXY="$ALL_PROXY"
export HTTP_PROXY="$ALL_PROXY"
export NO_PROXY="127.0.0.1,localhost,::1"
EOF
  chmod 0644 /etc/profile.d/proxy.sh
  ok "已写入 /etc/profile.d/proxy.sh"
}

remove_proxy_env(){
  rm -f /etc/profile.d/proxy.sh || true
}

setup_proxy_service(){
  info "配置代理常驻服务（本机 :3233 -> 18.183.63.49）"
  ensure_pkg autossh

  if [ ! -f /root/jan.pem ]; then
    err "未找到 /root/jan.pem（EC2 密钥）。把 jan.pem 放到 /root/jan.pem 并 chmod 600 /root/jan.pem"
  fi
  chmod 600 /root/jan.pem

  cat >/etc/systemd/system/ec2socks.service <<'EOF'
[Unit]
Description=EC2 SOCKS5 Proxy (SSH Dynamic Forward)
After=network-online.target
Wants=network-online.target

[Service]
User=root
Restart=always
RestartSec=2
Environment=AUTOSSH_GATETIME=0
ExecStart=/usr/lib/autossh/autossh -M 0 -N -D 0.0.0.0:3233 \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  -o StrictHostKeyChecking=accept-new \
  -i /root/jan.pem ubuntu@ec2-18-183-63-49.ap-northeast-1.compute.amazonaws.com
ExecStop=/bin/kill -TERM $MAINPID
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now ec2socks.service >/dev/null
  ok "代理常驻已启动：socks5h://<本机IP>:3233"
}

sdk_env(){
  cat >/etc/profile.d/android-sdk.sh <<'EOF'
export ANDROID_SDK_ROOT=/opt/android-sdk
export ANDROID_HOME=/opt/android-sdk
export PATH="$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$PATH"
EOF
  chmod 0644 /etc/profile.d/android-sdk.sh
  ok "已写入 /etc/profile.d/android-sdk.sh"
}

flutter_env(){
  cat >/etc/profile.d/flutter.sh <<'EOF'
export FLUTTER_HOME=/opt/flutter
export PATH="$FLUTTER_HOME/bin:$PATH"
EOF
  chmod 0644 /etc/profile.d/flutter.sh
  ok "已写入 /etc/profile.d/flutter.sh"
}

ensure_user_flutter(){
  if ! id flutter >/dev/null 2>&1; then
    useradd -m -s /bin/bash flutter
    ok "已创建用户 flutter"
  else
    ok "用户就绪：flutter"
  fi
  mkdir -p /home/flutter
  chown -R flutter:flutter /home/flutter
  chmod 755 /home/flutter
}

kill_flutter_leftovers(){
  pkill -9 -f flutter_tools >/dev/null 2>&1 || true
  pkill -9 -f "gradle.*daemon" >/dev/null 2>&1 || true
  rm -f /opt/flutter/bin/cache/lockfile >/dev/null 2>&1 || true
}

clone_flutter(){
  if [ -d /opt/flutter/.git ]; then
    ok "Flutter 已存在：/opt/flutter（跳过 clone）"
    return
  fi
  info "拉取 Flutter stable 到 /opt/flutter"
  git clone -b stable https://github.com/flutter/flutter.git /opt/flutter >/dev/null
  ok "Flutter 源码已就位"
}

install_android_sdk(){
  info "安装 Android SDK 到 /opt/android-sdk"
  mkdir -p /opt/android-sdk/cmdline-tools
  chown -R flutter:flutter /opt/android-sdk

  local tmp=/tmp/cmdline-tools.zip
  local url="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"

  info "下载 cmdline-tools"
  curl -fsSL -o "$tmp" "$url"
  rm -rf /opt/android-sdk/cmdline-tools/latest
  mkdir -p /opt/android-sdk/cmdline-tools/latest
  unzip -q "$tmp" -d /opt/android-sdk/cmdline-tools/latest
  if [ -d /opt/android-sdk/cmdline-tools/latest/cmdline-tools ]; then
    mv /opt/android-sdk/cmdline-tools/latest/cmdline-tools/* /opt/android-sdk/cmdline-tools/latest/
    rmdir /opt/android-sdk/cmdline-tools/latest/cmdline-tools || true
  fi
  rm -f "$tmp"
  ok "cmdline-tools 安装完成"

  sdk_env

  info "接受 licenses"
  yes | /opt/android-sdk/cmdline-tools/latest/bin/sdkmanager --sdk_root=/opt/android-sdk --licenses >/dev/null || true
  ok "licenses 已处理"

  info "安装 platforms/build-tools（sdkmanager 不支持 socks5h，运行时临时移除代理环境变量）"
  (
    unset ALL_PROXY HTTPS_PROXY HTTP_PROXY NO_PROXY
    /opt/android-sdk/cmdline-tools/latest/bin/sdkmanager --sdk_root=/opt/android-sdk \
      "platform-tools" \
      "platforms;android-36" \
      "build-tools;35.0.1" \
      "cmdline-tools;latest" >/dev/null
  )
  ok "platforms/build-tools 安装完成"

  info "安装 NDK/CMake（同样临时移除代理变量）"
  (
    unset ALL_PROXY HTTPS_PROXY HTTP_PROXY NO_PROXY
    /opt/android-sdk/cmdline-tools/latest/bin/sdkmanager --sdk_root=/opt/android-sdk \
      "ndk;28.2.13676358" \
      "cmake;3.22.1" >/dev/null || true
  )
  ok "NDK/CMake 安装完成"

  chown -R flutter:flutter /opt/android-sdk
}

flutter_setup(){
  flutter_env
  kill_flutter_leftovers
  chown -R flutter:flutter /opt/flutter || true

  info "配置 flutter（仅启用 Android，关闭 web/linux），并关闭 analytics"
  su - flutter -c 'export HOME=/home/flutter; source /etc/profile.d/flutter.sh; source /etc/profile.d/android-sdk.sh; flutter config --no-enable-web --no-enable-linux-desktop --no-analytics >/dev/null'
  ok "flutter config 完成"

  info "flutter doctor -v"
  su - flutter -c 'export HOME=/home/flutter; source /etc/profile.d/flutter.sh; source /etc/profile.d/android-sdk.sh; flutter doctor -v' || true
  ok "flutter doctor 已运行（有 device 为空属于正常）"
}

main(){
  need_root
  prompt_proxy

  ensure_pkg ca-certificates curl unzip git xz-utils zip jq
  ensure_user_flutter

  if [ "$PROXY_ON" -eq 1 ]; then
    setup_proxy_service
    write_proxy_env
    ok "代理已启用：socks5h://18.183.63.49:3233"
  else
    remove_proxy_env
    ok "代理未启用"
  fi

  clone_flutter
  install_android_sdk
  flutter_setup

  echo
  ok "完成 ✅"
  echo "使用方式："
  echo "  su - flutter"
  echo "  source /etc/profile.d/flutter.sh"
  echo "  source /etc/profile.d/android-sdk.sh"
  echo "  flutter --version"
}

main "$@"
