# NAS 与 SakuraFrp 部署

以下命令按 Debian/Ubuntu ARM64 和 systemd 编写。其他 NAS 发行版按其软件包管理方式安装依赖和启用 SSH。命令中的示例子域和端口必须替换成自己的隧道参数。

## 1. 准备 NAS

在 NAS 安装 Python 3.10+、支持 HTTP/2 的 curl、libopus 和 openssl。Debian/Ubuntu 可运行：

```sh
sudo apt-get update
sudo apt-get install python3 curl libopus0 openssl
curl -V
uname -m
ls -l /dev/serial/by-id/
```

curl 输出应包含 HTTP2，uname 输出应为 aarch64。若模块没有 by-id 路径，选择固定 USB 端口并使用自己的 udev 规则。确认模块的 USB 端口说明后分别设置 AT 与 PCM，先结束通话并暂停占用这两个串口的其他程序。

在仓库根目录构建媒体程序，再将 nas/ 完整复制到 NAS 的 /opt/homeline-nas。目录里应包含 launch.sh、deploy/、nas/、bin/homeline-media。

```sh
sudo install -d -m 700 /etc/homeline-nas /var/lib/homeline-nas /var/lib/homeline-sakurafrp
sudo cp /opt/homeline-nas/service.env.example /etc/homeline-nas/service.env
sudo cp /opt/homeline-nas/sakurafrp.env.example /etc/homeline-nas/sakurafrp.env
sudo chmod 600 /etc/homeline-nas/*.env
sudo python3 /opt/homeline-nas/configure.py --config /etc/homeline-nas --bundle-id com.example.myphone
```

com.example.myphone 必须与自己的 App ID 相同。configure.py 交互设置 12–120 字节的密码，已有 config.json 时会拒绝覆盖。开发签名默认 development，Ad Hoc 或正式分发使用 --apns-env production。密码对应的是自己的随行电话实例。

编辑 service.env，至少包括：

```ini
HOMELINE_CONFIG=/etc/homeline-nas
HOMELINE_STATE=/var/lib/homeline-nas
HOMELINE_MODE=sakurafrp
AT_DEVICE=/dev/serial/by-id/替换成AT口
PCM_DEVICE=/dev/serial/by-id/替换成PCM口
FRP_ORIGIN_PORT=18086
ICE_PORT=20119
SMS_LOOPBACK_PORT=14675
```

环境文件使用无引号的 KEY=value 格式，路径避免空格。实例需要独占 AT 与 PCM，当前媒体控制还占用本机 14676，因此每台主机默认运行一个实例。

## 2. SakuraFrp

在官方面板选择同时可创建 TCP、UDP 的节点。选择适合自己网络的节点，记录它的实际公网 UDP 主机与端口。

| 隧道 | 本地目标 | 用途 |
| --- | --- | --- |
| TCP | 127.0.0.1:22443 | HTTPS 登录、短信、通话信令 |
| UDP | 127.0.0.1:22444 | WebRTC 双向声音 |

TCP 开启自动 HTTPS，绑定平台分配的子域。App 使用该子域及 TCP 公网端口。frpc 的工作目录需要可写，用于平台证书等文件。

从 SakuraFrp 官方客户端下载页取得 Linux ARM64 客户端，按平台提供的命令核验下载文件。将可执行文件安装成 /opt/homeline-nas/bin/frpc。使用面板生成的配置文件保存成 /var/lib/homeline-sakurafrp/frpc.ini，配置包含自己的访问凭据。先用 frpc -h 和面板示例核对当前客户端兼容本项目单元使用的 -n、-c 参数。

```sh
sudo chmod 755 /opt/homeline-nas/bin/frpc
sudo chmod 600 /var/lib/homeline-sakurafrp/frpc.ini
```

编辑 sakurafrp.env：

```ini
FRP_HTTP_TARGET=127.0.0.1:18086
FRP_ICE_TARGET=127.0.0.1:20119
FRP_PUBLIC_UDP=替换成UDP节点主机:替换成UDP公网端口
```

两个本地目标应与 service.env 相同。FRP_PUBLIC_UDP 使用 UDP 隧道的连接主机，HTTPS 的子域可能与它不同。更换节点或 UDP 公网端口时同步修改此项，再在空闲时重启 homeline-sakurafrp-gateway。

原理和子域绑定见 [SakuraFrp 官方文档](https://doc.natfrp.com/bestpractice/domain-bind.html)。平台 HTTPS 证书由 NAS 上的 frpc 加载，HomeLine HTTP origin 仅监听环回地址。

## 3. 推送文件和启动

按 APPLE-IOS.md 将自己的 apns.pem、apns.key，以及适用时的 voip.pem、voip.key 安装到 /etc/homeline-nas，私钥权限为 600。

```sh
sudo python3 /opt/homeline-nas/install.py --check
sudo python3 /opt/homeline-nas/install.py
sudo systemctl status homeline-nas homeline-sakurafrp-gateway homeline-sakurafrp-client --no-pager
sudo journalctl -u homeline-nas -u homeline-sakurafrp-gateway -u homeline-sakurafrp-client -n 80 --no-pager
```

安装程序会创建 homeline-frp 系统用户并配置自启。NAS 模块服务使用 root 访问串口，两个网络网关分别受专用用户或动态用户限制。检查已有同名单元时，若内容不同会停止安装，先备份和核对自己的旧部署。

日志应出现 HomeLine WebRTC/AT ready，平台 TCP 和 UDP 隧道均连接成功，HTTPS 证书已加载。进入 App 设置后用自己的地址和密码连接，再完成验收。

## 可选旧短信导入

在第一次启动前执行，目标文件须为空：

```sh
sudo install -d -m 700 /var/lib/homeline-nas/work
sudo python3 /opt/homeline-nas/nas/webrtc-voice/import_sms.py /自己的旧短信快照.sqlite /var/lib/homeline-nas/work/messages.sqlite --device ec20
```

来源应为 HomeLine 兼容 SQLite 归档。导入保留消息 ID 和已有时间信息。独立短信库已有内容时导入会退出，防止覆盖。

## 更新和回退

更新前结束通话，记录当前软件版本、HTTPS 地址、UDP 参数和服务文件。停止 homeline-nas 后备份 /var/lib/homeline-nas、/etc/homeline-nas、/var/lib/homeline-sakurafrp 和 /opt/homeline-nas，复制程序文件后启动并重复验收。配置和数据库保留原路径。

回退时停止服务，恢复原程序和单元，再检查迁移后的数据库是否与旧版兼容。若恢复旧数据库快照，必须单独保存更新后新收发的短信。App 的签名团队和 Bundle ID 应保持一致以保留本地数据与录音。
