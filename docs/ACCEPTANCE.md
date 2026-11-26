# 验收和排障

## 接口检查

在 NAS 外的网络运行：

```sh
python3 nas/doctor.py https://自己的子域.nyat.app:自己的TCP端口
```

输入配对密码。预期登录、设备、短信、WebRTC 能力接口均返回 200。工具会打印耗时，不打印凭据或短信内容。接口通过后继续手机实测。

## 真机验收表

| 操作 | 通过条件 |
| --- | --- |
| iPhone 关闭 Wi-Fi，连接自己的 HTTPS 地址 | 成功登录，看到 SIM 状态和电话已连接 |
| 对端给 EC20 的 SIM 发一条普通短信 | NAS 归档，iPhone 收到新信息推送 |
| 收到推送后先留在主屏幕 | App 图标出现未读角标 |
| 点击信息通知 | 打开对应号码会话，阅读后通知及未读状态同步 |
| App 回复一条短信 | 对端实际收到，发送气泡保留同一位置 |
| 对端呼入，iPhone 处于锁屏 | 出现 CallKit，接听后双方各说一句且都听到 |
| App 挂断、对端挂断、拒接 | 两端按操作结束，模块释放线路 |
| 连续通话并切换听筒、扬声器、保持和恢复 | 双向声音正常，恢复后可继续通话 |
| 在通话中开启本机录音再挂断 | 通话详情可播放双方声音，文件留在手机 |
| NAS 在空闲时重启 | 三个服务自动运行，重复短信和锁屏来电验收 |

对端实际收到短信和听到声音需要人工配合。接口返回 200 和 UDP 握手是部分验证。

## 常见问题

| 现象 | 优先核对 |
| --- | --- |
| HTTPS 超时 | TCP 隧道在线状态、本地目标 22443、节点额度及账号状态 |
| TLS 失败 | 输入的子域与证书匹配，frpc 已加载该子域证书，手机时间正确 |
| 登录 401 | 该 NAS 实例的配对密码，重装是否换了 config.json |
| 已连接却没有声音 | UDP 隧道目标 22444，FRP_PUBLIC_UDP 的主机和公网端口，ICE 本地端口 |
| 收不到锁屏来电 | 推送登记、APNs 证书 topic、development/production、手机通知权限 |
| 短信只进列表没有通知 | SIM 状态里的信息推送最近投递结果、NAS 到 Apple 的联网情况 |
| 图标没有角标 | 系统允许标记，App 和扩展 Keychain Group 一致，打开并刷新过 App |
| 模块反复搜网 | MAIN 天线、信号、供电、USB 稳定性、SIM 与固件的运营商兼容性 |
| 发短信提示发送结果未知 | 先查看会话与对端结果。相同请求会去重，部分分段可能已提交 |
| 发送长短信中出现来电 | 串口会在分段之间检查来电，当前分段最多等待 8 秒，未提交的分段可被中止 |

NAS 日志：

```sh
sudo journalctl -u homeline-nas -u homeline-sakurafrp-gateway -u homeline-sakurafrp-client --since '15 minutes ago' --no-pager
```

分享日志前移除电话号码、短信内容、推送 token、隧道凭据和密码。

## 本机模拟串口与媒体联调

在 Mac 上从源码构建本机媒体程序，避免使用 ARM64 Linux 文件：

```sh
mkdir -p build
(cd nas/nas/webrtc-voice && go build -o ../../../build/homeline-media-native .)
fixture=$(mktemp -d)
python3 nas/nas/webrtc-voice/test_fixture.py --media build/homeline-media-native --work "$fixture" --launch nas/launch.sh
```

终端会持续运行模拟模块。另开终端，先把 fixture 设为前一步目录，并在 ios/ 中生成工程：

```sh
export TEST_RUNNER_HOMELINE_RUN_WEBRTC_FIXTURE=1
export TEST_RUNNER_HOMELINE_WEBRTC_FIXTURE_CA=$(base64 < "$fixture/ca.der" | tr -d '\n')
cd ios
xcodebuild -project HomeLineWebRTC.xcodeproj -scheme HomeLine -destination 'id=自己的模拟器UUID' -only-testing:HomeLineTests/WebRTCLANTests test CODE_SIGNING_ALLOWED=NO
```

这个测试使用模拟串口，验证双向音频、本机录音和保持恢复。结束后 Ctrl-C 关闭模拟程序。
