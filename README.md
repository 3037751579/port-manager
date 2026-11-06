# portman

VPS 端口查看与管理工具：一条命令看清服务器开放了哪些端口、是什么协议、被哪个程序占用、防火墙有没有放行，并可以一键放行或关闭端口。

## 一键安装

以 root 登录 SSH 后执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Eggfin/port-manager/main/install.sh)
```

没有 curl 时用 wget：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/Eggfin/port-manager/main/install.sh)
```

非 root 用户：

```bash
curl -fsSL https://raw.githubusercontent.com/Eggfin/port-manager/main/install.sh | sudo bash
```

安装后命令为 `portman`，位于 `/usr/local/bin/portman`。

**快捷键**：安装时会同时绑定 `s` 和 `S`，在 SSH 里输入 `s` 回车即可直接打开菜单。如果系统里已有同名命令，会跳过绑定、不覆盖。

## 使用

直接运行 `portman` 进入交互菜单，或使用子命令：

| 命令 | 说明 |
| --- | --- |
| `portman list` | 查看所有端口：正在监听的，以及防火墙已放行但未使用的 |
| `portman public` | 只看对公网开放的端口（含已放行但未使用的） |
| `portman check 80` | 查询指定端口 |
| `portman open 8080` | 放行端口（默认 tcp） |
| `portman open 80,443 both` | 同时放行 tcp 和 udp |
| `portman open 10000-10100 udp` | 放行端口范围 |
| `portman close 8080` | 关闭端口（删除放行规则） |
| `portman lockdown` | 一键关闭其他端口，只保留正在使用的端口和 SSH |
| `portman unlock` | 恢复放行全部端口（撤销 lockdown） |
| `portman fw` | 查看防火墙状态和规则 |
| `portman ip` | 查看 IPv4 / IPv6 状态：是否启用、地址、默认路由、能否访问外网 |
| `portman route` | 默认测试上海电信、联通、移动的 VPS 回程线路 |
| `portman route menu` | 打开三网路由菜单，支持北上广苏及自定义目标 |
| `portman route beijing --detail` | 中文逐跳、IP、ASN、位置及延迟 |
| `portman route mtr shanghai --save` | 多次探测终点丢包/延迟波动，保存 TXT 和 JSON |
| `portman route set suzhou ct IP` | 保存苏州电信的测试目标（联通 cu、移动 cm） |
| `portman ipv6 off` | 禁用 IPv6，重启后保持 |
| `portman ipv6 on` | 启用 IPv6，重启后保持 |
| `portman ssh` | SSH 密钥登录管理菜单 |
| `portman ssh status` | 查看公钥是否写入、密码登录是否关闭、配置是否生效 |
| `portman ssh addkey <来源>` | 写入公钥：sshid.io 用户名、公钥链接或公钥本身 |
| `portman ssh keyonly [-y]` | 只允许密钥登录（`-y` 跳过确认） |
| `portman ssh password` | 恢复密码登录 |
| `portman ssh keys` | 管理公钥：显示最近使用时间和当前连接所用的密钥，可删除、修改备注 |
| `portman ssh label 指纹前缀=备注 ...` | 按指纹批量加备注，例如 `portman ssh label FkK2Q24cqy46=iPhone`。命令可在「管理公钥 → 生成批量备注命令」里自动生成，在多台服务器上执行即可统一备注 |
| `portman ssh harden [-y]` | 安全加固：把其他配置文件里残留的 `PasswordAuthentication yes` 等改为关闭 |
| `portman ssh log [小时]` | 登录记录：失败/探测次数、尝试最多的 IP 和用户名、最近成功登录（显示用的哪把密钥）、当前在线 |
| `portman update` | 更新到最新版本 |
| `portman uninstall` | 卸载 |

示例输出：

```
协议  端口    范围   防火墙   服务            监听地址                  进程(PID)
tcp   22      公网   已放行   ssh             0.0.0.0,[::]              sshd(812)
tcp   80      公网   已放行   http            0.0.0.0                   nginx(1203),nginx(1204)
tcp   3306    本机   -        mysql           127.0.0.1                 mysqld(990)
udp   51820   公网   未放行   -               0.0.0.0                   -

共 4 个监听项，其中 3 个对公网监听，1 个未被防火墙放行
防火墙: UFW
```

