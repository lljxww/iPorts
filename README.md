# iPorts

原生 macOS 菜单栏端口查看器。点击菜单栏连接器图标展开面板；没有主窗口、Dock 图标或设置窗口。使用 AppKit + SwiftUI、IOKit 和 Disk Arbitration，使用 Sparkle 提供应用更新。

开源仓库：[lljxww/iPorts](https://github.com/lljxww/iPorts)。从 [GitHub Releases](https://github.com/lljxww/iPorts/releases/latest) 下载 Universal ZIP，解压后将 `iPorts.app` 放入“应用程序”；支持 Apple Silicon / Intel、macOS 14+。

## 应用自动更新

应用默认自动检查、下载并安装更新。检查由 Sparkle 管理，启动后按上次检查时间安排，并在运行期间约每 24 小时检查一次；更新包来自本仓库的 GitHub Release。自动安装通常在退出应用时完成，需要授权或确认时会显示更新窗口。面板底部的更新图标提供“检查更新…”、“自动检查更新”和“自动下载并安装”开关，选择会保存在本机。关闭自动下载后仍可手动下载安装。

更新源为 `https://github.com/lljxww/iPorts/releases/latest/download/appcast.xml`。发布流程使用 Ed25519 签名更新包及 appcast；应用使用内置公钥验证更新列表，并在解压前校验更新包。更新检查不附带硬件采集结果，不启用 Sparkle 系统画像。网络不可用或校验失败时保留当前版本，下次重试。

没有自动更新功能的旧版本需要手动安装一次新版，此后即可通过应用更新。当前发布包使用 ad-hoc 签名，未进行 Apple Developer ID 签名与公证；Sparkle 的更新签名用于确认更新来源，不能替代 macOS Gatekeeper 的首次安装验证。

## 功能与数据含义

| 类型 | 可查看的信息 | 操作 |
| --- | --- | --- |
| USB | 名称、厂商、设备类别、上下级集线器、控制器、位置 ID、VID/PID、序列号、USB 协议、链路速率、分配电流及功率 | 查看、搜索、复制详情 |
| Thunderbolt / USB4 | 系统端口编号、端口链路能力、已连接的雷雳设备及其固件、路由等系统提供的字段 | 查看、复制详情 |
| 外接显示器 | 名称、GPU、桌面分辨率及刷新率、渲染像素、镜像状态、厂商 / 产品 ID | 查看、复制详情 |
| 外接物理磁盘 / SD 卡 | 设备名、容量、设备节点、连接协议、块大小、可写状态、实时读取 / 写入速率（驱动提供统计时） | 安全推出整盘 |
| 有线网络 | 物理以太网 / USB 网卡、接口名、控制器、MAC 地址、链路状态、协商模式、实时接收 / 发送速率 | 查看、复制详情 |
| 无线网络 | Wi-Fi 接口、电源与连接状态、发送链路速率、802.11 协议、信道 / 频段 / 宽度、RSSI / 噪声 / 信噪比、安全模式、IP / MAC、接口实时收发速率；SSID / BSSID 需系统允许 | 查看、搜索、复制详情、按需申请网络名称权限 |
| 蓝牙 | 当前已连接设备名称、设备类型、连接方式、地址（系统提供时）、RSSI、固件 / 服务与电量（设备提供时） | 查看、搜索、复制详情 |
| 电源 / 整机功率 | 支持机型的整机负载、外部电源状态与输入功率；均为系统电源遥测 | 点击机身电源接口或顶部“功率”，查看、复制 |

**数值不会冒充硬件实测：**

- `分配功率`来自 IOKit 的 `UsbPowerSinkAllocation`，按 5 V × 分配电流换算。它是 USB 供电分配值，不是实时耗电，也不是 USB-C PD 的协商电压 / 功率。
- `链路速率`是连接速率，不是实际吞吐量。macOS 没有为所有 USB、雷雳、显示设备公开通用的实时流量 / 功耗计数器；不可读取的数据明确显示“未提供”。
- 磁盘速率通过累计读写字节的差值和单调时钟计算，单位 B/s、MB/s；首个采样不显示假定的零值。它反映磁盘 I/O，不能代表整个 USB 端口的流量，也不保证已写入物理介质。
- 有线网络使用内核 64 位计数器计算接口收发速率，单位为字节每秒，不是互联网带宽测速。排除 Thunderbolt IP、Mac 自身 USB 设备模式和未关联物理硬件的虚拟接口。不会修改网络配置或断开网络。
- Wi-Fi 按系统接口类型识别，不假定它一定是 `en0`；与以太网、蓝牙分别显示，不映射到机身插孔。关闭或未连接的接口仍列出状态，底部仅统计已连接的 Wi-Fi。CoreWLAN 提供的发送链路速率是 Mb/s，与内核字节计数采样得到的实时接收 / 发送速率分别展示；两者都不代表互联网测速。未提供的指标不估算，第三方无线驱动可能只提供部分信息。
- macOS 可能因定位权限而隐藏 SSID / BSSID；网络名称为空时，仍根据系统链路状态与 CoreWLAN 关联信息判断连接。详情中可点击“允许读取网络名称…”请求授权，拒绝后仍可查看连接状态和可用指标。应用不会自动弹出授权请求，不请求地理坐标，也不扫描附近网络。权限可在「系统设置 → 隐私与安全性 → 定位服务」管理。
- 蓝牙信息来自 `system_profiler SPBluetoothDataType`，只保留报告为当前已连接的设备；已配对但未连接的设备不显示。RSSI、电量、固件、服务和连接方式由 macOS 与设备驱动决定，没有提供的数值不估算。耳机左右耳及充电盒电量在系统提供时分别显示。蓝牙设备属于无线连接，不会关联到机身插孔；底部分开统计有线连接与蓝牙设备。此版本不提供蓝牙断开操作，可使用 macOS「系统设置 → 蓝牙」。
- “未建立雷雳链路”不等于物理 USB-C 接口空闲：同一接口仍可能连接普通 USB 或 DisplayPort 设备。系统端口编号不能保证对应机身左右位置。
- 系统按功能枚举有线设备，应用按已关联的物理端口合并展示，一个端口一个入口。扩展坞内的 USB、显示、磁盘和网卡功能保存在同一入口的“功能详情”中；有线连接数量按已连接端口统计，不是功能数量或机身插孔总数。纯供电线缆、模拟耳机口和未枚举的空 USB 接口不在当前检测范围内。

### 一个端口一个入口

例如 USB 3 硬盘接在支持 USB4 的 USB-C 插孔上，列表显示一个设备入口，并标注 `USB 3 · 5 Gb/s`。USB4 / 雷雳端口能力收在同一入口的“端口能力与通道信息”中，不再作为第二个设备，也不会将端口的 40 Gb/s 上限冒充当前连接速率。实际雷雳 / USB4 设备的具体代际未获系统确认时，保留 `Thunderbolt / USB4`，不猜测版本。

同一物理位置切换 USB / 雷雳连接方式时，端口入口使用同一个位置标识。缺少物理映射时按稳定根路径与设备父子关系归并，不仅凭相同端口编号合并；位置仍可手动校准。USB 连接方式按当前报告的链路速率区分，设备描述符中的“USB 协议”是设备规范字段，不能单独证明当前运行速率。

选中扩展坞后，在“功能详情”选择磁盘、网卡或显示功能查看对应指标与操作。类别筛选、搜索和复制详情均保留；复制包含此端口的相关功能及当前协议。诊断 JSON 继续保留底层原始记录，便于排障。

面板打开时，独立的轻量采样任务每约 **1 秒**读取有线 / Wi-Fi 状态、接口流量与可用的整机功率，不等待 `system_profiler`。USB / 磁盘 / 蓝牙等设备扫描每轮完成后间隔 5 秒，雷雳 / 显示器详情缓存 30 秒，也可手动刷新。面板开始关闭时取消两类采样任务及进行中的硬件查询；子进程先终止，未响应时约 1 秒后强制结束。已进入系统调用的轻量读取可能完成当前一次，但关闭后不再更新界面或发起下一次采样。重新打开会重建字节计数基线，首个样本等待下一次采样，不把隐藏期间的流量平均到当前网速。

硬件采集在本地完成，不上传设备标识、序列号或连接信息。未知型号首次尝试从 Apple 更新目录，也可在机身图菜单中手动更新；仅请求固定的 Apple 官方页面与图片，不发送硬件信息作为查询参数。复制详情和诊断 JSON 可能包含序列号、MAC / IP 地址及 SSID / BSSID，分享前请脱敏。

### 整机功率的口径与兼容性

点击机身图中的电源插孔，或顶部“功率”按钮，在当前面板内查看整机负载。没有独立电源插孔或型号未知时也可使用顶部入口。面板打开时每秒读取，关闭后停止，不运行后台功率监测进程。

采集通过公开 IOKit 注册表读取 API，按需读取 `AppleSmartBattery.PowerTelemetryData` 的 `SystemLoad` / `SystemPowerIn`，将 mW 转为 W。前者是系统报告的整机负载，后者是外部电源输入，可能包含电池充电；二者均非插座功率，也不是充电器额定瓦数。数值不能用于定位实际供电插孔。固件刷新频率可能低于界面读取频率。

这些驱动属性并非稳定的公开功率指标接口，依机型和 macOS 版本而异；缺失、格式异常或越界值显示“系统未提供”，不会以 USB 分配功率、电池放电或 CPU / GPU 功率之和冒充整机功率。不调用私有 SMC / IOReport 接口、不运行 `sudo powermetrics`、不请求管理员权限。本机 Mac mini 已取得遥测，其他机型按实际可用数据展示。

## 机身图与通用端口布局

通过 `sysctl hw.model` 精确匹配型号。离线目录来自 Apple 官方七个系列的机型识别页面，当前包含 **148 个型号标识、153 个外观版本**，覆盖 MacBook、MacBook Air、MacBook Pro、iMac / iMac Pro、Mac mini、Mac Studio 和 Mac Pro。官方机型图随应用打包；不同年份共用型号标识、Mac Pro 塔式 / 机架式等情况，会提示从机身图右上角菜单选择实际外观，选择会保存在本机。

应用根据可用资料展示三种视图：

| 可用资料 | 展示方式 |
| --- | --- |
| 已核对照片插孔坐标的 Mac mini | 官方照片上直接叠加可点击插孔 |
| 已知机型及端口布局 | 官方机型照片 + 左侧 / 右侧 / 正面 / 背面等分面端口示意 |
| 未收录、未来机型或缺少布局资料 | 通用机身示意 + 系统连接拓扑，可自行添加实际插孔 |

点击端口筛选关联设备；选择设备会高亮对应位置。**官方机型照片不一定包含端口视角，端口示意与图片分别展示，不在正面照片上虚构插孔。** 接口编号是应用的位置标签，不是 Apple 官方硬件编号；同一面的接口顺序可编辑校准。

机身图只为当前选中的一个端口显示选框，不再为其他已连接或推断位置的端口同时绘制彩色框。连接状态与定位依据在设备详情中查看。打开或重新打开菜单栏面板时不预先聚焦按钮或搜索框；仍可通过 Tab 导航和手动点击输入。

### 任意机型的布局与校准

1. 打开机身图右上角 `···` → **编辑机身端口布局**。
2. 按机身实际情况选择位置和接口类型，添加、删除或调整同一面的顺序，点击“保存布局”。取消编辑不会改变现有布局。
3. 选择设备，在详情位置卡片的滑杆菜单中选择实际插孔；可随时“恢复自动识别”。
4. 使用“恢复默认布局”可移除自定义布局。布局按硬件型号保存，端口使用独立 ID，重排不会改变已有校准。删除端口后，该端口的关联回到系统拓扑。

支持 USB-C、USB-A、HDMI、以太网、音频、电源 / MagSafe、SD / SDXC、Thunderbolt 1 / 2、Mini DisplayPort、DisplayPort、FireWire、DVI、VGA 和未确定接口。扩展坞下游设备共享上级根端口的位置；电源插孔展示整机级遥测，不代表该插孔已被检测为正在供电；模拟音频插孔可能没有可采集状态。

### 自动关联的依据

- **系统拓扑**：读取 USB 祖先的 `UsbIOPort` 和内置 `IOPort`，结合固件报告的位置匹配实际插孔。唯一机身 HDMI / 以太网可直接关联。
- **推断位置**：部分机型按系统编号推断；雷雳报告的接口编号不直接等同 IOPort。只有一台外接显示器且只有一个接口有视频信号时才推断显示器位置，多屏不猜测身份。
- **拓扑接口 · 未定位**：缺少物理位置时，仍显示可点击的系统根接口。Intel Mac 使用根 USB host port 的 IORegistry 路径区分接口，不从 `locationID` 猜机身左右；多个内置网口也保留各自路径。无根路径的设备按本次运行的条目显示。
- **手动校准**：有根路径时按机型和路径保存；没有稳定路径时仅本次运行有效。固件更新、控制器拓扑变化可能使路径改变，此时重新校准。

“未观察到 / 无采集”不代表接口空闲；未选中的端口统一以中性色显示。物理插孔精确定位、实时功耗、任意设备断开能力仍取决于 macOS 与驱动公开的数据；通用布局不会补造系统未提供的信息。应用支持范围为 **macOS 14+ 的 Intel / Apple Silicon Mac**，不是对所有历史系统版本的兼容承诺。

### 目录更新与扩展

机身图菜单 → **从 Apple 更新机型资料**：后台读取七个固定的官方页面，校验 HTTPS 域名、目录结构、图片格式和大小后缓存；失败时保留已有资料。新型号无需发布应用即可取得官方机型图，但新端口布局不从照片自动识别，仍可通过通用布局编辑和校准。

开发者可更新离线快照：

```bash
python3 scripts/sync-apple-models.py
swift test
```

脚本仅使用 Python 标准库和 macOS `sips`，生成 `src/PortsCore/Resources/MacCatalog.json` 与按 URL 哈希命名的缩略图。目录保留每条记录的官方页面、原图 URL 和可获得的技术规格链接。布局模板在 `UniversalPortLayout.swift`，已有照片坐标在 `MachineModel.swift`。新增布局必须核对对应型号和接口数量，未知型号始终保留通用路径。

图片来源与处理说明见 [APPLE-ARTWORK.md](resources/APPLE-ARTWORK.md)。

## 构建与运行

要求 macOS 14+、Xcode 16+ 或包含 Swift 6、swift-format 和 macOS SDK 的 Command Line Tools，以及 Python 3.9+（发布版本校验）。首次解析依赖需要联网，Sparkle 版本由 `Package.resolved` 固定。默认构建当前硬件的原生架构：Apple Silicon 生成纯 arm64 应用，Intel 生成 x86_64 应用；可显式指定 Universal。即使终端在 Apple Silicon 上通过 Rosetta 运行，默认仍选择 arm64。应用声明 `LSRequiresNativeExecution`，Universal 包通过系统启动时也要求使用本机原生架构。Intel / macOS 14 尚未完成实机验证。

```bash
swift package resolve             # 下载已锁定的 Sparkle 依赖
swift build                       # 调试编译
swift test                        # XCTest 核心逻辑、布局和状态保存测试
python3 -m unittest discover -s tests/ReleaseTests -v  # 发布版本校验测试
bash -n scripts/build-app.sh scripts/create-release.sh # Shell 语法检查
bash scripts/build-app.sh         # 当前硬件原生 Release .app、图标、临时签名和 ZIP
bash scripts/build-app.sh release arm64  # 纯 Apple Silicon，无 Intel 可执行代码
bash scripts/build-app.sh release universal  # 可选：同时支持 Intel / Apple Silicon
open build/iPorts.app             # 启动；点击菜单栏连接器图标
```

产物：`build/iPorts.app`、`build/iPorts-macos-<架构>.zip`；Apple Silicon 默认生成 `build/iPorts-macos-arm64.zip`，包含同架构的 Sparkle 与辅助程序。GitHub Release 使用 Universal 包。可将 `.app` 拖入“应用程序”。手动升级时先退出旧版本，再替换原应用；确认运行的是新包，避免从旧副本或旧 ZIP 启动。当前仅使用本地临时签名，面向正式分发仍建议配置 Developer ID 签名和 Apple 公证。未配置开发者签名时不启用 Hardened Runtime 的 Library Validation，以允许加载 Sparkle。

验证 Apple Silicon 安装包：`lipo -archs build/iPorts.app/Contents/MacOS/iPorts` 应只输出 `arm64`；该包不包含 x86_64 切片，也不依赖 Rosetta 或第三方 Intel 库。

```bash
# 只读诊断：输出 JSON，不启动界面、不执行推出；输出包含设备标识和序列号
build/iPorts.app/Contents/MacOS/iPorts --diagnose

# 只读轻量诊断：连续采集 3 个网络 / 功率样本，间隔约 1 秒，不运行 system_profiler
build/iPorts.app/Contents/MacOS/iPorts --diagnose-live

# 开发时启动并展开面板
build/iPorts.app/Contents/MacOS/iPorts --show-popover

# 使用真实设备数据进行离屏布局检查，不显示窗口
build/iPorts.app/Contents/MacOS/iPorts --render-preview build/panel-preview.png
build/iPorts.app/Contents/MacOS/iPorts --render-preview build/network-preview.png --select-kind=network
build/iPorts.app/Contents/MacOS/iPorts --render-preview build/wifi-preview.png --select-kind=wifi
build/iPorts.app/Contents/MacOS/iPorts --render-preview build/power-preview.png --select-system-power
build/iPorts.app/Contents/MacOS/iPorts --render-preview build/model-port-preview.png --select-port=rear.usb-c.4

# 仅用于布局检查：使用指定型号的空设备快照，不改变真实型号或保存设置
build/iPorts.app/Contents/MacOS/iPorts --render-preview build/mini-2024-front.png --preview-model=Mac16,10 --select-port=front.usb-c.1

# 多系列 / 未知型号和布局编辑器的离屏检查；不写入用户偏好
build/iPorts.app/Contents/MacOS/iPorts --render-preview build/macbook-pro-preview.png --preview-model=MacBookPro18,1
build/iPorts.app/Contents/MacOS/iPorts --render-preview build/layout-editor-preview.png --preview-model=MacBookPro18,1 --preview-edit-layout
build/iPorts.app/Contents/MacOS/iPorts --render-preview build/unknown-mac-preview.png --preview-model=Mac999,99

# 联网更新官方目录并测试图片缓存，不启动界面
build/iPorts.app/Contents/MacOS/iPorts --refresh-model-catalog --download-model=MacBookPro18,1

# 格式化与检查
xcrun swift-format format --in-place --recursive Package.swift src tests scripts/create-icon.swift
xcrun swift-format lint --strict --recursive Package.swift src tests scripts/create-icon.swift
```

## 按 tag 自动发布

提交代码并推送 `vMAJOR.MINOR.PATCH` tag 即可发布指定版本，例如：

```bash
git add .
git commit -m "Improve port monitoring"
git push origin main
git tag -a v0.8.1 -m "Release 0.8.1"
git push origin v0.8.1
```

`.github/workflows/release.yml` 在 macOS runner 上校验 tag、检查格式、运行 Swift / Python 测试、构建 Universal 应用、签名更新包及 appcast，然后先创建草稿 Release，上传全部附件后公开发布。版本号同时写入产物的 `CFBundleShortVersionString` 和 `CFBundleVersion`，不需要为发布手动修改源码中的版本。tag 必须是稳定版本，不接受前导零、预发布或构建后缀；为符合 `CFBundleVersion`，最大为 `9999.99.99`。更旧的 tag 可以发布，但不会替换最新版本的更新源；已公开的版本不覆盖，请使用新 tag。失败后的草稿可通过重跑 workflow 完成。

Release 附件包括 `iPorts-<版本>-macos-universal.zip`、已签名的 `appcast.xml`、`SHA256SUMS`。仅在全部构建和签名检查通过后发布，默认分支和 PR 另由 `.github/workflows/ci.yml` 检查。

仓库已配置 Actions Secret `SPARKLE_PRIVATE_KEY`；工作流使用仓库自动提供的 `GITHUB_TOKEN` 发布，不需要个人访问令牌。私钥保存在创建者的 macOS 登录钥匙串中，account 为 `lljxww.iPorts`，不进入 Git。维护者需妥善备份此密钥；丢失后现有用户无法验证新签名，不应随意重新生成。

本地准备同一套发布产物（只生成，不上传）：

```bash
swift package resolve
bash scripts/create-release.sh v0.8.1
# 输出到 build/release-v0.8.1/；默认从登录钥匙串读取签名密钥。
# CI 或另一台机器可通过 SPARKLE_PRIVATE_KEY 环境变量注入同一私钥。
```

如需迁移私钥，使用 Sparkle 的 `generate_keys --account lljxww.iPorts -x <安全路径>` 导出，再通过 `gh secret set SPARKLE_PRIVATE_KEY --repo lljxww/iPorts < <安全路径>` 设置仓库 Secret。导出文件需放在仓库外并限制权限，完成后删除。新建 fork 时需同时修改 `SUFeedURL`、公钥、发布脚本中的默认仓库，并为自己的仓库生成独立密钥。

Sparkle 集成与签名方式参考[官方文档](https://sparkle-project.org/documentation/)。

## 安全推出

选中磁盘所在端口；若有多个功能，在“功能详情”中选择目标存储设备，再点击“安全推出磁盘”并在面板内确认。应用使用 Disk Arbitration 卸载整盘全部卷，再请求推出；正在使用的卷可被系统拒绝，不会强制卸载。推出不是断电，部分设备重新使用前需拔插。

操作前和卸载后均重新核对 BSD 名称、IORegistry ID、外接属性、整盘属性、物理磁盘祖先，防止设备拔插后 `diskN` 被复用。内部盘、分区、磁盘镜像和身份不明的设备不能操作。若卸载成功但推出失败，提示会明确说明磁盘可能已卸载；可在“磁盘工具”中检查并重新挂载。

没有通用的公开 API 能安全断开所有键盘、声卡、显示器、集线器，或切断任意物理端口供电。当前版本仅对外接存储提供逻辑断开，不调用私有 API、不安装驱动、不请求管理员权限。

## 结构与维护

```text
src/PortsCore/     数据模型、IOKit / SystemConfiguration / CoreWLAN 采集、型号与位置映射、速率计算、安全推出
                  LiveMetricsReader 独立轻量采样；SystemPowerReader 读取可用整机遥测
                  Resources/MacCatalog.json + ModelArtwork/ 保存官方型号目录和图片
src/iPorts/        菜单栏入口、面板、主线程状态管理、按需 Wi-Fi 名称权限、Sparkle 更新入口与弹窗焦点
tests/            XCTest：速率、解析、推出校验、目录、拓扑、布局、偏好与弹窗焦点；Python 发布版本测试
resources/        应用 Info.plist（LSUIElement=true）
scripts/          打包 / 签名更新源 / 版本校验脚本与原生图标生成器
.github/workflows/ 持续集成和 tag 发布
```

硬件查询在独立 actor 中执行；UI 和 Disk Arbitration 回调使用主线程。错误显示在面板中，关键系统错误写入统一日志，可在“控制台”按 `local.iports.app` 过滤。每种硬件的字段取决于 macOS 版本与驱动，新增解析字段应补充缺失值和异常输入测试。

实机验证：连接 / 拔下 USB 设备，等待下一轮设备扫描更新；点击机身图插孔确认筛选和高亮，必要时按实际插孔校准并重启确认保存；连接显示器后手动刷新，多屏时检查不产生未经核对的自动位置。连接可用于测试的外接盘，确认复制文件时读写速率变化，再保存文件并尝试安全推出。对实际推出的验证应使用可安全卸载的测试介质。

Wi-Fi 验证：在「无线网络」中查看接口、信号、链路速率与实时收发；未授权时应能识别已连接状态。点击权限按钮并允许后检查网络名称；拒绝时应继续显示其他指标。手动切换网络或关闭 / 打开 Wi-Fi，确认状态更新且不残留旧 SSID、链路速率与 IP。应用自身不修改无线连接。

实时与节能验证：打开面板并传输文件，确认网速约每秒更新；查看“功率”，确认读取时间持续变化。关闭面板后不应继续发起采样；快速关闭再打开时先建立新基线，旧查询结果不应覆盖新状态。自动化测试覆盖慢扫描不阻塞采样、关闭与重复开关、手动刷新取消、迟到结果隔离、子进程取消及功率缺失值。

参考：[Apple Disk Arbitration 操作流程](https://developer.apple.com/library/archive/documentation/DriversKernelHardware/Conceptual/DiskArbitrationProgGuide/ManipulatingDisks/ManipulatingDisks.html)、[IOKit 磁盘累计写入字节](https://developer.apple.com/documentation/iokit/kioblockstoragedriverstatisticsbyteswrittenkey)。USB 功率字段的含义以 SDK 的 `IOKit/usb/IOUSBHostFamilyDefinitions.h` 为准。

## 许可

本项目原创代码使用 [MIT License](LICENSE)。Apple 图片及商标不包含在 MIT 授权中，来源与权利说明见 [APPLE-ARTWORK.md](resources/APPLE-ARTWORK.md)。Sparkle 使用其自身的 BSD 类许可证，打包时随应用附带 `SPARKLE-LICENSE.txt`。
