import AppKit
import PortsCore
import SwiftUI

private enum Palette {
    static let background = Color(red: 0.055, green: 0.067, blue: 0.083)
    static let surface = Color(red: 0.085, green: 0.10, blue: 0.12)
    static let raised = Color(red: 0.12, green: 0.14, blue: 0.16)
    static let accent = Color(red: 0.39, green: 0.89, blue: 0.75)
    static let secondary = Color(red: 0.57, green: 0.63, blue: 0.68)
    static let line = Color.white.opacity(0.075)
}

struct PortsPanel: View {
    @ObservedObject var store: PortStore
    var updater: AppUpdater? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            if store.showModelMap {
                ModelMapView(store: store)
            } else {
                summary
            }
            filters
            Rectangle().fill(Palette.line).frame(height: 1)
            HStack(spacing: 0) {
                deviceList.frame(width: 245)
                Rectangle().fill(Palette.line).frame(width: 1)
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.frame(maxHeight: .infinity)
            footer
        }
        .frame(width: PanelLayout.width, height: PanelLayout.height)
        .background(Palette.background)
        .foregroundStyle(Color.white.opacity(0.93))
        .font(.system(size: 12))
        .preferredColorScheme(.dark)
        .tint(Palette.accent)
        .onChange(of: store.selected?.id) { _, _ in store.pendingEjection = nil }
    }

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 11).fill(Palette.accent.opacity(0.12)).frame(
                    width: 40, height: 40)
                Image(systemName: "cable.connector.horizontal").font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Palette.accent)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("iPorts").font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text("端口一目了然").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                }
                Text("外接设备与连接详情").font(.system(size: 11)).foregroundStyle(Palette.secondary)
            }
            Spacer()
            Button {
                store.selectSystemPower()
            } label: {
                Label("功率", systemImage: "bolt").font(.system(size: 10)).padding(7)
                    .background(Palette.raised, in: RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain).foregroundStyle(Palette.secondary)
                .help("查看整机功率；面板打开时每秒读取，关闭后暂停")
                .accessibilityLabel("查看整机功率")
            Button {
                store.showModelMap.toggle()
            } label: {
                Label("机身图", systemImage: "macmini").font(.system(size: 10))
                    .padding(7).background(
                        store.showModelMap ? Palette.accent.opacity(0.1) : Palette.raised,
                        in: RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain).foregroundStyle(store.showModelMap ? Palette.accent : Palette.secondary)
                .help("显示或收起机身端口图")
            HStack(spacing: 5) {
                Circle().fill(Palette.accent).frame(width: 5, height: 5)
                Text(store.isVisible ? "实时 · 1 秒" : "已暂停").font(.system(size: 10, weight: .medium))
            }.foregroundStyle(Palette.accent).padding(.horizontal, 9).padding(.vertical, 6)
                .background(Palette.accent.opacity(0.08), in: Capsule())
            Button {
                Task { await store.refresh(forceDetails: true) }
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 13)).frame(width: 28, height: 28)
            }.buttonStyle(.plain).foregroundStyle(Palette.secondary).disabled(store.isRefreshing)
                .help("刷新所有设备信息").accessibilityLabel("刷新设备")
        }.padding(.horizontal, 20).padding(.top, 19).padding(.bottom, 17)
    }

    private var summary: some View {
        HStack(spacing: 6) {
            ForEach(DeviceKind.allCases, id: \.self) { kind in
                Button {
                    store.filter = store.filter == kind ? nil : kind
                    store.selectedPortID = nil
                    store.showsSystemPower = false
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Image(systemName: kind.symbol).font(.system(size: 14)).foregroundStyle(tint(kind))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(kind == .thunderbolt ? "雷雳 / USB4" : kind.title)
                                .lineLimit(1).minimumScaleFactor(0.75)
                                .font(.system(size: 10)).foregroundStyle(Palette.secondary)
                            Text("\(store.count(kind))").font(
                                .system(size: 20, weight: .medium, design: .rounded)
                            ).monospacedDigit()
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(
                        .vertical, 10
                    )
                    .background(
                        store.filter == kind ? tint(kind).opacity(0.09) : Palette.surface,
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10).stroke(
                            store.filter == kind ? tint(kind).opacity(0.4) : Palette.line, lineWidth: 1))
                }.buttonStyle(.plain)
            }
        }.padding(.horizontal, 20).padding(.bottom, 17)
    }

    private var filters: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(
                    Palette.secondary)
                TextField("搜索设备、类型或速率", text: $store.search).textFieldStyle(.plain).font(.system(size: 11))
                    .accessibilityIdentifier("deviceSearch")
                if !store.search.isEmpty {
                    Button {
                        store.search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(Palette.secondary).accessibilityLabel("清空搜索")
                }
            }.padding(9).background(Palette.surface, in: RoundedRectangle(cornerRadius: 7))
            Button {
                store.filter = nil
                store.search = ""
                store.selectedPortID = nil
                store.showsSystemPower = false
            } label: {
                Text(store.selectedModelPort?.label ?? store.filter?.title ?? "全部设备").font(
                    .system(size: 10, weight: .medium)
                )
                .padding(.horizontal, 9).padding(.vertical, 8)
                .background(Palette.raised, in: RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain).help("显示全部设备")
        }.padding(.horizontal, 20).padding(.bottom, 13)
    }

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("端口与设备").font(.system(size: 10, weight: .semibold))
                Spacer()
                Text("\(store.visibleConnections.count) 项").font(.system(size: 10)).monospacedDigit()
            }.foregroundStyle(Palette.secondary).padding(.horizontal, 15).padding(.top, 15).padding(
                .bottom, 9)
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(store.visibleConnections) { connection in
                        connectionRow(connection)
                    }
                    if store.visibleConnections.isEmpty {
                        VStack(spacing: 8) {
                            if !store.hasScanned { ProgressView().controlSize(.small) }
                            Text(!store.hasScanned ? "正在发现设备…" : "没有匹配的设备")
                                .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                        }.padding(.vertical, 30).frame(maxWidth: .infinity)
                    }
                }.padding(.horizontal, 8).padding(.bottom, 10)
            }
            HStack(spacing: 5) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                Text("有线按端口分组，无线独立显示")
            }.font(.system(size: 9)).foregroundStyle(Palette.secondary.opacity(0.8)).padding(12)
        }.background(Palette.surface.opacity(0.35))
    }

    @ViewBuilder private func connectionRow(_ connection: PortConnection) -> some View {
        if let device = connection.primary {
            let selected = store.selectedConnection?.id == connection.id
            let port = store.modelProfile?.ports.first { $0.id == connection.portID }
            Button {
                store.selectConnection(connection)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: device.kind.symbol).font(.system(size: 16)).foregroundStyle(
                        tint(device.kind)
                    )
                    .frame(width: 30, height: 32).background(
                        tint(device.kind).opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(device.name).font(.system(size: 11, weight: .medium)).lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(
                            device.kind.isWireless ? "无线连接 · \(device.subtitle)" : port?.title ?? "机身位置未确定"
                        ).font(.system(size: 9)).foregroundStyle(
                            Palette.secondary
                        ).lineLimit(
                            1)
                        HStack(spacing: 4) {
                            Circle().fill(connection.isConnected ? Palette.accent : Palette.secondary).frame(
                                width: 4, height: 4)
                            Text(connection.connectionDescription).font(
                                .system(size: 9)
                            )
                            .foregroundStyle(Palette.secondary).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                            .foregroundStyle(
                                Palette.accent
                            ).padding(.top, 11)
                    }
                }.padding(.horizontal, 9).padding(.vertical, 10).frame(
                    maxWidth: .infinity, alignment: .leading
                )
                .background(
                    selected ? Palette.accent.opacity(0.07) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8).stroke(
                        selected ? Palette.accent.opacity(0.22) : Color.clear, lineWidth: 1)
                )
                .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("connection-\(connection.id)")
        }
    }

    @ViewBuilder private var detail: some View {
        if store.showsSystemPower || store.selectedModelPort?.connector == .power {
            systemPowerDetail
        } else if let device = store.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    detailHeading(device)
                    if let connection = store.selectedConnection {
                        connectionDetails(connection, selected: device)
                    }
                    if device.kind == .wifi, device.linkActive == true,
                        device.fields.contains(where: {
                            $0.label == "网络名称 (SSID)" && $0.value.hasPrefix("系统未提供")
                        })
                    {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("macOS 可能因定位权限隐藏网络名称和接入点地址；不影响连接状态与流量识别。")
                                .font(.system(size: 10)).foregroundStyle(Palette.secondary)
                            Button("允许读取网络名称…") { store.requestWiFiIdentityAccess() }
                                .controlSize(.small)
                        }
                    }
                    location(device)
                    metrics(device)
                    if let parentID = device.parentID,
                        let parent = store.snapshot.devices.first(where: { $0.id == parentID })
                    {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.turn.down.right")
                            Text("经由 \(parent.name)")
                        }.font(.system(size: 10)).foregroundStyle(Palette.secondary)
                    }
                    ForEach(groups(device), id: \.self) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(group).font(.system(size: 10, weight: .semibold)).foregroundStyle(
                                Palette.secondary)
                            VStack(spacing: 0) {
                                ForEach(device.fields.filter { $0.group == group }) { field in
                                    HStack(alignment: .top, spacing: 12) {
                                        Text(field.label).foregroundStyle(Palette.secondary).frame(
                                            width: 91, alignment: .leading)
                                        Text(field.value).frame(maxWidth: .infinity, alignment: .trailing)
                                            .multilineTextAlignment(.trailing)
                                            .textSelection(.enabled)
                                    }.font(.system(size: 10)).padding(.vertical, 7)
                                    if field.id != device.fields.last(where: { $0.group == group })?.id {
                                        Rectangle().fill(Palette.line).frame(height: 1)
                                    }
                                }
                            }
                        }
                    }
                    actions(device)
                }.padding(19)
            }
        } else if let connection = store.selectedConnection, !connection.capabilities.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(store.selectedModelPort?.title ?? "端口信息").font(.system(size: 19, weight: .semibold))
                    connectionDetails(connection, selected: nil)
                    Text(
                        connection.devices.isEmpty
                            ? "尚未观察到此端口的已连接设备；端口能力不代表当前正在使用的协议。"
                            : "此端口的设备被当前筛选隐藏，可清除筛选或选择功能查看详情。"
                    ).font(.system(size: 11))
                        .foregroundStyle(Palette.secondary)
                }.padding(19)
            }
        } else {
            VStack(spacing: 13) {
                Image(systemName: "cable.connector.horizontal").font(.system(size: 33, weight: .light))
                    .foregroundStyle(Palette.accent.opacity(0.55))
                Text(store.selectedModelPort?.title ?? (store.hasScanned ? "连接，从这里看见" : "正在读取系统端口"))
                    .font(.system(size: 15, weight: .medium))
                Text(
                    store.selectedModelPort != nil
                        ? "未观察到此接口的关联设备。\n电源、模拟音频和纯供电连接可能无法采集，\n此状态不代表物理接口空闲。"
                        : store.hasScanned ? "连接外接设备或无线网络，\n即可查看系统提供的连接信息。" : "首次读取设备信息可能需要数秒。"
                )
                .font(.system(size: 11)).foregroundStyle(Palette.secondary).multilineTextAlignment(
                    .center
                ).lineSpacing(5)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var systemPowerDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("电源 · 系统遥测").font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Palette.accent)
                        Text("整机功率").font(.system(size: 19, weight: .semibold))
                        Text(store.isVisible ? "每秒读取 · 关闭面板后暂停" : "采样已暂停")
                            .font(.system(size: 10)).foregroundStyle(Palette.secondary)
                    }
                    Spacer()
                    Button {
                        store.copySystemPower()
                    } label: {
                        Image(systemName: "doc.on.doc").frame(width: 28, height: 28)
                            .background(Palette.raised, in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain).disabled(store.snapshot.systemPower == nil)
                        .accessibilityLabel("复制整机功率信息")
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("整机负载 · 系统报告值").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                    Text(
                        store.snapshot.systemPower?.systemWatts.map { String(format: "%.2f W", $0) }
                            ?? "系统未提供"
                    )
                    .font(.system(size: 30, weight: .medium, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Palette.accent)
                    Text("整机级遥测，非插座实测功率；数值精度与固件更新频率取决于机型和系统。")
                        .font(.system(size: 10)).foregroundStyle(Palette.secondary).lineSpacing(3)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 9))
                if let power = store.snapshot.systemPower {
                    powerRow("外部电源", power.externalConnected.map { $0 ? "已连接" : "未连接" } ?? "系统未提供")
                    powerRow("外部输入功率", power.inputWatts.map { String(format: "%.2f W", $0) } ?? "系统未提供")
                    powerRow("读取时间", power.sampledAt.formatted(date: .omitted, time: .standard))
                    if let reason = power.unavailableReason {
                        Text(reason).font(.system(size: 10)).foregroundStyle(Palette.secondary)
                    }
                } else {
                    Text(store.isVisible ? "正在读取可用的功率遥测…" : "打开面板后读取可用的功率遥测。")
                        .font(.system(size: 10)).foregroundStyle(Palette.secondary)
                }
                Text("外部输入可能包含电池充电；充电器额定功率、USB 分配功率和电池功率均不作为整机功率的替代。此信息不能用于确定正在供电的是哪个插孔。")
                    .font(.system(size: 10)).foregroundStyle(Palette.secondary).lineSpacing(4)
                Divider()
                Text("数据来源：系统电源遥测。无需管理员权限；当前机型可能仅提供部分指标。")
                    .font(.system(size: 9)).foregroundStyle(Palette.secondary).lineSpacing(4)
            }.padding(19).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func powerRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(title).foregroundStyle(Palette.secondary)
            Spacer(minLength: 0)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.system(size: 11))
    }

    private func connectionDetails(_ connection: PortConnection, selected: PortDevice?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("当前连接方式 / 协议").font(.system(size: 9)).foregroundStyle(Palette.secondary)
            Text(connection.connectionDescription).font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.accent).textSelection(.enabled)
            if connection.devices.count > 1 {
                Menu {
                    ForEach(connection.devices) { function in
                        Button("\(function.kind.title) · \(function.name)") {
                            store.selectFunction(function, in: connection)
                        }
                    }
                } label: {
                    Label(
                        "功能详情：\(selected?.name ?? "选择功能")（\(connection.devices.count) 项）",
                        systemImage: "square.stack.3d.up"
                    )
                    .font(.system(size: 10))
                }.menuStyle(.borderlessButton)
                    .accessibilityLabel("选择此端口下的设备功能")
            }
            if !connection.capabilities.isEmpty {
                DisclosureGroup(connection.capabilityLocationInferred ? "端口能力与通道信息（位置推断）" : "端口能力与通道信息") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("以下为端口支持能力与雷雳通道状态，不代表当前连接协议。").foregroundStyle(Palette.secondary)
                        ForEach(connection.capabilities) { capability in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(capability.name).fontWeight(.medium)
                                ForEach(capability.fields) { field in
                                    Text("\(field.label)：\(field.value)").foregroundStyle(Palette.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }.padding(.top, 6)
                }.font(.system(size: 9))
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.line, lineWidth: 1))
    }

    @ViewBuilder private func location(_ device: PortDevice) -> some View {
        if store.modelProfile != nil, !device.isInternal, !device.kind.isWireless {
            let association = store.associations[device.id]
            let port = store.modelProfile?.ports.first { $0.id == association?.portID }
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Image(systemName: "location")
                    Text(port?.title ?? "机身位置未确定").fontWeight(.medium)
                    Spacer(minLength: 0)
                    if let association {
                        Text(association.confidence.title).font(.system(size: 9))
                            .foregroundStyle(association.confidence == .inferred ? .orange : Palette.accent)
                    }
                    Menu {
                        if store.calibrationPorts(for: device).isEmpty {
                            Button("先添加实际机身端口…") { store.beginLayoutEditing() }
                        }
                        ForEach(store.calibrationPorts(for: device)) { candidate in
                            Button(candidate.title) { store.calibrate(device, portID: candidate.id) }
                        }
                        Divider()
                        Button("恢复自动识别") { store.calibrate(device, portID: nil) }
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .menuStyle(.borderlessButton).fixedSize().help("按实际插孔校准位置")
                    .accessibilityLabel("校准机身端口位置")
                }
                Text(association?.explanation ?? "系统未提供可直接定位的机身路径，可按实际插孔手动校准。无稳定端口路径时，校准仅在本次运行有效。")
                    .font(.system(size: 9)).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
            }.font(.system(size: 10)).padding(10)
                .background(Palette.accent.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line, lineWidth: 1))
        }
    }

    private func detailHeading(_ device: PortDevice) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                Text(device.kind.title.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(1.4)
                    .foregroundStyle(tint(device.kind))
                Text(device.name).font(.system(size: 19, weight: .semibold)).fixedSize(
                    horizontal: false, vertical: true
                ).textSelection(.enabled)
                Text(
                    device.isPort && device.kind == .thunderbolt
                        ? "系统枚举的雷雳端口" : device.kind.isNetwork ? device.subtitle : "已连接 · \(device.subtitle)"
                )
                .font(.system(size: 10)).foregroundStyle(Palette.secondary)
            }
            Spacer(minLength: 0)
            Button {
                store.copySelected()
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 12)).frame(width: 28, height: 28)
                    .background(Palette.raised, in: RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain).help("复制详情（包含序列号等设备标识）").accessibilityLabel("复制设备详情")
        }
    }

    private func metrics(_ device: PortDevice) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 7) {
                    Label(
                        device.kind == .display
                            ? "显示模式"
                            : device.kind == .bluetooth ? "连接方式" : device.kind == .wifi ? "发送链路速率" : "连接速率",
                        systemImage: device.kind == .bluetooth
                            ? "antenna.radiowaves.left.and.right" : "arrow.left.arrow.right"
                    )
                    .font(.system(size: 9)).foregroundStyle(Palette.secondary)
                    Text(device.connection).font(
                        .system(size: device.kind == .display ? 12 : 16, weight: .medium, design: .rounded)
                    )
                    .foregroundStyle(tint(device.kind)).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Rectangle().fill(Palette.line).frame(width: 1, height: 37)
                VStack(alignment: .leading, spacing: 7) {
                    Label(
                        device.kind == .bluetooth ? "设备电量" : device.kind == .wifi ? "信号强度" : "分配功率",
                        systemImage: device.kind == .bluetooth
                            ? "battery.75" : device.kind == .wifi ? "wifi" : "bolt"
                    ).font(.system(size: 9)).foregroundStyle(
                        Palette.secondary)
                    Text(
                        device.kind == .bluetooth
                            ? bluetoothBatterySummary(device)
                            : device.kind == .wifi
                                ? (device.fields.first { $0.label == "信号强度 (RSSI)" }?.value ?? "未提供")
                                : device.power?.formatted ?? "未提供"
                    ).font(
                        .system(size: 16, weight: .medium, design: .rounded)
                    )
                    .foregroundStyle(
                        device.kind == .bluetooth
                            ? (bluetoothBatterySummary(device) == "未提供" ? Palette.secondary : Palette.accent)
                            : device.power != nil ? Palette.accent : Palette.secondary)
                }.frame(width: 108, alignment: .leading)
            }
            Rectangle().fill(Palette.line).frame(height: 1)
            if device.kind == .storage || device.kind.isNetwork {
                if let rate = device.transfer {
                    HStack(spacing: 13) {
                        Label(PortFormatting.rate(rate.readBytesPerSecond), systemImage: "arrow.down")
                        Label(PortFormatting.rate(rate.writeBytesPerSecond), systemImage: "arrow.up")
                        Spacer(minLength: 0)
                        Text(rate.isActive ? (device.kind.isNetwork ? "传输中" : "读写中") : "本次采样空闲")
                            .foregroundStyle(
                                rate.isActive ? Palette.accent : Palette.secondary)
                    }.font(.system(size: 9)).monospacedDigit()
                } else {
                    Text("\(device.kind.isNetwork ? "网卡收发" : "磁盘读写")：等待下一次采样或驱动未公开统计").font(
                        .system(size: 9)
                    ).foregroundStyle(Palette.secondary)
                }
            }
            Text(
                device.kind == .bluetooth
                    ? "蓝牙连接状态与电量为系统最近报告值；macOS 未提供通用的实时功耗或传输速率。"
                    : device.kind == .wifi
                        ? "发送链路速率不是实际吞吐量；↓ 接收 / ↑ 发送为接口字节速率，包含本地流量，不能代表互联网网速。"
                        : device.kind.isNetwork
                            ? "↓ 接收 / ↑ 发送，单位为字节每秒；网卡流量不等于互联网速度。"
                            : "分配功率按 5 V 换算，并非实时功耗或 USB PD 协商功率。\(device.kind == .storage ? "速率为磁盘 I/O，非整条总线流量。" : "链路速率并非实际吞吐量。")"
            )
            .font(.system(size: 9)).foregroundStyle(Palette.secondary).lineSpacing(3).fixedSize(
                horizontal: false, vertical: true)
        }.padding(12).background(Palette.surface, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.line, lineWidth: 1))
    }

    @ViewBuilder private func actions(_ device: PortDevice) -> some View {
        if let disk = device.disk, disk.canEject {
            VStack(alignment: .leading, spacing: 9) {
                if store.pendingEjection == device.id {
                    Text("将卸载此磁盘的全部卷并安全推出。请先保存文件并停止读写。")
                        .font(.system(size: 10)).foregroundStyle(.orange).lineSpacing(3)
                    HStack {
                        Button("取消") { store.pendingEjection = nil }.buttonStyle(.bordered)
                        Button("确认安全推出") { store.eject(device) }.buttonStyle(.borderedProminent).tint(
                            Palette.accent)
                    }.controlSize(.small)
                } else {
                    Button {
                        store.pendingEjection = device.id
                    } label: {
                        HStack(spacing: 7) {
                            if store.ejectingID == device.id {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "eject")
                            }
                            Text(store.ejectingID == device.id ? "正在安全推出…" : "安全推出磁盘")
                        }.font(.system(size: 11, weight: .medium)).padding(.horizontal, 13).padding(
                            .vertical, 9
                        )
                        .background(Palette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).foregroundStyle(Palette.accent).disabled(store.ejectingID != nil)
                }
                Text("安全推出属于逻辑卸载，不会关闭物理端口供电。")
                    .font(.system(size: 9)).foregroundStyle(Palette.secondary)
            }
        } else {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "info.circle")
                Text(
                    device.kind == .wifi
                        ? "Wi-Fi 连接不代表互联网可达；链路速率不是网速测试。可在 macOS「系统设置 → Wi-Fi」管理连接。"
                        : device.kind == .bluetooth
                            ? "此版本只查看蓝牙状态。如需断开，请在 macOS「系统设置 → 蓝牙」中操作。"
                            : device.kind == .usb
                                ? "macOS 未提供此类 USB 设备通用的安全断开接口。如有磁盘，可在上方「功能详情」中选择存储后推出。"
                                : "此项仅提供状态查看；macOS 未提供可用的安全断开接口。"
                )
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }.font(.system(size: 9)).foregroundStyle(Palette.secondary)
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            if let message = store.message {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: store.messageIsError ? "exclamationmark.triangle" : "checkmark.circle")
                    Text(message).lineLimit(3)
                    Spacer(minLength: 0)
                    Button {
                        store.message = nil
                    } label: {
                        Image(systemName: "xmark")
                    }.buttonStyle(.plain).accessibilityLabel("关闭提示")
                }.font(.system(size: 10)).foregroundStyle(
                    store.messageIsError ? Color.orange : Palette.accent
                )
                .padding(10).background(Palette.surface)
            }
            if let notice = (store.liveNotices + store.snapshot.notices).first {
                Text(notice).font(.system(size: 9)).foregroundStyle(.orange).lineLimit(2).padding(
                    .horizontal, 15
                ).padding(.vertical, 7)
            }
            Rectangle().fill(Palette.line).frame(height: 1)
            HStack(spacing: 8) {
                Circle().fill(Palette.accent.opacity(0.8)).frame(width: 4, height: 4)
                Text(
                    store.hasScanned
                        ? "\(store.connectionCountDescription) · 更新于 \(store.snapshot.capturedAt.formatted(date: .omitted, time: .standard))"
                        : "首次扫描中…"
                )
                .monospacedDigit()
                Spacer()
                Toggle("内置 USB", isOn: $store.showInternal).toggleStyle(.checkbox).controlSize(.mini)
                Text("·").foregroundStyle(Palette.secondary.opacity(0.4))
                if let updater {
                    AppUpdateMenu(updater: updater).disabled(store.ejectingID != nil)
                    Text("·").foregroundStyle(Palette.secondary.opacity(0.4))
                }
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.plain).disabled(store.ejectingID != nil).help("退出 iPorts").accessibilityLabel(
                    "退出 iPorts")
            }.font(.system(size: 9)).foregroundStyle(Palette.secondary).padding(.horizontal, 17).padding(
                .vertical, 11)
        }
    }

    private func groups(_ device: PortDevice) -> [String] {
        var seen = Set<String>()
        return device.fields.map(\.group).filter { seen.insert($0).inserted }
    }

    private func bluetoothBatterySummary(_ device: PortDevice) -> String {
        let batteries = device.fields.filter { $0.group == "电池" && $0.value.hasSuffix("%") }
        return batteries.first { $0.label == "设备电量" || $0.label == "设备电量（主）" }?.value
            ?? (batteries.isEmpty ? "未提供" : "见电池详情")
    }

    private func tint(_ kind: DeviceKind) -> Color {
        switch kind {
        case .usb: Palette.accent
        case .thunderbolt: Color(red: 0.81, green: 0.74, blue: 0.99)
        case .display: Color(red: 0.52, green: 0.74, blue: 0.98)
        case .storage: Color(red: 0.98, green: 0.76, blue: 0.48)
        case .network: Color(red: 0.48, green: 0.83, blue: 0.95)
        case .wifi: Color(red: 0.48, green: 0.83, blue: 0.95)
        case .bluetooth: Color(red: 0.62, green: 0.66, blue: 0.98)
        }
    }
}
