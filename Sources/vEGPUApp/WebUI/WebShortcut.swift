import Foundation

struct WebShortcut: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var url: URL

    init(id: UUID = UUID(), title: String, url: URL) {
        self.id = id
        self.title = title
        self.url = url
    }
}
