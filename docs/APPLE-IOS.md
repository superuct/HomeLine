# Apple 推送和 iPhone 构建

## 自己的 App 和签名

在 Apple Developer 的 Certificates, Identifiers & Profiles 中注册显式 App ID，例如 com.example.myphone，并启用 Push Notifications。通知扩展使用 com.example.myphone.notifications。团队须支持所需的推送能力，测试 iPhone 登记到自己的团队。

Mac 安装 Xcode 26+、命令行工具和 XcodeGen。当前源码以 iOS 17 为最低版本，使用较新系统 API 的代码由 availability 判断保护。

```sh
cd ios
python3 generate.py --bundle-id com.example.myphone --team ABCDE12345
open HomeLineWebRTC.xcodeproj
```

在 Xcode 的 Signing & Capabilities 中核对主 App 与扩展使用同一团队。两者共享的 Keychain Group 应为描述文件真实 AppIdentifierPrefix 加上 com.example.myphone.sms-badge，主 App 另有自己的默认组。通常此前缀与 Team ID 一致，历史账号可能不同，可用 generate.py 的 --app-identifier-prefix 明确设置。描述文件必须允许所需组，角标依赖主 App 和扩展读写同一个组。

先连接并解锁自己的 iPhone，在 Xcode 选中 HomeLine scheme 和设备，完成系统提示的开发者模式及签名信任流程，然后运行。App 第一次使用需允许麦克风和通知，联系人权限用于姓名显示。

开发安装使用 development APNs。Ad Hoc 或正式分发用 production，并同步生成自己的匹配描述文件：

```sh
python3 generate.py --bundle-id com.example.myphone --team ABCDE12345 --apns-env production
```

若出现无法验证，检查设备联网、证书有效期、设备登记、主 App 和扩展签名、系统信任状态。已有匹配的 Ad Hoc 描述文件时，可用同一个 Bundle ID 覆盖安装，并核对 NAS 的 APNs 环境。

## Apple 服务器推送证书

NAS 当前使用 TLS 客户端证书连接 APNs。先为普通通知申请 Apple Push Notification service SSL 开发和生产证书，选择自己的 App ID。VoIP 可使用该 App ID 允许 VoIP topic 的证书，或为同一 App ID 单独申请 VoIP Services 证书。需要同时具备普通通知 topic 和 Bundle ID 加 .voip 的 topic。

在生成 CSR 的 Mac 上保存私钥，下载证书后导入钥匙串。在“我的证书”中选择证书及其私钥，导出受密码保护的 .p12。对应的证书和私钥必须配对。官方流程见 [Apple APNs TLS 证书说明](https://developer.apple.com/help/account/capabilities/communicate-with-apns-using-a-tls-certificate/)。

在私有目录中转换，openssl 将交互询问导出密码：

```sh
umask 077
openssl pkcs12 -in alerts.p12 -clcerts -nokeys -out apns.pem
openssl pkcs12 -in alerts.p12 -nocerts -nodes -out apns.key
```

若另外导出 VoIP 证书：

```sh
openssl pkcs12 -in calls.p12 -clcerts -nokeys -out voip.pem
openssl pkcs12 -in calls.p12 -nocerts -nodes -out voip.key
```

复制至 NAS 的 /etc/homeline-nas 并设置私钥为 600。NAS config.json 的 apns_topic 必须等于自己的主 App Bundle ID，apns_env 必须与构建签名一致。本项目不会从浏览器或仓库获取你的开发者凭据。

App 打开并连接后，普通推送 token 和 VoIP token 会登记到 NAS。SIM 状态下可查看登记状态，以及 Apple 最近接收请求和失败记录。Apple 接收推送请求后，实际展示还受手机联网、通知授权和专注模式影响。

## 模拟器和离线构建

模拟器可省略 --team。网络无法下载 WebRTC 时，--local-webrtc 指向已准备好的 156.0.0 本地 Swift Package。正式复现首次需要获取该固定 SDK。

在生成工程后：

```sh
xcodebuild -project HomeLineWebRTC.xcodeproj -scheme HomeLine -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData build CODE_SIGNING_ALLOWED=NO
```

用 xcrun simctl list devices available 找到模拟器 UUID，再用 -destination 'id=自己的UUID' 运行 test。固定依赖源见 ios/project.json 的 packages。