各列含义：

- **范围**：`公网` 表示监听在 0.0.0.0 / :: 等对外地址，`本机` 表示只监听 127.0.0.1，外部无法访问
- **防火墙**：本机防火墙是否放行该端口（仅对公网端口有意义）
- **进程(PID)**：占用该端口的程序和进程号

## 更新记录

完整版本变更历史见 [CHANGELOG.md](CHANGELOG.md)。

## NextTrace 中文三网回程测试

这是一个**独立于防火墙和 SSH 的只读网络诊断模块**。原有端口管理功能不受影响。全新安装会同时安装 `route-report.sh`；从 v1.6.x 升级时，由于旧更新器只下载主脚本，**第一次进入路由功能会自动从同一仓库补装模块**。之后 `portman update` 会同时更新两者。实际运行诊断需要 `nexttrace` 和 `jq`。

```bash
portman update                       # 从 main 拉取最新版主程序和路由模块
portman route                        # 默认上海三网快速测试
portman route shanghai --detail      # 显示中文逐跳明细
portman route beijing --save         # 北京三网 + 保存报告
portman route guangzhou cu           # 仅测试广州联通
portman route mtr shanghai --save    # MTR，每跳 20 次探测
portman route custom 1.1.1.1 --detail
portman route menu                   # 交互菜单
```

- **预置地区**：上海（默认）、北京、广州，均覆盖电信/联通/移动。
- **苏州**：考虑到公开目标地址不一定属于苏州或长期可达，暂不预置未经核实的三网 IP。首次使用前分别运行 `portman route set suzhou ct 目标IP`、`cu`、`cm` 保存地址；之后可直接 `portman route suzhou`。同样支持覆盖其他地区预置目标。
- **中文路径**：直接按照实际跳点显示所经过的网络（如 IIJ → 电信 163、NTT → 联通 169、Lumen → 移动 CMI）。已知 ASN 自动转为中文名称，陌生 ASN 保留编号和运营商原始名称；连续相同网段合并，`--detail` 仍可看每一跳。
- **显示原则**：每家运营商的结果只展示状态、终点延迟、跳数和实际经过的网络名称，不再逐条评价「未见 CN2 / 9929 / CMIN2」。三网汇总最后统一展示观测到的骨干特征；不凭单次 traceroute 宣称全程专线或 CN2 GIA；最终目标未确认到达时不虚报终点延迟。
- **稳定性**：`--mtr` 使用 NextTrace 的 `-r --json -q 20`，输出终点丢包及延迟标准差。中间跳不回应/丢包可能是 ICMP 限速，不能直接推断真实业务丢包。
- **报告**：`--save` 将 `summary.txt` 及每条线路的原始 JSON 保存到 `~/portman-reports/`（可通过 `PORTMAN_ROUTE_REPORTS` 自定义目录）。配套命令可验证原始结果。
- **依赖**：进入子菜单第 10 项「安装/修复检测依赖」，输入 `y` 确认后依次安装 `jq` 和官方 `nexttrace`（系统模式）。安装结束会重新检测程序路径及版本，并明确提示成功或失败；可用 `portman route doctor` 或子菜单第 11 项查看诊断。下载失败不会误报成功。模块不会静默执行安装或修改系统防火墙。
- **方向限制**：在 VPS 上运行只能测试 VPS → 国内目标的**回程**；国内 → VPS 的去程需要在国内网络测试，不能通过此模块冒充去程结果。

GitHub Actions 的 `tests/test-route.sh` 使用**模拟 NextTrace JSON** 验证脚本逻辑。真实路由、接口路由策略、丢包和晚高峰数据必须在实际 VPS 上复测。

## 支持的防火墙

自动识别并按以下顺序使用：

