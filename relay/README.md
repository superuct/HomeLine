# 随行电话公网中转包 · 可选

Linux VPS 使用 Python 3.9+、WireGuard 和 systemd。它将公开 TCP 端口的 TLS 字节及一个 WebRTC UDP 端口转发到 NAS。TLS、业务认证和 Apple 推送由 NAS 负责。

1. 两端各自生成 WireGuard 密钥。照 `wg-public.conf.example` 和 `wg-nas.conf.example` 配置双方的 `/etc/wireguard/homeline.conf`，权限设为 600。只交换公钥。两端启用 `wg-quick@homeline`，确认隧道互通。
2. 把 `relay.py` 放到 `/opt/homeline-relay`。把 `relay.env.example` 复制为 `/etc/homeline-relay/relay.env`，将 NAS、端口改为实际值。NAS 的 ICE UDP 端口必须和中转一致。
3. 安装本包的 systemd 单元，执行 `systemctl daemon-reload` 和 `systemctl enable --now homeline-relay`。云防火墙开放所选 TCP 端口、该 UDP 媒体端口和 WireGuard UDP 端口。NAS 两个业务端口可限于隧道可达。若 TCP 443 已有服务，改用空闲端口并在 App 地址中填写。
4. iPhone 输入与 NAS 证书匹配的公网地址。公网 IPv4 填入 NAS 的 `ICE_PUBLIC_IP`，NAS 监听自身的 WireGuard IP。
5. 从外网测试 HTTPS 登录、收发短信、锁屏接听及双向声音。TCP 可连接只代表信令可达，本方案的媒体要求 UDP。

局域网直连可跳过此包。停用中转时先关闭 `homeline-relay`，再按需停用这条专用 WireGuard 隧道。
