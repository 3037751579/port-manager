#!/usr/bin/env bash
#
# portman - VPS 端口查看与管理工具
#   查看监听端口、协议类型、占用进程、防火墙放行状态，并可放行/关闭指定端口。
#
# 仓库: https://github.com/3037751579/port-manager

VERSION="1.0.1"
REPO="3037751579/port-manager"
RAW_URL="https://raw.githubusercontent.com/${REPO}/main"
INSTALL_PATH="/usr/local/bin/portman"

if [[ -t 1 ]]; then
    RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
    CYAN=$'\033[36m'; BOLD=$'\033[1m'; PLAIN=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; CYAN=""; BOLD=""; PLAIN=""
fi

info()  { printf '%s[信息]%s %s\n' "$GREEN" "$PLAIN" "$*"; }
warn()  { printf '%s[警告]%s %s\n' "$YELLOW" "$PLAIN" "$*"; }
error() { printf '%s[错误]%s %s\n' "$RED" "$PLAIN" "$*" >&2; }

is_root() { [[ $EUID -eq 0 ]]; }

need_root() {
    is_root && return 0
    error "此操作需要 root 权限，请使用 sudo 或切换到 root 后重试"
    return 1
}

has() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# 采集监听端口，统一输出为: 协议|地址|端口|进程(PID),进程(PID)
# ---------------------------------------------------------------------------
collect_listen() {
    if has ss; then
        ss -tulnp 2>/dev/null | awk '
            NR > 1 {
                proto = $1; local_addr = $5
                addr = local_addr; sub(/:[^:]*$/, "", addr)
                port = substr(local_addr, length(addr) + 2)
                procs = ""; s = $0
                while (match(s, /\("[^"]*",pid=[0-9]+/)) {
                    t = substr(s, RSTART + 2, RLENGTH - 2)
                    n = index(t, "\",pid=")
                    item = substr(t, 1, n - 1) "(" substr(t, n + 6) ")"
                    if (index("," procs ",", "," item ",") == 0)
                        procs = procs (procs == "" ? "" : ",") item
                    s = substr(s, RSTART + RLENGTH)
                }
                if (procs == "") procs = "-"
                print proto "|" addr "|" port "|" procs
            }'
    elif has netstat; then
        netstat -tulnp 2>/dev/null | awk '
            $1 ~ /^(tcp|udp)/ {
                proto = $1; sub(/6$/, "", proto)
                if (proto == "tcp" && $6 != "LISTEN") next
                local_addr = $4
                addr = local_addr; sub(/:[^:]*$/, "", addr)
                port = substr(local_addr, length(addr) + 2)
                procs = "-"
                if ($NF ~ /^[0-9]+\//) { split($NF, a, "/"); procs = a[2] "(" a[1] ")" }
                print proto "|" addr "|" port "|" procs
            }'
    else
        error "未找到 ss 或 netstat，请先安装 iproute2 (或 net-tools)"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# 防火墙
# ---------------------------------------------------------------------------
detect_firewall() {
    if has ufw && LC_ALL=C ufw status 2>/dev/null | grep -q "Status: active"; then
        echo ufw
    elif has firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
        echo firewalld
    elif has iptables; then
        echo iptables
    elif has nft && nft list ruleset 2>/dev/null | grep -q "hook input"; then
        echo nftables
    else
        echo none
    fi
}

firewall_name() {
    case $1 in
        ufw)       echo "UFW" ;;
        firewalld) echo "firewalld" ;;
        iptables)  echo "iptables" ;;
        nftables)  echo "nftables" ;;
        none)      echo "未检测到防火墙" ;;
        *)         echo "未知 (需要 root 才能检测)" ;;
    esac
}

