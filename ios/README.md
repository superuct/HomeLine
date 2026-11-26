# 随行电话 iOS 源码 · WebRTC 专用

需要 Mac、Xcode、XcodeGen 和 Python 3.9+。iOS 最低版本为 17。工程从上游下载固定版本 WebRTC SDK；源码包包含 App 和通知扩展，不包含签名资料。

```sh
python3 generate.py --bundle-id org.example.homeline --team YOURTEAMID
open HomeLineWebRTC.xcodeproj
```

把示例改为你自己的 Bundle ID 和实际的 10 位 Apple Team ID。在 Xcode 确认 App 与通知扩展都由你的团队签名，主 App 已启用 Push Notifications，双方的 Keychain Sharing 使用同一个共享组。使用你自己的对应 Bundle ID 的 APNs 证书配置 NAS。开发时用默认 development。采用生产签名与推送时，生成工程加 `--apns-env production`，NAS 同步设置 production。

首次打开 App，在设置中输入 NAS 的 HTTPS 地址和配对密码。使用 iOS 信任且地址匹配的 TLS 证书。构建模拟器时可省略 `--team`。离线验证可加 `--local-webrtc /path/to/package` 指定已有的同版本 Swift Package。
