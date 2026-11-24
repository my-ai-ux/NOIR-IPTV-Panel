import SwiftUI
import AVKit

@main
struct NOIRPanelApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}

// MARK: - Models
enum MediaType: String, Codable, CaseIterable {
    case live = "بث مباشر"
    case vod = "أفلام"
    case series = "مسلسلات"

    var serverCode: String {
        switch self {
        case .live: return "live"
        case .vod: return "movie"
        case .series: return "series"
        }
    }

    static func fromServer(_ code: String) -> MediaType {
        switch code {
        case "movie": return .vod
        case "series": return .series
        default: return .live
        }
    }
}

enum StreamHealth: String, Codable {
    case unknown = "غير مفحوص"
    case checking = "جاري الفحص..."
    case online = "شغال"
    case offline = "طافي"
}

struct SeriesEpisode: Codable, Equatable, Identifiable {
    var id = UUID()
    var season: Int
    var episode: Int
    var title: String
    var url: String
}

struct ChannelItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var group: String
    var logo: String
    var url: String
    var type: MediaType = .live
    var health: StreamHealth = .unknown
    var pingMs: Int? = nil
    var plot: String = ""
    var cast: String = ""
    var rating: String = ""
    var year: String = ""
    var episodes: [SeriesEpisode] = []
}

struct SubUser: Identifiable, Codable, Equatable {
    var id = UUID()
    var username: String
    var password: String
    var daysValid: Int = 30
    var isActive: Bool = true
    var createdAt: Date = Date()
}

// MARK: - Store & Cloud Sync
@MainActor
class PanelStore: ObservableObject {
    @Published var channels: [ChannelItem] = [] { didSet { save() } }
    @Published var users: [SubUser] = [] { didSet { save() } }
    @Published var savedCategories: [String] = ["الرياضية", "قنوات عامة", "أفلام", "مسلسلات"] { didSet { save() } }
    @Published var isSyncing = false
    @Published var syncStatus = "جاهز للمزامنة"

    let serverURL = "https://noir-server.mkdos101.workers.dev"
    let adminKey = "noir2026"

    init() { load() }

    var allAvailableGroups: [String] {
        let fromChannels = channels.map { $0.group }
        return Array(Set(savedCategories + fromChannels)).filter { !$0.isEmpty }.sorted()
    }

    func registerCategory(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty && !savedCategories.contains(clean) {
            savedCategories.append(clean)
        }
    }

    func renameCategory(oldName: String, newName: String) {
        let cleanNew = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanNew.isEmpty, cleanNew != oldName else { return }

        if let idx = savedCategories.firstIndex(of: oldName) {
            savedCategories[idx] = cleanNew
        } else if !savedCategories.contains(cleanNew) {
            savedCategories.append(cleanNew)
        }

        for i in channels.indices {
            if channels[i].group == oldName {
                channels[i].group = cleanNew
            }
        }
        syncToCloud()
    }

    func deleteCategory(_ categoryName: String, deleteChannelsInside: Bool) {
        savedCategories.removeAll { $0 == categoryName }
        if deleteChannelsInside {
            channels.removeAll { $0.group == categoryName }
        } else {
            for i in channels.indices {
                if channels[i].group == categoryName {
                    channels[i].group = "عام"
                }
            }
            if !channels.filter({ $0.group == "عام" }).isEmpty {
                registerCategory("عام")
            }
        }
        syncToCloud()
    }

    func addChannel(name: String, group: String, logo: String, url: String, type: MediaType, plot: String = "", cast: String = "") {
        let cleanURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanURL.isEmpty else { return }
        let finalGroup = group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "عام" : group.trimmingCharacters(in: .whitespacesAndNewlines)
        registerCategory(finalGroup)

        let item = ChannelItem(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "عنصر جديد" : name,
            group: finalGroup,
            logo: logo.trimmingCharacters(in: .whitespacesAndNewlines),
            url: cleanURL,
            type: type,
            plot: plot,
            cast: cast
        )
        channels.insert(item, at: 0)
        checkStreamHealth(id: item.id)
        syncToCloud()
    }

    func updateChannel(_ updated: ChannelItem) {
        if let idx = channels.firstIndex(where: { $0.id == updated.id }) {
            registerCategory(updated.group)
            channels[idx] = updated
            checkStreamHealth(id: updated.id)
            syncToCloud()
        }
    }