# 输出防火墙已放行的端口，每行一个: 协议:起始-结束 (协议可为 any)；全部放行时输出 ALL
fw_allowed_list() {
    case $1 in
        ufw)
            if LC_ALL=C ufw status verbose 2>/dev/null | grep -q "allow (incoming)"; then
                echo ALL; return
            fi
            # user.rules 里的 tuple 行已把应用配置(如 OpenSSH)解析成了端口号
            cat /etc/ufw/user.rules /etc/ufw/user6.rules 2>/dev/null | awk '
                /^### tuple ###/ && $4 ~ /^(allow|limit)/ && $NF == "in" {
                    proto = $5; dports = $6
                    if (dports == "any") { print proto ":1-65535"; next }
                    n = split(dports, a, ",")
                    for (i = 1; i <= n; i++) { r = a[i]; sub(/:/, "-", r); print proto ":" r }
                }'
            ;;
        firewalld)
            local zone p s
            zone=$(firewall-cmd --get-default-zone 2>/dev/null)
            if [[ $(firewall-cmd --permanent --zone="$zone" --get-target 2>/dev/null) == ACCEPT ]]; then
                echo ALL; return
            fi
            for p in $(firewall-cmd --zone="$zone" --list-ports 2>/dev/null); do
                echo "${p#*/}:${p%/*}"
            done
            for s in $(firewall-cmd --zone="$zone" --list-services 2>/dev/null); do
                for p in $(firewall-cmd --info-service="$s" 2>/dev/null | awk '$1 == "ports:" { for (i = 2; i <= NF; i++) print $i }'); do
                    echo "${p#*/}:${p%/*}"
                done
            done
            ;;
        iptables)
            local rules
            rules=$(iptables -S INPUT 2>/dev/null)
            # 默认策略为 ACCEPT 且没有"全部拒绝"类规则，视为全部放行
            if grep -q -- "-P INPUT ACCEPT" <<<"$rules" &&
                ! grep -E -- "-j (DROP|REJECT)" <<<"$rules" |
                  grep -vqE -- "--dports? |-s |-i |state|-p icmp"; then
                echo ALL; return
            fi
            awk '/-j ACCEPT/ && /--dports? / {
                proto = "any"; d = ""
                for (i = 1; i <= NF; i++) {
                    if ($i == "-p") proto = $(i + 1)
                    if ($i == "--dport" || $i == "--dports") d = $(i + 1)
                }
                n = split(d, a, ",")
                for (j = 1; j <= n; j++) { r = a[j]; sub(/:/, "-", r); print proto ":" r }
            }' <<<"$rules"
            ;;
        none) echo ALL ;;
    esac
}

