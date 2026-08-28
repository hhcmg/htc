# htc

`htc` 是一个面向 Linux VPS 的出站聚合限速脚本。它使用 HTB 控制指定网卡的总出站速率，并以 `fq` 作为叶子队列，适合与 BBR pacing 配合使用。

> 脚本只限制出站流量，不限制入站流量，也不会修改 TCP 拥塞控制算法。

## 功能

- 临时开启或关闭指定网卡的聚合出站限速
- 自动识别默认公网出口网卡，也支持显式指定网卡
- 查看 TCP 拥塞控制、qdisc、HTB class 和 systemd 服务状态
- 安装为 systemd 服务并在开机时自动应用
- 修改永久速率、暂停、恢复或彻底卸载服务
- 参数校验和失败时的 `fq` 恢复处理

启用后的队列结构：

```text
HTB root 1:
└── HTB class 1:10 (rate = ceil = 指定速率)
    └── fq 10:
```

## 环境要求

- 使用 Bash 的 Linux 系统
- root 权限
- `iproute2`（提供 `ip` 和 `tc`）
- 内核支持 `sch_htb` 和 `sch_fq`
- 永久安装功能需要 systemd

## 快速开始

下载脚本后赋予执行权限：

```bash
chmod +x vps-egress-limit.sh
```

建议先临时测试。以下示例将 `eth0` 的全部出站流量合计限制为 300 Mbps：

```bash
sudo ./vps-egress-limit.sh apply 300 eth0
sudo ./vps-egress-limit.sh status eth0
```

关闭临时限速：

```bash
sudo ./vps-egress-limit.sh off eth0
```

确认运行正常后安装为永久服务：

```bash
sudo ./vps-egress-limit.sh install 300 eth0
```

如果省略网卡，脚本会通过系统路由自动识别出口；如果同时省略速率，则使用默认值 300 Mbps：

```bash
sudo ./vps-egress-limit.sh apply
```

## 命令说明

```text
apply [Mbps] [网卡]    临时开启限速
off [网卡]             临时关闭 HTB，根队列恢复为 fq
status [网卡]          查看拥塞控制、队列和服务状态

install [Mbps] [网卡]  安装并启动永久服务
set-rate <Mbps>         修改永久速率并立即生效
disable                 停止永久限速并取消开机启动
enable                  重新启用永久限速和开机启动
uninstall               删除永久安装并恢复根队列 fq
```

永久安装使用以下文件：

```text
/usr/local/sbin/vps-egress-limit
/etc/default/vps-egress-limit
/etc/systemd/system/vps-egress-limit.service
```

## 注意事项

- 速率单位是十进制 Mbps，限制对象是指定网卡上所有出站连接的总和。
- `apply` 会替换网卡现有的根 qdisc；`off` 和 `uninstall` 会恢复为 `fq`，不会还原执行脚本前的其他 qdisc 配置。
- VPN、多出口或策略路由环境中，自动识别结果可能不是目标网卡，建议显式指定接口。
- 永久安装后运行的是 `/usr/local/sbin/vps-egress-limit` 副本。修改仓库脚本后，需要重新执行 `install` 才会更新服务器上的安装副本。
- 远程操作 VPS 时，建议先使用临时 `apply` 验证效果，再安装永久服务。

## 开发与维护

提交前至少执行 Bash 语法检查：

```bash
bash -n vps-egress-limit.sh
```

仓库中的 GitHub Actions 会在 push 和 pull request 时自动执行同样的语法检查。

重大更新建议使用清晰的提交信息，并在验证后推送：

```bash
git add vps-egress-limit.sh README.md
git commit -m "feat: describe the major change"
git push origin main
```
