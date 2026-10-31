#!/usr/bin/env bash
#
# portman - VPS 端口查看与管理工具
#   查看监听端口、协议类型、占用进程、防火墙放行状态，并可放行/关闭指定端口。
#
# 仓库: https://github.com/3037751579/port-manager

VERSION="1.3.0"
REPO="3037751579/port-manager"
RAW_URL="https://raw.githubusercontent.com/${REPO}/main"
INSTALL_PATH="/usr/local/bin/portman"
BIN_DIR="/usr/local/bin"
SHORTCUTS="s S"

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

# 入站是否默认放行所有端口
fw_default_open() {
    case $1 in
        ufw)
            LC_ALL=C ufw status verbose 2>/dev/null | grep -q "allow (incoming)" ;;
        firewalld)
            [[ $(firewall-cmd --permanent --zone="$(firewall-cmd --get-default-zone 2>/dev/null)" --get-target 2>/dev/null) == ACCEPT ]] ;;
        iptables)
            local rules
            rules=$(iptables -S INPUT 2>/dev/null)
            # 默认策略为 ACCEPT 且没有"全部拒绝"类规则
            grep -q -- "-P INPUT ACCEPT" <<<"$rules" &&
                ! grep -E -- "-j (DROP|REJECT)" <<<"$rules" |
                  grep -vqE -- "--dports? |-s |-i |state|-p icmp" ;;
        none) return 0 ;;
        *) return 1 ;;
    esac
}

# 输出防火墙已放行的端口，每行一个: 协议:起始-结束 (协议可为 any)；默认全部放行时输出 ALL
fw_allowed_list() {
    if fw_default_open "$1"; then echo ALL; else fw_rule_list "$1"; fi
}

# 输出防火墙里明确放行端口的规则，格式同上
fw_rule_list() {
    case $1 in
        ufw)
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
            iptables -S INPUT 2>/dev/null | awk '/-j ACCEPT/ && /--dports? / {
                proto = "any"; d = ""
                for (i = 1; i <= NF; i++) {
                    if ($i == "-p") proto = $(i + 1)
                    if ($i == "--dport" || $i == "--dports") d = $(i + 1)
                }
                n = split(d, a, ",")
                for (j = 1; j <= n; j++) { r = a[j]; sub(/:/, "-", r); print proto ":" r }
            }'
            ;;
    esac
}