    // سحب الأفلام والمسلسلات من إضافة Stremio مع فاصل زمني آمن لحماية حساب TorBox / Debrid
    func importFromStremioAddon(manifestURL: String, maxItemsPerCatalog: Int = 20, completion: @escaping (String) -> Void) {
        var clean = manifestURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("stremio://") {
            clean = clean.replacingOccurrences(of: "stremio://", with: "https://")
        }
        guard let url = URL(string: clean), clean.hasSuffix("manifest.json") else {
            completion("الرجاء لصق رابط إضافة ستريمو المنتهي بـ manifest.json")
            return
        }

        let baseURL = clean.replacingOccurrences(of: "/manifest.json", with: "")
        isSyncing = true

        Task {
            do {
                let (manifestData, _) = try await URLSession.shared.data(from: url)
                guard let manifestJson = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
                      let catalogs = manifestJson["catalogs"] as? [[String: Any]] else {
                    self.isSyncing = false
                    completion("تعذر قراءة ملف الإضافة (Manifest).")
                    return
                }

                let addonName = manifestJson["name"] as? String ?? "Stremio"
                var addedCount = 0

                for cat in catalogs {
                    guard let type = cat["type"] as? String,
                          let catId = cat["id"] as? String,
                          (type == "movie" || type == "series") else { continue }

                    let catName = (cat["name"] as? String) ?? (type == "movie" ? "أفلام \(addonName)" : "مسلسلات \(addonName)")
                    let catalogEndpoint = "\(baseURL)/catalog/\(type)/\(catId).json"
                    guard let catURL = URL(string: catalogEndpoint),
                          let (catData, _) = try? await URLSession.shared.data(from: catURL),
                          let catJson = try? JSONSerialization.jsonObject(with: catData) as? [String: Any],
                          let metas = catJson["metas"] as? [[String: Any]] else { continue }

                    for meta in metas.prefix(maxItemsPerCatalog) {
                        // فاصل زمني آمن (0.6 ثانية) لحماية TorBox من Rate Limit
                        try? await Task.sleep(nanoseconds: 600_000_000)

                        guard let itemId = meta["id"] as? String,
                              let itemName = meta["name"] as? String else { continue }

                        var poster = meta["poster"] as? String ?? ""
                        var plot = meta["description"] as? String ?? ""
                        var castList = (meta["cast"] as? [String])?.joined(separator: "، ") ?? ""
                        var rating = meta["imdbRating"] as? String ?? ""
                        var year = meta["releaseInfo"] as? String ?? ""

                        var fetchedEpisodes: [SeriesEpisode] = []
                        if let metaURL = URL(string: "\(baseURL)/meta/\(type)/\(itemId).json"),
                           let (metaData, _) = try? await URLSession.shared.data(from: metaURL),
                           let metaWrapper = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
                           let fullMeta = metaWrapper["meta"] as? [String: Any] {

                            if let p = fullMeta["poster"] as? String, !p.isEmpty { poster = p }
                            if let d = fullMeta["description"] as? String, !d.isEmpty { plot = d }
                            if let c = fullMeta["cast"] as? [String], !c.isEmpty { castList = c.joined(separator: "، ") }
                            if let r = fullMeta["imdbRating"] as? String, !r.isEmpty { rating = r }
                            if let y = fullMeta["releaseInfo"] as? String, !y.isEmpty { year = y }

                            if type == "series", let videos = fullMeta["videos"] as? [[String: Any]] {
                                for vid in videos.prefix(25) {
                                    try? await Task.sleep(nanoseconds: 400_000_000)
                                    guard let vidId = vid["id"] as? String else { continue }
                                    let seasonNum = vid["season"] as? Int ?? 1
                                    let epNum = vid["episode"] as? Int ?? 1
                                    let epTitle = vid["title"] as? String ?? "الحلقة \(epNum)"

                                    if let epStreamURL = URL(string: "\(baseURL)/stream/series/\(vidId).json"),
                                       let (sData, _) = try? await URLSession.shared.data(from: epStreamURL),
                                       let sJson = try? JSONSerialization.jsonObject(with: sData) as? [String: Any],
                                       let streams = sJson["streams"] as? [[String: Any]],
                                       let direct = streams.first(where: {
                                           ($0["infoHash"] == nil) && (($0["url"] as? String)?.hasPrefix("http") == true)
                                       })?["url"] as? String {
                                        fetchedEpisodes.append(SeriesEpisode(season: seasonNum, episode: epNum, title: epTitle, url: direct))
                                    }
                                }
                            }
                        }

                        if type == "movie" {
                            if let streamURL = URL(string: "\(baseURL)/stream/movie/\(itemId).json"),
                               let (streamData, _) = try? await URLSession.shared.data(from: streamURL),
                               let streamJson = try? JSONSerialization.jsonObject(with: streamData) as? [String: Any],
                               let streams = streamJson["streams"] as? [[String: Any]],
                               let directLink = streams.first(where: {
                                   ($0["infoHash"] == nil) && (($0["url"] as? String)?.hasPrefix("http") == true)
                               })?["url"] as? String {

                                let groupTitle = "\(addonName) - \(catName)"
                                self.registerCategory(groupTitle)
                                let newMovie = ChannelItem(
                                    name: itemName,
                                    group: groupTitle,
                                    logo: poster,
                                    url: directLink,
                                    type: .vod,
                                    plot: plot,
                                    cast: castList,
                                    rating: rating,
                                    year: year
                                )
                                self.channels.insert(newMovie, at: 0)
                                addedCount += 1
                            }
                        } else if type == "series" && !fetchedEpisodes.isEmpty {
                            let groupTitle = "\(addonName) - \(catName)"
                            self.registerCategory(groupTitle)
                            let newSeries = ChannelItem(
                                name: itemName,
                                group: groupTitle,
                                logo: poster,
                                url: fetchedEpisodes.first?.url ?? "",
                                type: .series,
                                plot: plot,
                                cast: castList,
                                rating: rating,
                                year: year,
                                episodes: fetchedEpisodes
                            )
                            self.channels.insert(newSeries, at: 0)
                            addedCount += 1
                        }
                    }
                }

                self.isSyncing = false
                if addedCount > 0 {
                    self.syncToCloud()
                    completion("تم سحب \(addedCount) فيلم/مسلسل بأمان تام ورفعها للسيرفر!")
                } else {
                    completion("لم يتم العثور على روابط مباشرة (تأكد من تفعيل خيار منع التورنت / Debrid في إعدادات الإضافة).")
                }
            } catch {
                self.isSyncing = false
                completion("حدث خطأ أثناء الاتصال بالإضافة.")
            }
        }
    }

