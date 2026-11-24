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

struct ChannelItem: Identifiable, Codable {
    var id = UUID()
    var name: String
    var group: String
    var logo: String
    var url: String
}

struct SubUser: Identifiable, Codable {
    var id = UUID()
    var username: String
    var password: String
}

class PanelStore: ObservableObject {
    @Published var channels: [ChannelItem] = [] { didSet { save() } }
    @Published var users: [SubUser] = [] { didSet { save() } }
    @Published var isSyncing = false
    @Published var syncMessage = ""

    let serverURL = "https://noir-tv.mkdos101.workers.dev"
    let adminKey = "noir2026"

    init() { load() }

    func addChannel(name: String, group: String, logo: String, url: String) {
        let clean = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        channels.insert(ChannelItem(
            name: name.isEmpty ? "قناة بدون اسم" : name,
            group: group.isEmpty ? "عام" : group,
            logo: logo.trimmingCharacters(in: .whitespacesAndNewlines),
            url: clean
        ), at: 0)
    }

    func addUser(username: String, password: String) {
        let u = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty, !p.isEmpty else { return }
        users.insert(SubUser(username: u, password: p), at: 0)
    }

    func syncToCloud() {
        guard let url = URL(string: "\(serverURL)/api/sync") else { return }
        isSyncing = true
        syncMessage = "جاري رفع البيانات للسيرفر..."

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(adminKey)", forHTTPHeaderField: "Authorization")

        let payload: [String: Any] = [
            "channels": channels.map { ["name": $0.name, "group": $0.group, "logo": $0.logo, "url": $0.url] },
            "users": users.map { ["username": $0.username, "password": $0.password] }
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                self.isSyncing = false
                if let http = response as? HTTPURLResponse, http.statusCode == 200, error == nil {
                    self.syncMessage = "تم تحديث السيرفر بنجاح!"
                } else {
                    self.syncMessage = "فشل الاتصال بالسيرفر، تأكد من ربط DB في Cloudflare."
                }
            }
        }.resume()
    }

    private func save() {
        if let chData = try? JSONEncoder().encode(channels) {
            UserDefaults.standard.set(chData, forKey: "noir_channels")
        }
        if let uData = try? JSONEncoder().encode(users) {
            UserDefaults.standard.set(uData, forKey: "noir_users")
        }
    }

    private func load() {
        if let chData = UserDefaults.standard.data(forKey: "noir_channels"),
           let decoded = try? JSONDecoder().decode([ChannelItem].self, from: chData) {
            channels = decoded
        }
        if let uData = UserDefaults.standard.data(forKey: "noir_users"),
           let decoded = try? JSONDecoder().decode([SubUser].self, from: uData) {
            users = decoded
        }
    }
}

struct ContentView: View {
    @StateObject private var store = PanelStore()
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            ChannelsTab(store: store)
                .tabItem { Label("القنوات والفحص", systemImage: "tv.fill") }
                .tag(0)

            UsersTab(store: store)
                .tabItem { Label("الاشتراكات", systemImage: "person.2.fill") }
                .tag(1)
        }
        .accentColor(.purple)
    }
}

// تبويب القنوات وفحص البث
struct ChannelsTab: View {
    @ObservedObject var store: PanelStore
    @State private var name = ""
    @State private var group = "رياضة"
    @State private var logo = ""
    @State private var url = ""
    @State private var playingURL: URL?

