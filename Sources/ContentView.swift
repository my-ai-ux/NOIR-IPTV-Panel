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

enum MediaType: String, Codable, CaseIterable {
    case live = "بث مباشر"
    case vod = "أفلام / VOD"
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

class PanelStore: ObservableObject {
    @Published var channels: [ChannelItem] = [] { didSet { save() } }
    @Published var users: [SubUser] = [] { didSet { save() } }
    @Published var isSyncing = false
    @Published var syncStatus = "جاهز للمزامنة"

    let serverURL = "https://noir-tv.mkdos101.workers.dev"
    let adminKey = "noir2026"

    init() { load() }

    func addChannel(name: String, group: String, logo: String, url: String, type: MediaType) {
        let cleanURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanURL.isEmpty else { return }
        let item = ChannelItem(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "قناة جديدة" : name,
            group: group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "عام" : group,
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
            channels[idx] = updated
            checkStreamHealth(id: updated.id)
            syncToCloud()
        }
    }

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
                let item = ChannelItem(
                    name: currentName.isEmpty ? "قناة \(importedCount + 1)" : currentName,
                    group: currentGroup,
                    logo: currentLogo,
                    url: trimmed,
                    type: defaultType
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
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { _, response, error in
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
            DispatchQueue.main.async {
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
            "channels": channels.map { [
                "name": $0.name,
                "group": $0.group,
                "logo": $0.logo,
                "url": $0.url,
                "type": $0.type == .live ? "live" : "movie"
            ] },
            "users": activeUsers.map { [
                "username": $0.username,
                "password": $0.password,
                "daysValid": $0.daysValid
            ] }
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
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
            DispatchQueue.main.async {
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
                        return ChannelItem(
                            name: name,
                            group: group,
                            logo: logo,
                            url: streamUrl,
                            type: typeStr == "movie" ? .vod : .live
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
            UserDefaults.standard.set(chData, forKey: "noir_clean_channels")
        }
        if let uData = try? JSONEncoder().encode(users) {
            UserDefaults.standard.set(uData, forKey: "noir_clean_users")
        }
    }

    private func load() {
        if let chData = UserDefaults.standard.data(forKey: "noir_clean_channels"),
           let decoded = try? JSONDecoder().decode([ChannelItem].self, from: chData) {
            channels = decoded
        }
        if let uData = UserDefaults.standard.data(forKey: "noir_clean_users"),
           let decoded = try? JSONDecoder().decode([SubUser].self, from: uData) {
            users = decoded
        }
    }
}

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
                    Label("الاستيراد والسيرفر", systemImage: "arrow.triangle.2.circlepath.circle.fill")
                }
        }
        .accentColor(Color(red: 0.65, green: 0.35, blue: 0.98))
    }
}

struct ContentManagerView: View {
    @ObservedObject var store: PanelStore
    @State private var searchText = ""
    @State private var selectedGroup = "الكل"
    @State private var showAddSheet = false
    @State private var editingChannel: ChannelItem?
    @State private var playingURL: URL?

    var groups: [String] {
        let all = Set(store.channels.map { $0.group })
        return ["الكل"] + all.sorted()
    }

    var filteredChannels: [ChannelItem] {
        store.channels.filter { ch in
            let matchesGroup = (selectedGroup == "الكل" || ch.group == selectedGroup)
            let matchesSearch = searchText.isEmpty || ch.name.localizedCaseInsensitiveContains(searchText)
            return matchesGroup && matchesSearch
        }
    }

    var onlineCount: Int {
        store.channels.filter { $0.health == .online }.count
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    StatBox(title: "الإجمالي", value: "\(store.channels.count)", color: .purple)
                    StatBox(title: "شغال", value: "\(onlineCount)", color: .green)
                    StatBox(title: "المشتركين", value: "\(store.users.filter { $0.isActive }.count)", color: .blue)
                }
                .padding(.horizontal)