    // تحليل M3U
    func importM3U(rawText: String, defaultType: MediaType = .live) -> Int {
        let lines = rawText.components(separatedBy: .newlines)
        var currentName = ""
        var currentGroup = "مستورد"
        var currentLogo = ""
        var importedCount = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("#EXTINF:") {
                if let commaRange = trimmed.range(of: ",", options: .backwards) {
                    currentName = String(trimmed[commaRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                }
                if let grp = extractAttribute(from: trimmed, key: "group-title") {
                    currentGroup = grp.isEmpty ? "مستورد" : grp
                }
                if let lg = extractAttribute(from: trimmed, key: "tvg-logo") {
                    currentLogo = lg
                }
            } else if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
                registerCategory(currentGroup)
                let detectedType: MediaType
                if trimmed.contains("/movie/") || trimmed.hasSuffix(".mp4") || trimmed.hasSuffix(".mkv") {
                    detectedType = .vod
                } else if trimmed.contains("/series/") {
                    detectedType = .series
                } else {
                    detectedType = defaultType
                }

                let item = ChannelItem(
                    name: currentName.isEmpty ? "قناة \(importedCount + 1)" : currentName,
                    group: currentGroup,
                    logo: currentLogo,
                    url: trimmed,
                    type: detectedType
                )
                channels.append(item)
                importedCount += 1
                currentName = ""
                currentLogo = ""
            }
        }
        if importedCount > 0 { syncToCloud() }
        return importedCount
    }

