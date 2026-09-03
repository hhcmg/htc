# htc

`htc` 是一个面向 Linux VPS 的双向聚合限速脚本。出站方向使用 HTB 控制物理网卡的总发送速率；入站方向通过 IFB 重定向后使用 HTB 整形。两个方向均以 `fq` 作为叶子队列，适合与 BBR pacing 配合使用。

> 脚本不会开启或修改 BBR，也不会修改其他 TCP 拥塞控制算法。

## 如何理解入站和出站

方向始终以服务器为参照：

| 场景 | 服务器方向 | 对远端用户而言 |
| --- | --- | --- |
| 用户从服务器下载文件、观看服务器视频 | 出站（egress） | 用户下载 |
| 用户向服务器上传文件 | 入站（ingress） | 用户上传 |
| 服务器运行 `apt`、`curl` 下载数据 | 入站（ingress） | 服务器下载 |
| 服务器向另一台机器备份数据 | 出站（egress） | 服务器上传 |

因此，如果主要用途是让其他用户从这台服务器下载内容，限制服务器出站速率，就是限制这些用户合计的下载速率。

## 限速值与最大带宽

“限速 300 Mbps”和“线路最大带宽 300 Mbps”不是完全相同的概念：

- 最大带宽通常是运营商、VPS 服务商或网卡能够提供的理论上限。
- 脚本中的 300 Mbps 是 Linux 队列规则设置的发送上限。
- 实际应用吞吐量还会受到协议开销、网络拥塞、对端能力、CPU、虚拟化和测速方法影响，通常不会始终精确等于 300 Mbps。
- 如果服务商严格按线路流量判断是否超过 300 Mbps，建议从略低的值开始，例如 285–295 Mbps，再根据实测调整。

## 功能

- 分别开启或关闭出站、入站聚合限速
- 支持“出站限速、入站不限”“入站限速、出站不限”或双向不同速率
- 自动识别默认公网出口网卡，也支持显式指定网卡
- 查看 TCP 拥塞控制、物理网卡 qdisc、入站过滤器、IFB 和 systemd 服务状态
- 安装为 systemd 服务并在开机时自动应用
- 修改永久速率、暂停、恢复或彻底卸载服务
- 兼容旧版只限制出站的命令和配置文件

队列结构：

```text
服务器出站：
物理网卡 → HTB → fq → 网络

服务器入站：
网络 → 物理网卡 ingress → IFB → HTB → fq → 网络协议栈
```

## 环境要求

- 使用 Bash 的 Linux 系统
- root 权限
- `iproute2`（提供 `ip` 和 `tc`）
- 永久安装功能需要 systemd
- 内核需要支持以下模块或将其内建：
  - `sch_htb`
  - `sch_fq`
  - `ifb`
  - `act_mirred`
  - `cls_u32`

## 参数规则

`apply` 和 `install` 使用相同的参数顺序：

```text
命令 [出站Mbps|off] [入站Mbps|off] [网卡]
```

`off`、`none`、`unlimited` 或 `0` 均表示对应方向不限速，配置文件中统一保存为 `off`。

为了兼容旧版本，以下旧命令仍表示“出站 300 Mbps、入站不限”：

```bash
sudo ./vps-egress-limit.sh apply 300 eth0
sudo ./vps-egress-limit.sh install 300 eth0
```

## 临时使用

下载脚本后赋予执行权限：

```bash
chmod +x vps-egress-limit.sh
```

### 出站 300 Mbps，入站 400 Mbps

```bash
sudo ./vps-egress-limit.sh apply 300 400 eth0
```

### 出站不限，入站 400 Mbps

```bash
sudo ./vps-egress-limit.sh apply off 400 eth0
```

### 出站 300 Mbps，入站不限

```bash
sudo ./vps-egress-limit.sh apply 300 off eth0
```

如果全部参数都省略，默认出站 300 Mbps、入站不限，并自动识别公网出口网卡：

```bash
sudo ./vps-egress-limit.sh apply
```

查看状态：

```bash
sudo ./vps-egress-limit.sh status eth0
```

分别关闭限速：