# ---------------------------------------------------------------------------
# 显示端口表
#   $1: all | public | <端口号>
# ---------------------------------------------------------------------------
show_ports() {
    local mode=${1:-all} data fw allowed=""
    data=$(collect_listen) || return 1

    if is_root; then
        fw=$(detect_firewall)
        allowed=$(fw_allowed_list "$fw" | tr '\n' ' ')
    else
        fw=unknown
        warn "当前不是 root，进程信息和防火墙状态可能不完整"
    fi

    printf '%s\n' "$data" | LC_ALL=C awk -F'|' \
        -v mode="$mode" -v fw="$fw" -v allowed="$allowed" \
        -v G="$GREEN" -v R="$RED" -v Y="$YELLOW" -v C="$CYAN" -v B="$BOLD" -v P="$PLAIN" '
    # 显示宽度: 3 字节的中文按 2 列算，2 字节字符按 1 列算
    function dw(s,   t, n3, n2) {
        t = s; n3 = gsub(/[\340-\357]/, "", t); n2 = gsub(/[\300-\337]/, "", t)
        return length(s) - n3 - n2
    }
    function cell(s, w, color,   pad) {
        pad = w - dw(s); if (pad < 1) pad = 1
        return color s (color == "" ? "" : P) sprintf("%" pad "s", "")
    }
    function is_local(a) {
        return a ~ /^127\./ || a == "[::1]" || a == "::1" || a ~ /^\[::ffff:127\./ || a ~ /%lo$/
    }
    function fw_allows(proto, port,   i) {
        if (allow_all) return 1
        for (i = 1; i <= nal; i++)
            if ((ap[i] == "any" || ap[i] == proto) && port >= lo[i] && port <= hi[i]) return 1
        return 0
    }
    function addlist(list, item) {
        if (index("," list ",", "," item ",")) return list
        return list (list == "" ? "" : ",") item
    }
    BEGIN {
        n = split(allowed, tok, " ")
        for (i = 1; i <= n; i++) {
            if (tok[i] == "ALL") { allow_all = 1; continue }
            split(tok[i], t, ":"); r = t[2]
            nal++; ap[nal] = t[1]
            if (index(r, "-")) { split(r, b, "-"); lo[nal] = b[1] + 0; hi[nal] = b[2] + 0 }
            else { lo[nal] = r + 0; hi[nal] = r + 0 }
        }
        while ((getline line < "/etc/services") > 0) {
            sub(/#.*/, "", line); split(line, f, " ")
            if (f[2] != "" && !(f[2] in svc)) svc[f[2]] = f[1]
        }
        split("21/ftp 22/ssh 25/smtp 53/dns 80/http 110/pop3 143/imap 443/https 465/smtps " \
              "587/submission 993/imaps 995/pop3s 1080/socks 1433/mssql 3306/mysql 3389/rdp " \
              "5432/postgresql 5900/vnc 6379/redis 8080/http-alt 8443/https-alt 9000/php-fpm " \
              "11211/memcached 27017/mongodb", d, " ")
        for (i in d) { split(d[i], kv, "/"); common[kv[1]] = kv[2] }
    }
    {
        proto = $1; addr = $2; port = $3; procs = $4
        if (port !~ /^[0-9]+$/) next
        if (mode != "all" && mode != "public" && port != mode) next
        k = proto "/" port
        if (!(k in seen)) { seen[k] = 1; cnt++; key[cnt] = k; KP[k] = proto; KN[k] = port + 0 }
        A[k] = addlist(A[k], addr)
        if (procs != "-") { m = split(procs, pp, ","); for (j = 1; j <= m; j++) PR[k] = addlist(PR[k], pp[j]) }
        if (!is_local(addr)) PUB[k] = 1
    }
    END {
        # 按端口号、协议排序
        for (i = 2; i <= cnt; i++) {
            v = key[i]; j = i - 1
            while (j > 0 && (KN[key[j]] > KN[v] || (KN[key[j]] == KN[v] && key[j] > v))) { key[j + 1] = key[j]; j-- }
            key[j + 1] = v
        }
        printf "%s%s%s%s%s%s%s%s\n", B, cell("协议", 6, ""), cell("端口", 8, ""), cell("范围", 7, ""),
            cell("防火墙", 9, ""), cell("服务", 16, ""), cell("监听地址", 26, ""), "进程(PID)" P
        shown = 0; npub = 0; nblock = 0
        for (i = 1; i <= cnt; i++) {
            k = key[i]; proto = KP[k]; port = KN[k]
            if (mode == "public" && !PUB[k]) continue
            shown++
            s = svc[port "/" proto]; if (s == "") s = common[port]; if (s == "") s = "-"
            if (PUB[k]) {
                npub++; scope = cell("公网", 7, Y)
                if (fw == "unknown" || fw == "nftables") st = cell("未知", 9, "")
                else if (fw_allows(proto, port)) st = cell("已放行", 9, G)
                else { st = cell("未放行", 9, R); nblock++ }
            } else {
                scope = cell("本机", 7, ""); st = cell("-", 9, "")
            }
            printf "%s%s%s%s%s%s%s\n", cell(proto, 6, C), cell(port, 8, ""), scope, st,
                cell(s, 16, ""), cell(A[k], 26, ""), (PR[k] == "" ? "-" : PR[k])
        }
        if (shown == 0) {
            if (mode == "all" || mode == "public") print "  (没有找到监听中的端口)"
            else print "  端口 " mode " 当前没有程序在监听"
            exit
        }
        printf "\n共 %d 个监听项，其中 %d 个对公网监听", shown, npub
        if (nblock > 0) printf "，%s%d 个未被防火墙放行%s", R, nblock, P
        print ""
    }'

    printf '防火墙: %s\n' "$(firewall_name "$fw")"
    printf '%s提示: 云服务器(阿里云/腾讯云/AWS 等)还需在控制台「安全组」中放行端口，本脚本无法修改安全组。%s\n' "$YELLOW" "$PLAIN"
}

# ---------------------------------------------------------------------------
# 端口与协议参数解析
# ---------------------------------------------------------------------------
# 支持: 8080 / 80,443 / 8000-8100 / 8000:8100，每行输出一项
parse_ports() {
    local spec=${1// /} tok lo hi
    local -a toks
    if [[ -z $spec ]]; then error "请指定端口"; return 1; fi
    IFS=',' read -ra toks <<<"$spec"
    for tok in "${toks[@]}"; do
        tok=${tok/:/-}
        if [[ $tok =~ ^([0-9]+)-([0-9]+)$ ]]; then
            lo=${BASH_REMATCH[1]}; hi=${BASH_REMATCH[2]}
        elif [[ $tok =~ ^[0-9]+$ ]]; then
            lo=$tok; hi=$tok
        else
            error "无效的端口: $tok"; return 1
        fi
        lo=$((10#$lo)); hi=$((10#$hi))
        if (( lo < 1 || hi > 65535 || lo > hi )); then
            error "端口超出范围 (1-65535): $tok"; return 1
        fi
        if (( lo == hi )); then echo "$lo"; else echo "$lo-$hi"; fi
    done
}

parse_proto() {
    case ${1:-tcp} in
        tcp|TCP|t)        echo "tcp" ;;
        udp|UDP|u)        echo "udp" ;;
        both|all|tcp+udp) echo "tcp udp" ;;
        *) error "无效的协议: $1 (可选 tcp / udp / both)"; return 1 ;;
    esac
}

save_iptables() {
    if has netfilter-persistent; then
        netfilter-persistent save >/dev/null 2>&1 && info "iptables 规则已持久化" && return
    fi
    if [[ -f /etc/sysconfig/iptables ]]; then
        iptables-save >/etc/sysconfig/iptables
        has ip6tables-save && [[ -f /etc/sysconfig/ip6tables ]] && ip6tables-save >/etc/sysconfig/ip6tables
        info "iptables 规则已保存到 /etc/sysconfig/iptables"
    elif [[ -d /etc/iptables ]]; then
        iptables-save >/etc/iptables/rules.v4
        has ip6tables-save && ip6tables-save >/etc/iptables/rules.v6
        info "iptables 规则已保存到 /etc/iptables/"
    else
        warn "规则已生效，但重启后会丢失。持久化方法: Debian/Ubuntu 安装 iptables-persistent，CentOS 安装 iptables-services"
    fi
}

# ---------------------------------------------------------------------------
# 放行 / 关闭端口
# ---------------------------------------------------------------------------
open_port() {
    need_root || return 1
    local ports protos fw port p ipt_port cmd changed=0
    ports=$(parse_ports "$1") || return 1
    protos=$(parse_proto "${2:-tcp}") || return 1
    fw=$(detect_firewall)

    case $fw in
        none)
            info "未检测到防火墙，端口无需放行；只要有程序在监听，就可以从外部访问"
            warn "如果是云服务器，请到控制台「安全组」中放行对应端口"
            return 0 ;;
        nftables)
            error "检测到原生 nftables 规则，暂不支持自动修改，请手动添加规则或改用 ufw/firewalld"
            return 1 ;;
    esac

    info "使用 $(firewall_name "$fw") 放行端口..."
    for port in $ports; do
        for p in $protos; do
            case $fw in
                ufw)
                    ufw allow "${port/-/:}/$p" >/dev/null && changed=1 ;;
                firewalld)
                    firewall-cmd --permanent --add-port="$port/$p" >/dev/null && changed=1 ;;
                iptables)
                    ipt_port=${port/-/:}
                    for cmd in iptables ip6tables; do
                        has $cmd || continue
                        $cmd -C INPUT -p "$p" --dport "$ipt_port" -j ACCEPT 2>/dev/null ||
                            $cmd -I INPUT -p "$p" --dport "$ipt_port" -j ACCEPT
                    done
                    changed=1 ;;
            esac
            printf '  %s✔%s %s/%s\n' "$GREEN" "$PLAIN" "$port" "$p"
        done
    done

    if (( changed )); then
        [[ $fw == firewalld ]] && firewall-cmd --reload >/dev/null
        [[ $fw == iptables ]] && save_iptables
    fi
    info "完成。云服务器请同时确认「安全组」已放行"
}