    func importFromM3UURL(_ urlString: String, completion: @escaping (String) -> Void) {
        let clean = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: clean) else {
            completion("الرابط غير صحيح")
            return
        }
        isSyncing = true
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: req) { data, _, error in
            Task { @MainActor in
                self.isSyncing = false
                guard let data = data, error == nil, let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
                    completion("تعذر تحميل القائمة من الرابط")
                    return
                }
                let count = self.importM3U(rawText: content, defaultType: .live)
                completion(count > 0 ? "تم نسخ واستيراد \(count) عنصر بنجاح!" : "الملف فارغ أو لا يحتوي روابط صالحة")
            }
        }.resume()
    }

    func importFromXtream(host: String, username: String, password: String, completion: @escaping (String) -> Void) {
        var cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanHost.hasSuffix("/") { cleanHost.removeLast() }
        if !cleanHost.hasPrefix("http") { cleanHost = "http://\(cleanHost)" }

        let u = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = password.trimmingCharacters(in: .whitespacesAndNewlines)

        let m3uLink = "\(cleanHost)/get.php?username=\(u)&password=\(p)&type=m3u_plus&output=ts"
        importFromM3UURL(m3uLink, completion: completion)
    }

    private func extractAttribute(from line: String, key: String) -> String? {
        let pattern = "\(key)=\"([^\"]*)\""
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
           let range = Range(match.range(at: 1), in: line) {
            return String(line[range])
        }
        return nil
    }

    func checkStreamHealth(id: UUID) {
        guard let index = channels.firstIndex(where: { $0.id == id }),
              let url = URL(string: channels[index].url) else { return }

        channels[index].health = .checking
        let startTime = Date()

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 8
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { _, response, error in
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
            Task { @MainActor in
                guard let idx = self.channels.firstIndex(where: { $0.id == id }) else { return }
                if let http = response as? HTTPURLResponse, (200...399).contains(http.statusCode), error == nil {
                    self.channels[idx].health = .online
                    self.channels[idx].pingMs = elapsed
                } else {
                    self.channels[idx].health = .offline
                    self.channels[idx].pingMs = nil
                }
            }
        }.resume()
    }

    func checkAllStreams() {
        Task {
            for ch in channels {
                let lower = ch.url.lowercased()
                if lower.contains("torbox") || lower.contains("real-debrid") || lower.contains("debrid") {
                    continue
                }
                checkStreamHealth(id: ch.id)
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }

    func addUser(username: String, password: String, days: Int) {
        let u = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty, !p.isEmpty else { return }
        users.insert(SubUser(username: u, password: p, daysValid: days), at: 0)
        syncToCloud()
    }

    func toggleUserStatus(id: UUID) {
        if let idx = users.firstIndex(where: { $0.id == id }) {
            users[idx].isActive.toggle()
            syncToCloud()
        }
    }

    func syncToCloud() {
        guard let url = URL(string: "\(serverURL)/api/sync") else { return }
        isSyncing = true
        syncStatus = "جاري الرفع..."

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(adminKey)", forHTTPHeaderField: "Authorization")

        let activeUsers = users.filter { $0.isActive }
        let payload: [String: Any] = [
            "channels": channels.map { ch in
                [
                    "name": ch.name,
                    "group": ch.group,
                    "logo": ch.logo,
                    "url": ch.url,
                    "type": ch.type.serverCode,
                    "plot": ch.plot,
                    "cast": ch.cast,
                    "rating": ch.rating,
                    "year": ch.year,
                    "episodes": ch.episodes.map { [
                        "season": $0.season,
                        "episode": $0.episode,
                        "title": $0.title,
                        "url": $0.url
                    ] }
                ] as [String: Any]
            },
            "users": activeUsers.map { [
                "username": $0.username,
                "password": $0.password,
                "daysValid": $0.daysValid
            ] }
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        URLSession.shared.dataTask(with: request) { _, response, error in
            Task { @MainActor in
                self.isSyncing = false
                if let http = response as? HTTPURLResponse, http.statusCode == 200, error == nil {
                    self.syncStatus = "محدّث ✓"
                } else {
                    self.syncStatus = "خطأ اتصال!"
                }
            }
        }.resume()
    }

    func pullFromCloud() {
        guard let url = URL(string: "\(serverURL)/api/data") else { return }
        isSyncing = true
        syncStatus = "جاري الاسترجاع..."

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(adminKey)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { data, response, error in
            Task { @MainActor in
                self.isSyncing = false
                guard let data = data,
                      let http = response as? HTTPURLResponse,
                      http.statusCode == 200,
                      error == nil,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.syncStatus = "فشل الاسترجاع"
                    return
                }

                if let rawChannels = json["channels"] as? [[String: Any]] {
                    self.channels = rawChannels.compactMap { dict in
                        guard let name = dict["name"] as? String,
                              let streamUrl = dict["url"] as? String else { return nil }
                        let group = dict["group"] as? String ?? "عام"
                        let logo = dict["logo"] as? String ?? ""
                        let typeStr = dict["type"] as? String ?? "live"
                        let plot = dict["plot"] as? String ?? ""
                        let cast = dict["cast"] as? String ?? ""
                        let rating = dict["rating"] as? String ?? ""
                        let year = dict["year"] as? String ?? ""
                        var eps: [SeriesEpisode] = []
                        if let rawEps = dict["episodes"] as? [[String: Any]] {
                            eps = rawEps.compactMap { e in
                                guard let u = e["url"] as? String else { return nil }
                                return SeriesEpisode(
                                    season: e["season"] as? Int ?? 1,
                                    episode: e["episode"] as? Int ?? 1,
                                    title: e["title"] as? String ?? "حلقة",
                                    url: u
                                )
                            }
                        }
                        self.registerCategory(group)
                        return ChannelItem(
                            name: name,
                            group: group,
                            logo: logo,
                            url: streamUrl,
                            type: MediaType.fromServer(typeStr),
                            plot: plot,
                            cast: cast,
                            rating: rating,
                            year: year,
                            episodes: eps
                        )
                    }
                }

                if let rawUsers = json["users"] as? [[String: Any]] {
                    self.users = rawUsers.compactMap { dict in
                        guard let username = dict["username"] as? String,
                              let password = dict["password"] as? String else { return nil }
                        let days = dict["daysValid"] as? Int ?? 30
                        return SubUser(username: username, password: password, daysValid: days)
                    }
                }

                self.syncStatus = "تم الاسترجاع ✓"
            }
        }.resume()
    }

    func generateFullM3U() -> String {
        var text = "#EXTM3U\n"
        for ch in channels {
            text += "#EXTINF:-1 tvg-logo=\"\(ch.logo)\" group-title=\"\(ch.group)\",\(ch.name)\n\(ch.url)\n"
        }
        return text
    }

    private func save() {
        if let chData = try? JSONEncoder().encode(channels) {
            UserDefaults.standard.set(chData, forKey: "noir_v4_channels")
        }
        if let uData = try? JSONEncoder().encode(users) {
            UserDefaults.standard.set(uData, forKey: "noir_v4_users")
        }
        UserDefaults.standard.set(savedCategories, forKey: "noir_v4_cats")
    }

    private func load() {
        if let chData = UserDefaults.standard.data(forKey: "noir_v4_channels"),
           let decoded = try? JSONDecoder().decode([ChannelItem].self, from: chData) {
            channels = decoded
        }
        if let uData = UserDefaults.standard.data(forKey: "noir_v4_users"),
           let decoded = try? JSONDecoder().decode([SubUser].self, from: uData) {
            users = decoded
        }
        if let cats = UserDefaults.standard.stringArray(forKey: "noir_v4_cats") {
            savedCategories = cats
        }
    }
}

// MARK: - Main Tab View
struct ContentView: View {
    @StateObject private var store = PanelStore()

    var body: some View {
        TabView {
            ContentManagerView(store: store)
                .tabItem {
                    Label("المحتوى والفحص", systemImage: "play.tv.fill")
                }

            SubscribersView(store: store)
                .tabItem {
                    Label("الاشتراكات", systemImage: "person.badge.key.fill")
                }

            ToolsView(store: store)
                .tabItem {
                    Label("سحب اشتراك وستريمو", systemImage: "sparkles.tv.fill")
                }
        }
        .accentColor(Color(red: 0.65, green: 0.35, blue: 0.98))
    }
}

// MARK: - Tab 1: Content & Stream Checker
struct ContentManagerView: View {
    @ObservedObject var store: PanelStore
    @State private var searchText = ""
    @State private var selectedTypeFilter: String = "الكل"
    @State private var selectedGroup = "الكل"
    @State private var showAddSheet = false
    @State private var showCategorySheet = false
    @State private var editingChannel: ChannelItem?
    @State private var playingURL: URL?

    var typeFilters: [String] {
        ["الكل", MediaType.live.rawValue, MediaType.vod.rawValue, MediaType.series.rawValue]
    }

    var groups: [String] {
        ["الكل"] + store.allAvailableGroups
    }

    var filteredChannels: [ChannelItem] {
        store.channels.filter { ch in
            let matchesType = (selectedTypeFilter == "الكل" || ch.type.rawValue == selectedTypeFilter)
            let matchesGroup = (selectedGroup == "الكل" || ch.group == selectedGroup)
            let matchesSearch = searchText.isEmpty || ch.name.localizedCaseInsensitiveContains(searchText)
            return matchesType && matchesGroup && matchesSearch
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    StatBox(title: "بث مباشر", value: "\(store.channels.filter { $0.type == .live }.count)", color: .purple)
                    StatBox(title: "أفلام", value: "\(store.channels.filter { $0.type == .vod }.count)", color: .orange)
                    StatBox(title: "مسلسلات", value: "\(store.channels.filter { $0.type == .series }.count)", color: .pink)
                    StatBox(title: "شغال", value: "\(store.channels.filter { $0.health == .online }.count)", color: .green)
                }
                .padding(.horizontal)

                Picker("النوع", selection: $selectedTypeFilter) {
                    ForEach(typeFilters, id: \.self) { t in
                        Text(t).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button(action: { showCategorySheet = true }) {
                            Label("الأقسام", systemImage: "folder.badge.gearshape")
                                .font(.caption.bold())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.purple.opacity(0.25))
                                .foregroundColor(.purple)
                                .cornerRadius(20)
                        }

                        ForEach(groups, id: \.self) { grp in
                            Button(action: { selectedGroup = grp }) {
                                Text(grp)
                                    .font(.caption.bold())
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 6)
                                    .background(selectedGroup == grp ? Color.purple : Color(.systemGray6))
                                    .foregroundColor(.white)
                                    .cornerRadius(20)
                            }
                        }
                    }
                    .padding(.horizontal)
                }

                if filteredChannels.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "tv.slash")
                            .font(.system(size: 46))
                            .foregroundColor(.gray)
                        Text("لا يوجد محتوى في هذا القسم")
                            .font(.headline)
                        Text("اضغط + لإضافة رابط أو اسحب مكتبة أفلام ومسلسلات من تبويب (سحب اشتراك وستريمو).")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 35)
                        Button("إضافة رابط جديد") { showAddSheet = true }
                            .buttonStyle(.borderedProminent)
                            .tint(.purple)
                    }
                    Spacer()
                } else {
                    List {
                        ForEach(filteredChannels) { ch in
                            HStack(spacing: 12) {
                                VStack {
                                    Circle()
                                        .fill(healthColor(ch.health))
                                        .frame(width: 10, height: 10)
                                    if let ms = ch.pingMs {
                                        Text("\(ms)ms")
                                            .font(.system(size: 9))
                                            .foregroundColor(.secondary)
                                    }
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(ch.name)
                                        .font(.headline)
                                    if !ch.plot.isEmpty {
                                        Text(ch.plot)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                    HStack(spacing: 6) {
                                        Text(ch.group)
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.purple.opacity(0.25))
                                            .cornerRadius(4)
                                        Text(ch.type.rawValue)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        if !ch.episodes.isEmpty {
                                            Text("(\(ch.episodes.count) حلقة)")
                                                .font(.caption2)
                                                .foregroundColor(.pink)
                                        }
                                    }
                                }

                                Spacer()

                                Button(action: { store.checkStreamHealth(id: ch.id) }) {
                                    Image(systemName: "waveform.path.ecg")
                                        .foregroundColor(.orange)
                                }
                                .buttonStyle(.borderless)

                                if let streamURL = URL(string: ch.url) {
                                    Button(action: { playingURL = streamURL }) {
                                        Image(systemName: "play.circle.fill")
                                            .font(.title2)
                                            .foregroundColor(.green)
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { editingChannel = ch }
                        }
                        .onDelete { offsets in
                            let idsToDelete = offsets.map { filteredChannels[$0].id }
                            store.channels.removeAll { idsToDelete.contains($0.id) }
                            store.syncToCloud()
                        }
                    }
                    .searchable(text: $searchText, prompt: "ابحث عن قناة، فيلم، أو مسلسل...")
                }
            }
            .navigationTitle("NOIR Panel")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if !store.channels.isEmpty {
                        Button("فحص الكل") { store.checkAllStreams() }
                            .font(.caption.bold())
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 14) {
                        Button(action: { store.syncToCloud() }) {
                            Image(systemName: "icloud.and.arrow.up")
                        }
                        Button(action: { showAddSheet = true }) {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                        }
                    }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                AddEditChannelSheet(store: store, existingChannel: nil, initialGroup: selectedGroup == "الكل" ? "" : selectedGroup)
            }
            .sheet(item: $editingChannel) { ch in
                AddEditChannelSheet(store: store, existingChannel: ch, initialGroup: ch.group)
            }
            .sheet(isPresented: $showCategorySheet) {
                ManageCategoriesSheet(store: store, selectedGroup: $selectedGroup)
            }
            .sheet(item: $playingURL) { url in
                StreamPlayerView(url: url)
            }
        }
    }

    func healthColor(_ h: StreamHealth) -> Color {
        switch h {
        case .online: return .green
        case .offline: return .red
        case .checking: return .yellow
        case .unknown: return .gray
        }
    }
}

