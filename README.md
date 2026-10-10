# OsMutation-fix — EUServ(LXC) Alpine 重装失联修复版

基于 [LloydAsp/OsMutation](https://github.com/LloydAsp/OsMutation) 的 LXC 分支修复。
原版在 EUServ 免费 VPS (LXC) 上重装 Alpine 后必然失联（Debian 正常），本仓库修复该问题。

## 根因分析

原版 `migrate_configuration` 重写的 `/etc/network/interfaces` 中包含一行**顶级的 `hostname xxx`**：

```text
auto eth0
iface eth0 inet static
address 1.2.3.4/24
up ip route add default via 1.2.3.4 dev eth0

hostname myhost        <- 顶级指令行
```

Debian 模板的 ifup 解析器对无法识别的顶级行宽松跳过，所以装 Debian 没事；
而 Alpine 模板使用的是 **ifupdown-ng**（严格解析），networking 服务启动时解析
失败 → 网卡没有 IP → SSH 无法连接 → "失联"。

叠加的次要问题：

1. 网关用 `up ip route add ...` 外部命令实现，/32 掩码（德国商家常见点对点网络）下缺少 `onlink` 会加不上默认路由；
2. 旧系统是纯 DHCP 时，`grep static` 判断失败后生成的 static 配置若取不到 IP/网关会写出残缺配置；
3. `apk add openssh` 失败时脚本静默继续，重启后系统里根本没有 sshd；
4. 发行版识别只靠 `grep alpine /etc/issue`，脆弱；
5. `PermitRootLogin yes` 盲目追加到 sshd_config 末尾，若模板已有 `PermitRootLogin prohibit-password`（同名指令第一条生效）则不生效。

## 修复点

1. interfaces 不再写入顶级 `hostname` 行，hostname 改写 `/etc/hostname`；
2. 网关改用标准 `gateway` 行（ifupdown 与 ifupdown-ng 都原生支持），/32 自动改用 `up ip route add default via ... onlink`；
3. 取不到 IP/网关时自动回落 DHCP（busybox udhcpc）；
4. Alpine 用 `/etc/alpine-release` 标志文件识别；
5. `apk add openssh bash ifupdown-ng` 失败自动重试一次，仍失败则红色报错退出，**绝不带病重启**，装完校验 sshd 存在；
6. sshd_config 先清理已有 `PermitRootLogin`/`PasswordAuthentication` 行再追加；
7. 重复运行自动清理上次残留的 `/x`；
8. `hostname` 服务加入 boot runlevel，networking 同时注册 boot + default。

## 使用方法（在 VPS 上执行）

```bash
curl -so OsMutation.sh https://raw.githubusercontent.com/hackerxiaow/OsMutation-fix/main/OsMutation.sh
chmod u+x OsMutation.sh
./OsMutation.sh
```

选好系统（如 alpine-3.23-amd64）后等脚本跑完，最后手动 `reboot` 即可进入新系统。
root 密码与 `/root/.ssh` 沿用旧系统。

## 重装失败失联后如何恢复

到 EUServ 客户面板 (Server Admin Panel) → 选择服务器 → *Server data* 标签 →
勾选一个官方基础镜像（如 Debian 11 minimal）→ 提交重装，等几分钟即恢复，然后再跑本修复脚本。

## 说明

- 本修复仅针对 **LXC** 路径（EUServ 实测场景）；OpenVZ 分支在 `main()` 中被禁用（原版逻辑未改动），
  KVM 仍透传调用上游 `OsMutationKvm.sh`。
- License: GPLv3（沿用上游）。