# 待关闭的端口里是否包含当前 SSH 端口
hits_ssh_port() {
    local ports=$1 sshp port lo hi
    for sshp in $(collect_listen 2>/dev/null | awk -F'|' '$4 ~ /sshd/ { print $3 }' | sort -u); do
        for port in $ports; do
            lo=${port%-*}; hi=${port#*-}
            if (( sshp >= lo && sshp <= hi )); then echo "$sshp"; return 0; fi
        done
    done
    return 1
}

close_port() {
    need_root || return 1
    local ports protos fw port p ipt_port cmd sshp ans
    ports=$(parse_ports "$1") || return 1
    protos=$(parse_proto "${2:-tcp}") || return 1
    fw=$(detect_firewall)

    case $fw in
        none)     warn "未检测到防火墙，没有可删除的放行规则"; return 0 ;;
        nftables) error "检测到原生 nftables 规则，暂不支持自动修改"; return 1 ;;
    esac

    if sshp=$(hits_ssh_port "$ports"); then
        warn "端口 $sshp 是当前 SSH 端口，关闭后可能导致无法远程登录！"
        read -rp "确定要继续吗? [y/N]: " ans
        [[ $ans == [yY] ]] || { info "已取消"; return 0; }
    fi

    info "使用 $(firewall_name "$fw") 关闭端口..."
    for port in $ports; do
        for p in $protos; do
            case $fw in
                ufw)
                    ufw delete allow "${port/-/:}/$p" >/dev/null 2>&1 ;;
                firewalld)
                    firewall-cmd --permanent --remove-port="$port/$p" >/dev/null 2>&1 ;;
                iptables)
                    ipt_port=${port/-/:}
                    for cmd in iptables ip6tables; do
                        has $cmd || continue
                        while $cmd -C INPUT -p "$p" --dport "$ipt_port" -j ACCEPT 2>/dev/null; do
                            $cmd -D INPUT -p "$p" --dport "$ipt_port" -j ACCEPT
                        done
                    done ;;
            esac
            printf '  %s✘%s %s/%s\n' "$RED" "$PLAIN" "$port" "$p"
        done
    done

    [[ $fw == firewalld ]] && firewall-cmd --reload >/dev/null
    if [[ $fw == iptables ]]; then
        save_iptables
        if [[ $(fw_allowed_list iptables) == ALL ]]; then
            warn "iptables 默认策略为 ACCEPT，删除放行规则后端口仍然可以访问"
        fi
    fi
    info "完成"
}