// MARK: - Manage Categories
struct ManageCategoriesSheet: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var store: PanelStore
    @Binding var selectedGroup: String
    @State private var newCatName = ""
    @State private var categoryToRename: String?
    @State private var renameText = ""
    @State private var categoryToDelete: String?

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("إنشاء قسم جديد")) {
                    HStack {
                        TextField("اسم القسم (مثال: الرياضية، وثائقي)", text: $newCatName)
                        Button("إضافة") {
                            store.registerCategory(newCatName)
                            newCatName = ""
                        }
                        .disabled(newCatName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                Section(header: Text("الأقسام الحالية (اضغط لتغيير الاسم أو اسحب للحذف)")) {
                    ForEach(store.allAvailableGroups, id: \.self) { cat in
                        HStack {
                            Text(cat)
                            Spacer()
                            Text("\(store.channels.filter { $0.group == cat }.count) عنصر")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundColor(.purple)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            categoryToRename = cat
                            renameText = cat
                        }
                    }
                    .onDelete { idx in
                        let items = store.allAvailableGroups
                        if let first = idx.first {
                            categoryToDelete = items[first]
                        }
                    }
                }
            }
            .navigationTitle("إدارة الأقسام")
            .toolbar {
                Button("تم") { dismiss() }
            }
            .alert("تغيير اسم القسم", isPresented: Binding(
                get: { categoryToRename != nil },
                set: { if !$0 { categoryToRename = nil } }
            )) {
                TextField("الاسم الجديد للقسم", text: $renameText)
                Button("حفظ التعديل") {
                    if let old = categoryToRename {
                        let cleanNew = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                        store.renameCategory(oldName: old, newName: cleanNew)
                        if selectedGroup == old && !cleanNew.isEmpty {
                            selectedGroup = cleanNew
                        }
                    }
                    categoryToRename = nil
                }
                Button("إلغاء", role: .cancel) { categoryToRename = nil }
            } message: {
                Text("سيتم تحديث اسم القسم في جميع العناصر المرتبطة به وعلى السيرفر تلقائياً.")
            }
            .confirmationDialog("حذف القسم", isPresented: Binding(
                get: { categoryToDelete != nil },
                set: { if !$0 { categoryToDelete = nil } }
            ), titleVisibility: .visible) {
                Button("حذف القسم مع جميع المحتوى بداخله", role: .destructive) {
                    if let target = categoryToDelete {
                        store.deleteCategory(target, deleteChannelsInside: true)
                        if selectedGroup == target { selectedGroup = "الكل" }
                    }
                    categoryToDelete = nil
                }
                Button("حذف القسم فقط ونقل المحتوى إلى (عام)") {
                    if let target = categoryToDelete {
                        store.deleteCategory(target, deleteChannelsInside: false)
                        if selectedGroup == target { selectedGroup = "الكل" }
                    }
                    categoryToDelete = nil
                }
                Button("إلغاء", role: .cancel) { categoryToDelete = nil }
            } message: {
                Text("اختر طريقة حذف قسم \"\(categoryToDelete ?? "")\":")
            }
        }
    }
}