# ---------------------------------------------------------------------------
# 显示端口表
#   $1: all | public | <端口号>
# ---------------------------------------------------------------------------
show_ports() {
    local mode=${1:-all} data fw allowed="" defopen=0
    data=$(collect_listen) || return 1

    if is_root; then
        fw=$(detect_firewall)
        allowed=$(fw_rule_list "$fw" | tr '\n' ' ')
        fw_default_open "$fw" && defopen=1
    else
        fw=unknown
        warn "当前不是 root，进程信息和防火墙状态可能不完整"
    fi

    printf '%s\n' "$data" | LC_ALL=C awk -F'|' \
        -v mode="$mode" -v fw="$fw" -v allowed="$allowed" -v defopen="$defopen" \
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
                else if (fw == "none") st = cell("无防火墙", 9, Y)
                else if (fw_allows(proto, port)) st = cell("已放行", 9, G)
                else if (defopen) st = cell("默认放行", 9, Y)
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

    printf '防火墙: %s' "$(firewall_name "$fw")"
    if (( defopen )) && [[ $fw != none ]]; then
        printf '  %s(入站默认放行：所有端口都能从外部访问)%s' "$YELLOW" "$PLAIN"
    elif [[ $fw == ufw || $fw == firewalld || $fw == iptables ]]; then
        printf '  %s(入站默认拒绝：只有已放行的端口能访问)%s' "$GREEN" "$PLAIN"
    fi
    echo
    printf '说明: 已放行=有明确放行规则  默认放行=没有规则但防火墙未拦截  未放行=外部无法访问\n'
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

# ---------------------------------------------------------------------------
# iptables 规则持久化
#   portman 把自己添加的规则记录在 STATE_FILE，开机时由 systemd 服务调用
#   `portman restore` 重新应用。只恢复 portman 的规则，不影响 docker/fail2ban 等。
# ---------------------------------------------------------------------------
STATE_FILE="/etc/portman/iptables.conf"
SERVICE_NAME="portman-restore.service"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"

# 规则不存在时插入到 INPUT 最前面
ipt_add() {
    local cmd=$1; shift
    $cmd -C INPUT "$@" 2>/dev/null || $cmd -I INPUT "$@" 2>/dev/null
}

# 默认拒绝前必须的基础规则: 回环、已建立的连接、ICMP。不支持连接状态匹配时返回 1
ipt_base() {
    local cmd=$1
    if [[ $cmd == iptables ]]; then ipt_add "$cmd" -p icmp -j ACCEPT
    else ipt_add "$cmd" -p ipv6-icmp -j ACCEPT; fi
    ipt_add "$cmd" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT ||
        ipt_add "$cmd" -m state --state ESTABLISHED,RELATED -j ACCEPT || return 1
    ipt_add "$cmd" -i lo -j ACCEPT
}

state_add() {
    mkdir -p "${STATE_FILE%/*}"
    grep -qx "allow $1 $2" "$STATE_FILE" 2>/dev/null || echo "allow $1 $2" >>"$STATE_FILE"
}

state_del() {
    [[ -f $STATE_FILE ]] && sed -i "/^allow $1 $2\$/d" "$STATE_FILE"
}

state_policy() {
    mkdir -p "${STATE_FILE%/*}"
    [[ -f $STATE_FILE ]] && sed -i '/^policy /d' "$STATE_FILE"
    echo "policy $1" >>"$STATE_FILE"
}

# 开机时重新应用记录的规则 (可重复执行)
restore_rules() {
    [[ -f $STATE_FILE ]] || return 0
    local cmd kw p port policy
    policy=$(awk '$1 == "policy" { v = $2 } END { print v }' "$STATE_FILE")
    for cmd in iptables ip6tables; do
        has $cmd || continue
        while read -r kw p port; do
            [[ $kw == allow ]] && ipt_add "$cmd" -p "$p" --dport "${port/-/:}" -j ACCEPT
        done <"$STATE_FILE"
        if [[ $policy == DROP ]]; then
            ipt_base "$cmd" && $cmd -P INPUT DROP
        elif [[ $policy == ACCEPT ]]; then
            $cmd -P INPUT ACCEPT
        fi
    done
}

install_restore_service() {
    if ! has systemctl || [[ ! -d /run/systemd/system ]]; then
        warn "系统未使用 systemd，规则已生效但重启后会丢失"
        return 1
    fi
    cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=portman: restore firewall rules
DefaultDependencies=no
After=local-fs.target
Before=network-pre.target shutdown.target
Wants=network-pre.target
Conflicts=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$INSTALL_PATH restore

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
}

save_iptables() {
    has netfilter-persistent && netfilter-persistent save >/dev/null 2>&1
    if install_restore_service; then
        info "规则已保存，重启后自动恢复 (记录在 $STATE_FILE)"
    fi
}

remove_restore_service() {
    [[ -f $SERVICE_FILE ]] || return 0
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload 2>/dev/null
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
                    for cmd in iptables ip6tables; do
                        has $cmd && ipt_add "$cmd" -p "$p" --dport "${port/-/:}" -j ACCEPT
                    done
                    state_add "$p" "$port"
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
    for sshp in $(ssh_ports); do
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
                    done
                    state_del "$p" "$port" ;;
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

# ---------------------------------------------------------------------------
# 一键关闭其他端口 / 恢复全部放行
# ---------------------------------------------------------------------------
# 当前 SSH 端口: 优先取本次连接的端口，其次是 sshd 正在监听的端口
ssh_ports() {
    {
        [[ -n ${SSH_CONNECTION:-} ]] && awk '{ print $4 }' <<<"$SSH_CONNECTION"
        collect_listen 2>/dev/null | awk -F'|' '$4 ~ /sshd/ { print $3 }'
    } | sort -un
}

# 一键关闭时使用的防火墙: 已启用的 ufw/firewalld 优先，其次是已安装但未启用的 ufw，最后是 iptables
lock_backend() {
    local fw
    fw=$(detect_firewall)
    case $fw in
        ufw|firewalld) echo "$fw" ;;
        *) if has ufw; then echo ufw-off; else echo "$fw"; fi ;;
    esac
}