show_firewall() {
    need_root || return 1
    local fw
    fw=$(detect_firewall)
    printf '%s防火墙: %s%s\n\n' "$BOLD" "$(firewall_name "$fw")" "$PLAIN"
    case $fw in
        ufw)       ufw status verbose ;;
        firewalld) firewall-cmd --list-all ;;
        iptables)
            iptables -L INPUT -n -v --line-numbers
            [[ $(fw_allowed_list iptables) == ALL ]] && echo && info "当前 INPUT 默认放行，所有端口都可以访问"
            ;;
        nftables)  nft list ruleset ;;
        none)      info "所有端口都不受本机防火墙限制" ;;
    esac
}

# ---------------------------------------------------------------------------
# 更新 / 卸载
# ---------------------------------------------------------------------------
download() {
    if has curl; then curl -fsSL "$1" -o "$2"
    elif has wget; then wget -qO "$2" "$1"
    else error "需要 curl 或 wget"; return 1
    fi
}

update_self() {
    need_root || return 1
    local tmp
    tmp=$(mktemp)
    info "正在下载最新版本..."
    if download "$RAW_URL/portman.sh" "$tmp" && bash -n "$tmp"; then
        install -m 755 "$tmp" "$INSTALL_PATH"
        rm -f "$tmp"
        info "已更新到 $("$INSTALL_PATH" version)"
    else
        rm -f "$tmp"
        error "下载失败，请检查网络"
        return 1
    fi
}

