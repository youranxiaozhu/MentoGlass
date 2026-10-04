# 路由器部署前提

App 不负责开启厂商未开放的 SSH、刷固件或自动安装校园认证协议。请先使用学校允许的接入方式，在自己的路由器部署适合该网络的 MentoHUST，并验证一次正常认证。

## 1. 必需路径与接口

| 路径／名称 | 用途 |
| --- | --- |
| `/data/mentohust/mentohust` | 已有的可执行认证程序 |
| `/data/mentohust/mentohust.conf` | 第一账号配置，建议 0600 |
| `/etc/mentohust.conf` | 原有程序读取配置的位置，部署可使用指向上项的软链接 |
| `/etc/crontabs/patches/mentohust_boot.sh` | 已有认证控制脚本 |
| `/data/mentohust/enabled` | 控制脚本的认证守护开关标记 |
| `eth0` | 此 RA80 部署的第一校园网接口 |
| `br-lan` | 私有 LAN／主 Wi‑Fi 网桥 |

控制脚本须实现 `status`、`start`、`stop`、`enable`、`disable`。`status` 至少输出 `running=yes/no`、`enabled=yes/no`；`stop` 只停当前认证，`disable` 关闭守护并停止，`enable` 打开守护。定时认证在调用 `stop` 后仍需保留 `/data/mentohust/enabled`，否则会按设计跳过后续启动。

**该原有控制脚本和 MentoHUST 二进制不在仓库内。** 这是现有部署的依赖，不能用空文件或名字相同但行为不同的脚本代替。新装路由器必须先补齐兼容部署；无法满足时只阅读源码，不执行 App 的管理动作。

## 2. 只读检查

下面把检查脚本通过 SSH 发给自己的路由器执行，不保存密码，不修改配置，也不发起校园网探测：

```bash
ssh -T -p 22 \
  -o HostKeyAlgorithms=+ssh-rsa \
  -o PubkeyAcceptedAlgorithms=+ssh-rsa \
  root@192.168.31.1 'sh -s' < tools/check-router.sh
```

根据提示核实主机公钥并输入已有 SSH 密码。地址、用户名、端口按自己的设备填写；兼容旧 Dropbear 的 RSA 选项只应用于这条连接。

输出的 `PASS` 说明对应文件／命令存在，**不代表已经认证成功或外网可用**。双线路未部署时，该项显示未安装是正常的，单线路功能不依赖第二线路。

## 3. 第一线路 DHCP

曾经发现的一种错误是 `DhcpScript=udhcpc -i` 缺少网卡参数；这会导致 DHCP 命令直接失败。在本项目实测部署中，配置改用：

```ini
DhcpScript=/bin/ubus call network.interface.wan renew
```

这个命令由已有 netifd WAN 客户端进行普通续租。它要求 `network.interface.wan` 在你的固件上存在；不能未经检查直接套用到别的系统。修改前备份自己的配置并设为 0600；保存不会改变已运行进程的内存配置，需要下一次正常启动才生效。

## 4. 保留现有认证策略

认证模式、心跳、DHCP 模式与失败策略需要按学校和原有插件选择。教程不提供适用于所有学校的“万能参数”。先记录当前能正常认证的配置，避免同时改账号、网卡和认证模式，导致无法判断失败原因。

不要把自己的 `mentohust.conf`、网络／无线备份、认证日志或 SSH 主机记录提交到仓库，也不要粘贴完整文件到公开 Issue。