// MARK: - Add/Edit Channel Sheet
struct AddEditChannelSheet: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var store: PanelStore
    var existingChannel: ChannelItem?
    var initialGroup: String

    @State private var name = ""
    @State private var group = ""
    @State private var logo = ""
    @State private var url = ""
    @State private var plot = ""
    @State private var cast = ""
    @State private var type: MediaType = .live
    @State private var previewURL: URL?

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("1. اختر التصنيف")) {
                    Picker("النوع", selection: $type) {
                        ForEach(MediaType.allCases, id: \.self) { t in
                            Text(t.rawValue).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section(header: Text("2. القسم")) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(store.allAvailableGroups, id: \.self) { existingGrp in
                                Button(action: { group = existingGrp }) {
                                    Text(existingGrp)
                                        .font(.caption.bold())
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(group == existingGrp ? Color.purple : Color(.systemGray5))
                                        .foregroundColor(.white)
                                        .cornerRadius(16)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    TextField("اسم القسم (مثال: الرياضية)", text: $group)
                }

                Section(header: Text("3. البيانات الأساسية")) {
                    TextField("الاسم", text: $name)
                    TextField("رابط البث (.m3u8 أو .mp4)", text: $url)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    TextField("رابط البوستر / الشعار (اختياري)", text: $logo)
                        .textInputAutocapitalization(.never)
                }

                if type != .live {
                    Section(header: Text("4. تفاصيل الفيلم أو المسلسل (تظهر في المشغل)")) {
                        TextField("الممثلين (مثال: Tom Cruise, ...)", text: $cast)
                        TextField("قصة الفيلم / الوصف", text: $plot)
                    }
                }

                if let validURL = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)), !url.isEmpty {
                    Section(header: Text("اختبار البث")) {
                        Button(action: { previewURL = validURL }) {
                            Label("تشغيل ومشاهدة البث الآن", systemImage: "play.rectangle.fill")
                                .foregroundColor(.green)
                        }
                    }
                }
            }
            .navigationTitle(existingChannel == nil ? "إضافة رابط جديد" : "تعديل البيانات")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("إلغاء") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("حفظ") {
                        if var edited = existingChannel {
                            edited.name = name
                            edited.group = group.isEmpty ? "عام" : group
                            edited.logo = logo
                            edited.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
                            edited.type = type
                            edited.plot = plot
                            edited.cast = cast
                            store.updateChannel(edited)
                        } else {
                            store.addChannel(name: name, group: group, logo: logo, url: url, type: type, plot: plot, cast: cast)
                        }
                        dismiss()
                    }
                    .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if let ch = existingChannel {
                    name = ch.name
                    group = ch.group
                    logo = ch.logo
                    url = ch.url
                    type = ch.type
                    plot = ch.plot
                    cast = ch.cast
                } else if !initialGroup.isEmpty {
                    group = initialGroup
                }
            }
            .sheet(item: $previewURL) { u in
                StreamPlayerView(url: u)
            }
        }
    }
}