    var body: some View {
        NavigationView {
            VStack(spacing: 10) {
                VStack(spacing: 8) {
                    HStack {
                        TextField("اسم القناة", text: $name)
                            .padding(10).background(Color(.systemGray6)).cornerRadius(8)
                        TextField("القسم", text: $group)
                            .frame(width: 90)
                            .padding(10).background(Color(.systemGray6)).cornerRadius(8)
                    }
                    TextField("رابط البث (.m3u8 أو .mp4)", text: $url)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .padding(10).background(Color(.systemGray6)).cornerRadius(8)

                    HStack {
                        Button(action: {
                            store.addChannel(name: name, group: group, logo: logo, url: url)
                            name = ""; url = ""
                        }) {
                            Label("إضافة للقائمة", systemImage: "plus.circle.fill")
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent).tint(.purple)

                        if let testURL = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)), !url.isEmpty {
                            Button(action: { playingURL = testURL }) {
                                Label("فحص البث", systemImage: "play.fill")
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.bordered).tint(.green)
                        }
                    }
                }
                .padding()
                .background(Color(.systemGray6).opacity(0.3))
                .cornerRadius(12)
                .padding(.horizontal)

                List {
                    ForEach(store.channels) { ch in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(ch.name).font(.headline)
                                Text(ch.group).font(.caption).foregroundColor(.purple)
                            }
                            Spacer()
                            if let streamURL = URL(string: ch.url) {
                                Button(action: { playingURL = streamURL }) {
                                    Image(systemName: "play.circle.fill").font(.title2).foregroundColor(.green)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .onDelete { idx in store.channels.remove(atOffsets: idx) }
                }
            }
            .navigationTitle("NOIR Panel")
            .toolbar {
                Button(action: { store.syncToCloud() }) {
                    HStack {
                        Image(systemName: "icloud.and.arrow.up.fill")
                        Text("نشر للسيرفر")
                    }
                }
                .disabled(store.isSyncing)
            }
            .sheet(item: $playingURL) { streamURL in
                StreamPlayerView(url: streamURL)
            }
        }
    }
}

// تبويب المشتركين وتوليد الروابط
struct UsersTab: View {
    @ObservedObject var store: PanelStore
    @State private var username = ""
    @State private var password = ""
    @State private var copiedAlert = false

    var body: some View {
        NavigationView {
            VStack(spacing: 12) {
                VStack(spacing: 8) {
                    HStack {
                        TextField("اسم المستخدم (User)", text: $username)
                            .textInputAutocapitalization(.never)
                            .padding(10).background(Color(.systemGray6)).cornerRadius(8)
                        TextField("كلمة المرور (Pass)", text: $password)
                            .textInputAutocapitalization(.never)
                            .padding(10).background(Color(.systemGray6)).cornerRadius(8)
                    }

                    Button(action: {
                        store.addUser(username: username, password: password)
                        username = ""; password = ""
                        store.syncToCloud()
                    }) {
                        Label("إنشاء وتفعيل الاشتراك", systemImage: "key.fill")
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent).tint(.purple)

                    if !store.syncMessage.isEmpty {
                        Text(store.syncMessage)
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
                .padding()
                .background(Color(.systemGray6).opacity(0.3))
                .cornerRadius(12)
                .padding(.horizontal)

                List {
                    ForEach(store.users) { u in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("المشترك: \(u.username)").font(.headline)
                                Spacer()
                                Text("Pass: \(u.password)").font(.caption).foregroundColor(.secondary)
                            }

                            HStack(spacing: 10) {
                                Button("نسخ Xtream") {
                                    let xtream = """
                                    Host: \(store.serverURL)
                                    Username: \(u.username)
                                    Password: \(u.password)
                                    """
                                    UIPasteboard.general.string = xtream
                                    copiedAlert = true
                                }
                                .buttonStyle(.borderedProminent).tint(.purple)

                                Button("نسخ رابط M3U") {
                                    let m3u = "\(store.serverURL)/get.php?username=\(u.username)&password=\(u.password)"
                                    UIPasteboard.general.string = m3u
                                    copiedAlert = true
                                }
                                .buttonStyle(.bordered)
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
            .navigationTitle("توليد الاشتراكات")
            .alert("تم النسخ", isPresented: $copiedAlert) {
                Button("تمام", role: .cancel) {}
            } message: {
                Text("تم نسخ بيانات الاشتراك للحافظة جاهزة للإرسال أو التشغيل.")
            }
        }
    }
}

struct StreamPlayerView: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            if let player = player {
                VideoPlayer(player: player).edgesIgnoringSafeArea(.all)
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
