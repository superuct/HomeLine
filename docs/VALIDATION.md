# 验证记录

本记录对应 2026-11-26 整理的 0.7.14 开源项目预览。测试直接从生成后的脱敏目录执行。

| 验证项 | 结果 |
| --- | --- |
| 源码重建 ARM64 Linux 媒体文件 | 成功，Go 1.27.3，依赖通过 go mod verify |
| Go 媒体测试 | 通过 |
| Python 服务回归 | 23 项通过 |
| 另一组 Bundle ID 和 AppIdentifierPrefix 生成 iOS 工程 | 主 App 和扩展的 ID、共享 Keychain 权限检查通过 |
| iOS 模拟器单元与媒体联调 | 55 项通过，含模拟串口双向音频、保持、录音和挂断 |
| ARM64 Linux 上启动导出的 NAS 包 | 通过，Python 3.11、模拟 AT 与 PCM 串口，HTTPS 状态接口正常 |
| iOS 筛选和发送界面 | 3 项通过，含居中分段选择、单气泡交接及草稿保留 |
| 发布内容检查 | 排除部署密钥、证书、数据库及个人端点，附 SHA256SUMS |
| 第三方说明 | 附 23 个编译用 Go 模块的许可证、Go 许可、WebRTC 许可 |

Linux 检查在独立临时目录执行，未将预览服务安装成现网自启服务。专用用户创建及 systemd 安装脚本仍需在新用户自己的发行版执行 install.py --check 核对。

复现测试使用已有的本地 WebRTC 156.0.0 SDK。首次在线下载 SDK 以及新账号的 Apple 开发者配置需由使用者完成。

使用新用户自己的 SakuraFrp 隧道、Apple 证书和 SIM 完成真实蜂窝短信、锁屏 CallKit、手机角标及双向通话验收后，才能确认该用户的完整部署可用。验收表见 ACCEPTANCE.md。
