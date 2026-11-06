#!/usr/bin/env bash
# portman 路由检测模块，依赖 nexttrace 的 MTR JSON v1。
# 仅做出站探测；不更改防火墙、路由、代理或 SSH 设置。

ROUTE_HOME="${PORTMAN_ROUTE_HOME:-${HOME:-/root}/.config/portman}"
ROUTE_TARGETS="${ROUTE_HOME}/route-targets.tsv"
ROUTE_REPORTS="${PORTMAN_ROUTE_REPORTS:-${HOME:-/root}/portman-reports}"

route_err() { printf '[路由] 错误：%s\n' "$*" >&2; }
route_note() { printf '[路由] %s\n' "$*"; }

route_valid_target() {
    local t=${1:-}
    [[ -n $t && ${#t} -le 253 && $t =~ ^[[:alnum:]][[:alnum:].:_-]*$ ]]
}

route_city() {
    case ${1:-} in
        shanghai|sh|上海|'') echo shanghai ;;
        beijing|bj|北京) echo beijing ;;
        guangzhou|gz|广州) echo guangzhou ;;
        suzhou|sz|苏州) echo suzhou ;;
        *) return 1 ;;
    esac
}
route_city_cn() {
    case $1 in shanghai) echo 上海;; beijing) echo 北京;; guangzhou) echo 广州;; suzhou) echo 苏州;; custom) echo 自定义;; esac
}
route_isp() {
    case ${1:-} in
        telecom|ct|电信) echo telecom;;
        unicom|cu|联通) echo unicom;;
        mobile|cm|移动) echo mobile;;
        all|三网|'') echo all;;
        *) return 1;;
    esac
}
route_isp_cn() {
    case $1 in telecom) echo 电信;; unicom) echo 联通;; mobile) echo 移动;; custom) echo 自定义;; esac
}

# 目标仅供路由定位，不保证所有节点永久响应 ICMP。
# 苏州不存在已经核实的可长期使用的三网测试地址，用户首次选用时配置。
route_builtin_target() {
    case "$1:$2" in
        shanghai:telecom) echo 202.96.209.133;;
        shanghai:unicom) echo 210.22.97.1;;
        shanghai:mobile) echo 211.136.112.200;;
        beijing:telecom) echo 219.141.140.10;;
        beijing:unicom) echo 202.106.195.68;;
        beijing:mobile) echo 221.179.155.161;;
        guangzhou:telecom) echo 58.60.188.222;;
        guangzhou:unicom) echo 210.21.196.6;;
        guangzhou:mobile) echo 120.196.165.24;;
        *) return 1;;
    esac
}
route_target() {
    local saved=""
    if [[ -f $ROUTE_TARGETS ]]; then
        saved=$(awk -F '\t' -v c="$1" -v i="$2" '$1 == c && $2 == i {t=$3} END {print t}' "$ROUTE_TARGETS")
        if route_valid_target "$saved"; then printf '%s\n' "$saved"; return 0; fi
    fi
    route_builtin_target "$1" "$2"
}
route_set_target() {
    local city isp target tmp
    city=$(route_city "${1:-}") || { route_err '地区必须是上海、北京、广州或苏州'; return 2; }
    isp=$(route_isp "${2:-}") || { route_err '运营商必须是电信、联通或移动'; return 2; }
    [[ $isp != all ]] || { route_err '设置目标时必须指定一个运营商'; return 2; }
    target=${3:-}
    route_valid_target "$target" || { route_err '目标地址格式不合法'; return 2; }
    mkdir -p -m 700 "$ROUTE_HOME" || return 1
    tmp=$(mktemp "${ROUTE_HOME}/.targets.XXXXXX") || return 1
    if [[ -f $ROUTE_TARGETS ]]; then
        awk -F '\t' -v c="$city" -v i="$isp" '($1 != c || $2 != i) && NF == 3' "$ROUTE_TARGETS" > "$tmp"
    fi
    printf '%s\t%s\t%s\n' "$city" "$isp" "$target" >> "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$ROUTE_TARGETS" || return 1
    route_note "已保存：$(route_city_cn "$city")$(route_isp_cn "$isp") → $target"
}

