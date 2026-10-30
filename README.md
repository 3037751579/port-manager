# portman

VPS 端口查看与管理工具：一条命令看清服务器开放了哪些端口、是什么协议、被哪个程序占用、防火墙有没有放行，并可以一键放行或关闭端口。

## 一键安装

以 root 登录 SSH 后执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/3037751579/port-manager/main/install.sh)
```

没有 curl 时用 wget：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/3037751579/port-manager/main/install.sh)
```

非 root 用户：

```bash
curl -fsSL https://raw.githubusercontent.com/3037751579/port-manager/main/install.sh | sudo bash
```

安装后命令为 `portman`，位于 `/usr/local/bin/portman`。

**快捷键**：安装时会同时绑定 `s` 和 `S`，在 SSH 里输入 `s` 回车即可直接打开菜单。如果系统里已有同名命令，会跳过绑定、不覆盖。

## 使用

直接运行 `portman` 进入交互菜单，或使用子命令：

| 命令 | 说明 |
| --- | --- |
| `portman list` | 查看所有监听端口 |
| `portman public` | 只看对公网监听的端口 |
| `portman check 80` | 查询指定端口 |
| `portman open 8080` | 放行端口（默认 tcp） |
| `portman open 80,443 both` | 同时放行 tcp 和 udp |
| `portman open 10000-10100 udp` | 放行端口范围 |
| `portman close 8080` | 关闭端口（删除放行规则） |
| `portman lockdown` | 一键关闭其他端口，只保留正在使用的端口和 SSH |
| `portman unlock` | 恢复放行全部端口（撤销 lockdown） |
| `portman fw` | 查看防火墙状态和规则 |
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

## 注意

- 阿里云、腾讯云、AWS、GCP 等云服务器还有一层 **安全组**，需要在云控制台放行，本脚本无法修改。
- 关闭端口前，如果该端口是当前 SSH 端口，脚本会要求二次确认，防止把自己锁在外面。
- 查看进程和防火墙状态需要 root 权限。
- 依赖：bash、ss（iproute2）或 netstat，安装脚本会在缺失时尝试自动安装 iproute2。
