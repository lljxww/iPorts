import CryptoKit
import Foundation
import ImageIO
import OSLog

public enum MacFamily: String, Codable, CaseIterable, Sendable {
    case macBookPro, macBookAir, macBook, iMac, macMini, macStudio, macPro, unknown

    public var symbol: String {
        switch self {
        case .macBookPro, .macBookAir, .macBook: "laptopcomputer"
        case .iMac: "desktopcomputer"
        case .macMini: "macmini"
        case .macStudio: "macstudio"
        case .macPro: "macpro.gen3"
        case .unknown: "desktopcomputer"
        }
    }

    public var sourceURL: URL {
        let article: String
        switch self {
        case .macBookPro: article = "108052"
        case .macBookAir: article = "102869"
        case .macBook: article = "103257"
        case .iMac: article = "108054"
        case .macMini: article = "102852"
        case .macStudio: article = "102231"
        case .macPro: article = "102887"
        case .unknown: article = "109523"
        }
        guard let url = URL(string: "https://support.apple.com/en-us/\(article)") else {
            preconditionFailure("Invalid built-in Apple source")
        }
        return url
    }
}

public struct OfficialMacModel: Codable, Identifiable, Sendable {
    public let id: String
    public let identifiers: [String]
    public let name: String
    public let family: MacFamily
    public let imageURL: URL
    public let imageName: String
    public let sourceURL: URL
    public let specsURL: URL?

    public var isValid: Bool {
        !id.isEmpty && id.count <= 100 && !name.isEmpty && name.count <= 180
            && !identifiers.isEmpty && identifiers.allSatisfy(AppleMacCatalog.isIdentifier)
            && imageName.range(of: #"\Aapple-[a-f0-9]{20}\z"#, options: .regularExpression) != nil
            && AppleMacCatalog.isAppleURL(imageURL) && sourceURL == family.sourceURL
            && family != .unknown && (specsURL == nil || specsURL.map(AppleMacCatalog.isAppleURL) == true)
    }
}

public struct AppleCatalogDocument: Codable, Sendable {
    public let version: Int
    public let updatedAt: String
    public let models: [OfficialMacModel]