                if !store.channels.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
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
                }

                if store.channels.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "tv.slash")
                            .font(.system(size: 50))
                            .foregroundColor(.gray)
                        Text("القائمة فارغة حالياً")
                            .font(.headline)
                        Text("اضغط على زر + في الأعلى لإضافة قنواتك أو أفلامك وفحص بثها.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                        Button("إضافة أول رابط") { showAddSheet = true }
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
                    .searchable(text: $searchText, prompt: "ابحث عن قناة أو فيلم...")
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
                AddEditChannelSheet(store: store, existingChannel: nil)
            }
            .sheet(item: $editingChannel) { ch in
                AddEditChannelSheet(store: store, existingChannel: ch)
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

struct AddEditChannelSheet: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var store: PanelStore
    var existingChannel: ChannelItem?

    @State private var name = ""
    @State private var group = ""
    @State private var logo = ""
    @State private var url = ""
    @State private var type: MediaType = .live
    @State private var previewURL: URL?

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("نوع المحتوى")) {
                    Picker("النوع", selection: $type) {
                        ForEach(MediaType.allCases, id: \.self) { t in
                            Text(t.rawValue).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section(header: Text("بيانات القناة أو الفيلم")) {
                    TextField("الاسم (مثال: الرياضية 1)", text: $name)
                    TextField("القسم / الباقة (مثال: رياضة، أفلام)", text: $group)
                    TextField("رابط الشعار Logo (اختياري)", text: $logo)
                        .textInputAutocapitalization(.never)
                    TextField("رابط البث (.m3u8 أو .mp4)", text: $url)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                }

                if let validURL = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)), !url.isEmpty {
                    Section(header: Text("اختبار البث قبل الاعتماد")) {
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
                }
            }
            .sheet(item: $previewURL) { u in
                StreamPlayerView(url: u)
            }
        }
    }
}

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
                        Text("مدة الاشتراك:")
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

struct ToolsView: View {
    @ObservedObject var store: PanelStore
    @State private var m3uInput = ""
    @State private var importType: MediaType = .live
    @State private var statusAlert = ""
    @State private var showAlert = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("استيراد قائمة M3U دفعة واحدة")) {
                    Picker("تصنيف القائمة المستوردة", selection: $importType) {
                        ForEach(MediaType.allCases, id: \.self) { t in
                            Text(t.rawValue).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)

                    TextEditor(text: $m3uInput)
                        .frame(height: 130)
                        .overlay(
                            Group {
                                if m3uInput.isEmpty {
                                    Text("الصق محتوى ملف #EXTM3U هنا...")
                                        .foregroundColor(.gray)
                                        .padding(8)
                                }
                            }, alignment: .topLeading
                        )

                    Button(action: {
                        let count = store.importM3U(rawText: m3uInput, defaultType: importType)
                        m3uInput = ""
                        statusAlert = count > 0 ? "تم استيراد \(count) رابط بنجاح ورفعها للسيرفر!" : "لم يتم العثور على روابط صالحة في النص."
                        showAlert = true
                    }) {
                        Label("استيراد وتحليل القائمة", systemImage: "square.and.arrow.down.fill")
                    }
                    .disabled(m3uInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section(header: Text("التصدير والمزامنة السحابية")) {
                    Button(action: {
                        UIPasteboard.general.string = store.generateFullM3U()
                        statusAlert = "تم نسخ ملف M3U الكامل للحافظة."
                        showAlert = true
                    }) {
                        Label("نسخ قائمتي بصيغة M3U", systemImage: "doc.on.doc.fill")
                    }

                    Button(action: { store.syncToCloud() }) {
                        HStack {
                            Label("مزامنة يدوية مع السيرفر", systemImage: "icloud.and.arrow.up.fill")
                            Spacer()
                            Text(store.syncStatus)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Button(action: {
                        store.pullFromCloud()
                        statusAlert = "جاري سحب القنوات والاشتراكات المحفوظة من السيرفر..."
                        showAlert = true
                    }) {
                        Label("استرجاع البيانات من السيرفر", systemImage: "icloud.and.arrow.down.fill")
                            .foregroundColor(.green)
                    }
                }

                Section(header: Text("بيانات السيرفر المرتبط")) {
                    HStack {
                        Text("الهوست")
                        Spacer()
                        Text(store.serverURL)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("الأدوات والاستيراد")
            .alert("تنبيه", isPresented: $showAlert) {
                Button("حسناً", role: .cancel) {}
            } message: {
                Text(statusAlert)
            }
        }
    }
}

struct StatBox: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2.bold())
                .foregroundColor(color)
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
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
