import AppKit
import Combine
import Foundation

extension Notification.Name {
    /// Posted after settings were changed by another Mac through sync.
    static let settingsSyncedFromCloud = Notification.Name("SettingsSyncedFromCloud")
}

/// Syncs vocabulary, settings, usage and history through the iCloud Drive folder.
///
/// Every Mac writes only its own folder (`ChillTalk/devices/<id>/`) and reads everyone
/// else's, so iCloud never sees two writers on one file and never makes conflict copies.
/// API keys are never synced.
@MainActor
final class SyncService: ObservableObject {
    enum Kind: String, CaseIterable, Identifiable {
        case vocabulary, settings, usage, history
        var id: String { rawValue }
    }

    enum Status: Equatable {
        case unavailable        // iCloud Drive not enabled
        case off                // nothing selected
        case idle(Date?)
        case syncing
        case failed(String)
    }

    struct Device: Identifiable, Codable, Equatable {
        let id: String
        var name: String
        var updatedAt: Date
    }

    static let shared = SyncService(root: SyncService.defaultRoot(), defaults: .standard,
                                    history: .shared, vocabulary: .shared)

    @Published private(set) var status: Status = .off
    @Published private(set) var otherDevices: [Device] = []
    @Published var enabled: [Kind: Bool] {
        didSet { persistToggles(); updateTimer(); syncSoon() }
    }
    @Published var mergeHistory: Bool {
        didSet { persistToggles(); applyRemoteHistoryVisibility(); syncSoon() }
    }

    let deviceID: String
    let deviceName: String
    private let root: URL?
    private let defaults: UserDefaults
    private let history: HistoryStore
    private let vocabulary: VocabularyStore
    private var timer: Timer?
    private var pending: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    private var isApplyingRemote = false

    /// UserDefaults keys synced as settings (no API keys; those live in the Keychain).
    static let settingKeys = [
        "asrProvider", "dashScopeASRModel", "dashScopeBatchASRModel", "polishEnabled", "polishProvider", "dashScopePolishModel",
        "openRouterModel", "hotkeyPreset", "correctionHotkeyPreset", "trailingPeriod", "phoneticCorrection",
        "dictationLanguage", "mixEnglish", "voiceProcessing", "recognitionMode"
    ]
    private static let contextKey = "recognitionContext"

