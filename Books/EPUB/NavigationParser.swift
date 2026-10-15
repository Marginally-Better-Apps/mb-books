import Foundation

/// Parses EPUB 3 navigation documents and EPUB 2 NCX files.
nonisolated enum NavigationParser {
    struct Navigation {
        var toc: [NavigationPoint] = []
        var pageList: [NavigationPoint] = []
        var landmarks: [NavigationPoint] = []
    }

    static func parseNavigationDocument(_ data: Data, path: String) throws -> Navigation {
        let root = try MarkupParser.parse(data)
        var navigation = Navigation()
        var counter = 0
        for nav in root.descendants(named: "nav") {
            let types = nav.tokens("type", namespace: XMLNamespace.ops)
            guard let list = nav.child(named: "ol") else { continue }
            let points = parseList(list, basePath: path, counter: &counter)
            if types.contains("toc"), navigation.toc.isEmpty {
                navigation.toc = points
            } else if types.contains("page-list") {
                navigation.pageList = points
            } else if types.contains("landmarks") {
                navigation.landmarks = points
            }
        }
        return navigation
    }

    private static func parseList(_ list: MarkupElement, basePath: String, counter: inout Int) -> [NavigationPoint] {
        list.children(named: "li").compactMap { item in
            let label = item.child(named: "a") ?? item.child(named: "span")
            let children = item.child(named: "ol").map { parseList($0, basePath: basePath, counter: &counter) } ?? []
            let title = label.map(labelText) ?? ""
            guard !title.isEmpty || !children.isEmpty else { return nil }
            let target = label?.attribute("href").flatMap { EPUBPath.resolve($0, relativeTo: basePath) }
            counter += 1
            return NavigationPoint(
                id: "nav-\(counter)", title: title, path: target?.path, fragment: target?.fragment, children: children)
        }
    }

    /// Prefers the visible label but falls back to `title`/`aria-label`, which nav docs use for image labels.
    private static func labelText(_ element: MarkupElement) -> String {
        let text = element.normalizedText
        if !text.isEmpty { return text }
        return element.attribute("title") ?? element.attribute("label", namespace: nil)
            ?? element.attribute("aria-label")
            ?? element.firstDescendant(named: "img")?.attribute("alt") ?? ""
    }

    static func parseNCX(_ data: Data, path: String) throws -> Navigation {
        let root = try MarkupParser.parse(data)
        var counter = 0
        func points(_ parent: MarkupElement?, element: String) -> [NavigationPoint] {
            (parent?.children(named: element) ?? []).map { point in
                let title = point.child(named: "navLabel")?.child(named: "text")?.normalizedText ?? ""
                let target = point.child(named: "content")?.attribute("src")
                    .flatMap { EPUBPath.resolve($0, relativeTo: path) }
                counter += 1
                return NavigationPoint(
                    id: "ncx-\(counter)", title: title, path: target?.path, fragment: target?.fragment,
                    children: points(point, element: element))
            }
        }
        var navigation = Navigation()
        navigation.toc = points(root.child(named: "navMap"), element: "navPoint")
        navigation.pageList = points(root.child(named: "pageList"), element: "pageTarget")
        return navigation
    }
}
