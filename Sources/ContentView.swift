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

struct ChannelItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var group: String
    var logo: String
    var url: String
    var type: MediaType = .live
    var health: StreamHealth = .unknown
    var pingMs: Int? = nil
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

    let serverURL = "https://noir-tv.mkdos101.workers.dev"
    let adminKey = "noir2026"

    init() { load() }

    // جميع الأقسام المتاحة (المحفوظة + الموجودة في القنوات)
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

    func addChannel(name: String, group: String, logo: String, url: String, type: MediaType) {
        let cleanURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanURL.isEmpty else { return }
        let finalGroup = group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "عام" : group.trimmingCharacters(in: .whitespacesAndNewlines)
        registerCategory(finalGroup)

        let item = ChannelItem(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "قناة جديدة" : name,
            group: finalGroup,
            logo: logo.trimmingCharacters(in: .whitespacesAndNewlines),
            url: cleanURL,
            type: type
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

    // تحليل واستيراد نص M3U
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

    // سحب اشتراك كامل عبر رابط M3U URL
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
                completion(count > 0 ? "تم نسخ واستيراد \(count) قناة/محتوى بنجاح!" : "الملف فارغ أو لا يحتوي روابط صالحة")
            }
        }.resume()
    }

    // سحب اشتراك كامل عبر بيانات Xtream Codes (Host + User + Pass)
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

    // فحص البث
    func checkStreamHealth(id: UUID) {
        guard let index = channels.firstIndex(where: { $0.id == id }),
              let url = URL(string: channels[index].url) else { return }

        channels[index].health = .checking
        let startTime = Date()

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
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
        for ch in channels {
            checkStreamHealth(id: ch.id)
        }
    }

    // المشتركين
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

    // المزامنة مع السيرفر
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
            "channels": channels.map { [
                "name": $0.name,
                "group": $0.group,
                "logo": $0.logo,
                "url": $0.url,
                "type": $0.type.serverCode
            ] },
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
                        self.registerCategory(group)
                        return ChannelItem(
                            name: name,
                            group: group,
                            logo: logo,
                            url: streamUrl,
                            type: MediaType.fromServer(typeStr)
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
            UserDefaults.standard.set(chData, forKey: "noir_v3_channels")
        }
        if let uData = try? JSONEncoder().encode(users) {
            UserDefaults.standard.set(uData, forKey: "noir_v3_users")
        }
        UserDefaults.standard.set(savedCategories, forKey: "noir_v3_cats")
    }

    private func load() {
        if let chData = UserDefaults.standard.data(forKey: "noir_v3_channels"),
           let decoded = try? JSONDecoder().decode([ChannelItem].self, from: chData) {
            channels = decoded
        }
        if let uData = UserDefaults.standard.data(forKey: "noir_v3_users"),
           let decoded = try? JSONDecoder().decode([SubUser].self, from: uData) {
            users = decoded
        }
        if let cats = UserDefaults.standard.stringArray(forKey: "noir_v3_cats") {
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
                    Label("سحب اشتراك والسيرفر", systemImage: "arrow.down.doc.fill")
                }
        }
        .accentColor(Color(red: 0.65, green: 0.35, blue: 0.98))
    }
}

