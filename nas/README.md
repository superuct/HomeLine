# 随行电话 NAS 部署包 · AT + WebRTC

适用 Linux ARM64、Python 3.10+、EC20 已具备可用的运营商语音和短信服务、可读写的 AT 和 PCM 串口。预编译的 `bin/homeline-media` 对应本包 Go 源码。安装可选的 `libopus.so.0` 以启用 Opus。信令使用 HTTPS，媒体使用单个 UDP 端口。每个实例当前服务一张 SIM 和一部接听 iPhone。

1. 识别模块的 AT 和 PCM 端口。建议使用 `/dev/serial/by-id/` 下的固定路径。暂停占用这些端口的旧软件。
2. 用管理员身份把本包放到 `/opt/homeline-nas`。创建权限为 700 的 `/etc/homeline-nas`。将 `service.env.example` 复制为该目录中的 `service.env`，填写串口和监听参数。
3. 运行 `python3 configure.py --config /etc/homeline-nas --bundle-id org.example.homeline`，把示例 ID 换成 iOS 包实际使用的 ID。交互设置配对密码。
4. 选 SakuraFrp 时按下节配置。局域网直连或自建 VPS 时，把 iPhone 可验证且与实际连接地址匹配的 TLS 证书链和私钥放到配置目录，命名为 `fullchain.pem`、`tls.key`。公网中转透传 TLS，证书仍使用 iPhone 输入的地址。更新证书后在空闲时重启 NAS 服务加载。
5. 安装单元 `install -m 644 homeline-nas.service /etc/systemd/system/homeline-nas.service`，然后运行 `systemctl daemon-reload` 和 `systemctl enable --now homeline-nas.service`。查看 `journalctl -u homeline-nas.service`，等待 WebRTC/AT ready。App 输入地址和配对密码。

局域网内使 iPhone 可达 TCP 18443 和 UDP 20119 即可。通过可选中转时，把 `ICE_BIND` 设为 NAS 隧道 IP，`ICE_PUBLIC_IP` 设为中转的实际公网 IPv4。WireGuard 没准备好时，systemd 会重试，直到模块和媒体连接准备好。

## SakuraFrp 公网接入

1. 在 `service.env` 设置 `HOMELINE_MODE=sakurafrp`。NAS 将 HTTP 和 WebRTC UDP 绑定到环回地址，TLS 由 NAS 上的 SakuraFrp 客户端终止。
2. 在 SakuraFrp 创建 TCP 和 UDP 隧道，分别转发到 `127.0.0.1:22443` 和 `127.0.0.1:22444`。TCP 启用自动 HTTPS 并绑定自己的 `nyat.app` 子域。在控制面板取得两个隧道的实际连接地址。
3. 将 `sakurafrp.env.example` 复制到 `/etc/homeline-nas/sakurafrp.env`。填写 UDP 隧道的主机和公网端口。若已更改 `FRP_ORIGIN_PORT` 或 `ICE_PORT`，同步调整本地目标。
4. 将官方 Linux ARM64 SakuraFrp 客户端放到 `/opt/homeline-nas/bin/frpc`，权限设为 755。创建系统用户 `homeline-frp`，以该账号拥有的 700 权限目录 `/var/lib/homeline-sakurafrp` 保存平台下载的 `frpc.ini`，配置权限设为 600。
5. 安装并启用 `homeline-sakurafrp-gateway.service` 和 `homeline-sakurafrp-client.service`。App 输入绑定子域的 HTTPS 地址及 TCP 公网端口。用蜂窝网络分别验证短信、锁屏接听和双向声音。

## 推送和数据迁移

锁屏接听与短信推送要配置匹配该 Bundle ID 和环境的 Apple APNs 证书。证书与私钥只放 NAS，使用 `apns.pem/apns.key`，如 VoIP 使用独立证书则另放 `voip.pem/voip.key`。配置文件中的 `apns_env` 须匹配签名，HTTP/2 推送需要支持 HTTP/2 的 curl。当前版本的入站呼叫由 PushKit 通知 iPhone，因此真正的接听验收需要 APNs。按 Apple 的证书说明核对证书包含相应 topic。

旧短信迁移可选。先停止新服务，创建权限为 700 的 `/var/lib/homeline-nas/work`，执行 `umask 077` 后运行 `python3 nas/webrtc-voice/import_sms.py /path/old.sqlite /var/lib/homeline-nas/work/messages.sqlite --device ec20`。目标必须为空，来源应为一致的数据库快照。导入保留 ID 和会话。第一次正常启动会自行创建空库。

回退前停止本服务并备份整个数据目录，再恢复旧服务与兼容的客户端。已由新服务收发的短信在独立库，旧服务不会自动同步这部分记录。卸载可用 `systemctl disable --now homeline-nas.service`，本地数据须单独保管。

源码重建：进入 `nas/webrtc-voice`，用 Go 1.25+ 执行 `go mod verify`、`go test ./...`、`CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -o ../../bin/homeline-media .`。
