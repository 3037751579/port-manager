#!/usr/bin/env bash
# 离线回归测试：所有 NextTrace 输出均为构造样本，并非真实网络实测。
set -euo pipefail
cd "$(dirname "$0")/.."
bash -n portman.sh
bash -n install.sh
bash -n route-report.sh

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/config"
export PATH="$work/bin:$PATH"
export PORTMAN_ROUTE_HOME="$work/config"
export PORTMAN_ROUTE_REPORTS="$work/reports"
export MOCK_TRACE_LOG="$work/nexttrace-args.log"

cat > "$work/bin/nexttrace" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_TRACE_LOG"
target=${!#}
case "$target" in
  202.96.209.133)
    cat <<'JSON'
{"schema_version":1,"version":"mock","resolved_ip":"202.96.209.133","end_reason":"completed","path_end":{"hop":3,"reason":"destination_reached"},"stats":[{"ttl":1,"ip":"218.30.48.97","geo":{"asnumber":"AS4134","country":"美国","city":"洛杉矶"},"avg_ms":1.2,"received":3,"loss_percent":0},{"ttl":2,"ip":"59.43.246.237","geo":{"country":"中国","city":"上海"},"avg_ms":125.5,"received":3,"loss_percent":0},{"ttl":3,"ip":"202.96.209.133","geo":{"asnumber":"AS4812","country":"中国","city":"上海"},"avg_ms":125.3,"received":3,"loss_percent":0,"stdev_ms":1.2}]}
JSON
    ;;
  210.22.97.1)
    cat <<'JSON'
{"schema_version":1,"version":"mock","resolved_ip":"210.22.97.1","end_reason":"completed","path_end":{"hop":4,"reason":"destination_reached"},"stats":[{"ttl":1,"ip":"162.219.85.161","geo":{"asnumber":"AS10099"},"avg_ms":0.4,"received":3},{"ttl":2,"ip":"218.105.2.93","geo":{"asnumber":"AS9929"},"avg_ms":138.2,"received":3},{"ttl":3,"ip":"219.158.120.17","geo":{"asnumber":"AS4837"},"avg_ms":139.2,"received":3},{"ttl":4,"ip":"210.22.97.1","geo":{"asnumber":"AS17621"},"avg_ms":140.1,"received":3,"loss_percent":0}]}
JSON
    ;;
  211.136.112.200)
    cat <<'JSON'
{"schema_version":1,"version":"mock","resolved_ip":"211.136.112.200","end_reason":"completed","path_end":{"hop":3,"reason":"destination_reached"},"stats":[{"ttl":1,"ip":"223.120.201.65","geo":{"asnumber":"AS58807"},"avg_ms":0.6,"received":3},{"ttl":2,"ip":"221.183.92.121","geo":{"asnumber":"AS9808"},"avg_ms":126.1,"received":3},{"ttl":3,"ip":"211.136.112.200","geo":{"asnumber":"AS24400"},"avg_ms":129.3,"received":3,"loss_percent":0}]}
JSON
    ;;
  *)
    cat <<JSON
{"schema_version":1,"version":"mock","resolved_ip":"$target","end_reason":"completed","path_end":{"hop":2,"reason":"max_hops"},"stats":[{"ttl":1,"ip":"203.0.113.1","geo":{"asnumber":"AS4134"},"avg_ms":17,"received":3},{"ttl":2,"ip":"198.51.100.1","geo":{"asnumber":"AS4134"},"avg_ms":19,"received":3}]}
JSON
    ;;
esac
MOCK
chmod +x "$work/bin/nexttrace"

fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
expect() { grep -Fq -- "$2" "$1" || fail "未匹配：$2"; }

bash portman.sh version > "$work/version"
expect "$work/version" 'portman v1.7.0'
bash route-report.sh shanghai > "$work/shanghai"
expect "$work/shanghai" '经过电信 CN2'
expect "$work/shanghai" '经过联通 9929，随后经过 4837'
expect "$work/shanghai" '经过移动 CMIN2'
expect "$work/shanghai" '3/3 个目标产生有效报告'
expect "$work/shanghai" '125.3ms'
expect "$work/shanghai" '140.1ms'

bash route-report.sh shanghai unicom --detail > "$work/detail"
expect "$work/detail" '联通 9929 精品骨干'
expect "$work/detail" '219.158.120.17'
bash route-report.sh shanghai mobile --mtr --save > "$work/mtr"
expect "$work/mtr" '终点丢包: 0.0%'
expect "$MOCK_TRACE_LOG" '-q 20'
test -f "$(find "$work/reports" -name 'shanghai-mobile.json' -print -quit)" || fail '原始 JSON 未保存'
test -f "$(find "$work/reports" -name 'summary.txt' -print -quit)" || fail 'TXT 未保存'

if bash route-report.sh suzhou telecom > "$work/suzhou" 2>&1; then fail '苏州没有配置时应该失败'; fi
expect "$work/suzhou" '缺少已核实目标'
bash route-report.sh set suzhou telecom 8.8.8.8 > "$work/set"
bash route-report.sh suzhou telecom > "$work/suzhou2"
expect "$work/suzhou2" '8.8.8.8'
bash route-report.sh custom 1.1.1.1 --detail > "$work/custom"
expect "$work/custom" '203.0.113.1'
expect "$work/custom" '未确认到达'
expect "$work/custom" '终点: —'
if bash route-report.sh custom ';rm -rf /' > "$work/invalid" 2>&1; then fail '危险地址应被拒绝'; fi

# 模拟无元数据的 JSON，脚本应保留占位字段，不能误判公网运营商。
cat > "$work/bin/nexttrace" <<'MOCK2'
#!/usr/bin/env bash
cat <<'JSON'
{"schema_version":1,"resolved_ip":"192.0.2.1","end_reason":"completed","path_end":{"hop":1,"reason":"destination_reached"},"stats":[{"ttl":1,"ip":"192.0.2.1","avg_ms":0,"received":1}]}
JSON
MOCK2
chmod +x "$work/bin/nexttrace"
bash route-report.sh custom 192.0.2.1 --detail > "$work/emptygeo"
expect "$work/emptygeo" '0.0ms'
expect "$work/emptygeo" '未识别'

printf '[PASS] bash 语法、三网识别、混合路径、中文逐跳、MTR、报告、苏州配置、自定义目标、异常处理\n'
