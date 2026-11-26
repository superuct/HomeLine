# 第三方组件

HomeLine 自有代码采用根目录的 MIT 许可证。第三方组件分别遵循其随附许可。

- Pion WebRTC 及 Go 依赖的准确版本见 nas/nas/webrtc-voice/go.mod、go.sum，逐模块许可证见 licenses/go/ 和 licenses/go-modules.json。重建程序时应重新核对依赖清单。
- iOS 从 https://github.com/stasel/WebRTC 的固定 156.0.0 Swift Package 下载 WebRTC SDK。WebRTC 许可见 licenses/WebRTC-LICENSE。分发包含 SDK 的 App 时也需要保留该 SDK 中的第三方许可说明。
- 系统可选的 libopus 由 Linux 发行版安装，遵循该软件包的许可。
- SakuraFrp 客户端由用户从官方渠道单独下载，遵循平台客户端的许可及服务条款。
- Apple SDK 和系统框架由 Xcode 提供，遵循 Apple 的相应条款。