    init(root: URL?, defaults: UserDefaults, history: HistoryStore, vocabulary: VocabularyStore,
         deviceName: String = Host.current().localizedName ?? "Mac") {
        self.root = root
        self.defaults = defaults
        self.history = history
        self.vocabulary = vocabulary
        self.deviceName = deviceName
        if let id = defaults.string(forKey: "sync.deviceID") {
            deviceID = id
        } else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: "sync.deviceID")
        }
        var toggles: [Kind: Bool] = [:]
        for kind in Kind.allCases { toggles[kind] = defaults.bool(forKey: "sync.\(kind.rawValue)") }
        enabled = toggles
        mergeHistory = defaults.object(forKey: "sync.mergeHistory") as? Bool ?? true
    }

    /// `~/Library/Mobile Documents/com~apple~CloudDocs/ChillTalk`, if iCloud Drive is on.
    nonisolated static func defaultRoot() -> URL? {
        let drive = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: drive.path) else { return nil }
        return drive.appendingPathComponent("ChillTalk", isDirectory: true)
    }

    var isAvailable: Bool { root != nil }
    var isAnyEnabled: Bool { enabled.values.contains(true) }

    // MARK: - Lifecycle

    func start() {
        applyRemoteHistoryVisibility()
        // Local changes → push shortly after.
        history.$records.dropFirst().sink { [weak self] _ in self?.syncSoon() }.store(in: &cancellables)
        history.$usage.dropFirst().sink { [weak self] _ in self?.syncSoon() }.store(in: &cancellables)
        vocabulary.$entries.dropFirst().sink { [weak self] _ in
            guard self?.isApplyingRemote == false else { return }
            self?.syncSoon()
        }.store(in: &cancellables)
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncNow() }
        }
        updateTimer()
        syncNow()
    }

    /// Polls other Macs every 30s, but only while at least one kind is synced.
    private func updateTimer() {
        if isAnyEnabled && isAvailable {
            guard timer == nil else { return }
            timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncNow() }
            }
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Debounced sync after a local change.
    func syncSoon() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.syncNow() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// Reads and writes run on this queue: files in iCloud Drive can block while the system
    /// downloads or coordinates them, which must never stall the hotkey or the HUD.
    private static let ioQueue = DispatchQueue(label: "com.chilltalk.sync.io", qos: .utility)
    private var isRunning = false
    private var rerunRequested = false

    func syncNow() {
        guard let root = root else { status = .unavailable; return }
        guard isAnyEnabled else {
            status = .off
            history.remoteRecords = []
            history.remoteUsage = [:]
            return
        }
        guard !isRunning else { rerunRequested = true; return }
        isRunning = true
        status = .syncing

        let kinds = Set(enabled.filter(\.value).map(\.key))
        let deviceID = self.deviceID
        Self.ioQueue.async {
            let remote = Self.readRemote(root: root, excluding: deviceID, kinds: kinds)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Stamp local edits right before merging (not before the read, which takes
                    // a while), so a change the user just made beats an older remote one.
                    if self.enabled[.settings] == true { Self.settingKeys.forEach(self.stampSetting) }
                    if self.enabled[.vocabulary] == true { self.stampSetting(Self.contextKey) }
                    // Pull first, then push the merged result.
                    self.pull(remote)
                    let outgoing = self.outgoing()
                    Self.ioQueue.async {
                        let result = Result { try Self.write(outgoing, root: root, deviceID: deviceID) }
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated { self.finishSync(result) }
                        }
                    }
                }
            }
        }
    }

    private func finishSync(_ result: Result<Void, Error>) {
        isRunning = false
        switch result {
        case _ where !isAnyEnabled: status = .off   // turned off while this sync ran
        case .success: status = .idle(Date())
        case .failure(let error): status = .failed(error.localizedDescription)
        }
        if rerunRequested {
            rerunRequested = false
            syncNow()
        }
    }

    // MARK: - Push (this Mac's folder)

    /// What this Mac writes, captured on the main thread so the background write sees one
    /// consistent state.
    private struct Outgoing {
        var device: Device
        var vocabulary: VocabularySnapshot?
        var settings: [String: SyncedSetting]?
        var usage: [String: DailyUsage]?
        var history: [DictationRecord]?
    }

    private func outgoing() -> Outgoing {
        var out = Outgoing(device: Device(id: deviceID, name: deviceName, updatedAt: Date()))
        if enabled[.vocabulary] == true {
            out.vocabulary = VocabularySnapshot(
                entries: vocabulary.entries,
                deleted: vocabulary.deleted,
                context: defaults.string(forKey: Self.contextKey) ?? "",
                contextUpdatedAt: defaults.object(forKey: "sync.stamp.\(Self.contextKey)") as? Date
            )
        }
        if enabled[.settings] == true {
            var values: [String: SyncedSetting] = [:]
            for key in Self.settingKeys {
                guard let value = SyncedSetting.Value(defaults.object(forKey: key)),
                      let stamp = defaults.object(forKey: "sync.stamp.\(key)") as? Date else { continue }
                values[key] = SyncedSetting(value: value, updatedAt: stamp)
            }
            out.settings = values
        }
        if enabled[.usage] == true { out.usage = history.usage }
        if enabled[.history] == true { out.history = history.records }
        return out
    }

    nonisolated private static func write(_ out: Outgoing, root: URL, deviceID: String) throws {
        let folder = root.appendingPathComponent("devices/\(deviceID)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write(out.device, to: folder.appendingPathComponent("device.json"))
        if let vocabulary = out.vocabulary { try write(vocabulary, to: folder.appendingPathComponent("vocabulary.json")) }
        if let settings = out.settings { try write(settings, to: folder.appendingPathComponent("settings.json")) }
        if let usage = out.usage { try write(usage, to: folder.appendingPathComponent("usage.json")) }
        if let history = out.history { try write(history, to: folder.appendingPathComponent("history.json")) }
    }

    /// Records when a local setting last changed (compared with what was last pushed).
    private func stampSetting(_ key: String) {
        let current = defaults.object(forKey: key)
        let last = defaults.object(forKey: "sync.last.\(key)")
        guard current != nil else { return }
        if !Self.equal(current, last) || defaults.object(forKey: "sync.stamp.\(key)") == nil {
            defaults.set(Date(), forKey: "sync.stamp.\(key)")
            defaults.set(current, forKey: "sync.last.\(key)")
        }
    }

    // MARK: - Pull (other Macs' folders)

    /// Other Macs' files, read and decoded off the main thread.
    private struct RemoteData {
        var devices: [Device] = []
        var vocabulary: [VocabularySnapshot] = []
        var settings: [[String: SyncedSetting]] = []
        var usage: [[String: DailyUsage]] = []
        var history: [[DictationRecord]] = []
    }

    nonisolated private static func readRemote(root: URL, excluding deviceID: String, kinds: Set<Kind>) -> RemoteData {
        var data = RemoteData()
        let devicesDir = root.appendingPathComponent("devices", isDirectory: true)
        guard let folders = try? FileManager.default.contentsOfDirectory(at: devicesDir, includingPropertiesForKeys: nil) else {
            return data
        }
        for folder in folders where folder.lastPathComponent != deviceID {
            guard let info: Device = read(folder.appendingPathComponent("device.json")) else { continue }
            data.devices.append(info)
            if kinds.contains(.vocabulary), let snapshot: VocabularySnapshot = read(folder.appendingPathComponent("vocabulary.json")) {
                data.vocabulary.append(snapshot)
            }
            if kinds.contains(.settings), let values: [String: SyncedSetting] = read(folder.appendingPathComponent("settings.json")) {
                data.settings.append(values)
            }
            if kinds.contains(.usage), let usage: [String: DailyUsage] = read(folder.appendingPathComponent("usage.json")) {
                data.usage.append(usage)
            }
            if kinds.contains(.history), var list: [DictationRecord] = read(folder.appendingPathComponent("history.json")) {
                for i in list.indices { list[i].deviceName = info.name }
                data.history.append(list)
            }
        }
        data.devices.sort { $0.updatedAt > $1.updatedAt }
        return data
    }

    /// Merges what other Macs wrote. Kinds turned off since the read are skipped.
    private func pull(_ remote: RemoteData) {
        otherDevices = remote.devices

        if enabled[.vocabulary] == true {
            isApplyingRemote = true
            for snapshot in remote.vocabulary {
                vocabulary.merge(remote: snapshot.entries, remoteDeleted: snapshot.deleted)
                if let stamp = snapshot.contextUpdatedAt,
                   stamp > (defaults.object(forKey: "sync.stamp.\(Self.contextKey)") as? Date ?? .distantPast) {
                    applySetting(Self.contextKey, value: snapshot.context, stamp: stamp)
                }
            }
            isApplyingRemote = false
        }

        if enabled[.settings] == true {
            var changed = false
            for values in remote.settings {
                for (key, setting) in values where Self.settingKeys.contains(key) {
                    let localStamp = defaults.object(forKey: "sync.stamp.\(key)") as? Date ?? .distantPast
                    if setting.updatedAt > localStamp {
                        applySetting(key, value: setting.value.object, stamp: setting.updatedAt)
                        changed = true
                    }
                }
            }
            if changed { NotificationCenter.default.post(name: .settingsSyncedFromCloud, object: nil) }
        }

        if enabled[.usage] == true {
            var total: [String: DailyUsage] = [:]
            for usage in remote.usage {
                for (day, value) in usage { total[day] = HistoryStore.sum([total[day] ?? DailyUsage(), value]) }
            }
            history.remoteUsage = total
        } else {
            history.remoteUsage = [:]
        }

        history.remoteRecords = enabled[.history] == true ? remote.history.flatMap { $0 } : []
        applyRemoteHistoryVisibility()
    }

    private func applySetting(_ key: String, value: Any, stamp: Date) {
        defaults.set(value, forKey: key)
        defaults.set(value, forKey: "sync.last.\(key)")
        defaults.set(stamp, forKey: "sync.stamp.\(key)")
        if key == Self.contextKey {
            NotificationCenter.default.post(name: .settingsSyncedFromCloud, object: nil)
        }
    }

    private func applyRemoteHistoryVisibility() {
        history.showsRemoteRecords = enabled[.history] == true && mergeHistory
    }

    private func persistToggles() {
        for (kind, on) in enabled { defaults.set(on, forKey: "sync.\(kind.rawValue)") }
        defaults.set(mergeHistory, forKey: "sync.mergeHistory")
    }

    // MARK: - Files

    nonisolated private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        // Sub-second precision: "last edit wins" must order edits made within one second.
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(value)
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { url in
            do { try data.write(to: url, options: .atomic) } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError { throw error }
    }

    /// Last successfully read contents per remote file, used while iCloud re-downloads one.
    nonisolated private static let lastRead = RemoteFileCache()

    /// Reads a JSON file. One that iCloud hasn't downloaded (or has evicted) is requested and
    /// stands in with what was read last time, instead of blocking until it arrives or
    /// dropping that Mac's data for a cycle.
    nonisolated private static func read<T: Decodable>(_ url: URL) -> T? {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            // Older systems leave a ".name.icloud" placeholder instead of the file.
            let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
            if fm.fileExists(atPath: placeholder.path) {
                try? fm.startDownloadingUbiquitousItem(at: url)
                return lastRead.value(for: url) as? T
            }
            lastRead.remove(url)
            return nil
        }
        // Since macOS 14 an evicted file keeps its name but has no data on disk.
        if let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus,
           status == .notDownloaded {
            try? fm.startDownloadingUbiquitousItem(at: url)
            return lastRead.value(for: url) as? T
        }
        var data: Data?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { url in
            data = try? Data(contentsOf: url)
        }
        guard let data else { return lastRead.value(for: url) as? T }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let value = try? decoder.decode(T.self, from: data) else { return nil }
        lastRead.set(value, for: url)
        return value
    }

    private static func equal(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x as NSObject, y as NSObject): return x.isEqual(y)
        default: return false
        }
    }
}

/// Decoded remote files by path. Touched only from the sync I/O queue; locked anyway.
private final class RemoteFileCache {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    func value(for url: URL) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        return values[url.path]
    }

    func set(_ value: Any, for url: URL) {
        lock.lock()
        values[url.path] = value
        lock.unlock()
    }

    func remove(_ url: URL) {
        lock.lock()
        values[url.path] = nil
        lock.unlock()
    }
}

struct VocabularySnapshot: Codable {
    var entries: [VocabularyEntry]
    var deleted: [UUID: Date]
    var context: String
    var contextUpdatedAt: Date?
}

struct SyncedSetting: Codable {
    enum Value: Codable, Equatable {
        case string(String)
        case bool(Bool)
        case int(Int)

        init?(_ object: Any?) {
            switch object {
            case let v as String: self = .string(v)
            case let v as NSNumber where CFGetTypeID(v) == CFBooleanGetTypeID(): self = .bool(v.boolValue)
            case let v as Int: self = .int(v)
            default: return nil
            }
        }

        var object: Any {
            switch self {
            case .string(let v): return v
            case .bool(let v): return v
            case .int(let v): return v
            }
        }
    }

    let value: Value
    let updatedAt: Date
}