// MARK: - Tab 2: Subscriptions
struct SubscribersView: View {
    @ObservedObject var store: PanelStore
    @State private var username = ""
    @State private var password = ""
    @State private var days = 30
    @State private var alertText = ""
    @State private var showAlert = false

    var body: some View {
        NavigationView {
            VStack(spacing: 12) {
                VStack(spacing: 10) {
                    HStack {
                        TextField("اسم المستخدم", text: $username)
                            .textInputAutocapitalization(.never)
                            .padding(10).background(Color(.systemGray6)).cornerRadius(8)

                        TextField("كلمة المرور", text: $password)
                            .textInputAutocapitalization(.never)
                            .padding(10).background(Color(.systemGray6)).cornerRadius(8)

                        Button(action: generateRandomCreds) {
                            Image(systemName: "dice.fill")
                                .padding(10)
                                .background(Color(.systemGray5))
                                .cornerRadius(8)
                        }
                    }

                    HStack {
                        Text("المدة:")
                            .font(.subheadline)
                        Picker("المدة", selection: $days) {
                            Text("يوم").tag(1)
                            Text("أسبوع").tag(7)
                            Text("شهر").tag(30)
                            Text("سنة").tag(365)
                        }
                        .pickerStyle(.segmented)
                    }

                    Button(action: {
                        store.addUser(username: username, password: password, days: days)
                        username = ""; password = ""
                    }) {
                        Label("إنشاء وتوليد الاشتراك", systemImage: "key.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                }
                .padding()
                .background(Color(.systemGray6).opacity(0.35))
                .cornerRadius(12)
                .padding(.horizontal)

                if store.users.isEmpty {
                    Spacer()
                    Text("لا يوجد مشتركين بعد. أنشئ أول اشتراك من الأعلى ليظهر لك رابط M3U وبيانات Xtream.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 35)
                    Spacer()
                } else {
                    List {
                        ForEach(store.users) { u in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(u.username)
                                            .font(.headline)
                                        Text("Pass: \(u.password) • \(u.daysValid) يوم")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Button(u.isActive ? "مفعّل" : "موقوف") {
                                        store.toggleUserStatus(id: u.id)
                                    }
                                    .font(.caption.bold())
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(u.isActive ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
                                    .foregroundColor(u.isActive ? .green : .red)
                                    .cornerRadius(8)
                                }

                                HStack(spacing: 8) {
                                    Button("نسخ Xtream") {
                                        UIPasteboard.general.string = """
                                        Host: \(store.serverURL)
                                        Username: \(u.username)
                                        Password: \(u.password)
                                        """
                                        alertText = "تم نسخ بيانات Xtream Codes!"
                                        showAlert = true
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.purple)
                                    .font(.caption)

                                    Button("نسخ رابط M3U") {
                                        UIPasteboard.general.string = "\(store.serverURL)/get.php?username=\(u.username)&password=\(u.password)"
                                        alertText = "تم نسخ رابط M3U المباشر!"
                                        showAlert = true
                                    }
                                    .buttonStyle(.bordered)
                                    .font(.caption)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .onDelete { idx in
                            store.users.remove(atOffsets: idx)
                            store.syncToCloud()
                        }
                    }
                }
            }
            .navigationTitle("توليد الاشتراكات")
            .alert("تم النسخ", isPresented: $showAlert) {
                Button("حسناً", role: .cancel) {}
            } message: {
                Text(alertText)
            }
        }
    }

    func generateRandomCreds() {
        let num = Int.random(in: 1000...9999)
        username = "noir\(num)"
        password = "\(Int.random(in: 100000...999999))"
    }
}

// MARK: - Tab 3: Stremio Addon Importer & IPTV Cloner
struct ToolsView: View {
    @ObservedObject var store: PanelStore
    @State private var importMode = 0
    @State private var stremioManifest = ""
    @State private var stremioLimit = 15
    @State private var xtreamHost = ""
    @State private var xtreamUser = ""
    @State private var xtreamPass = ""
    @State private var m3uLink = ""
    @State private var statusAlert = ""
    @State private var showAlert = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("سحب الأفلام والمسلسلات أو الاشتراكات")) {
                    Picker("المصدر", selection: $importMode) {
                        Text("إضافة Stremio").tag(0)
                        Text("Xtream").tag(1)
                        Text("رابط M3U").tag(2)
                    }
                    .pickerStyle(.segmented)

                    if importMode == 0 {
                        TextField("رابط الإضافة (https://.../manifest.json)", text: $stremioManifest)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)

                        Stepper("عدد العناصر لكل قسم: \(stremioLimit)", value: $stremioLimit, in: 5...50, step: 5)

                        Text("يجلب الأفلام والمسلسلات فقط مع البوستر، الوصف، الممثلين، والحلقات بفاصل زمني آمن لحماية حساب TorBox.")
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        Button(action: {
                            store.importFromStremioAddon(manifestURL: stremioManifest, maxItemsPerCatalog: stremioLimit) { msg in
                                statusAlert = msg
                                showAlert = true
                            }
                        }) {
                            HStack {
                                Label("سحب الأفلام والمسلسلات الآن", systemImage: "sparkles.tv.fill")
                                if store.isSyncing { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(stremioManifest.isEmpty || store.isSyncing)

                    } else if importMode == 1 {
                        TextField("الهوست (مثال: http://line.tv:8080)", text: $xtreamHost)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                        TextField("اسم المستخدم", text: $xtreamUser)
                            .textInputAutocapitalization(.never)
                        TextField("كلمة المرور", text: $xtreamPass)
                            .textInputAutocapitalization(.never)

                        Button(action: {
                            store.importFromXtream(host: xtreamHost, username: xtreamUser, password: xtreamPass) { msg in
                                statusAlert = msg
                                showAlert = true
                            }
                        }) {
                            HStack {
                                Label("سحب اشتراك Xtream كامل", systemImage: "arrow.down.circle.fill")
                                if store.isSyncing { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(xtreamHost.isEmpty || xtreamUser.isEmpty || xtreamPass.isEmpty || store.isSyncing)

                    } else {
                        TextField("رابط اشتراك M3U المباشر (http://...)", text: $m3uLink)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)

                        Button(action: {
                            store.importFromM3UURL(m3uLink) { msg in
                                statusAlert = msg
                                showAlert = true
                            }
                        }) {
                            HStack {
                                Label("تحميل القائمة من الرابط", systemImage: "link.badge.plus")
                                if store.isSyncing { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(m3uLink.isEmpty || store.isSyncing)
                    }
                }

                Section(header: Text("المزامنة السحابية والتصدير")) {
                    Button(action: {
                        UIPasteboard.general.string = store.generateFullM3U()
                        statusAlert = "تم نسخ قائمتك كاملة بصيغة M3U."
                        showAlert = true
                    }) {
                        Label("نسخ قائمتي بصيغة M3U", systemImage: "doc.on.doc.fill")
                    }

                    Button(action: { store.syncToCloud() }) {
                        HStack {
                            Label("رفع التحديثات للسيرفر", systemImage: "icloud.and.arrow.up.fill")
                            Spacer()
                            Text(store.syncStatus).font(.caption).foregroundColor(.secondary)
                        }
                    }

                    Button(action: {
                        store.pullFromCloud()
                        statusAlert = "جاري سحب البيانات من السيرفر..."
                        showAlert = true
                    }) {
                        Label("استرجاع البيانات من السيرفر", systemImage: "icloud.and.arrow.down.fill")
                            .foregroundColor(.green)
                    }
                }
            }
            .navigationTitle("سحب اشتراك وستريمو")
            .alert("النتيجة", isPresented: $showAlert) {
                Button("حسناً", role: .cancel) {}
            } message: {
                Text(statusAlert)
            }
        }
    }
}

// MARK: - Helper Views
struct StatBox: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.headline.bold())
                .foregroundColor(color)
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(.systemGray6).opacity(0.4))
        .cornerRadius(10)
    }
}

struct StreamPlayerView: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            if let player = player {
                VideoPlayer(player: player)
                    .edgesIgnoringSafeArea(.all)
            }
        }
        .onAppear {
            let p = AVPlayer(url: url)
            self.player = p
            p.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}

extension URL: Identifiable {
    public var id: String { absoluteString }
}