route_require() {
    local missing=0
    if ! command -v nexttrace >/dev/null 2>&1; then
        route_err '未安装 NextTrace，进入菜单选择「安装检测依赖」，或运行 curl -fsSL https://nxtrace.org/nt | bash'
        missing=1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        route_err '未安装 jq，Debian/Ubuntu 可执行 apt-get update && apt-get install -y jq'
        missing=1
    fi
    return "$missing"
}
route_install_deps() {
    local a
    route_note '将检查 jq 和 NextTrace。第三方安装脚本需要从网络下载并执行。'
    read -rp '确定安装缺失依赖？[y/N] ' a
    [[ $a == y || $a == Y ]] || return 0
    if ! command -v jq >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update && apt-get install -y jq || return 1
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y jq || return 1
        elif command -v apk >/dev/null 2>&1; then
            apk add jq || return 1
        else
            route_err '无法自动安装 jq，请通过系统包管理器手动安装'; return 1
        fi
    fi
    if ! command -v nexttrace >/dev/null 2>&1; then
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL https://nxtrace.org/nt | bash || return 1
        elif command -v wget >/dev/null 2>&1; then
            wget -qO- https://nxtrace.org/nt | bash || return 1
        else
            route_err '需要 curl 或 wget 安装 NextTrace'; return 1
        fi
    fi
    route_require && route_note '依赖已就绪'
}

# 仅根据实际可见的 ASN/IP 判断，不把经过某条优质骨干等同于全程优质，
# 也绝不将 CN2 简单标成 CN2 GIA。
route_label() {
    local asn=${1#AS} ip=${2:-} owner=${3:-}
    [[ $asn == '-' ]] && asn=''
    [[ $owner == '-' ]] && owner=''
    if [[ $ip == 59.43.* ]]; then echo '电信 CN2 骨干'; return; fi
    case $asn in
        4809) echo '电信 CN2 骨干';;
        4134) echo '电信 163 骨干';;
        4812|134774|140293) echo '电信国内接入';;
        10099) echo '联通国际 CUG';;
        9929) echo '联通 9929 精品骨干';;
        4837) echo '联通 169 普通骨干';;
        17621|140717) echo '联通国内接入';;
        58807) echo '移动 CMIN2 国际精品网';;
        58453) echo '移动 CMI 国际网';;
        9808) echo '移动国内骨干';;
        24400|56040|56041) echo '移动国内接入/骨干';;
        1054) echo '上游网络（AS1054）';;
        '') echo "${owner:-未识别}";;
        *) echo "${owner:-其他网络}";;
    esac
}

route_json_valid() {
    jq -e '(.schema_version == 1) and (.stats | type == "array") and (.path_end == null or (.path_end | type == "object"))' "$1" >/dev/null 2>&1
}