1. **UFW**（Ubuntu/Debian 常见）
2. **firewalld**（CentOS/RHEL/Rocky/Alma 常见）
3. **iptables**：portman 添加的规则记录在 `/etc/portman/iptables.conf`，并注册 systemd 服务 `portman-restore`，开机时自动恢复。只恢复 portman 自己的规则，不影响 docker、fail2ban 等程序的规则

未检测到防火墙时，所有端口默认可访问，无需放行。

## 一键关闭其他端口

`portman lockdown`（菜单第 6 项）会把防火墙设为「默认拒绝入站」，只放行：

- 当前正在对公网监听的所有端口（例如 SSH、nginx、代理程序的端口）
- 当前 SSH 端口（一定会保留，防止断连）
- 执行时手动输入的额外端口

执行前会列出要保留的端口，需要输入 `yes` 确认。已有的放行规则不会被删除。没有防火墙时，Debian/Ubuntu 上会询问是否安装 ufw。之后新装的程序需要用 `portman open` 放行端口；想撤销就运行 `portman unlock`。

## 开关 IPv6

`portman ipv6 off`（菜单第 10 项）把设置写入 `/etc/sysctl.d/99-zz-portman-ipv6.conf`，立即生效，开机时由系统自动加载。本机回环 `::1` 会保留，避免依赖它的程序出错。

- 当前通过 IPv6 连接 SSH，或机器没有 IPv4 时，会拒绝禁用，防止断连
- `portman ipv6 on` 会删除该文件并立即启用；如果其他配置文件也在禁用 IPv6，会列出来提示
- 若 IPv6 是被内核启动参数 `ipv6.disable=1` 禁用的，需要修改 GRUB，脚本会给出步骤

## SSH 密钥登录

菜单第 11 项，或 `portman ssh`：

1. **写入公钥**：输入 Termius 的 sshid.io 用户名（如 `abc123`，即 `https://sshid.io/abc123`）、任意公钥链接（如 `https://github.com/用户名.keys`），或直接粘贴公钥。会校验格式、跳过已存在的公钥，并修正 `~/.ssh` 权限；上次的来源会被记住，下次直接回车即可。
2. **只允许密钥登录**：没有公钥时会拒绝执行。写入 `/etc/ssh/sshd_config.d/00-key-only.conf`（不支持 `sshd_config.d` 的系统则写到 `sshd_config` 顶部），用 `sshd -t` 检查，失败自动回滚，通过后重载 sshd 并确认已生效。当前连接不会断开。
3. **查看状态**：公钥数量和指纹、文件权限、当前生效的登录方式（读取 `sshd -T`）、哪些配置文件设置了密码登录、配置检查和服务状态，最后给出结论。
4. **恢复密码登录**：删除上述配置；如果系统其他配置仍禁止密码登录，会写入一条明确开启的配置。
5. **管理公钥**：列出每个公钥的指纹、备注、最近使用时间，并标出当前连接正在用的那个。删除前会备份；密码登录已关闭时禁止删光全部公钥，删除当前正在用的公钥需要输入 `yes`。
6. **安全加固**：云厂商常在 `sshd_config.d/50-cloud-init.conf` 等文件里写 `PasswordAuthentication yes`。只允许密钥登录时它们被 `00-key-only.conf` 覆盖，但一旦该文件被删，密码登录就会悄悄恢复。状态页会标出这些隐患并询问是否加固；开启只允许密钥登录时也会自动检查。加固前备份为 `*.bak-portman`，`sshd -t` 失败自动回滚。

新服务器一条命令完成（把 `abc123` 换成你的 sshid.io 用户名）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Eggfin/port-manager/main/install.sh) && portman ssh addkey abc123 && portman ssh keyonly -y
```

## 注意

- 阿里云、腾讯云、AWS、GCP 等云服务器还有一层 **安全组**，需要在云控制台放行，本脚本无法修改。
- 关闭端口前，如果该端口是当前 SSH 端口，脚本会要求二次确认，防止把自己锁在外面。
- 查看进程和防火墙状态需要 root 权限。
- 依赖：bash、ss（iproute2）或 netstat，安装脚本会在缺失时尝试自动安装 iproute2。