# 输出要保留的端口，每行: 协议 端口 说明
keep_list() {
    local p
    {
        collect_listen | awk -F'|' '
            !($2 ~ /^127\./ || $2 == "[::1]" || $2 == "::1" || $2 ~ /^\[::ffff:127\./ || $2 ~ /%lo$/) {
                print $1, $3, $4
            }'
        p=$(ssh_ports)
        for p in ${p:-22}; do echo "tcp $p SSH"; done
    } | awk '!seen[$1 " " $2]++' | sort -k2,2n -k1,1
}

lockdown() {
    need_root || return 1
    local backend keep extra eprotos port p ans cmd state_ok

    backend=$(lock_backend)
    if [[ $backend == none ]]; then
        warn "未检测到可用的防火墙"
        if has apt-get; then
            read -rp "是否安装 ufw 防火墙? [y/N]: " ans
            [[ $ans == [yY] ]] || { info "已取消"; return 0; }
            apt-get update -qq && apt-get install -y -qq ufw || { error "ufw 安装失败"; return 1; }
            backend=ufw-off
        else
            error "请先安装 firewalld 或 iptables"; return 1
        fi
    elif [[ $backend == nftables ]]; then
        error "检测到原生 nftables 规则，暂不支持自动修改，请手动配置或改用 ufw/firewalld"
        return 1
    fi

    keep=$(keep_list) || return 1
    printf '%s以下正在使用的端口会被保留，其余所有入站端口将被关闭:%s\n\n' "$BOLD" "$PLAIN"
    echo "  协议   端口        进程"
    while read -r p port note; do
        printf '  %s%-6s%s %-11s %s\n' "$CYAN" "$p" "$PLAIN" "$port" "$note"
    done <<<"$keep"
    echo

    read -rp "如需额外保留端口请输入 (如 8080 / 80,443 / 8000-8100)，直接回车跳过: " extra
    if [[ -n $extra ]]; then
        extra=$(parse_ports "$extra") || return 1
        read -rp "额外端口的协议 tcp/udp/both [默认 tcp]: " ans
        eprotos=$(parse_proto "${ans:-tcp}") || return 1
        for port in $extra; do
            for p in $eprotos; do keep+=$'\n'"$p $port 手动添加"; done
        done
    fi

    echo
    warn "将使用 $(firewall_name "${backend%-off}") 设置为「默认拒绝入站」，只放行上面列出的端口"
    warn "SSH 端口会自动保留；已有的放行规则不会被删除"
    read -rp "确认执行请输入 yes: " ans
    [[ $ans == yes ]] || { info "已取消"; return 0; }

    case $backend in
        ufw|ufw-off)
            while read -r p port _; do
                ufw allow "${port/-/:}/$p" >/dev/null
            done <<<"$keep"
            ufw default deny incoming >/dev/null
            ufw default allow outgoing >/dev/null
            [[ $backend == ufw-off ]] && ufw --force enable >/dev/null
            ;;
        firewalld)
            local zone
            zone=$(firewall-cmd --get-default-zone)
            while read -r p port _; do
                firewall-cmd --permanent --zone="$zone" --add-port="$port/$p" >/dev/null
            done <<<"$keep"
            if [[ $(firewall-cmd --permanent --zone="$zone" --get-target) == ACCEPT ]]; then
                firewall-cmd --permanent --zone="$zone" --set-target=default >/dev/null
            fi
            firewall-cmd --reload >/dev/null
            ;;
        iptables)
            state_ok=0
            for cmd in iptables ip6tables; do
                has $cmd || continue
                # -I 插入到最前面，所以先插端口规则，再插回环和已建立连接
                while read -r p port _; do
                    ipt_add "$cmd" -p "$p" --dport "${port/-/:}" -j ACCEPT
                done <<<"$keep"
                if ! ipt_base "$cmd"; then
                    error "$cmd 不支持连接状态匹配，为避免断网，未修改默认策略"
                    continue
                fi
                $cmd -P INPUT DROP
                [[ $cmd == iptables ]] && state_ok=1
            done
            while read -r p port _; do state_add "$p" "$port"; done <<<"$keep"
            (( state_ok )) && state_policy DROP
            save_iptables
            ;;
    esac

    info "完成！除上面列出的端口外，其余入站端口已全部关闭"
    info "如需恢复，运行: portman unlock"
    warn "建议先新开一个 SSH 窗口测试能否正常登录，确认后再关闭当前窗口"
}

