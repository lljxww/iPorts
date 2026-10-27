# Apple 机身图片来源

这些图片来自 Apple 官方支持网站。四张 `mac-mini-*.png` 保留原文件；`apple-<URL SHA-256 前 20 位>.png` 使用 macOS `sips` 转为最长边 640 像素的 PNG 缩略图。已核对的 Mac mini 图片叠加插孔标记；其他机型显示官方外观图与独立的端口示意。图片的版权和商标归 Apple 所有，来源记录不构成重新授权。

核对日期：2026-10-16。

目录记录了每个外观版本的精确型号标识、名称、系列、原图 URL、来源页面和可获得的技术规格链接，见 `src/PortsCore/Resources/MacCatalog.json`。由 `scripts/sync-apple-models.py` 从以下页面生成：

- [MacBook Pro](https://support.apple.com/en-us/108052)
- [MacBook Air](https://support.apple.com/en-us/102869)
- [MacBook](https://support.apple.com/en-us/103257)
- [iMac / iMac Pro](https://support.apple.com/en-us/108054)
- [Mac mini](https://support.apple.com/en-us/102852)
- [Mac Studio](https://support.apple.com/en-us/102231)
- [Mac Pro](https://support.apple.com/en-us/102887)

同一型号对应多个外观时保留全部记录，不通过年份或前缀猜测。运行时更新使用同一组官方页面；下载的图片缓存在 `~/Library/Caches/local.iports.app/AppleCatalog/`。

资源目录：`src/PortsCore/Resources/ModelArtwork/`。

| 文件 | 对应机型 | 原图 |
| --- | --- | --- |
| `mac-mini-2023-m2-pro.png` | `Mac14,12`，Mac mini M2 Pro（2023） | [Apple CDN](https://cdsassets.apple.com/live/7WUAS350/images/mac-mini/mac-mini-2023-m2-pro.png) |
| `mac-mini-2023-m2.png` | `Mac14,3`，Mac mini M2（2023） | [Apple CDN](https://cdsassets.apple.com/live/7WUAS350/images/mac-mini/mac-mini-2023-m2.png) |
| `mac-mini-2020-m1.png` | `Macmini9,1`，Mac mini M1（2020） | [Apple CDN](https://cdsassets.apple.com/live/7WUAS350/images/mac-mini/mac-mini-2020-m1.png) |
| `mac-mini-2024.png` | `Mac16,10`、`Mac16,11`，Mac mini（2024） | [Apple CDN](https://cdsassets.apple.com/live/7WUAS350/images/mac-mini/mac-mini-2024.png) |

`MachineModel.swift` 中的裁剪区域、插孔坐标和 C1 / A1 标签由本应用维护；这些标签并非 Apple 官方硬件编号。图片展示机型外观，不能单独证明某个 IORegistry 条目对应具体插孔。关联依据、推断和校准见 README。

端口示意模板参考各记录的技术规格以及 Apple 的 [MacBook Pro 机身导览](https://support.apple.com/guide/macbook-pro/apd921215d6c/mac)、[MacBook Air 机身导览](https://support.apple.com/guide/macbook-air/apd7e765329d/mac)、[Mac Studio 机身导览](https://support.apple.com/guide/mac-studio/apd0fd69f4be/mac) 和 [Mac Pro（2023）技术规格](https://support.apple.com/en-us/111343)。示意图中的同侧编号和顺序属于应用布局，可按实际插孔校准。没有核对的历史机型或新布局使用系统拓扑，不从机型照片自动推测插孔。