```bash
sudo ./vps-egress-limit.sh off egress eth0
sudo ./vps-egress-limit.sh off ingress eth0
sudo ./vps-egress-limit.sh off all eth0
```

旧命令 `off eth0` 等同于 `off all eth0`。

## 永久安装

建议先使用临时 `apply` 测试，确认 SSH 和业务连接正常后再安装永久服务。

双向安装示例：

```bash
sudo ./vps-egress-limit.sh install 300 400 eth0
```

只限制入站：

```bash
sudo ./vps-egress-limit.sh install off 400 eth0
```

只限制出站：

```bash
sudo ./vps-egress-limit.sh install 300 off eth0
```

永久安装使用以下文件：

```text
/usr/local/sbin/vps-egress-limit
/etc/default/vps-egress-limit
/etc/systemd/system/vps-egress-limit.service
```

## 永久服务管理

修改两个方向并立即生效：

```bash
sudo vps-egress-limit set-rate 500 600
```

只把入站改为 500 Mbps，保持当前出站配置：

```bash
sudo vps-egress-limit set-rate keep 500
```

只把出站改为 500 Mbps，保持当前入站配置：

```bash
sudo vps-egress-limit set-rate 500
```

取消出站限制、把入站设为 400 Mbps：

```bash
sudo vps-egress-limit set-rate off 400
```

暂停全部限速并取消开机启动，但保留安装文件：

```bash
sudo vps-egress-limit disable
```

重新启用：

```bash
sudo vps-egress-limit enable
```

查看状态：

```bash
sudo vps-egress-limit status eth0
```

彻底卸载：

```bash
sudo vps-egress-limit uninstall
```

卸载不会删除最初下载或克隆的 `vps-egress-limit.sh`。

## 完整命令摘要

```text
apply [出站|off] [入站|off] [网卡]      临时应用双向配置
off [all|egress|ingress] [网卡]         按方向关闭临时限速
status [网卡]                            查看双向队列和服务状态

install [出站|off] [入站|off] [网卡]      安装并启动永久服务
set-rate <出站|off|keep> [入站|off|keep] 修改永久速率
disable                                  停止限速并取消开机启动
enable                                   重新启用永久限速
uninstall                                删除永久安装并关闭双向限速
```

## 升级旧版本

新版可以读取旧配置中的 `RATE_MBIT`，并将其解释为出站速率，入站默认为 `off`。更新仓库脚本后，在服务器上重新执行一次 `install` 即可更新 `/usr/local/sbin` 中的安装副本和配置格式：

```bash
sudo ./vps-egress-limit.sh install 300 off eth0
```

## 注意事项

- 限制的是指定网卡上对应方向的所有流量总和，不是每个连接各获得该速率。
- `apply` 会替换物理网卡现有的根 qdisc；关闭出站时恢复为 `fq`，不会还原运行脚本前的其他根 qdisc。
- 入站限速会在物理网卡的 ingress hook 上添加优先级为 `49152` 的过滤器，并创建脚本专用的 `ifb-vpslimit`。关闭后只删除该过滤器和带有脚本所有权标记的 IFB，不主动删除可能由其他程序创建的 ingress/clsact hook。
- 如果已有 tc、QoS、防火墙流量控制或其他 IFB 配置，应先确认不会与本脚本使用的过滤器优先级和 IFB 名称冲突。
- VPN、多出口或策略路由环境中，自动识别结果可能不是目标网卡，建议显式指定接口。
- 入站 IFB 整形比单纯丢包 policing 更平滑，但会增加一定 CPU 和内存开销。
- 网卡被删除并重新创建后，队列规则可能丢失，可执行 `sudo systemctl restart vps-egress-limit` 恢复。
- 永久安装后运行的是 `/usr/local/sbin/vps-egress-limit` 副本；仓库脚本更新后需要重新执行 `install`。

## 开发与维护

提交前至少执行：

```bash
bash -n vps-egress-limit.sh
bash vps-egress-limit.sh --help
```

仓库中的 GitHub Actions 会在 push 和 pull request 时自动执行 Bash 语法检查。

```bash
git add vps-egress-limit.sh README.md
git commit -m "feat: add independent ingress and egress limits"
git push origin main
```
