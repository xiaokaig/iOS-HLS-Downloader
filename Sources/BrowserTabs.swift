import Foundation
import Combine

struct BrowserTab: Identifiable {
    let id: UUID
    let controller: BrowserController
    var url: String
    var title: String

    init(id: UUID = UUID(), url: String = "", title: String = "起始页", controller: BrowserController) {
        self.id = id
        self.url = url
        self.title = title
        self.controller = controller
    }
}

private struct SavedBrowserTab: Codable {
    var id: UUID
    var url: String
    var title: String
}

@MainActor
final class BrowserTabManager: ObservableObject {
    @Published private(set) var tabs: [BrowserTab] = []
    @Published private(set) var activeTabID: UUID

    private let storageKey = "browserTabs.v1"
    private let activeKey = "browserActiveTab.v1"

    init() {
        let saved = (UserDefaults.standard.data(forKey: storageKey))
            .flatMap { try? JSONDecoder().decode([SavedBrowserTab].self, from: $0) } ?? []
        if saved.isEmpty {
            let first = BrowserTab(controller: BrowserController())
            tabs = [first]
            activeTabID = first.id
        } else {
            tabs = saved.map { BrowserTab(id: $0.id, url: $0.url, title: $0.title, controller: BrowserController()) }
            let requested = (UserDefaults.standard.string(forKey: activeKey)).flatMap(UUID.init(uuidString:))
            activeTabID = tabs.first(where: { $0.id == requested })?.id ?? tabs[0].id
        }
        persist()
    }

    var activeTab: BrowserTab {
        tabs.first(where: { $0.id == activeTabID }) ?? tabs[0]
    }

    var activeController: BrowserController { activeTab.controller }

    @discardableResult
    func addTab(url: URL? = nil, activate: Bool = true) -> UUID {
        let value = url?.absoluteString ?? ""
        let tab = BrowserTab(url: value, title: url?.host ?? "起始页", controller: BrowserController())
        tabs.append(tab)
        if activate { activeTabID = tab.id }
        persist()
        return tab.id
    }

    func activate(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
        persist()
    }

    func update(_ id: UUID, url: String, title: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].url = url
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tabs[index].title = title
        }
        persist()
    }

    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].controller.dispose()
        tabs.remove(at: index)
        if tabs.isEmpty {
            let replacement = BrowserTab(controller: BrowserController())
            tabs = [replacement]
            activeTabID = replacement.id
        } else if activeTabID == id {
            activeTabID = tabs[min(index, tabs.count - 1)].id
        }
        persist()
    }

    func closeOthers(keeping id: UUID) {
        for tab in tabs where tab.id != id { tab.controller.dispose() }
        tabs = tabs.filter { $0.id == id }
        activeTabID = id
        persist()
    }

    private func persist() {
        let values = tabs.map { SavedBrowserTab(id: $0.id, url: $0.url, title: $0.title) }
        if let data = try? JSONEncoder().encode(values) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        UserDefaults.standard.set(activeTabID.uuidString, forKey: activeKey)
    }
}
