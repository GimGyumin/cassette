// Cassette - Music client for Subsonic/OpenSubsonic servers
// Licensed under the Mozilla Public License 2.0.

import Foundation

nonisolated enum AppleLyricTTMLParser {
    enum ParseError: Error { case invalidXML, emptyDocument }

    static func parse(data: Data) throws -> LyricDocument {
        guard data.count <= 8 * 1024 * 1024 else { throw ParseError.invalidXML }
        let delegate = TTMLTreeParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { throw parser.parserError ?? ParseError.invalidXML }
        guard let root = delegate.root, root.name == "tt" else { throw ParseError.emptyDocument }
        return try TTMLDocumentDecoder().decode(root)
    }

    static func parse(string: String) throws -> LyricDocument {
        guard let data = string.data(using: .utf8) else { throw ParseError.invalidXML }
        return try parse(data: data)
    }
}

/// Mixed content order distinguishes adjacent syllables from explicit word spaces.
nonisolated private final class TTMLNode {
    enum Content { case text(String), node(TTMLNode) }
    let name: String
    let attributes: [String: String]
    var content: [Content] = []
    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }
    var children: [TTMLNode] { content.compactMap { if case .node(let node) = $0 { return node }; return nil } }
    var text: String { content.map { switch $0 { case .text(let value): return value; case .node(let node): return node.text } }.joined() }
    func descendants(_ name: String) -> [TTMLNode] {
        children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(name) }
    }
    func apple(_ name: String) -> String? {
        attributes["http://itunes.apple.com/lyric-ttml-extensions|\(name)"]
            ?? attributes["http://music.apple.com/lyric-ttml-internal|\(name)"] ?? attributes[name]
    }
    func metadata(_ name: String) -> String? { attributes["http://www.w3.org/ns/ttml#metadata|\(name)"] ?? attributes[name] }
    func xml(_ name: String) -> String? { attributes["http://www.w3.org/XML/1998/namespace|\(name)"] }
    var role: String? { metadata("role") }
    var ruby: String? { attributes["http://www.w3.org/ns/ttml#styling|ruby"] }
}

nonisolated private final class TTMLTreeParser: NSObject, XMLParserDelegate {
    private(set) var root: TTMLNode?
    private var stack: [TTMLNode] = []
    private var namespaces = ["xml": ["http://www.w3.org/XML/1998/namespace"]]
    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
        namespaces[prefix, default: []].append(namespaceURI)
    }
    func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) { _ = namespaces[prefix]?.popLast() }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        guard stack.count < 128 else { parser.abortParsing(); return }
        var resolved: [String: String] = [:]
        for (key, value) in attributes {
            let parts = key.split(separator: ":", maxSplits: 1)
            if parts.count == 2, let uri = namespaces[String(parts[0])]?.last {
                resolved["\(uri)|\(parts[1])"] = value
            } else { resolved[key] = value }
        }
        let node = TTMLNode(name: elementName, attributes: resolved)
        if let parent = stack.last { parent.content.append(.node(node)) } else { root = node }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) { _ = stack.popLast() }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let node = stack.last else { return }
        if case .text(let previous) = node.content.last {
            node.content[node.content.count - 1] = .text(previous + string)
        } else { node.content.append(.text(string)) }
    }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let text = String(data: CDATABlock, encoding: .utf8) { self.parser(parser, foundCharacters: text) }
    }
    func parser(_ parser: XMLParser, foundIgnorableWhitespace whitespaceString: String) {
        self.parser(parser, foundCharacters: whitespaceString)
    }
}