# 打印中文逐跳，汇总仅使用实际可见的路径信号；不将中间跳 ICMP 丢包视为业务丢包。
route_render() {
    local file=$1 city=$2 isp=$3 ip=$4 detail=$5 mtr=$6 summary_file=${7:--}
    local c cn reached reason endhop resolved rows first_hop=0
    local ttl hopip asn avg received loss stdev country prov loc owner label sig
    local last_sig="" path="" seen_cn2=0 seen_9929=0 seen_4837=0 seen_4837_after_9929=0 seen_cmin2=0 seen_cmi=0 seen_163=0
    local endavg='—' endloss='—' endjitter='—' endrecv=0 summary='未识别'
    cn=$(route_isp_cn "$isp")
    reason=$(jq -r '.path_end.reason // "unknown"' "$file")
    endhop=$(jq -r '.path_end.hop // 0' "$file")
    resolved=$(jq -r '.resolved_ip // ""' "$file")
    [[ $reason == destination_reached ]] && reached='已到达' || reached='未确认到达'
    [[ $reason == unreachable ]] && reached='目标不可达'
    [[ $reason == max_hops ]] && reached='达到最大跳数'
    [[ $(jq -r '.end_reason // "completed"' "$file") == completed ]] || reached='检测异常/中断'

    rows=$(jq -r '.stats[] | [.ttl // 0, .ip // "*", .geo.asnumber // "-", .avg_ms // 0, .received // 0, .loss_percent // 0, .stdev_ms // 0, .geo.country // "-", .geo.prov // "-", .geo.city // "-", (.geo.owner // .geo.isp // "-")] | map(tostring) | @tsv' "$file")
    if [[ $detail == 1 ]]; then
        printf '\n  ── %s%s · %s ──\n' "$(route_city_cn "$city")" "$cn" "$ip"
        printf '  跳点  IP / ASN / 中文线路                       平均延迟\n'
    fi
    while IFS=$'\t' read -r ttl hopip asn avg received loss stdev country prov loc owner; do
        [[ -n $ttl ]] || continue
        [[ $hopip == '*' || $hopip == "" ]] && { [[ $detail == 1 ]] && printf '  %02d    *  (该跳未回应探测)\n' "$ttl"; continue; }
        label=$(route_label "$asn" "$hopip" "$owner")
        [[ $hopip == 59.43.* || ${asn#AS} == 4809 ]] && seen_cn2=1
        [[ ${asn#AS} == 9929 ]] && seen_9929=1
        if [[ ${asn#AS} == 4837 ]]; then
            seen_4837=1
            ((seen_9929)) && seen_4837_after_9929=1
        fi
        [[ ${asn#AS} == 58807 ]] && seen_cmin2=1
        [[ ${asn#AS} == 58453 ]] && seen_cmi=1
        [[ ${asn#AS} == 4134 ]] && seen_163=1
        sig=$label
        if [[ $sig != "$last_sig" ]]; then
            path+="$([[ -n $path ]] && printf ' → ')$label"
            last_sig=$sig
        fi
        if [[ $detail == 1 ]]; then
            printf '  %02d    %-16s %-10s %s\n' "$ttl" "$hopip" "${asn:--}" "$label"
            printf '        地点: %s %s %s · 平均: %.1fms' "${country:--}" "$prov" "$loc" "$avg"
            [[ $mtr == 1 ]] && printf ' · 丢包: %.1f%% · 样本: %s' "$loss" "$received"
            printf '\n'
        fi
        if [[ $reached == '已到达' ]] && { [[ $hopip == "$resolved" || $hopip == "$ip" ]]; }; then
            endavg=$(printf '%.1fms' "$avg")
            endloss=$(printf '%.1f%%' "$loss")
            endjitter=$(printf '%.1fms' "$stdev")
            endrecv=$received
        fi
    done <<< "$rows"

    case $isp in
        telecom)
            if ((seen_cn2)); then summary='经过电信 CN2'
            elif ((seen_163)); then summary='看到电信 163，未见 CN2'
            else summary='证据不足，未识别电信骨干'; fi ;;
        unicom)
            if ((seen_9929)); then
                summary='经过联通 9929'
                if ((seen_4837_after_9929)); then summary+='，随后经过 4837'
                elif ((seen_4837)); then summary+='，同时出现 4837（顺序不确定）'; fi
            elif ((seen_4837)); then summary='经过联通 4837，未见 9929'
            else summary='证据不足，未识别联通骨干'; fi ;;
        mobile)
            if ((seen_cmin2)); then summary='经过移动 CMIN2'
            elif ((seen_cmi)); then summary='经过移动 CMI，未见 CMIN2'
            else summary='证据不足，未识别移动国际骨干'; fi ;;
        custom) summary='自定义目标：仅展示可见路径' ;;
    esac

    printf '\n  %-6s  目标: %-15s  %s\n' "$cn" "$ip" "$reached"
    printf '  线路: %s\n' "$summary"
    printf '  终点: %s  ·  抵达跳数: %s' "$endavg" "${endhop:-0}"
    [[ $mtr == 1 ]] && printf '  ·  终点丢包: %s  ·  延迟标准差: %s' "$endloss" "$endjitter"
    printf '\n'
    if [[ $summary_file != '-' ]]; then
        printf '%s%s | %s | %s | %s\n' "$(route_city_cn "$city")" "$cn" "$reached" "$endavg" "$summary" >> "$summary_file"
    fi
    printf '  路径: %s\n' "${path:-无可识别跳点}"
    if [[ $mtr == 1 ]]; then
        printf '  注: 中间跳丢包可能是 ICMP 限速；重点看最终目标丢包。\n'
    fi
    if [[ $reached != '已到达' ]]; then
        printf '  注意: 未确认到达，不根据最后一个中间跳填充终点延迟。\n'
    fi
}

route_probe_one() {
    local city=$1 isp=$2 ip=$3 detail=$4 mtr=$5 outputdir=$6 summary_file=${7:--}
    local raw err count=3 code=0
    [[ $mtr == 1 ]] && count=20
    raw=$(mktemp) || return 1
    err=$(mktemp) || { rm -f "$raw"; return 1; }
    printf '\n[测试] %s%s → %s (每跳 %s 次)\n' "$(route_city_cn "$city")" "$(route_isp_cn "$isp")" "$ip" "$count"
    if command -v timeout >/dev/null 2>&1; then
        timeout 180 nexttrace -r --json --language cn --no-rdns -q "$count" "$ip" > "$raw" 2>"$err" || code=$?
    else
        nexttrace -r --json --language cn --no-rdns -q "$count" "$ip" > "$raw" 2>"$err" || code=$?
    fi
    if ! route_json_valid "$raw"; then
        if [[ $summary_file != '-' ]]; then
            printf '%s%s | 失败 | — | NextTrace 未输出有效 JSON\n' "$(route_city_cn "$city")" "$(route_isp_cn "$isp")" >> "$summary_file"
        fi
        route_err "$(route_city_cn "$city")$(route_isp_cn "$isp") 检测失败 (退出码 $code)"
        [[ -s $err ]] && sed -n '1,5p' "$err" >&2
        [[ -s $raw ]] && sed -n '1,3p' "$raw" >&2
        rm -f "$raw" "$err"
        return 1
    fi
    if [[ $outputdir != '-' ]]; then
        cp "$raw" "$outputdir/${city}-${isp}.json"
    fi
    route_render "$raw" "$city" "$isp" "$ip" "$detail" "$mtr" "$summary_file"
    rm -f "$raw" "$err"
    [[ $code == 0 ]]
}

route_run_inner() {
    local city=$1 isp=$2 detail=$3 mtr=$4 outputdir=$5
    local carriers=() current ip failures=0 summary_file
    summary_file=$(mktemp) || return 1
    [[ $isp == all ]] && carriers=(telecom unicom mobile) || carriers=("$isp")
    printf '============================================\n'
    printf '   %s三网回程检测  |  NextTrace MTR JSON\n' "$(route_city_cn "$city")"
    printf '   模式：%s  ·  方向：VPS → 国内目标\n' "$([[ $mtr == 1 ]] && echo 'MTR 稳定性' || echo '快速路由')"
    printf '============================================\n'
    for current in "${carriers[@]}"; do
        ip=$(route_target "$city" "$current") || ip=""
        if [[ -z $ip ]]; then
            printf '%s%s | 未测试 | — | 未配置目标地址\n' "$(route_city_cn "$city")" "$(route_isp_cn "$current")" >> "$summary_file"
            route_err "$(route_city_cn "$city")$(route_isp_cn "$current") 缺少已核实目标。使用 portman route set $city $current <IP> 配置"
            failures=$((failures+1))
            continue
        fi
        route_probe_one "$city" "$current" "$ip" "$detail" "$mtr" "$outputdir" "$summary_file" || failures=$((failures+1))
    done
    echo
    printf '=============== 本次路由汇总 ===============\n'
    cat "$summary_file"
    printf '============================================\n'
    rm -f "$summary_file"
    route_note "本次测试结束：$((${#carriers[@]}-failures))/${#carriers[@]} 个目标产生有效报告。"
    route_note '线路标签代表经过该骨干，不代表全程专线；单次 ICMP 不等于晚高峰真实业务质量。'
    route_note 'VPS 上仅能直接测回程；去程必须由中国境内的测点发起。'
    (( failures == 0 ))
}
route_run() {
    local city=$1 isp=$2 detail=$3 mtr=$4 save=$5
    local dir="" rc=0
    route_require || return 1
    if [[ $save == 1 ]]; then
        dir="$ROUTE_REPORTS/$(date +%Y%m%d_%H%M%S)_${city}_$([[ $mtr == 1 ]] && echo mtr || echo route)"
        mkdir -p -m 700 "$dir" || { route_err "无法创建报告目录: $dir"; return 1; }
        route_run_inner "$city" "$isp" "$detail" "$mtr" "$dir" 2>&1 | tee "$dir/summary.txt"
        rc=${PIPESTATUS[0]}
        route_note "报告已保存在 $dir （TXT + 原始 JSON）"
        return "$rc"
    fi
    route_run_inner "$city" "$isp" "$detail" "$mtr" '-'
}
route_custom() {
    local addr=$1 detail=$2 mtr=$3 save=$4 dir='-'
    route_valid_target "$addr" || { route_err '自定义目标格式不合法'; return 2; }
    route_require || return 1
    if [[ $save == 1 ]]; then
        dir="$ROUTE_REPORTS/$(date +%Y%m%d_%H%M%S)_custom"
        mkdir -p -m 700 "$dir" || return 1
        route_probe_one custom custom "$addr" "$detail" "$mtr" "$dir" 2>&1 | tee "$dir/summary.txt"
        local rc=${PIPESTATUS[0]}
        route_note "报告：$dir"
        return "$rc"
    fi
    route_probe_one custom custom "$addr" "$detail" "$mtr" '-'
}
route_usage() {
    cat <<'HELP'
路由检测 · NextTrace 中文报告（VPS → 国内回程）
  portman route                         默认上海三网快速测试
  portman route shanghai [all|ct|cu|cm]  上海；也支持 beijing/guangzhou/suzhou
  portman route beijing --detail         显示每一跳 IP、ASN、中文名称
  portman route guangzhou --save         保存 TXT 汇总与逐运营商原始 JSON
  portman route mtr shanghai --save      每跳 20 次，统计终点丢包与延迟波动
  portman route custom 1.1.1.1 --detail  自定义目标
  portman route set suzhou ct 目标IP     设置苏州测试地址（cu=联通，cm=移动）
  portman route menu                    交互菜单
  portman route install                 确认后安装缺失依赖
参数: --detail 详细逐跳 | --save 保存报告 | --mtr 稳定性测试
提示: 苏州首次使用需指定三网测试 IP，防止误用外地节点。
HELP
}
route_menu() {
    local choice city isp ip
    while :; do
        printf '\n===== portman · 路由检测 =====\n'
        printf ' 1. 上海三网快速测试（默认）\n 2. 上海三网详细逐跳\n'
        printf ' 3. 北京三网测试\n 4. 广州三网测试\n 5. 苏州三网测试\n'
        printf ' 6. 上海三网 MTR 稳定性（20 次/跳）\n'
        printf ' 7. 自定义目标 IP / 域名\n 8. 配置苏州测试地址\n'
        printf ' 9. 上海三网测试并保存报告\n 10. 安装检测依赖\n 0. 返回上级\n'
        read -rp '请选择 [0-10]: ' choice || return 0
        case $choice in
            1) route_run shanghai all 0 0 0;;
            2) route_run shanghai all 1 0 0;;
            3) route_run beijing all 0 0 0;;
            4) route_run guangzhou all 0 0 0;;
            5) route_run suzhou all 0 0 0;;
            6) route_run shanghai all 0 1 0;;
            7) read -rp '目标 IP / 域名: ' ip; route_custom "$ip" 1 0 0;;
            8)
                read -rp '运营商 [ct 电信 / cu 联通 / cm 移动]: ' isp
                read -rp '已核实的苏州测试 IP: ' ip
                route_set_target suzhou "$isp" "$ip";;
            9) route_run shanghai all 0 0 1;;
            10) route_install_deps;;
            0|q) return 0;;
            *) route_err '无效选择';;
        esac
        printf '\n'
        read -rp '按回车键继续...' _ || return 0
    done
}
route_main() {
    local city=shanghai isp=all detail=0 mtr=0 save=0 args=()
    case ${1:-} in
        menu) shift; route_menu; return ;;
        help|-h|--help) route_usage; return ;;
        install) route_install_deps; return ;;
        set) shift; route_set_target "${1:-}" "${2:-}" "${3:-}"; return ;;
        mtr) mtr=1; shift ;;
    esac
    if [[ ${1:-} == custom ]]; then
        shift
        local target=${1:-}
        shift || true
        for a in "$@"; do case $a in --detail) detail=1;; --save) save=1;; --mtr) mtr=1;; *) route_err "未知参数：$a"; return 2;; esac; done
        route_custom "$target" "$detail" "$mtr" "$save"
        return
    fi
    local arg
    for arg in "$@"; do
        case $arg in
            --detail) detail=1;;
            --save) save=1;;
            --mtr) mtr=1;;
            *)
                if route_city "$arg" >/dev/null 2>&1; then
                    city=$(route_city "$arg")
                elif route_isp "$arg" >/dev/null 2>&1; then
                    isp=$(route_isp "$arg")
                else
                    route_err "未知参数：$arg"; route_usage; return 2
                fi ;;
        esac
    done
    route_run "$city" "$isp" "$detail" "$mtr" "$save"
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    route_main "$@"
fi