    public func validated() throws -> AppleCatalogDocument {
        guard version == 1, !models.isEmpty, models.count <= 2000,
            models.allSatisfy(\.isValid), Set(models.map(\.id)).count == models.count
        else {
            throw AppleCatalogError.invalidCatalog
        }
        return self
    }
}

public enum AppleMacCatalog {
    public static let bundled: [OfficialMacModel] = {
        do {
            guard let url = resourceURL(name: "MacCatalog", extension: "json") else {
                throw AppleCatalogError.invalidCatalog
            }
            return try JSONDecoder().decode(AppleCatalogDocument.self, from: Data(contentsOf: url))
                .validated().models
        } catch {
            Logger(subsystem: "local.iports.app", category: "model-catalog").error(
                "Bundled model catalog: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }()

    public static func models(for identifier: String, in records: [OfficialMacModel] = bundled)
        -> [OfficialMacModel]
    {
        records.filter { $0.identifiers.contains(identifier) }
    }

    public static func isIdentifier(_ value: String) -> Bool {
        value.range(
            of: #"\A(?:Mac(?:Book(?:Air|Pro)?|mini|Pro)?|iMac(?:Pro)?)[0-9]+,[0-9]+\z"#,
            options: .regularExpression) != nil
    }

    public static func isAppleURL(_ url: URL) -> Bool {
        url.scheme == "https" && ["support.apple.com", "cdsassets.apple.com"].contains(url.host ?? "")
            && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
    }

    public static func resourceURL(name: String, extension suffix: String, directory: String? = nil) -> URL? {
        guard !name.isEmpty else { return nil }
        if let url = Bundle.main.url(forResource: "iPorts_PortsCore", withExtension: "bundle"),
            let bundle = Bundle(url: url)
        {
            return bundle.url(forResource: name, withExtension: suffix, subdirectory: directory)
        }
        if Bundle.main.bundleURL.pathExtension == "app" { return nil }
        return Bundle.module.url(forResource: name, withExtension: suffix, subdirectory: directory)
    }

    public static var cacheDirectory: URL {
        (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("local.iports.app/AppleCatalog", isDirectory: true)
    }

    public static func merging(_ cached: [OfficialMacModel], with bundled: [OfficialMacModel] = bundled)
        -> [OfficialMacModel]
    {
        let merged = Dictionary(bundled.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            .merging(Dictionary(cached.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })) { _, new in
                new
            }
        return merged.values.sorted { $0.id < $1.id }
    }

    public static func cachedArtworkURL(name: String) -> URL? {
        guard name.range(of: #"\Aapple-[a-f0-9]{20}\z"#, options: .regularExpression) != nil else {
            return nil
        }
        let url = cacheDirectory.appendingPathComponent(name + ".image")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

public enum AppleCatalogError: LocalizedError {
    case invalidCatalog, invalidResource, changedArticle
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidCatalog: "机型目录内容无效，继续使用已安装的资料。"
        case .invalidResource: "Apple 资源地址、大小或图片格式无效。"
        case .changedArticle: "Apple 机型页面结构已变化，保留现有资料。"
        case .http(let code): "Apple 资源请求失败（HTTP \(code)）。"
        }
    }
}

public enum AppleArticleParser {
    public static func parse(_ html: String, family: MacFamily) throws -> [OfficialMacModel] {
        let headings = matches(#"<h[23]\b[^>]*>(.*?)</h[23]>"#, html)
        var models: [OfficialMacModel] = []
        for (index, heading) in headings.enumerated() {
            let end = index + 1 < headings.count ? headings[index + 1].range.lowerBound : html.endIndex
            let section = String(html[heading.range.upperBound..<end])
            let paragraphs = matches(#"<p\b[^>]*>(.*?)</p>"#, section)
            for (pIndex, paragraph) in paragraphs.enumerated() {
                let text = clean(paragraph.groups[0])
                guard text.localizedCaseInsensitiveContains("model identifier") else { continue }
                let identifiers = matches(
                    #"\b(?:Mac(?:Book(?:Air|Pro)?|mini|Pro)?|iMac(?:Pro)?)\d+,\d+\b"#, text
                ).map { String(text[$0.range]) }
                guard !identifiers.isEmpty else { continue }
                let prefix = String(section[..<paragraph.range.lowerBound])
                guard let image = matches(#"<img\b[^>]*\bsrc=["']([^"']+)["']"#, prefix).last,
                    let imageURL = URL(string: clean(image.groups[0])), AppleMacCatalog.isAppleURL(imageURL)
                else { throw AppleCatalogError.changedArticle }
                var name = clean(heading.groups[0])
                if !name.hasPrefix("Mac") && !name.hasPrefix("iMac") {
                    name =
                        paragraphs.prefix(pIndex).map { clean($0.groups[0]) }.last {
                            $0.hasPrefix("MacBook (")
                        } ?? "MacBook \(name)"
                }
                let suffix = String(section[paragraph.range.upperBound...])
                let links = matches(#"<a\b[^>]*\bhref=["']([^"']+)["'][^>]*>(.*?)</a>"#, suffix)
                let specs = links.first { clean($0.groups[1]).localizedCaseInsensitiveContains("tech spec") }
                    .flatMap { URL(string: clean($0.groups[0]), relativeTo: family.sourceURL)?.absoluteURL }
                let record = OfficialMacModel(
                    id: family.rawValue + "-" + hash(name + imageURL.absoluteString, length: 16),
                    identifiers: Array(Set(identifiers)).sorted(), name: name, family: family,
                    imageURL: imageURL, imageName: "apple-" + hash(imageURL.absoluteString, length: 20),
                    sourceURL: family.sourceURL, specsURL: specs
                )
                guard record.isValid else { throw AppleCatalogError.changedArticle }
                models.append(record)
            }
        }
        var seen = Set<String>()
        models = models.filter { seen.insert($0.id).inserted }
        guard !models.isEmpty else { throw AppleCatalogError.changedArticle }
        return models
    }

    private static func hash(_ value: String, length: Int) -> String {
        String(SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined().prefix(length))
    }

    private struct Match {
        let range: Range<String.Index>
        let groups: [String]
    }

    private static func matches(_ pattern: String, _ input: String) -> [Match] {
        guard
            let expression = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        else { return [] }
        return expression.matches(in: input, range: NSRange(input.startIndex..., in: input)).compactMap {
            match in
            guard let range = Range(match.range, in: input) else { return nil }
            return Match(
                range: range,
                groups: (1..<match.numberOfRanges).map { index in
                    Range(match.range(at: index), in: input).map { String(input[$0]) } ?? ""
                })
        }
    }

    private static func clean(_ input: String) -> String {
        var value = input.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (entity, replacement) in [
            "&nbsp;": " ", "&amp;": "&", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<",
            "&gt;": ">",
        ] {
            value = value.replacingOccurrences(of: entity, with: replacement)
        }
        return value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

public actor AppleCatalogService {
    private let directory: URL
    private let session: URLSession

    public init(directory: URL = AppleMacCatalog.cacheDirectory) {
        self.directory = directory
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 18
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(
            configuration: configuration, delegate: AppleRedirectPolicy(), delegateQueue: nil)
    }

    public func cachedModels() throws -> [OfficialMacModel]? {
        let url = directory.appendingPathComponent("catalog.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(AppleCatalogDocument.self, from: Data(contentsOf: url)).validated()
            .models
    }

    public func refresh() async throws -> [OfficialMacModel] {
        let models = try await withThrowingTaskGroup(of: [OfficialMacModel].self) { group in
            for family in MacFamily.allCases where family != .unknown {
                group.addTask {
                    let data = try await self.fetch(family.sourceURL, maximum: 8_000_000)
                    guard let html = String(data: data, encoding: .utf8) else {
                        throw AppleCatalogError.changedArticle
                    }
                    return try AppleArticleParser.parse(html, family: family)
                }
            }
            var result: [OfficialMacModel] = []
            for try await records in group { result += records }
            return result.sorted { $0.id < $1.id }
        }
        let catalog = try AppleCatalogDocument(
            version: 1, updatedAt: Date().formatted(.iso8601), models: models
        ).validated()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(catalog).write(
            to: directory.appendingPathComponent("catalog.json"), options: .atomic)
        return models
    }

    public func cacheArtwork(_ model: OfficialMacModel) async throws {
        guard model.isValid else { throw AppleCatalogError.invalidCatalog }
        let data = try await fetch(model.imageURL, maximum: 8_000_000)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
            let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
            let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
            width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 20_000_000
        else {
            throw AppleCatalogError.invalidResource
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(model.imageName + ".image"), options: .atomic)
    }

    private func fetch(_ url: URL, maximum: Int) async throws -> Data {
        guard AppleMacCatalog.isAppleURL(url) else { throw AppleCatalogError.invalidResource }
        let (bytes, response) = try await session.bytes(from: url)
        guard let response = response as? HTTPURLResponse else { throw AppleCatalogError.invalidResource }
        guard response.statusCode == 200 else { throw AppleCatalogError.http(response.statusCode) }
        guard response.expectedContentLength <= maximum else { throw AppleCatalogError.invalidResource }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximum else { throw AppleCatalogError.invalidResource }
            data.append(byte)
        }
        return data
    }
}

private final class AppleRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(request.url.map(AppleMacCatalog.isAppleURL) == true ? request : nil)
    }
}
