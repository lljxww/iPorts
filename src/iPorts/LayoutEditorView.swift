import PortsCore
import SwiftUI

struct LayoutEditorView: View {
    @ObservedObject var store: PortStore
    @State private var side = PortSide.rear
    @State private var connector = PortConnector.usbC

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("按实际机身添加端口，再到设备详情中选择对应插孔。布局按本机型号保存。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Picker("位置", selection: $side) {
                    ForEach(PortSide.allCases, id: \.self) { Text($0.title).tag($0) }
                }.frame(width: 135)
                Picker("类型", selection: $connector) {
                    ForEach(PortConnector.allCases, id: \.self) { Text($0.title).tag($0) }
                }.frame(width: 245)
                Button("添加端口") { store.addLayoutPort(side: side, connector: connector) }
                Spacer(minLength: 0)
            }.controlSize(.small).font(.system(size: 10))
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(store.layoutDraft?.ports ?? []) { port in
                        HStack(spacing: 8) {
                            Text(port.side.title).foregroundStyle(.secondary).frame(
                                width: 70, alignment: .leading)
                            Text(port.connector.title)
                            Spacer()
                            Button {
                                store.moveLayoutPort("slot:\(port.id)", offset: -1)
                            } label: {
                                Image(systemName: "arrow.up")
                            }.help("在同一面内前移")
                            Button {
                                store.moveLayoutPort("slot:\(port.id)", offset: 1)
                            } label: {
                                Image(systemName: "arrow.down")
                            }.help("在同一面内后移")
                            Button {
                                store.removeLayoutPort("slot:\(port.id)")
                            } label: {
                                Image(systemName: "minus.circle")
                            }.help("删除此端口")
                        }.font(.system(size: 10)).buttonStyle(.plain).padding(6)
                            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 5))
                    }
                    if store.layoutDraft?.ports.isEmpty != false {
                        Text("尚无端口，使用上方选择器添加。").font(.system(size: 10)).foregroundStyle(.secondary).padding(
                            10)
                    }
                }
            }.frame(height: 100)
            HStack(spacing: 8) {
                Text("\(store.layoutDraft?.ports.count ?? 0) / 64 个接口").font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { store.cancelLayoutEdits() }
                Button("保存布局") { store.applyLayoutEdits() }.buttonStyle(.borderedProminent)
            }.controlSize(.small)
        }.padding(.vertical, 6)
    }
}
