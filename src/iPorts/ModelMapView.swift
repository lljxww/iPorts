import AppKit
import PortsCore
import SwiftUI

enum PanelLayout {
    static let width: CGFloat = 720
    static var height: CGFloat { min(780, max(600, (NSScreen.main?.visibleFrame.height ?? 860) - 70)) }
}

struct ModelMapView: View {
    @ObservedObject var store: PortStore
    private let accent = Color(red: 0.39, green: 0.89, blue: 0.75)

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: store.modelProfile?.family.symbol ?? "desktopcomputer").foregroundStyle(
                    accent)
                Text(store.modelProfile?.name ?? "正在识别 Mac 型号…")
                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
                if let identifier = store.snapshot.machine?.identifier,
                    store.modelProfile?.name.contains(identifier) == false
                {
                    Text(identifier).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let profile = store.modelProfile {
                    Link(destination: profile.sourceURL) { Label("Apple 资料", systemImage: "arrow.up.right") }
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Menu {
                    if store.modelVariants.count > 1 {
                        Section("选择实际外观 / 年份") {
                            ForEach(store.modelVariants) { variant in
                                Button(variant.name) { store.chooseModelVariant(variant.id) }
                            }
                        }
                    }
                    Button("编辑机身端口布局") { store.beginLayoutEditing() }
                    if store.customLayout != nil { Button("恢复默认布局") { store.restoreDefaultLayout() } }
                    Divider()
                    Button("从 Apple 更新机型资料") { store.updateModelCatalog() }.disabled(
                        store.isCatalogRefreshing)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("机型资料和端口布局")
            }
            if store.modelVariants.count > 1, store.modelVariantID == nil {
                Text("此型号标识对应多个年份或外观，请在右上角菜单中选择实际版本。")
                    .font(.system(size: 9)).foregroundStyle(.orange)
            }
            if let profile = store.modelProfile,
                let diagram = profile.diagrams.first(where: { $0.id == store.modelDiagramID })
                    ?? profile.diagrams.first
            {
                if store.editingLayout {
                    LayoutEditorView(store: store)
                } else {
                    HStack(spacing: 6) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(profile.diagrams) { view in
                                    Button {
                                        store.modelDiagramID = view.id
                                        store.selectedPortID = nil
                                    } label: {
                                        Text(view.title).font(.system(size: 9)).padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(
                                                diagram.id == view.id ? Color.white.opacity(0.09) : .clear,
                                                in: Capsule())
                                    }.buttonStyle(.plain).foregroundStyle(
                                        diagram.id == view.id ? .white : .secondary)
                                }
                            }
                        }.frame(height: 24)
                        Text("点击端口查看设备").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    if diagram.isSchematic {
                        schematic(profile: profile, diagram: diagram).id(store.artworkRevision)
                    } else {
                        artwork(profile: profile, diagram: diagram)
                    }
                    HStack(spacing: 12) {
                        legend("当前选中", color: accent)
                        Text("连接状态与定位依据见设备详情").foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if store.selectedPortID != nil {
                            Button("显示全部") { store.selectedPortID = nil }.buttonStyle(.plain).foregroundStyle(
                                accent)
                        }
                    }
                    .font(.system(size: 9))
                }
                if let message = store.catalogMessage {
                    HStack(alignment: .top, spacing: 5) {
                        if store.isCatalogRefreshing { ProgressView().controlSize(.mini) }
                        Text(message).lineLimit(2)
                        Spacer(minLength: 0)
                        Button {
                            store.catalogMessage = nil
                        } label: {
                            Image(systemName: "xmark")
                        }.buttonStyle(.plain)
                    }.font(.system(size: 9)).foregroundStyle(.secondary)
                }
            } else if store.hasScanned {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                    Text("已识别型号，尚无经过核对的官方端口图；保留设备列表，避免使用其他机型的布局。")
                        .fixedSize(horizontal: false, vertical: true)
                    if let url = URL(string: "https://support.apple.com/en-us/109523") {
                        Link("Apple 端口说明", destination: url)
                    }
                }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.vertical, 10)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text("正在读取机身端口拓扑…")
                }
                .font(.system(size: 10)).foregroundStyle(.secondary).padding(.vertical, 15)
            }
        }.padding(12)
            .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.065), lineWidth: 1))
            .padding(.horizontal, 20).padding(.bottom, 10)
    }

    private func schematic(profile: MacModelProfile, diagram: ModelDiagram) -> some View {
        HStack(spacing: 14) {
            VStack(spacing: 5) {
                if let image = ModelArtwork.overview(profile: profile) {
                    Image(nsImage: image).resizable().scaledToFit().frame(width: 135, height: 75)
                    Text("Apple 官方机型图").font(.system(size: 8)).foregroundStyle(.secondary)
                } else {
                    Image(systemName: profile.family.symbol).font(.system(size: 48, weight: .ultraLight))
                        .foregroundStyle(accent.opacity(0.65)).frame(width: 135, height: 75)
                    Text("通用机身示意").font(.system(size: 8)).foregroundStyle(.secondary)
                }
            }.frame(width: 135)
            Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1)
            VStack(alignment: .leading, spacing: 8) {
                Text(profile.layoutDescription).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(
                    2)
                if store.ports(in: diagram).isEmpty {
                    Text("尚未枚举接口。可编辑布局添加实际插孔，或接入设备后刷新。").font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("编辑机身布局") { store.beginLayoutEditing() }.buttonStyle(.plain).font(
                        .system(size: 10)
                    ).foregroundStyle(accent)
                } else {
                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(spacing: 8) {
                            ForEach(store.ports(in: diagram)) { port in
                                schematicPort(port)
                            }
                        }.padding(.vertical, 4)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(height: 112).padding(.vertical, 3)
    }

    private func schematicPort(_ port: ModelPort) -> some View {
        let selected = store.isSelectedPort(port)
        let connected = store.hasConnectedDevice(at: port.id)
        let attached = store.devices(at: port.id)
        let color: Color = selected ? accent : .gray
        return Button {
            store.selectPort(port)
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(color.opacity(selected ? 0.18 : 0.06)).frame(
                        width: 57, height: 36)
                    RoundedRectangle(cornerRadius: port.connector == .usbC ? 7 : 2)
                        .fill(Color.black.opacity(0.45)).frame(
                            width: port.connector == .audio || port.connector == .power ? 12 : 28,
                            height: port.connector == .sd ? 4 : 10
                        )
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(color.opacity(0.8), lineWidth: 1))
                }.overlay(
                    RoundedRectangle(cornerRadius: 7).stroke(
                        selected ? accent : .clear, lineWidth: 1.5))
                Text(port.label).font(.system(size: 8)).lineLimit(1)
                Text(port.isLogical ? "未定位置" : connected ? "已关联" : "未观察到").font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }.foregroundStyle(color).frame(width: 65)
        }.buttonStyle(.plain).help(port.title + " · " + attached.map(\.name).joined(separator: "、"))
            .accessibilityLabel(port.title).accessibilityIdentifier("model-port-\(port.id)")
    }

    @ViewBuilder private func artwork(profile: MacModelProfile, diagram: ModelDiagram) -> some View {
        if let image = ModelArtwork.image(profile: profile, diagram: diagram) {
            GeometryReader { geometry in
                let width = geometry.size.width
                let imageHeight = geometry.size.height - 24
                ZStack(alignment: .topLeading) {
                    Image(nsImage: image).resizable().frame(width: width, height: imageHeight).offset(y: 20)
                    ForEach(diagram.ports) { port in
                        let selected = store.isSelectedPort(port)
                        let attached = store.devices(at: port.id)
                        let color: Color = selected ? accent : Color.white.opacity(0.42)
                        let x = port.x * width
                        let y = port.y * imageHeight + 20
                        let lowerLabel = port.connector == .audio
                        if selected {
                            Path { path in
                                path.move(to: CGPoint(x: x, y: lowerLabel ? y + 10 : 20))
                                path.addLine(to: CGPoint(x: x, y: lowerLabel ? imageHeight + 22 : y - 9))
                            }.stroke(accent.opacity(0.55), lineWidth: 1)
                        }
                        Button {
                            store.selectPort(port)
                        } label: {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(selected ? accent.opacity(0.32) : .clear)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4).stroke(
                                        selected ? accent : .clear, lineWidth: 2)
                                )
                                .frame(
                                    width: port.connector == .hdmi || port.connector == .ethernet ? 34 : 24,
                                    height: 20
                                )
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).position(x: x, y: y)
                            .help(
                                port.title
                                    + (attached.isEmpty
                                        ? " · 未观察到关联设备，不代表接口空闲"
                                        : " · " + attached.map(\.name).joined(separator: "、"))
                            )
                            .accessibilityLabel(port.title).accessibilityIdentifier("model-port-\(port.id)")
                        Text(port.label).font(
                            .system(size: 9, weight: selected ? .bold : .medium, design: .rounded)
                        )
                        .foregroundStyle(color).position(x: x, y: lowerLabel ? imageHeight + 26 : 8)
                        .allowsHitTesting(false)
                    }
                }
            }.frame(height: min(136, 640 * diagram.crop.height / diagram.crop.width) + 24)
        } else {
            Text("官方机身图片资源不可用；设备信息仍可查看。").font(.system(size: 10)).foregroundStyle(.orange)
        }
    }

    private func legend(_ text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 4, height: 4)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

@MainActor
private enum ModelArtwork {
    private static var cache: [String: NSImage] = [:]

    static func overview(profile: MacModelProfile) -> NSImage? {
        let key = "overview:\(profile.imageName)"
        if let image = cache[key] { return image }
        guard let url = MacModelCatalog.artworkURL(for: profile), let image = NSImage(contentsOf: url) else {
            return nil
        }
        cache[key] = image
        return image
    }

    static func image(profile: MacModelProfile, diagram: ModelDiagram) -> NSImage? {
        let key = profile.id + ":" + diagram.id
        if let cached = cache[key] { return cached }
        guard let url = MacModelCatalog.artworkURL(for: profile),
            let data = try? Data(contentsOf: url), let bitmap = NSBitmapImageRep(data: data),
            let original = bitmap.cgImage,
            let cropped = original.cropping(
                to: CGRect(
                    x: diagram.crop.x, y: diagram.crop.y, width: diagram.crop.width,
                    height: diagram.crop.height))
        else { return nil }
        let image = NSImage(
            cgImage: cropped, size: NSSize(width: diagram.crop.width, height: diagram.crop.height))
        cache[key] = image
        return image
    }
}
