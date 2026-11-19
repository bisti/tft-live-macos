import Darwin
import Foundation

extension Configuration {
    @discardableResult public func prepareFiles(report: (String) -> Void = { _ in }, beforeChangingFiles: () throws -> Void = {}) throws -> Bool {
        try prepareFiles(riotSystem: { try readText(installedRiot().appendingPathComponent("Contents/Resources/system.yaml")) },
                         report: report, beforeChangingFiles: beforeChangingFiles)
    }
    @discardableResult func prepareFiles(riotSystem: () throws -> String, report: (String) -> Void = { _ in },
                                         beforeChangingFiles: () throws -> Void = {}) throws -> Bool {
        try makeDirectory(data)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: data.path)
        let override = try ConfigurationFile(data.appendingPathComponent("riot-sdk-host-override.json"))
        let system = try ConfigurationFile(data.appendingPathComponent("sdk-host-system.yaml"))
        let newOverride = try overrideMigration(override, source: assets.appendingPathComponent(override.path.lastPathComponent))
        let newSystem = try systemMigration(system, riotSystem: riotSystem, report: report)
        let changed = newOverride.content != override.content || newSystem.content != system.content
        if changed { try beforeChangingFiles() }
        try override.install(newOverride)
        try system.install(newSystem)
        return changed
    }
    private func overrideMigration(_ file: ConfigurationFile, source: URL) throws -> ConfigurationUpdate {
        let latest = try overrideObject(Data(contentsOf: source), name: source.path)
        let template = try jsonData(latest)
        guard let content = file.content else { return ConfigurationUpdate(content: template, template: template) }
        let current = try overrideObject(content, name: file.path.path)
        if file.template == template { return ConfigurationUpdate(content: content, template: template) }
        let previous = try file.template.map { try overrideObject($0, name: file.templatePath.path) }
        let merged = try mergeOverride(current, previous: previous, latest: latest, hasPrevious: previous != nil) as? JSON ?? current
        let encoded = try jsonData(merged)
        _ = try overrideObject(encoded, name: file.path.path)
        return ConfigurationUpdate(content: encoded == (try jsonData(current)) ? content : encoded, template: template,
                                   saveOriginal: previous == nil)
    }
    private func systemMigration(_ file: ConfigurationFile, riotSystem: () throws -> String,
                                 report: (String) -> Void) throws -> ConfigurationUpdate {
        let source: String
        do { source = try riotSystem() }
        catch {
            // A previously prepared profile can start with its private Riot runtime.
            guard let content = file.content else { throw error }
            return ConfigurationUpdate(content: try managedSystemYAML(content, name: file.path.path), template: nil, saveOriginal: true)
        }
        let latest = try managedSystemYAML(Data(source.utf8), name: "Riot system.yaml")
        guard let content = file.content else { return ConfigurationUpdate(content: latest, template: latest) }
        let local = try managedSystemYAML(content, name: file.path.path)
        if file.template == latest { return ConfigurationUpdate(content: local, template: latest, saveOriginal: true) }
        let merged: Data
        if let previous = file.template {
            _ = try managedSystemYAML(previous, name: file.templatePath.path)
            guard let updated = try mergeSystemYAML(local, previous: previous, latest: latest) else {
                report("Riot's system.yaml update conflicts with local changes in " + file.path.path + ". Keeping the local configuration.")
                return ConfigurationUpdate(content: local, template: nil, saveOriginal: true)
            }
            merged = try managedSystemYAML(updated, name: file.path.path)
        } else {
            // No previous source is known. Differences may be local edits.
            merged = local
        }
        return ConfigurationUpdate(content: merged, template: latest, saveOriginal: content != file.template)
    }
}

private struct ConfigurationUpdate {
    let content: Data
    let template: Data?
    var saveOriginal = false
}

private struct ConfigurationFile {
    let path: URL
    let templatePath: URL
    let content: Data?
    let template: Data?

    init(_ path: URL) throws {
        self.path = path
        templatePath = path.appendingPathExtension("template")
        content = try Self.read(path)
        template = try Self.read(templatePath)
    }

    private static func read(_ path: URL) throws -> Data? {
        var info = stat()
        if lstat(path.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw LauncherError("Unable to inspect " + path.path + ".")
        }
        try require(info.st_mode & S_IFMT == S_IFREG, "Expected a regular configuration file at " + path.path + ".")
        return try Data(contentsOf: path)
    }