// MARK: - Tab 1: Content, Categories & Stream Checker
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
                // إحصائيات
                HStack(spacing: 10) {
                    StatBox(title: "بث مباشر", value: "\(store.channels.filter { $0.type == .live }.count)", color: .purple)
                    StatBox(title: "أفلام", value: "\(store.channels.filter { $0.type == .vod }.count)", color: .orange)
                    StatBox(title: "مسلسلات", value: "\(store.channels.filter { $0.type == .series }.count)", color: .pink)
                    StatBox(title: "شغال", value: "\(store.channels.filter { $0.health == .online }.count)", color: .green)
                }
                .padding(.horizontal)

                // فلتر النوع (الكل / بث مباشر / أفلام / مسلسلات)
                Picker("النوع", selection: $selectedTypeFilter) {
                    ForEach(typeFilters, id: \.self) { t in
                        Text(t).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                // شريط الأقسام الأفقي + زر إضافة قسم
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button(action: { showCategorySheet = true }) {
                            Label("قسم +", systemImage: "folder.badge.plus")
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
                        Text("اضغط + لإضافة رابط جديد أو اسحب اشتراك جاهز من تبويب (سحب اشتراك).")
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
                ManageCategoriesSheet(store: store)
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

// نافذة إدارة الأقسام
struct ManageCategoriesSheet: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var store: PanelStore
    @State private var newCatName = ""

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

                Section(header: Text("الأقسام المحفوظة")) {
                    ForEach(store.allAvailableGroups, id: \.self) { cat in
                        HStack {
                            Text(cat)
                            Spacer()
                            Text("\(store.channels.filter { $0.group == cat }.count) عنصر")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .onDelete { idx in
                        let items = store.allAvailableGroups
                        for i in idx {
                            let target = items[i]
                            store.savedCategories.removeAll { $0 == target }
                        }
                    }
                }
            }
            .navigationTitle("إدارة الأقسام")
            .toolbar {
                Button("تم") { dismiss() }
            }
        }
    }
}

// نافذة الإضافة والتعديل مع أزرار اختيار الأقسام الموجودة
struct AddEditChannelSheet: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var store: PanelStore
    var existingChannel: ChannelItem?
    var initialGroup: String

    @State private var name = ""
    @State private var group = ""
    @State private var logo = ""
    @State private var url = ""
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

                Section(header: Text("2. القسم (اختر من الموجود أو اكتب قسماً جديداً)")) {
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

                Section(header: Text("3. بيانات البث")) {
                    TextField("الاسم (مثال: الرياضية 1، مسلسل...)", text: $name)
                    TextField("رابط البث (.m3u8 أو .mp4)", text: $url)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    TextField("رابط الشعار Logo (اختياري)", text: $logo)
                        .textInputAutocapitalization(.never)
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
            .navigationTitle(existingChannel == nil ? "إضافة رابط جديد" : "تعديل الرابط")
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
                            store.updateChannel(edited)
                        } else {
                            store.addChannel(name: name, group: group, logo: logo, url: url, type: type)
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

// MARK: - Tab 2: Subscriptions Generator
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

// MARK: - Tab 3: Subscription Cloner / Importer & Cloud
struct ToolsView: View {
    @ObservedObject var store: PanelStore
    @State private var importMode = 0 // 0 = Xtream, 1 = M3U URL, 2 = Raw Text
    @State private var xtreamHost = ""
    @State private var xtreamUser = ""
    @State private var xtreamPass = ""
    @State private var m3uLink = ""
    @State private var m3uRawText = ""
    @State private var statusAlert = ""
    @State private var showAlert = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("نسخ محتوى اشتراك IPTV جاهز وإضافته")) {
                    Picker("طريقة السحب", selection: $importMode) {
                        Text("بيانات Xtream").tag(0)
                        Text("رابط M3U").tag(1)
                        Text("نص M3U").tag(2)
                    }
                    .pickerStyle(.segmented)

                    if importMode == 0 {
                        TextField("الهوست (مثال: http://line.tv:8080)", text: $xtreamHost)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                        TextField("اسم المستخدم (Username)", text: $xtreamUser)
                            .textInputAutocapitalization(.never)
                        TextField("كلمة المرور (Password)", text: $xtreamPass)
                            .textInputAutocapitalization(.never)

                        Button(action: {
                            store.importFromXtream(host: xtreamHost, username: xtreamUser, password: xtreamPass) { msg in
                                statusAlert = msg
                                showAlert = true
                            }
                        }) {
                            HStack {
                                Label("سحب كل قنوات وأقسام الاشتراك", systemImage: "arrow.down.circle.fill")
                                if store.isSyncing { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(xtreamHost.isEmpty || xtreamUser.isEmpty || xtreamPass.isEmpty || store.isSyncing)

                    } else if importMode == 1 {
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
                                Label("تحميل ونسخ القائمة من الرابط", systemImage: "link.badge.plus")
                                if store.isSyncing { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(m3uLink.isEmpty || store.isSyncing)

                    } else {
                        TextEditor(text: $m3uRawText)
                            .frame(height: 110)
                            .overlay(
                                Group {
                                    if m3uRawText.isEmpty {
                                        Text("الصق محتوى #EXTM3U هنا...")
                                            .foregroundColor(.gray)
                                            .padding(8)
                                    }
                                }, alignment: .topLeading
                            )

                        Button(action: {
                            let count = store.importM3U(rawText: m3uRawText)
                            m3uRawText = ""
                            statusAlert = count > 0 ? "تم استيراد \(count) رابط بنجاح!" : "لم يتم العثور على روابط."
                            showAlert = true
                        }) {
                            Label("تحليل وإضافة النص", systemImage: "doc.text.fill")
                        }
                        .disabled(m3uRawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
            .navigationTitle("سحب اشتراك والسيرفر")
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
