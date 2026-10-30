#!/usr/bin/env bash
#
# portman 一键安装脚本
#   bash <(curl -fsSL https://raw.githubusercontent.com/3037751579/port-manager/main/install.sh)

set -e

REPO="3037751579/port-manager"
URL="https://raw.githubusercontent.com/${REPO}/main/portman.sh"
INSTALL_PATH="/usr/local/bin/portman"

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; PLAIN=$'\033[0m'

if [[ $EUID -ne 0 ]]; then
    echo "${RED}[错误]${PLAIN} 请使用 root 运行安装脚本 (或在命令前加 sudo)"
    exit 1
fi

# 缺少 ss/netstat 时尝试安装 iproute2
if ! command -v ss >/dev/null 2>&1 && ! command -v netstat >/dev/null 2>&1; then
    echo "${YELLOW}[信息]${PLAIN} 正在安装 iproute2..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y -qq iproute2
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q iproute
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q iproute
    elif command -v apk >/dev/null 2>&1; then
        apk add --quiet iproute2
    fi
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

echo "${GREEN}[信息]${PLAIN} 正在下载 portman..."
if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$URL" -o "$tmp"
elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp" "$URL"
else
    echo "${RED}[错误]${PLAIN} 需要 curl 或 wget"
    exit 1
fi

bash -n "$tmp"
install -m 755 "$tmp" "$INSTALL_PATH"

echo "${GREEN}[信息]${PLAIN} 安装完成: $("$INSTALL_PATH" version)"
"$INSTALL_PATH" shortcut
echo
cat <<'EOF'
常用命令:
  0. s                     快捷键：输入 s 回车，直接打开菜单
  1. portman               打开交互菜单，输入数字选择功能
  2. portman list          查看所有监听端口（协议、进程、防火墙是否放行）
  3. portman public        只看对公网开放的端口
  4. portman check 80      查询某个端口被谁占用
  5. portman open 8080     放行(开启) 8080 端口，默认 tcp
  6. portman close 8080    关闭 8080 端口（删除放行规则）
  7. portman fw            查看防火墙状态和规则
  8. portman help          查看全部命令和用法示例
EOF