nonisolated private final class TTMLDocumentDecoder {
    private struct Range {
        var begin: Double? = nil
        var end: Double? = nil
    }
    private var order = 0
    private var sections: [LyricSection] = []
    private var translations: [String: [String: LyricTranslation]] = [:]
    private var transliterations: [String: [String: LyricTransliteration]] = [:]
    private var hasWordTiming = false
    private var songDuration: Double?

    func decode(_ root: TTMLNode) throws -> LyricDocument {
        guard let body = root.children.first(where: { $0.name == "body" }) else { throw AppleLyricTTMLParser.ParseError.emptyDocument }
        let duration = LyricTime.parse(body.attributes["dur"] ?? "")
        songDuration = duration
        var agents: [String: LyricAgent] = [:]
        for node in root.descendants("agent") {
            guard let id = node.xml("id") ?? node.attributes["id"] else { continue }
            agents[id] = LyricAgent(id: id, name: node.children.first(where: { $0.name == "name" })?.text.trimmingCharacters(in: .whitespacesAndNewlines), type: node.attributes["type"], role: node.role)
        }
        readBody(body, inherited: Range(end: duration), part: nil, agent: nil, preserve: root.xml("space") == "preserve")
        guard !sections.flatMap(\.lines).isEmpty else { throw AppleLyricTTMLParser.ParseError.emptyDocument }
        for (element, pronunciation) in [("translation", false), ("transliteration", true)] {
            for layer in root.descendants(element) {
                let language = layer.xml("lang") ?? "und"
                let automaticallyCreated = layer.apple("automaticallyCreated") == "true"
                for text in layer.children where text.name == "text" {
                    guard let key = text.attributes["for"] else { continue }
                    let owner = sections.flatMap(\.lines).first { $0.key == key }
                    let inherited = pronunciation ? Range(begin: owner?.begin, end: owner?.end) : Range()
                    let words = tokens(text, inherited: inherited, role: .main, agent: nil, preserve: false, localization: true)
                    if pronunciation {
                        transliterations[language, default: [:]][key] = LyricTransliteration(
                            words: words,
                            automaticallyCreated: automaticallyCreated
                        )
                    } else {
                        translations[language, default: [:]][key] = translation(
                            words,
                            automaticallyCreated: automaticallyCreated
                        )
                    }
                }
            }
        }
        let metadata = root.descendants("iTunesMetadata").first
        let offset = root.descendants("audio").first?.attributes["lyricOffset"].flatMap(Double.init) ?? 0
        let timed = sections.flatMap(\.lines).contains { $0.begin != nil }
        let language = translations.keys.sorted().first
        return LyricDocument(
            language: root.xml("lang"), timing: hasWordTiming ? .word : (timed ? .line : .none),
            duration: duration, leadingSilence: LyricTime.parse(metadata?.attributes["leadingSilence"] ?? "") ?? 0,
            lyricOffset: offset.isFinite ? offset : 0, agents: agents,
            songwriters: root.descendants("songwriter").map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) },
            sections: sections, translationLanguage: language, translations: language.flatMap { translations[$0] } ?? [:],
            translationsByLanguage: translations, transliterationsByLanguage: transliterations
        )
    }

    private func range(_ node: TTMLNode, inherited: Range) -> Range {
        let ownBegin = LyricTime.parse(node.attributes["begin"] ?? "")
        let begin = ownBegin ?? inherited.begin
        let ownEnd = LyricTime.parse(node.attributes["end"] ?? "")
            ?? LyricTime.parse(node.attributes["dur"] ?? "").map { (begin ?? 0) + $0 }
        return Range(begin: [begin, inherited.begin].compactMap { $0 }.max(), end: [ownEnd, inherited.end].compactMap { $0 }.min())
    }

    private func readBody(_ node: TTMLNode, inherited: Range, part: String?, agent: String?, preserve: Bool) {
        let bounds = range(node, inherited: inherited)
        let part = node.apple("song-part") ?? node.apple("songPart") ?? part
        let agent = node.metadata("agent") ?? agent
        let preserve = node.xml("space").map { $0 == "preserve" } ?? preserve
        let initialSectionCount = sections.count
        var lines: [LyricLine] = []
        func flush() {
            guard !lines.isEmpty else { return }
            sections.append(LyricSection(begin: bounds.begin, end: bounds.end, songPart: part, lines: lines))
            lines = []
        }
        for child in node.children {
            if child.name == "div" {
                flush()
                readBody(child, inherited: bounds, part: part, agent: agent, preserve: preserve)
            } else if child.name == "p" {
                // Server excerpts can retain stale div bounds. Explicit p clocks remain
                // authoritative; timed spans are still constrained to their owning p.
                let parentRange = Range(
                    begin: child.attributes["begin"] == nil ? bounds.begin : nil,
                    end: child.attributes["end"] == nil && child.attributes["dur"] == nil ? bounds.end : songDuration
                )
                let lineRange = range(child, inherited: parentRange)
                if let begin = lineRange.begin, let end = lineRange.end, end <= begin { continue }
                let key: String? = child.apple("key") ?? child.xml("id") ?? "__cassette_line_\(order)"
                let lineAgent = child.metadata("agent") ?? agent
                let words = tokens(child, inherited: lineRange, role: LyricRole.map(child.role), agent: lineAgent, preserve: preserve, localization: false)
                guard !words.isEmpty else { continue }
                let begin = lineRange.begin ?? (child.descendants("span").contains { $0.attributes["begin"] != nil } ? words.map(\.begin).min() : nil)
                lines.append(LyricLine(begin: begin, end: begin == nil ? nil : lineRange.end ?? words.map(\.end).max(), key: key, agentId: lineAgent, words: words, documentOrder: order, sourceLineIndex: nil, preservesSourceSpacing: true, preservesSourceTiming: true))
                order += 1
                if let key {
                    for inline in child.descendants("span") where inline.role == "x-translation" || inline.role == "x-roman" {
                        let language = inline.xml("lang") ?? "und"
                        let values = tokens(inline, inherited: lineRange, role: .main, agent: lineAgent, preserve: false, localization: true)
                        if inline.role == "x-roman" { transliterations[language, default: [:]][key] = LyricTransliteration(words: values, automaticallyCreated: false) }
                        else { translations[language, default: [:]][key] = translation(values) }
                    }
                }
            }
        }
        flush()
        if sections.count == initialSectionCount, node.name == "div", part != nil {
            sections.append(LyricSection(begin: bounds.begin, end: bounds.end, songPart: part, lines: []))
        }
    }

    private func tokens(_ node: TTMLNode, inherited: Range, role: LyricRole, agent: String?, preserve: Bool, localization: Bool) -> [LyricWord] {
        if !localization, ["x-translation", "x-roman"].contains(node.role ?? "") { return [] }
        if ["text", "textContainer", "delimiter"].contains(node.ruby ?? "") { return [] }
        let bounds = range(node, inherited: inherited)
        if let begin = bounds.begin, let end = bounds.end, end <= begin {
            // Some word-timed sources encode delimiters as zero-duration spans.
            // They have no sung interval, but still separate the surrounding words.
            let raw = node.text
            if !raw.isEmpty, raw.allSatisfy(\.isWhitespace),
               !raw.contains(where: \.isNewline) {
                return [LyricWord(text: preserve ? raw : " ", begin: begin, end: begin, role: role, agentId: agent)]
            }
            return []
        }
        let role = role.isBackground ? role : (node.role == "x-bg" ? .background : role)
        let agent = node.metadata("agent") ?? agent
        let preserve = node.xml("space").map { $0 == "preserve" } ?? preserve
        let ruby = node.ruby == "container" ? node.descendants("span").filter { $0.ruby == "text" }.map(\.text).joined() : nil
        var words: [LyricWord] = []
        for item in node.content {
            switch item {
            case .text(let raw):
                let text = preserve ? raw : raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if words.isEmpty, node.name == "span", !raw.contains(where: \.isNewline) {
                        words.append(LyricWord(text: text, begin: bounds.begin ?? 0, end: bounds.end ?? 0, role: role, agentId: agent))
                    }
                    let isPreservedFormattingWhitespace = preserve && raw.contains(where: \.isNewline)
                    if !isPreservedFormattingWhitespace,
                       !words.isEmpty,
                       words[words.count - 1].role == role,
                       !words[words.count - 1].text.hasSuffix(" ") {
                        let last = words.removeLast()
                        words.append(LyricWord(text: last.text + (preserve ? text : " "), begin: last.begin, end: last.end, role: last.role, agentId: last.agentId, ruby: last.ruby))
                    }
                } else {
                    words.append(LyricWord(text: text, begin: bounds.begin ?? 0, end: bounds.end ?? bounds.begin ?? 0, role: role, agentId: agent, ruby: ruby))
                }
            case .node(let child):
                if child.name == "br" {
                    words.append(LyricWord(text: "\n", begin: bounds.begin ?? 0, end: bounds.end ?? 0, role: role, agentId: agent))
                } else {
                    words.append(contentsOf: tokens(child, inherited: bounds, role: role, agent: agent, preserve: preserve, localization: localization))
                }
            }
        }
        if !localization, node.name == "span", node.attributes["begin"] != nil, !words.isEmpty { hasWordTiming = true }
        if let ruby, !ruby.isEmpty { words = words.map { var word = $0; word.ruby = ruby; return word } }
        return words
    }

    private func translation(
        _ words: [LyricWord],
        automaticallyCreated: Bool = false
    ) -> LyricTranslation {
        let background = words.filter(\.role.isBackground)
        let timed = background.filter { $0.end > $0.begin }
        return LyricTranslation(
            main: words.filter { !$0.role.isBackground }.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines),
            background: background.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines),
            backgroundBegin: timed.map(\.begin).min(),
            backgroundEnd: timed.map(\.end).max(),
            automaticallyCreated: automaticallyCreated
        )
    }
}