unlock() {
    need_root || return 1
    local fw ans cmd
    fw=$(detect_firewall)
    if [[ $fw == none ]]; then info "未检测到防火墙，所有端口本来就是放行的"; return 0; fi
    if [[ $fw == nftables ]]; then error "检测到原生 nftables 规则，暂不支持自动修改"; return 1; fi

    read -rp "将把 $(firewall_name "$fw") 改为「默认放行所有入站端口」，确认? [y/N]: " ans
    [[ $ans == [yY] ]] || { info "已取消"; return 0; }

    case $fw in
        ufw) ufw default allow incoming >/dev/null ;;
        firewalld)
            firewall-cmd --permanent --zone="$(firewall-cmd --get-default-zone)" --set-target=ACCEPT >/dev/null
            firewall-cmd --reload >/dev/null ;;
        iptables)
            for cmd in iptables ip6tables; do
                has $cmd && $cmd -P INPUT ACCEPT
            done
            state_policy ACCEPT
            save_iptables ;;
    esac
    info "已恢复：所有入站端口均已放行"
}

show_firewall() {
    need_root || return 1
    local fw rules icmp
    fw=$(detect_firewall)

    printf '%s防火墙类型:%s %s\n' "$BOLD" "$PLAIN" "$(firewall_name "$fw")"
    if [[ $fw == nftables ]]; then
        warn "原生 nftables 规则暂不支持解析，以下为原始规则"
        echo; nft list ruleset; return
    fi

    printf '%s入站策略:%s   ' "$BOLD" "$PLAIN"
    if [[ $fw == none ]]; then
        printf '%s没有防火墙，所有端口都能从外部访问%s\n' "$YELLOW" "$PLAIN"
    elif fw_default_open "$fw"; then
        printf '%s默认放行 —— 所有端口都能从外部访问%s\n' "$YELLOW" "$PLAIN"
    else
        printf '%s默认拒绝 —— 只有下方已放行的端口能访问%s\n' "$GREEN" "$PLAIN"
    fi

    icmp="允许 (系统默认)"
    if [[ $fw == iptables ]] && ! fw_default_open iptables; then
        if iptables -S INPUT 2>/dev/null | grep -qE -- "-p icmp .*-j ACCEPT|-p icmp -j ACCEPT"; then icmp="允许"
        else icmp="${RED}禁止${PLAIN}"; fi
    elif [[ $fw == none ]] || fw_default_open "$fw"; then
        icmp="允许"
    fi
    printf '%sICMP(ping):%s %s\n' "$BOLD" "$PLAIN" "$icmp"

    if [[ $fw == iptables ]]; then
        printf '%s重启后恢复:%s ' "$BOLD" "$PLAIN"
        if systemctl is-enabled "$SERVICE_NAME" >/dev/null 2>&1; then
            printf '%s已开启%s (规则记录在 %s)\n' "$GREEN" "$PLAIN" "$STATE_FILE"
        else
            printf '%s未开启%s (portman 添加规则后会自动开启)\n' "$YELLOW" "$PLAIN"
        fi
    fi

    [[ $fw == none ]] && return 0

    echo
    printf '%s已放行的端口规则:%s\n' "$BOLD" "$PLAIN"
    rules=$(fw_rule_list "$fw" | awk '!seen[$0]++')
    if [[ -z $rules ]]; then
        echo "  (没有单独的放行规则)"
    else
        echo "  协议     端口          当前使用情况"
        { collect_listen 2>/dev/null; echo "--"; echo "$rules"; } | LC_ALL=C awk -F'|' \
            -v G="$GREEN" -v C="$CYAN" -v P="$PLAIN" '
            $0 == "--" { phase = 1; next }
            phase == 0 { if (!(($1 "/" $3) in L)) L[$1 "/" $3] = $4; next }
            {
                split($0, a, ":"); proto = a[1]; r = a[2]
                if (r ~ /-/) { split(r, b, "-"); if (b[1] == b[2]) r = b[1] }
                if (r == "1-65535") use = "全部端口"
                else if (r ~ /-/) use = "端口范围"
                else {
                    use = ""
                    if (proto != "udp" && (("tcp/" r) in L)) use = "tcp: " L["tcp/" r]
                    if (proto != "tcp" && (("udp/" r) in L)) use = use (use == "" ? "" : "  ") "udp: " L["udp/" r]
                    use = (use == "") ? "无程序监听" : G use P
                }
                if (proto == "any") proto = "tcp/udp"
                printf "  %s%-8s%s %-13s %s\n", C, proto, P, r, use
            }'
    fi

    echo
    printf '%s原始规则:%s\n' "$BOLD" "$PLAIN"
    case $fw in
        ufw)       ufw status numbered ;;
        firewalld) firewall-cmd --list-all ;;
        iptables)
            echo "[IPv4]"; iptables -L INPUT -n --line-numbers
            if has ip6tables; then echo; echo "[IPv6]"; ip6tables -L INPUT -n --line-numbers; fi ;;
    esac
}

