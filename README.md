# 随行电话 HomeLine

将 SIM 卡插在 NAS 的 EC20 模块中，在 iPhone 上用随行电话收发短信、接打电话。当前主方案使用 AT + WebRTC 和 SakuraFrp。每个部署实例服务一张 SIM 和一部接听 iPhone。

```text
运营商 ←→ SIM / EC20 ←USB→ NAS
                              ↑↓ HTTP 接口、WebRTC UDP
                         NAS 上的 frpc
                              ↑↓ SakuraFrp 节点
                           iPhone App

NAS ── Apple APNs ──→ 新信息通知、PushKit 唤醒 ──→ CallKit 来电
```

支持联系人匹配、短信未读与验证码筛选、批量删除、最近通话、拨号、系统来电界面、静音、扬声器、保持、DTMF 和本机双方录音。录音保存在 iPhone 的通话详情。短信及发送请求记录保存在 NAS 的 SQLite 数据库。App 的 HTTPS 地址和连接密码统一配置短信与电话。

## 复现准备

| 需要准备 | 要求 |
| --- | --- |
| NAS | Linux ARM64、systemd、Python 3.10+、USB 串口支持，能访问互联网 |
| EC20 | 已验证支持当前运营商语音和短信的固件与 SIM，AT 和 PCM 串口可用 |
| 天线与供电 | MAIN 天线连接可靠，放置位置和供电能支持持续蜂窝通话 |
| SakuraFrp | 自己的账号、可用的 TCP 和 UDP 隧道、平台子域绑定与 HTTPS 证书 |
| Apple | 自己的 Apple Developer Program 团队、App ID 和 APNs 证书 |
| Mac | Xcode 26+、XcodeGen、Python 3.10+，用于构建当前含新系统控件的 App |
| iPhone | iOS 17+，开发签名需允许开发者模式，并登记到自己的团队 |

iOS 26+ 展示较新的系统玻璃控件，较旧系统使用代码中的兼容样式。EC20 的型号、固件和运营商组合会影响 VoLTE；硬件接入成功后仍需完成真实通话验收。SIM 插在 EC20，iPhone 使用自己的 Wi-Fi 或蜂窝网络连接 NAS。

## 从零部署顺序

1. 在 Mac 或 Linux 安装 Go 1.25+。仓库根目录运行 `./scripts/build-media.sh`，生成 ARM64 的 `nas/bin/homeline-media`。依赖版本由 go.mod 和 go.sum 固定。
2. 按 [Apple 推送与 iOS 构建](docs/APPLE-IOS.md) 创建自己的 Bundle ID、证书和签名，再生成 iOS 工程。
3. 按 [NAS 与 SakuraFrp 部署](docs/DEPLOY.md) 设置服务密码、串口和隧道，先跑检查再启动。
4. 在 Mac 或其他能访问公网的机器运行 `python3 nas/doctor.py https://你的子域.nyat.app:TCP端口`。它会交互询问密码并测试登录、读取短信和语音能力接口。
5. 将 App 安装到 iPhone，设置同一个 HTTPS 地址和密码，按 [验收和排障](docs/ACCEPTANCE.md) 完成真实短信、锁屏接听与双向声音测试。

## 项目目录

| 目录 | 内容 |
| --- | --- |
| nas/ | 独立 NAS 服务、Go 媒体程序源码、SakuraFrp 网关、自启配置、安装检查 |
| ios/ | WebRTC 专用 iOS 源码、通知扩展、脱敏后的 XcodeGen 工程配置 |
| relay/ | 可选的自建 VPS + WireGuard 中转部署，见该目录 README |
| scripts/ | 从干净源码构建媒体程序和运行服务测试 |
| licenses/ | 构建时核对的第三方许可证及模块清单 |
| docs/ | 完整安装、Apple 配置、验收、备份和回退说明 |

SakuraFrp 主方案不需要部署 relay/。使用者自己的账号、端口、域名、证书和密钥均在部署时配置。平台节点是否可用、是否要求实名及流量额度以各自账号面板为准。平台子域和自动 HTTPS 的操作见 [SakuraFrp 官方说明](https://doc.natfrp.com/bestpractice/domain-bind.html)。

## 数据与备份

默认数据目录为 /var/lib/homeline-nas，配置目录为 /etc/homeline-nas。迁移旧短信为可选步骤，参照部署文档。切换前结束通话并停止服务，对数据库使用 SQLite backup 或复制停止后的完整数据目录。备份包含私人短信和推送凭据，应按私有数据保管。

Apple 推送依赖证书、App 签名环境和系统通知权限。专注模式会影响通知呈现。录音需由用户在 App 中开启，并遵循通话所在地的要求。

## 开发与许可

运行 `./scripts/test.sh` 验证 Go、Python 服务。iOS 和模拟串口联调见验收文档。可移植服务的 GitHub Actions 配置已附在 .github/workflows/check.yml。

自有代码使用 [MIT](LICENSE)，第三方组件说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。本目录为本地开源预览，具体验证范围记在 [VALIDATION.md](docs/VALIDATION.md)。