uninstall_self() {
    need_root || return 1
    rm -f "$INSTALL_PATH"
    info "portman 已卸载 (防火墙规则保持不变)"
}

# ---------------------------------------------------------------------------
# 菜单与命令行
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
portman v${VERSION} - VPS 端口查看与管理工具

命令列表:
   1. portman                        打开交互菜单，输入数字选择功能
   2. portman list                   查看所有监听端口（协议、进程、防火墙是否放行）
   3. portman public                 只看对公网开放的端口
   4. portman check <端口>           查询某个端口被哪个程序占用
   5. portman open  <端口> [协议]    放行(开启)端口，协议: tcp(默认) / udp / both
   6. portman close <端口> [协议]    关闭端口（删除防火墙放行规则）
   7. portman fw                     查看防火墙状态和规则
   8. portman update                 更新到最新版本
   9. portman uninstall              卸载 portman（不影响已有防火墙规则）
  10. portman version                查看当前版本

端口写法:
  8080          单个端口
  80,443        多个端口，用英文逗号分隔
  8000-8100     端口范围

示例:
  portman open 8080                 放行 8080/tcp
  portman open 80,443 tcp           放行 80 和 443 的 tcp
  portman open 10000-10100 both     放行 10000~10100 的 tcp 和 udp
  portman close 8080                关闭 8080/tcp
EOF
}

pause() { read -rp "按回车键返回菜单..." _; }

menu() {
    local c port proto
    while true; do
        clear 2>/dev/null
        printf '%s===== portman v%s · 端口查看与管理 =====%s\n\n' "$BOLD" "$VERSION" "$PLAIN"
        echo "  1. 查看所有监听端口"
        echo "  2. 只看对公网开放的端口"
        echo "  3. 查询指定端口"
        echo "  4. 放行(开启)端口"
        echo "  5. 关闭端口"
        echo "  6. 查看防火墙状态"
        echo "  7. 更新 portman"
        echo "  8. 卸载 portman"
        echo "  0. 退出"
        echo
        read -rp "请选择 [0-8]: " c
        echo
        case $c in
            1) show_ports all ;;
            2) show_ports public ;;
            3) read -rp "端口号: " port
               if [[ $port =~ ^[0-9]+$ ]]; then show_ports "$port"; else error "请输入单个端口号"; fi ;;
            4|5)
               read -rp "端口 (如 8080 / 80,443 / 8000-8100): " port
               read -rp "协议 tcp/udp/both [默认 tcp]: " proto
               if [[ $c == 4 ]]; then open_port "$port" "${proto:-tcp}"; else close_port "$port" "${proto:-tcp}"; fi ;;
            6) show_firewall ;;
            7) update_self ;;
            8) uninstall_self && exit 0 ;;
            0|q) exit 0 ;;
            *) error "无效选择" ;;
        esac
        echo
        pause
    done
}

main() {
    case ${1:-} in
        "")              menu ;;
        list|ls|l)       show_ports all ;;
        public|pub)      show_ports public ;;
        check|c)
            [[ ${2:-} =~ ^[0-9]+$ ]] || { error "用法: portman check <端口>"; exit 1; }
            show_ports "$2" ;;
        open|allow)      [[ -n ${2:-} ]] || { usage; exit 1; }; open_port "$2" "${3:-tcp}" ;;
        close|deny)      [[ -n ${2:-} ]] || { usage; exit 1; }; close_port "$2" "${3:-tcp}" ;;
        fw|firewall)     show_firewall ;;
        update)          update_self ;;
        uninstall)       uninstall_self ;;
        version|-v|--version) echo "portman v${VERSION}" ;;
        help|-h|--help)  usage ;;
        *)               error "未知命令: $1"; echo; usage; exit 1 ;;
    esac
}

# 被 source 时只加载函数(便于测试)
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