    private static func write(_ data: Data, to path: URL) throws {
        try atomicWrite(data, to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    func install(_ update: ConfigurationUpdate) throws {
        if update.content != content {
            if update.saveOriginal, let content {
                let backup = path.appendingPathExtension("backup-" + sha256(content))
                if let saved = try Self.read(backup) {
                    try require(saved == content, "A configuration backup already exists at " + backup.path + ".")
                } else {
                    try Self.write(content, to: backup)
                }
            }
            try Self.write(update.content, to: path)
        }
        // Publish the template last, so retrying an interrupted update uses the same base.
        if let next = update.template, next != template { try Self.write(next, to: templatePath) }
    }
}

private func overrideObject(_ data: Data, name: String) throws -> JSON {
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? JSON,
          let product = object(root["public"])[liveProduct] as? JSON,
          let platforms = product["platforms"] as? JSON, platforms["mac"] != nil else {
        throw LauncherError("Invalid TFT override configuration in " + name + ".")
    }
    for platform in ["mac", "win", "windows"] where platforms[platform] != nil {
        let entries = object(platforms[platform])["configurations"] as? [JSON]
        try require(entries?.count == 1, "Expected one TFT configuration for " + platform + " in " + name + ".")
    }
    return root
}

private func mergeOverride(_ current: Any?, previous: Any?, latest: Any?,
                           hasPrevious: Bool, key: String = "") throws -> Any? {
    if hasPrevious {
        let base = try previous.map(jsonData)
        if try current.map(jsonData) == base { return latest }
        if try latest.map(jsonData) == base { return current }
    }
    if let local = current as? JSON, let defaults = latest as? JSON {
        let base = object(previous)
        var merged = local
        for name in Set(local.keys).union(defaults.keys) {
            merged[name] = try mergeOverride(local[name], previous: base[name], latest: defaults[name], hasPrevious: hasPrevious, key: name)
        }
        return merged
    }
    if key == "configurations", let local = current as? [JSON], local.count == 1,
       let defaults = latest as? [JSON], defaults.count == 1 {
        let base = (previous as? [JSON])?.first
        return [try mergeOverride(local[0], previous: base, latest: defaults[0], hasPrevious: hasPrevious) ?? local[0]]
    }
    return hasPrevious ? current : current ?? latest
}

private func managedSystemYAML(_ data: Data, name: String) throws -> Data {
    guard let yaml = String(data: data, encoding: .utf8),
          yaml.range(of: #"(?m)^(?:[A-Za-z_][A-Za-z0-9_-]*|"[^"\r\n]+"|'[^'\r\n]+')[ \t]*:"#, options: .regularExpression) != nil else {
        throw LauncherError("Invalid Riot system configuration in " + name + ".")
    }
    let range = NSRange(yaml.startIndex..<yaml.endIndex, in: yaml)
    let documents = try NSRegularExpression(pattern: "(?m)^---[ \\t]*(?:#[^\\r\\n]*)?\\r?$")
    if let marker = documents.firstMatch(in: yaml, range: range), let start = Range(marker.range, in: yaml)?.lowerBound {
        let preamble = yaml[..<start].split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        try require(preamble.allSatisfy { $0.isEmpty || $0.hasPrefix("#") || $0.hasPrefix("%") }
                    && documents.numberOfMatches(in: yaml, range: range) == 1, "Multiple YAML documents in " + name + ".")
    }
    let keyPattern = #"(?:enable_self_update|"enable_self_update"|'enable_self_update')"#
    let key = try NSRegularExpression(pattern: "(?m)^" + keyPattern + "[ \\t]*:")
    let matches = key.numberOfMatches(in: yaml, range: range)
    if matches == 0 {
        try require(yaml.range(of: "(?m)^\\.\\.\\.(?:\\s|$)", options: .regularExpression) == nil,
                    "Unable to add the self-update setting in " + name + ".")
        let newline = yaml.contains("\r\n") ? "\r\n" : "\n"
        return Data((yaml + (yaml.hasSuffix(newline) ? "" : newline) + "enable_self_update: false" + newline).utf8)
    }
    let setting = try NSRegularExpression(pattern: "(?m)^(" + keyPattern + "[ \\t]*:[ \\t]*)(true|false)(?=(?:[ \\t]*|[ \\t]+#[^\\r\\n]*)\\r?$)")
    try require(matches == 1 && setting.numberOfMatches(in: yaml, range: range) == 1,
                "Invalid self-update setting in " + name + ".")
    return Data(setting.stringByReplacingMatches(in: yaml, range: range, withTemplate: "$1false").utf8)
}

private func mergeSystemYAML(_ current: Data, previous: Data, latest: Data) throws -> Data? {
    if current == previous { return latest }
    if latest == previous || current == latest { return current }
    let stage = FileManager.default.temporaryDirectory.appendingPathComponent("tft-system-merge-" + UUID().uuidString)
    try makeDirectory(stage)
    defer { try? remove(stage) }
    let local = stage.appendingPathComponent("local.yaml")
    let base = stage.appendingPathComponent("previous.yaml")
    let source = stage.appendingPathComponent("latest.yaml")
    try current.write(to: local)
    try previous.write(to: base)
    try latest.write(to: source)
    let result = try command(["/usr/bin/diff3", "-m", local.path, base.path, source.path], checked: false, timeout: 5)
    try require(result.status == 0 || result.status == 1, "Unable to merge the updated Riot system configuration.")
    return result.status == 0 ? Data(result.output.utf8) : nil
}