# ---------------------------------------------------------------------------
# IPv4 / IPv6 状态与 IPv6 开关
#   禁用写入 sysctl.d 配置文件，开机由 systemd-sysctl 自动加载。
#   文件名以 99-zz 开头，排在 99-sysctl.conf 之后，不会被系统默认配置覆盖。
# ---------------------------------------------------------------------------
SYSCTL_FILE="/etc/sysctl.d/99-zz-portman-ipv6.conf"

# 输出: kernel-off (内核参数禁用) | off (sysctl 禁用) | on
ipv6_state() {
    [[ -d /proc/sys/net/ipv6 ]] || { echo kernel-off; return; }
    local dev
    dev=$(ip -4 route show default 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')
    if [[ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null) == 1 ]] ||
        [[ -n $dev && $(cat "/proc/sys/net/ipv6/conf/$dev/disable_ipv6" 2>/dev/null) == 1 ]]; then
        echo off
    else
        echo on
    fi
}

# 系统里其他会在开机时禁用 IPv6 的 sysctl 配置
ipv6_other_disablers() {
    grep -lsE '^[[:space:]]*net\.ipv6\.conf\.(all|default)\.disable_ipv6[[:space:]]*=[[:space:]]*1' \
        /etc/sysctl.conf /etc/sysctl.d/*.conf /run/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf 2>/dev/null |
        grep -vxF "$SYSCTL_FILE"
}

# 用外部服务检测出口 IP，$1 为 4 或 6
public_ip() {
    local url ip
    for url in https://api64.ipify.org https://icanhazip.com; do
        if has curl; then ip=$(curl -"$1" -fsS -m 5 "$url" 2>/dev/null)
        elif has wget; then ip=$(wget -"$1" -qO- -T 5 "$url" 2>/dev/null)
        else return 1; fi
        ip=$(tr -d '[:space:]' <<<"$ip")
        [[ -n $ip ]] && { echo "$ip"; return 0; }
    done
    return 1
}

print_ip_family() {
    local v=$1 addrs route pub label
    addrs=$(ip -o -"$v" addr show scope global 2>/dev/null | awk '{ printf "%s%s %s", (n++ ? "\n          " : ""), $2, $4 }')
    route=$(ip -"$v" route show default 2>/dev/null | head -1)
    printf '本机地址: %s\n' "${addrs:-${YELLOW}无公网地址${PLAIN}}"
    printf '默认路由: %s\n' "${route:-${YELLOW}无${PLAIN}}"
    if [[ -z $route ]]; then
        printf '外网连通: %s✘ 无法访问 (没有默认路由)%s\n' "$RED" "$PLAIN"
    elif pub=$(public_ip "$v"); then
        printf '外网连通: %s✔ 正常%s  出口 IP: %s\n' "$GREEN" "$PLAIN" "$pub"
    else
        printf '外网连通: %s✘ 无法访问外网%s\n' "$RED" "$PLAIN"
    fi
}

show_ip_status() {
    local state others
    if ! has ip; then error "未找到 ip 命令，请先安装 iproute2"; return 1; fi
    info "正在检测网络，最多需要十几秒..."
    echo

    printf '%s========== IPv4 ==========%s\n' "$BOLD" "$PLAIN"
    if [[ -n $(ip -o -4 addr show scope global 2>/dev/null) ]]; then
        printf '状态:     %s已启用%s\n' "$GREEN" "$PLAIN"
    else
        printf '状态:     %s没有 IPv4 地址%s (可能是纯 IPv6 机器)\n' "$YELLOW" "$PLAIN"
    fi
    print_ip_family 4
    echo

    printf '%s========== IPv6 ==========%s\n' "$BOLD" "$PLAIN"
    state=$(ipv6_state)
    case $state in
        on)  printf '状态:     %s已启用%s\n' "$GREEN" "$PLAIN" ;;
        off) printf '状态:     %s已禁用%s\n' "$RED" "$PLAIN" ;;
        kernel-off) printf '状态:     %s已禁用 (内核启动参数 ipv6.disable=1)%s\n' "$RED" "$PLAIN" ;;
    esac
    others=$(ipv6_other_disablers | tr '\n' ' ')
    if [[ -f $SYSCTL_FILE ]]; then
        printf '开机设置: 由 portman 禁用，重启后保持 (%s)\n' "$SYSCTL_FILE"
    elif [[ -n $others ]]; then
        printf '开机设置: 被 %s禁用\n' "$others"
    elif [[ $state != kernel-off ]]; then
        printf '开机设置: 系统默认 (启用)\n'
    fi
    [[ $state == on ]] && print_ip_family 6
}

ipv6_disable() {
    need_root || return 1
    local state server_ip ans
    state=$(ipv6_state)
    if [[ $state == kernel-off ]]; then info "IPv6 已被内核参数禁用，无需操作"; return 0; fi

    server_ip=$(awk '{ print $3 }' <<<"${SSH_CONNECTION:-}")
    if [[ $server_ip == *:* && $server_ip != ::ffff:* ]]; then
        error "你当前是通过 IPv6 连接的 SSH，禁用后会立即断开。请改用 IPv4 地址连接后再操作"
        return 1
    fi
    if [[ -z $(ip -4 route show default 2>/dev/null) ]]; then
        error "没有检测到 IPv4 默认路由，这台机器可能只有 IPv6，禁用后将无法联网"
        return 1
    fi

    warn "禁用后，服务器的 IPv6 地址会失效，IPv6 入站和出站都将不可用 (本机回环 ::1 保留)"
    read -rp "确认禁用 IPv6? [y/N]: " ans
    [[ $ans == [yY] ]] || { info "已取消"; return 0; }

    cat >"$SYSCTL_FILE" <<'EOF'
# 由 portman 生成: 禁用 IPv6，保留本机回环 ::1
# 删除本文件并重启即可恢复 IPv6，或运行: portman ipv6 on
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 0
EOF
    sysctl -p "$SYSCTL_FILE" >/dev/null
    info "IPv6 已禁用，重启后保持"
}

ipv6_enable() {
    need_root || return 1
    local state others
    state=$(ipv6_state)
    if [[ $state == kernel-off ]]; then
        error "IPv6 被内核启动参数 ipv6.disable=1 禁用，无法在线开启"
        echo "  请编辑 /etc/default/grub，删除 GRUB_CMDLINE_LINUX 里的 ipv6.disable=1，"
        echo "  然后执行 update-grub (CentOS: grub2-mkconfig -o /boot/grub2/grub.cfg) 并重启"
        return 1
    fi

    rm -f "$SYSCTL_FILE"
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0 \
        net.ipv6.conf.lo.disable_ipv6=0 >/dev/null
    info "IPv6 已启用"

    others=$(ipv6_other_disablers)
    if [[ -n $others ]]; then
        warn "以下配置文件会在开机时再次禁用 IPv6，请手动删除其中的 disable_ipv6 = 1:"
        printf '  %s\n' $others
    else
        info "重启后保持启用"
    fi

    sleep 3
    if [[ -z $(ip -o -6 addr show scope global 2>/dev/null) ]]; then
        warn "网卡暂时还没有拿到 IPv6 地址。如果服务商分配了 IPv6，重启服务器后即可恢复"
    fi
}

ipv6_menu() {
    local c state
    state=$(ipv6_state)
    case $state in
        on)  printf 'IPv6 当前状态: %s已启用%s\n\n' "$GREEN" "$PLAIN" ;;
        *)   printf 'IPv6 当前状态: %s已禁用%s\n\n' "$RED" "$PLAIN" ;;
    esac
    echo "  1. 禁用 IPv6 (重启后保持)"
    echo "  2. 启用 IPv6 (重启后保持)"
    echo "  0. 返回"
    echo
    read -rp "请选择 [0-2]: " c
    case $c in
        1) ipv6_disable ;;
        2) ipv6_enable ;;
        *) return 0 ;;
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

# 快捷命令 s / S 是指向 portman 的软链接
is_our_shortcut() {
    [[ -L $1 && $(readlink -f "$1") == "$(readlink -f "$INSTALL_PATH")" ]]
}

setup_shortcuts() {
    need_root || return 1
    local k path existing
    for k in $SHORTCUTS; do
        path="$BIN_DIR/$k"
        existing=$(command -v "$k" 2>/dev/null)
        if is_our_shortcut "$path"; then
            continue
        elif [[ -n $existing && $existing != "$path" ]] || [[ -e $path ]]; then
            warn "系统中已存在命令 $k ($existing)，跳过绑定"
            continue
        fi
        ln -s "$INSTALL_PATH" "$path"
    done
    for k in $SHORTCUTS; do
        if is_our_shortcut "$BIN_DIR/$k"; then
            info "快捷键已绑定: 输入 ${BOLD}$k${PLAIN} 回车即可打开菜单"
            return 0
        fi
    done
}

# 从旧版本更新上来时自动补上快捷命令，不输出任何提示
ensure_shortcuts() {
    is_root && [[ -x $INSTALL_PATH ]] || return 0
    local k
    for k in $SHORTCUTS; do
        [[ -e $BIN_DIR/$k ]] || command -v "$k" >/dev/null 2>&1 || ln -s "$INSTALL_PATH" "$BIN_DIR/$k" 2>/dev/null
    done
}

remove_shortcuts() {
    local k
    for k in $SHORTCUTS; do
        is_our_shortcut "$BIN_DIR/$k" && rm -f "$BIN_DIR/$k"
    done
}

update_self() {
    need_root || return 1
    local tmp
    tmp=$(mktemp)
    info "正在下载最新版本..."
    if download "$RAW_URL/portman.sh" "$tmp" && bash -n "$tmp"; then
        install -m 755 "$tmp" "$INSTALL_PATH"
        rm -f "$tmp"
        "$INSTALL_PATH" shortcut >/dev/null
        info "已更新到 $("$INSTALL_PATH" version)"
    else
        rm -f "$tmp"
        error "下载失败，请检查网络"
        return 1
    fi
}

uninstall_self() {
    need_root || return 1
    remove_shortcuts
    remove_restore_service
    rm -rf "$INSTALL_PATH" "${STATE_FILE%/*}"
    info "portman 已卸载 (当前防火墙规则保持不变，但重启后不再自动恢复 iptables 规则)"
    if [[ -f $SYSCTL_FILE ]]; then
        warn "IPv6 仍保持禁用。如需恢复，删除 $SYSCTL_FILE 后重启"
    fi
}

# ---------------------------------------------------------------------------
# 菜单与命令行
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
portman v${VERSION} - VPS 端口查看与管理工具

快捷键: 输入 s (或 S) 回车，等同于 portman，直接打开菜单

命令列表:
   1. portman                        打开交互菜单，输入数字选择功能
   2. portman list                   查看所有监听端口（协议、进程、防火墙是否放行）
   3. portman public                 只看对公网开放的端口
   4. portman check <端口>           查询某个端口被哪个程序占用
   5. portman open  <端口> [协议]    放行(开启)端口，协议: tcp(默认) / udp / both
   6. portman close <端口> [协议]    关闭端口（删除防火墙放行规则）
   7. portman lockdown               一键关闭其他端口，只保留正在使用的端口和 SSH
   8. portman unlock                 恢复放行全部端口（撤销第 7 项）
   9. portman fw                     查看防火墙状态和规则
  10. portman ip                     查看 IPv4 / IPv6 状态（地址、路由、能否上网）
  11. portman ipv6 off               禁用 IPv6，重启后保持
  12. portman ipv6 on                启用 IPv6，重启后保持
  13. portman update                 更新到最新版本
  14. portman uninstall              卸载 portman（不影响已有防火墙规则）
  15. portman version                查看当前版本

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
        printf '%s===== portman v%s · 端口查看与管理 =====%s\n' "$BOLD" "$VERSION" "$PLAIN"
        if is_our_shortcut "$BIN_DIR/s"; then
            printf '      快捷键: 任意位置输入 %ss%s 回车即可打开本菜单\n' "$CYAN" "$PLAIN"
        fi
        echo
        echo "  1. 查看所有监听端口"
        echo "  2. 只看对公网开放的端口"
        echo "  3. 查询指定端口"
        echo "  4. 放行(开启)端口"
        echo "  5. 关闭端口"
        echo "  6. 一键关闭其他端口 (只保留正在使用的端口)"
        echo "  7. 恢复放行全部端口"
        echo "  8. 查看防火墙状态"
        echo "  9. 查看 IPv4 / IPv6 状态"
        echo " 10. 开启 / 关闭 IPv6"
        echo " 11. 更新 portman"
        echo " 12. 卸载 portman"
        echo "  0. 退出"
        echo
        read -rp "请选择 [0-12]: " c
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
            6) lockdown ;;
            7) unlock ;;
            8) show_firewall ;;
            9) show_ip_status ;;
            10) ipv6_menu ;;
            11) update_self ;;
            12) uninstall_self && exit 0 ;;
            0|q) exit 0 ;;
            *) error "无效选择" ;;
        esac
        echo
        pause
    done
}

main() {
    [[ ${1:-} == uninstall || ${1:-} == restore ]] || ensure_shortcuts
    case ${1:-} in
        restore)         restore_rules ;;
        "")              menu ;;
        list|ls|l)       show_ports all ;;
        public|pub)      show_ports public ;;
        check|c)
            [[ ${2:-} =~ ^[0-9]+$ ]] || { error "用法: portman check <端口>"; exit 1; }
            show_ports "$2" ;;
        open|allow)      [[ -n ${2:-} ]] || { usage; exit 1; }; open_port "$2" "${3:-tcp}" ;;
        close|deny)      [[ -n ${2:-} ]] || { usage; exit 1; }; close_port "$2" "${3:-tcp}" ;;
        lockdown|lock)   lockdown ;;
        unlock)          unlock ;;
        fw|firewall)     show_firewall ;;
        ip)              show_ip_status ;;
        ipv6)
            case ${2:-} in
                on)  ipv6_enable ;;
                off) ipv6_disable ;;
                *)   ipv6_menu ;;
            esac ;;
        update)          update_self ;;
        uninstall)       uninstall_self ;;
        shortcut)        setup_shortcuts ;;
        version|-v|--version) echo "portman v${VERSION}" ;;
        help|-h|--help)  usage ;;
        *)               error "未知命令: $1"; echo; usage; exit 1 ;;
    esac
}

# 被 source 时只加载函数(便于测试)
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
