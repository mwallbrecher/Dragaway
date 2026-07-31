import Foundation
import Combine

// MARK: - Canonical folder manifest

/// The single bounded description of a dropped folder. Both the local preview and
/// the AI context consume this exact value, so the UI never claims that a file was
/// analysed when it was not included in the request.
struct FolderManifest: Sendable {
    struct Entry: Identifiable, Sendable {
        enum Kind: String, Sendable {
            case folder
            case text
            case code
            case data
            case pdf
            case richText
            case email
            case image
            case media
            case archive
            case unknown

            nonisolated var title: String {
                switch self {
                case .folder:   return "Folder"
                case .text:     return "Text"
                case .code:     return "Code"
                case .data:     return "Data"
                case .pdf:      return "PDF"
                case .richText: return "Document"
                case .email:    return "Mail"
                case .image:    return "Image"
                case .media:    return "Media"
                case .archive:  return "Archive"
                case .unknown:  return "File"
                }
            }
        }

        enum SkipReason: String, Sendable {
            case hidden
            case generatedDirectory
            case package
            case sensitive
            case symlink
            case unreadable
            case unsupportedType
            case imageNotAnalysed
            case mediaNotAnalysed
            case richTextNotAnalysed
            case sessionFolderLimit
            case sessionContextLimit
            case tooLarge
            case depthLimit
            case extractionFailed

            nonisolated var label: String {
                switch self {
                case .hidden:             return "Hidden"
                case .generatedDirectory: return "Generated/dependency folder"
                case .package:            return "Package contents"
                case .sensitive:          return "Sensitive file"
                case .symlink:            return "Symlink or alias"
                case .unreadable:         return "Unreadable"
                case .unsupportedType:    return "Unsupported type"
                case .imageNotAnalysed:   return "Image not included in folder AI context"
                case .mediaNotAnalysed:   return "Media not included in folder AI context"
                case .richTextNotAnalysed:
                    return "Document requires a direct drop for safe text extraction"
                case .sessionFolderLimit:
                    return "Folder not scanned — session folder limit"
                case .sessionContextLimit:
                    return "Folder not scanned — context slice too small"
                case .tooLarge:           return "Too large"
                case .depthLimit:         return "Depth limit"
                case .extractionFailed:   return "Text extraction failed"
                }
            }
        }

        enum Status: Sendable {
            /// Strictly supported by the extractor, but context selection has not run yet.
            case eligible
            case included
            case eligibleButOmitted
            case skipped(SkipReason)
            case directory
        }

        enum OmissionReason: String, Sendable {
            case contextLimit
            case preparationLimit
            case userDeselected

            nonisolated var label: String {
                switch self {
                case .contextLimit:     return "Context limit"
                case .preparationLimit: return "Folder preparation safety limit"
                case .userDeselected:   return "Deselected"
                }
            }
        }

        let relativePath: String
        let url: URL
        let kind: Kind
        let byteSize: Int64?
        var status: Status
        var omissionReason: OmissionReason?
        var isPartial: Bool

        nonisolated var id: String { relativePath }
    }

    let rootURL: URL
    var entries: [Entry]
    let scannedCount: Int
    let wasLimited: Bool
    let limitDescription: String?
    var contextCharacterCount: Int

    nonisolated var includedCount: Int {
        entries.reduce(into: 0) { count, entry in
            if case .included = entry.status { count += 1 }
        }
    }

    nonisolated var omittedCount: Int {
        entries.reduce(into: 0) { count, entry in
            if case .eligibleButOmitted = entry.status { count += 1 }
        }
    }

    nonisolated var skippedCount: Int {
        entries.reduce(into: 0) { count, entry in
            if case .skipped = entry.status { count += 1 }
        }
    }

    nonisolated var supportedCount: Int {
        entries.reduce(into: 0) { count, entry in
            switch entry.status {
            case .eligible, .included, .eligibleButOmitted: count += 1
            case .directory, .skipped: break
            }
        }
    }
}

struct FolderAnalysisResult: Sendable {
    let manifest: FolderManifest
    let content: String
    let truncated: Bool
    let characterLimit: Int
}

enum FolderAnalysisError: LocalizedError {
    case notFolder
    case cannotEnumerate

    var errorDescription: String? {
        switch self {
        case .notFolder:
            return "This item is not a readable folder."
        case .cannotEnumerate:
            return "Dragaway could not inspect this folder."
        }
    }
}

/// One deterministic budget split for both eager folder preparation and the final
/// multi-file request. Keeping this arithmetic in one place means the preview can
/// never advertise a larger folder slice than the provider will actually receive.
enum SessionContextBudget {
    nonisolated static func header(for url: URL) -> String {
        // A terminally excluded folder may be sensitive, hidden, a package, or a
        // symlink. Its body redacts the root; the outer multi-item framing must not
        // re-introduce that path. Normal folder names remain inside their safe body.
        let label = FileInspector.isDirectory(url) ? "Folder" : url.lastPathComponent
        return "=== \(label) ===\n"
    }

    nonisolated static func framingCharacterCount(for urls: [URL]) -> Int {
        guard urls.count > 1 else { return 0 }
        return urls.reduce(0) { $0 + header(for: $1).count }
            + (urls.count - 1) * 2
    }

    nonisolated static func bodyLimits(
        for urls: [URL],
        characterLimit: Int
    ) -> [Int] {
        guard !urls.isEmpty else { return [] }
        guard urls.count > 1 else { return [max(0, characterLimit)] }

        let available = max(
            0,
            characterLimit - framingCharacterCount(for: urls)
        )
        let base = available / urls.count
        // Equal limits also make a duplicated path reuse the same prepared manifest.
        // At most `urls.count - 1` characters stay unused.
        return Array(repeating: base, count: urls.count)
    }
}

// MARK: - Bounded local scanner

enum FolderScanner {
    nonisolated static let maxEntries = 500
    nonisolated static let maxDepth = 8
    nonisolated static let maxScanSeconds: TimeInterval = 2.0
    nonisolated static let maxPlainTextBytes: Int64 = 2 * 1_024 * 1_024
    nonisolated static let maxDocumentBytes: Int64 = 25 * 1_024 * 1_024

    private nonisolated static let generatedDirectories: Set<String> = [
        ".git", ".svn", ".hg", ".idea", ".vscode",
        "node_modules", "pods", "vendor", "venv", ".venv",
        "__pycache__", ".build", "build", "dist", "deriveddata",
        ".next", ".cache", "target", "coverage"
    ]

    private nonisolated static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "webp", "gif", "tiff", "bmp", "svg"
    ]
    private nonisolated static let mediaExtensions: Set<String> = [
        "mp4", "mov", "avi", "mkv", "m4v", "wmv", "flv", "webm",
        "mp3", "aac", "wav", "flac", "ogg", "m4a", "aiff", "aif"
    ]
    private nonisolated static let archiveExtensions: Set<String> = [
        "zip", "rar", "7z", "tar", "gz", "bz2", "xz", "dmg", "pkg", "iso", "app"
    ]
    private nonisolated static let codeExtensions: Set<String> = [
        "swift", "py", "rb", "go", "rs", "java", "kt", "kts", "gradle",
        "c", "h", "cpp", "cc", "hpp", "hh", "cs", "m", "mm", "php",
        "sh", "bash", "zsh", "fish", "js", "mjs", "cjs", "jsx", "ts",
        "tsx", "sql", "r", "lua", "pl", "pm", "dart", "scala", "clj",
        "ex", "exs", "vue", "svelte", "tex"
    ]
    private nonisolated static let dataExtensions: Set<String> = [
        "csv", "tsv", "json", "ndjson", "jsonl", "xml", "yaml", "yml",
        "toml", "ini", "conf", "cfg", "properties", "plist", "resolved"
    ]
    private nonisolated static let textExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "log", "html", "htm", "css",
        "scss", "sass", "less", "srt", "vtt", "gitignore", "b64", "base64",
        "pbxproj", "xcconfig", "entitlements", "strings", "storyboard", "xib",
        "lock", "graphql", "proto"
    ]
    private nonisolated static let sensitiveNames: Set<String> = [
        ".npmrc", ".pypirc", ".netrc", ".htpasswd",
        "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519",
        "secret", "secrets", "credentials", "credentials.json", "secrets.json",
        "key.properties", "service-account.json", "serviceaccount.json",
        "google-services.json"
    ]
    private nonisolated static let sensitiveExtensions: Set<String> = [
        "env", "pem", "key", "p12", "pfx", "mobileprovision", "keystore"
    ]

    /// Synchronous by design so it can run wholly inside a detached task. Every
    /// traversal axis is bounded, and cancellation is checked for every entry.
    nonisolated static func scan(root rootURL: URL) throws -> FolderManifest {
        let root = rootURL.standardizedFileURL
        let fm = FileManager.default
        let rootKeys: Set<URLResourceKey> = [
            .isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey,
            .isPackageKey, .isHiddenKey
        ]
        guard let rootValues = try? root.resourceValues(forKeys: rootKeys),
              rootValues.isDirectory == true else {
            throw FolderAnalysisError.notFolder
        }

        if rootValues.isSymbolicLink == true || rootValues.isAliasFile == true {
            return terminalManifest(root: root, reason: .symlink)
        }
        if rootValues.isPackage == true {
            return terminalManifest(root: root, reason: .package)
        }
        if isSensitiveFile(root) {
            return terminalManifest(root: root, reason: .sensitive)
        }
        if isGeneratedDirectoryName(root.lastPathComponent) {
            return terminalManifest(root: root, reason: .generatedDirectory)
        }
        if rootValues.isHidden == true || root.lastPathComponent.hasPrefix(".") {
            return terminalManifest(root: root, reason: .hidden)
        }

        let accessing = root.startAccessingSecurityScopedResource()
        defer { if accessing { root.stopAccessingSecurityScopedResource() } }

        let resourceKeys: [URLResourceKey] = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .isAliasFileKey, .isPackageKey, .isHiddenKey, .fileSizeKey
        ]
        let started = Date()
        var entries: [FolderManifest.Entry] = []
        var traversalFailures: [URL] = []
        var wasLimited = false
        var limitDescription: String?
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: resourceKeys,
            options: [],
            errorHandler: { url, _ in
                if Task.isCancelled { return false }
                if entries.count + traversalFailures.count >= maxEntries {
                    wasLimited = true
                    limitDescription = "Only the first \(maxEntries) entries were inspected."
                    return false
                }
                if Date().timeIntervalSince(started) >= maxScanSeconds {
                    wasLimited = true
                    limitDescription =
                        "The local scan stopped after \(Int(maxScanSeconds)) seconds."
                    return false
                }
                traversalFailures.append(url)
                return true
            }
        ) else {
            throw FolderAnalysisError.cannotEnumerate
        }

        while let url = enumerator.nextObject() as? URL {
            if Task.isCancelled { throw CancellationError() }
            if entries.count + traversalFailures.count >= maxEntries {
                wasLimited = true
                limitDescription = "Only the first \(maxEntries) entries were inspected."
                break
            }
            if Date().timeIntervalSince(started) >= maxScanSeconds {
                wasLimited = true
                limitDescription = "The local scan stopped after \(Int(maxScanSeconds)) seconds."
                break
            }

            let relativePath = relativePath(of: url, below: root)
            let depth = relativePath.split(separator: "/").count
            guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)) else {
                entries.append(entry(url, relativePath, .unknown, nil, .skipped(.unreadable)))
                continue
            }
            let isDirectory = values.isDirectory == true

            if values.isSymbolicLink == true || values.isAliasFile == true {
                if isDirectory { enumerator.skipDescendants() }
                entries.append(entry(url, relativePath,
                                     isDirectory ? .folder : .unknown,
                                     values.fileSize.map(Int64.init),
                                     .skipped(.symlink)))
                continue
            }
            if isSensitiveFile(url) {
                if isDirectory { enumerator.skipDescendants() }
                entries.append(entry(url, relativePath,
                                     isDirectory ? .folder : .unknown,
                                     values.fileSize.map(Int64.init),
                                     .skipped(.sensitive)))
                continue
            }
            if values.isHidden == true || url.lastPathComponent.hasPrefix(".") {
                if isDirectory { enumerator.skipDescendants() }
                entries.append(entry(url, relativePath,
                                     isDirectory ? .folder : .unknown,
                                     values.fileSize.map(Int64.init),
                                     .skipped(.hidden)))
                continue
            }
            if isDirectory, isGeneratedDirectoryName(url.lastPathComponent) {
                enumerator.skipDescendants()
                entries.append(entry(url, relativePath, .folder, nil,
                                     .skipped(.generatedDirectory)))
                continue
            }
            if isDirectory, values.isPackage == true {
                enumerator.skipDescendants()
                entries.append(entry(url, relativePath, .folder, nil, .skipped(.package)))
                continue
            }
            if depth > maxDepth {
                if isDirectory { enumerator.skipDescendants() }
                entries.append(entry(url, relativePath,
                                     isDirectory ? .folder : .unknown,
                                     values.fileSize.map(Int64.init),
                                     .skipped(.depthLimit)))
                continue
            }
            if isDirectory {
                entries.append(entry(url, relativePath, .folder, nil, .directory))
                continue
            }
            guard values.isRegularFile == true, fm.isReadableFile(atPath: url.path) else {
                entries.append(entry(url, relativePath, .unknown,
                                     values.fileSize.map(Int64.init), .skipped(.unreadable)))
                continue
            }

            guard let rawSize = values.fileSize else {
                entries.append(entry(url, relativePath, .unknown, nil, .skipped(.unreadable)))
                continue
            }
            let size = Int64(rawSize)
            let classification = classifyFile(url, byteSize: size)
            entries.append(entry(url, relativePath, classification.kind, size, classification.status))
        }

        if Task.isCancelled { throw CancellationError() }
        for failedURL in traversalFailures where entries.count < maxEntries {
            if Task.isCancelled { throw CancellationError() }
            let relative = relativePath(of: failedURL, below: root)
            if let existing = entries.firstIndex(where: { $0.relativePath == relative }) {
                entries[existing].status = .skipped(.unreadable)
            } else {
                entries.append(entry(failedURL, relative, .folder, nil, .skipped(.unreadable)))
            }
        }

        entries.sort {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
        return FolderManifest(
            rootURL: root,
            entries: entries,
            scannedCount: entries.count,
            wasLimited: wasLimited,
            limitDescription: limitDescription,
            contextCharacterCount: 0
        )
    }

    nonisolated static func terminalManifest(
        root: URL,
        reason: FolderManifest.Entry.SkipReason,
        wasLimited: Bool = false,
        limitDescription: String? = nil
    ) -> FolderManifest {
        let only = entry(root, root.lastPathComponent, .folder, nil, .skipped(reason))
        return FolderManifest(
            rootURL: root,
            entries: [only],
            scannedCount: 1,
            wasLimited: wasLimited,
            limitDescription: limitDescription,
            contextCharacterCount: 0
        )
    }

    private nonisolated static func classifyFile(
        _ url: URL,
        byteSize: Int64
    ) -> (kind: FolderManifest.Entry.Kind, status: FolderManifest.Entry.Status) {
        let ext = url.pathExtension.lowercased()
        let kind: FolderManifest.Entry.Kind
        let maxBytes: Int64

        switch ext {
        case "pdf":
            kind = .pdf; maxBytes = maxDocumentBytes
        case "eml", "emlx":
            kind = .email; maxBytes = maxDocumentBytes
        case "rtf", "rtfd", "doc", "docx":
            // Cocoa's Office/rich-text importer must run synchronously on the main
            // actor and cannot be cancelled mid-import. Keep direct drops supported,
            // but never invoke it automatically while recursively preparing a folder.
            guard byteSize <= maxDocumentBytes else {
                return (.richText, .skipped(.tooLarge))
            }
            return (.richText, .skipped(.richTextNotAnalysed))
        case _ where codeExtensions.contains(ext):
            kind = .code; maxBytes = maxPlainTextBytes
        case _ where dataExtensions.contains(ext):
            kind = .data; maxBytes = maxPlainTextBytes
        case _ where textExtensions.contains(ext):
            kind = .text; maxBytes = maxPlainTextBytes
        case _ where imageExtensions.contains(ext):
            return (.image, .skipped(.imageNotAnalysed))
        case _ where mediaExtensions.contains(ext):
            return (.media, .skipped(.mediaNotAnalysed))
        case _ where archiveExtensions.contains(ext):
            return (.archive, .skipped(.unsupportedType))
        case "":
            kind = .text; maxBytes = maxPlainTextBytes
        default:
            return (.unknown, .skipped(.unsupportedType))
        }
        guard byteSize <= maxBytes else { return (kind, .skipped(.tooLarge)) }
        switch kind {
        case .text, .code, .data:
            // Extension is only a hint. Folder ingestion must fail closed because the
            // ordinary direct-drop extractor deliberately has a Latin-1 fallback that
            // can turn arbitrary mislabeled bytes into plausible-looking gibberish.
            guard safelyLooksLikeUTF8Text(url) else {
                return (kind, .skipped(.unsupportedType))
            }
        default:
            break
        }
        return (kind, .eligible)
    }

    private nonisolated static func safelyLooksLikeUTF8Text(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let sampleLimit = 4_099 // 4 KiB plus room for one split UTF-8 scalar
        let data: Data
        do {
            data = try handle.read(upToCount: sampleLimit) ?? Data()
        } catch {
            return false
        }
        if data.isEmpty { return true }
        if data.starts(with: Data("bplist".utf8)) { return false }
        guard !data.contains(0) else { return false }

        // A bounded read can end inside a valid 2–4-byte scalar. Validate the whole
        // sample first, then remove at most the three boundary bytes needed to reach
        // the last complete scalar. Invalid UTF-8 anywhere earlier still fails closed.
        let minimumLength = data.count == sampleLimit ? max(0, data.count - 3) : data.count
        var decoded: String?
        for length in stride(from: data.count, through: minimumLength, by: -1) {
            if let text = String(data: data.prefix(length), encoding: .utf8) {
                decoded = text
                break
            }
        }
        guard let text = decoded else { return false }
        let disallowedControls = text.unicodeScalars.reduce(into: 0) { count, scalar in
            if scalar.value < 32, scalar != "\n", scalar != "\r", scalar != "\t" {
                count += 1
            }
        }
        return Double(disallowedControls) / Double(max(text.unicodeScalars.count, 1)) < 0.01
    }

    private nonisolated static func isGeneratedDirectoryName(_ name: String) -> Bool {
        generatedDirectories.contains(name.lowercased())
    }

    private nonisolated static func isSensitiveFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if name == ".env" || name.hasPrefix(".env.") { return true }
        if sensitiveNames.contains(name) { return true }
        let ext = url.pathExtension.lowercased()
        if sensitiveExtensions.contains(ext) { return true }
        if name.hasPrefix("credential.") || name.hasPrefix("credentials.")
            || name.hasPrefix("secret.") || name.hasPrefix("secrets.") {
            return true
        }
        if ext == "json",
           name.hasPrefix("service-account")
            || name.contains("serviceaccount")
            || name.contains("firebase-adminsdk") {
            return true
        }
        return false
    }

    private nonisolated static func relativePath(of url: URL, below root: URL) -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.count >= rootComponents.count else { return url.lastPathComponent }
        let relative = components.dropFirst(rootComponents.count).joined(separator: "/")
        return relative.isEmpty ? url.lastPathComponent : relative
    }

    private nonisolated static func entry(
        _ url: URL,
        _ relativePath: String,
        _ kind: FolderManifest.Entry.Kind,
        _ byteSize: Int64?,
        _ status: FolderManifest.Entry.Status
    ) -> FolderManifest.Entry {
        FolderManifest.Entry(
            relativePath: relativePath,
            url: url,
            kind: kind,
            byteSize: byteSize,
            status: status,
            omissionReason: nil,
            isPartial: false
        )
    }
}

// MARK: - One bounded context from the manifest

enum FolderContextBuilder {
    private nonisolated static let perFileCharacterLimit = 6_000
    private nonisolated static let maxExtractionAttempts = 64
    private nonisolated static let maxSourceBytes: Int64 = 64 * 1_024 * 1_024
    private nonisolated static let maxExtractionSeconds: TimeInterval = 4.0

    /// Session-local, bounded preparation result. Selection changes consume only
    /// this immutable value; they never reopen a file which was already inspected.
    struct PreparedContent: Sendable {
        enum Outcome: Sendable {
            case content(text: String, sourceTruncated: Bool)
            case extractionFailed
            case preparationLimit
        }

        let byEntryID: [String: Outcome]
    }

    /// Reads every supported manifest entry at most once, independently from the
    /// provider's smaller final context window. The same safety ceilings that used
    /// to apply during every rebuild now apply once to the entire folder session.
    nonisolated static func prepare(
        manifest: FolderManifest
    ) async throws -> PreparedContent {
        let eligibleIndices = sortedEligibleIndices(in: manifest)
        var outcomes: [String: PreparedContent.Outcome] = [:]
        var extractionAttempts = 0
        var sourceBytes: Int64 = 0
        let extractionStarted = Date()

        for index in eligibleIndices {
            try Task.checkCancellation()
            let entry = manifest.entries[index]
            let entryBytes = entry.byteSize ?? 0
            guard extractionAttempts < maxExtractionAttempts,
                  sourceBytes + entryBytes <= maxSourceBytes,
                  Date().timeIntervalSince(extractionStarted) < maxExtractionSeconds else {
                outcomes[entry.id] = .preparationLimit
                continue
            }

            extractionAttempts += 1
            sourceBytes += entryBytes
            do {
                let extracted = try await FileContentExtractor.extract(
                    from: entry.url,
                    limit: perFileCharacterLimit
                )
                let trimmed = extracted.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    outcomes[entry.id] = .extractionFailed
                    continue
                }
                outcomes[entry.id] = .content(
                    text: String(trimmed.prefix(perFileCharacterLimit)),
                    sourceTruncated: extracted.truncated
                        || trimmed.count > perFileCharacterLimit
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                outcomes[entry.id] = .extractionFailed
            }
        }

        return PreparedContent(byEntryID: outcomes)
    }

    nonisolated static func build(
        manifest scannedManifest: FolderManifest,
        characterLimit: Int,
        selectedEntryIDs: Set<String>? = nil
    ) async throws -> FolderAnalysisResult {
        let preparedContent = try await prepare(manifest: scannedManifest)
        return assemble(
            manifest: scannedManifest,
            preparedContent: preparedContent,
            characterLimit: characterLimit,
            selectedEntryIDs: selectedEntryIDs
        )
    }

    /// Pure in-memory context assembly. It is intentionally synchronous: toggling
    /// folder rows only changes selection/status accounting and copies bounded text.
    nonisolated static func assemble(
        manifest scannedManifest: FolderManifest,
        preparedContent: PreparedContent,
        characterLimit: Int,
        selectedEntryIDs: Set<String>? = nil
    ) -> FolderAnalysisResult {
        var manifest = scannedManifest
        if let selectedEntryIDs {
            for index in manifest.entries.indices {
                guard case .eligible = manifest.entries[index].status,
                      !selectedEntryIDs.contains(manifest.entries[index].id) else {
                    continue
                }
                manifest.entries[index].status = .eligibleButOmitted
                manifest.entries[index].omissionReason = .userDeselected
            }
        }
        let sectionPreamble = "\n\nINCLUDED FILE CONTENT\n\n"
        // Small folders should not lose a fixed quarter of their allowance to an
        // mostly-empty tree. Estimate the real header footprint, while still capping
        // huge manifests so file content always retains most of the global budget.
        let estimatedTreeCharacters = manifest.entries.reduce(0) {
            $0 + min($1.relativePath.count + 48, 240)
        }
        let headerBudget = min(
            min(6_000, max(800, 420 + estimatedTreeCharacters)),
            max(0, characterLimit / 2)
        )
        var remainingFileBudget = max(
            0,
            characterLimit - headerBudget - sectionPreamble.count
        )
        var sections: [String] = []
        let eligibleIndices = sortedEligibleIndices(in: manifest)

        for index in eligibleIndices {
            let entry = manifest.entries[index]
            guard case .eligible = entry.status else { continue }

            let prepared = preparedContent.byEntryID[entry.id]
                ?? .preparationLimit
            let preparedText: String
            let sourceTruncated: Bool
            switch prepared {
            case .content(let text, let truncated):
                preparedText = text
                sourceTruncated = truncated
            case .extractionFailed:
                manifest.entries[index].status = .skipped(.extractionFailed)
                continue
            case .preparationLimit:
                manifest.entries[index].status = .eligibleButOmitted
                manifest.entries[index].omissionReason = .preparationLimit
                continue
            }

            let sectionHeader = "### \(entry.relativePath)\n"
            let separatorCost = sections.isEmpty ? 0 : 2
            guard remainingFileBudget > separatorCost + sectionHeader.count + 64 else {
                manifest.entries[index].status = .eligibleButOmitted
                manifest.entries[index].omissionReason = .contextLimit
                continue
            }

            let extractionLimit = min(
                perFileCharacterLimit,
                remainingFileBudget - separatorCost - sectionHeader.count
            )
            let section = sectionHeader + String(preparedText.prefix(extractionLimit))
            sections.append(section)
            remainingFileBudget -= separatorCost + section.count
            manifest.entries[index].status = .included
            manifest.entries[index].isPartial =
                sourceTruncated || preparedText.count > extractionLimit
        }

        for index in manifest.entries.indices {
            if case .eligible = manifest.entries[index].status {
                manifest.entries[index].status = .eligibleButOmitted
                manifest.entries[index].omissionReason = .contextLimit
            }
        }

        let header = boundedHeader(manifest: manifest, limit: headerBudget)
        var content = header
        if !sections.isEmpty {
            content += sectionPreamble + sections.joined(separator: "\n\n")
        }

        // Every component above is accounted for before extraction. Fail closed if a
        // future edit violates that contract: discard file sections and stop claiming
        // any file was included instead of clipping their contents behind the UI's back.
        let violatedEnvelope = content.count > characterLimit
        if violatedEnvelope {
            for index in manifest.entries.indices {
                if case .included = manifest.entries[index].status {
                    manifest.entries[index].status = .eligibleButOmitted
                    manifest.entries[index].omissionReason = .contextLimit
                    manifest.entries[index].isPartial = false
                }
            }
            content = boundedHeader(manifest: manifest, limit: characterLimit)
        }

        manifest.contextCharacterCount = content.count
        let truncated = violatedEnvelope
            || manifest.wasLimited
            || manifest.omittedCount > 0
            || manifest.entries.contains(where: { $0.isPartial })
        return FolderAnalysisResult(
            manifest: manifest,
            content: content,
            truncated: truncated,
            characterLimit: characterLimit
        )
    }

    private nonisolated static func sortedEligibleIndices(
        in manifest: FolderManifest
    ) -> [Int] {
        manifest.entries.indices
            .filter {
                if case .eligible = manifest.entries[$0].status { return true }
                return false
            }
            .sorted { lhs, rhs in
                let left = manifest.entries[lhs]
                let right = manifest.entries[rhs]
                let lp = priority(of: left)
                let rp = priority(of: right)
                if lp != rp { return lp < rp }
                let leftSize = left.byteSize ?? .max
                let rightSize = right.byteSize ?? .max
                if leftSize != rightSize { return leftSize < rightSize }
                return left.relativePath.localizedStandardCompare(right.relativePath)
                    == .orderedAscending
            }
    }

    nonisolated static func excludedRootResult(
        root: URL,
        reason: FolderManifest.Entry.SkipReason,
        characterLimit: Int,
        limitDescription: String
    ) -> FolderAnalysisResult {
        var manifest = FolderScanner.terminalManifest(
            root: root,
            reason: reason,
            wasLimited: true,
            limitDescription: limitDescription
        )
        let content = boundedHeader(manifest: manifest, limit: max(0, characterLimit))
        manifest.contextCharacterCount = content.count
        return FolderAnalysisResult(
            manifest: manifest,
            content: content,
            truncated: true,
            characterLimit: characterLimit
        )
    }

    /// Produces a coverage header that never exceeds its reserved envelope. The full
    /// form contains scan completeness and a bounded tree; tiny multi-item slices
    /// degrade to an exact compact count instead of stealing bytes from file sections.
    private nonisolated static func boundedHeader(
        manifest: FolderManifest,
        limit: Int
    ) -> String {
        guard limit > 0 else { return "" }
        let rootName = safeRootName(for: manifest)
        let scanCoverage = manifest.wasLimited
            ? "LIMITED — \(manifest.limitDescription ?? "the local scan reached its safety limit")"
            : "Complete within local scan limits"
        let intro = """
        FOLDER ANALYSIS CONTEXT
        Root: \(rootName)
        Coverage: \(manifest.includedCount) included, \(manifest.omittedCount) supported but omitted, \(manifest.skippedCount) skipped.
        Scan coverage: \(scanCoverage)
        Only files marked INCLUDED below were read into this context. Qualify conclusions accordingly.
        """
        let treeTitle = "\n\nBOUNDED FOLDER TREE\n"
        if intro.count + treeTitle.count < limit {
            let treeLimit = limit - intro.count - treeTitle.count
            return intro + treeTitle + boundedTree(manifest: manifest, limit: treeLimit)
        }

        let compact = """
        FOLDER CONTEXT
        Coverage: \(manifest.includedCount) included, \(manifest.omittedCount) omitted, \(manifest.skippedCount) skipped.
        Scan: \(manifest.wasLimited ? "LIMITED" : "complete within local limits").
        Only INCLUDED file contents were read.
        """
        if compact.count <= limit { return compact }

        let minimal = "\(manifest.includedCount) included, \(manifest.omittedCount) omitted, \(manifest.skippedCount) skipped; scan \(manifest.wasLimited ? "limited" : "complete")."
        return String(minimal.prefix(limit))
    }

    private nonisolated static func safeRootName(for manifest: FolderManifest) -> String {
        guard manifest.entries.count == 1,
              manifest.entries[0].url.standardizedFileURL == manifest.rootURL.standardizedFileURL,
              case .skipped = manifest.entries[0].status else {
            return manifest.rootURL.lastPathComponent
        }
        return "[excluded folder name hidden]"
    }

    private nonisolated static func priority(of entry: FolderManifest.Entry) -> Int {
        let path = entry.relativePath.lowercased()
        let name = entry.url.lastPathComponent.lowercased()
        if name.hasPrefix("readme") || name.hasPrefix("changelog")
            || name.hasPrefix("license") || path.hasPrefix("docs/") {
            return 0
        }
        let manifests: Set<String> = [
            "package.swift", "package.json", "pyproject.toml", "cargo.toml",
            "go.mod", "pom.xml", "build.gradle", "gemfile", "requirements.txt",
            "dockerfile", "makefile", "podfile"
        ]
        if manifests.contains(name) { return 1 }
        let stem = entry.url.deletingPathExtension().lastPathComponent.lowercased()
        if ["main", "app", "index", "server", "application"].contains(stem) { return 2 }
        return 3
    }

    private nonisolated static func boundedTree(manifest: FolderManifest, limit: Int) -> String {
        guard limit > 0 else { return "" }
        var output = ""
        for entry in manifest.entries {
            let line: String
            switch entry.status {
            case .directory:
                line = "DIR       \(entry.relativePath)/"
            case .included:
                line = "INCLUDED  \(entry.relativePath)\(entry.isPartial ? " [partial]" : "")"
            case .eligibleButOmitted:
                if entry.omissionReason == .userDeselected {
                    line = "OMITTED   [deselected file path hidden]"
                } else {
                    let reason = entry.omissionReason?.label ?? "Context limit"
                    line = "OMITTED   \(entry.relativePath) [\(reason)]"
                }
            case .eligible:
                line = "OMITTED   \(entry.relativePath) [context limit]"
            case .skipped(let reason):
                line = "SKIPPED   [\(reason.label); path hidden]"
            }
            let candidate = output.isEmpty ? line : output + "\n" + line
            if candidate.count > limit {
                let marker = "… folder tree truncated"
                guard !output.isEmpty else { return String(marker.prefix(limit)) }
                let marked = output + "\n" + marker
                return marked.count <= limit ? marked : output
            }
            output = candidate
        }
        return output.isEmpty ? "(empty folder)" : output
    }
}

// MARK: - Shared preparation state

enum FolderAnalysisSnapshot {
    case idle
    case scanning
    case ready(FolderAnalysisResult)
    case failed(String, characterLimit: Int)
}

@MainActor
final class FolderAnalysisStore: ObservableObject {
    static let shared = FolderAnalysisStore()
    static let maxFoldersPerSession = 4
    static let minimumFolderContextCharacters = 256

    @Published private var snapshots: [String: FolderAnalysisSnapshot] = [:]
    @Published private var selections: [String: Set<String>] = [:]

    private struct PreparedAnalysis: Sendable {
        let sourceManifest: FolderManifest
        let preparedContent: FolderContextBuilder.PreparedContent
        let selectedEntryIDs: Set<String>
        let result: FolderAnalysisResult
    }
    private struct Work {
        let id: UUID
        let characterLimit: Int
        let retainsSnapshot: Bool
        let task: Task<PreparedAnalysis, Error>
    }
    private var work: [String: Work] = [:]
    private var sourceManifests: [String: FolderManifest] = [:]
    private var preparedContents: [String: FolderContextBuilder.PreparedContent] = [:]
    private typealias SessionExclusion = (
        reason: FolderManifest.Entry.SkipReason,
        description: String
    )
    private var sessionExclusions: [String: SessionExclusion] = [:]

    private init() {}

    func snapshot(for root: URL) -> FolderAnalysisSnapshot {
        snapshots[key(for: root)] ?? .idle
    }

    func selectedEntryIDs(for root: URL) -> Set<String> {
        selections[key(for: root)] ?? []
    }

    func selectableEntryIDs(for root: URL) -> Set<String> {
        let path = key(for: root)
        if let sourceManifest = sourceManifests[path],
           let preparedContent = preparedContents[path] {
            return Self.selectableEntryIDs(
                in: sourceManifest,
                preparedContent: preparedContent
            )
        }
        guard case .ready(let result) = snapshots[path] else { return [] }
        return Set(result.manifest.entries.compactMap { entry in
            switch entry.status {
            case .eligible, .included, .eligibleButOmitted:
                return entry.id
            case .directory, .skipped:
                return nil
            }
        })
    }

    /// Updates the exact set of supported files which may enter provider context.
    /// The original bounded scan is reused; only extraction/context assembly is rerun.
    func setSelectedEntryIDs(_ entryIDs: Set<String>, for root: URL) {
        let path = key(for: root)
        guard sessionExclusions[path] == nil,
              let sourceManifest = sourceManifests[path],
              let preparedContent = preparedContents[path] else {
            return
        }
        let filtered = entryIDs.intersection(Self.selectableEntryIDs(
            in: sourceManifest,
            preparedContent: preparedContent
        ))
        guard selections[path] != filtered else { return }
        selections[path] = filtered

        let limit: Int
        if let current = work[path] {
            limit = current.characterLimit
        } else if case .ready(let result) = snapshots[path] {
            limit = result.characterLimit
        } else {
            limit = Self.activeCharacterLimit
        }
        startWork(
            root: root,
            path: path,
            characterLimit: limit,
            sourceManifest: sourceManifest,
            preparedContent: preparedContents[path],
            selectedEntryIDs: filtered,
            retainsSnapshot: true
        )
    }

    /// Starts preparation without delaying the chips stage. Reuses an in-flight or
    /// completed result for the same path and active context ceiling.
    func prepare(_ root: URL, characterLimit: Int? = nil) {
        guard FileInspector.isDirectory(root) else { return }
        let path = key(for: root)
        var failedLimit: Int?
        // UI onAppear calls are only a lazy-start fallback. They must not replace an
        // exact smaller manifest produced for a multi-file session after the AI action.
        if characterLimit == nil {
            if work[path] != nil { return }
            if let snapshot = snapshots[path] {
                switch snapshot {
                case .ready, .scanning:
                    return
                case .failed(_, let characterLimit):
                    failedLimit = characterLimit
                case .idle:
                    break
                }
            }
        }
        let limit = characterLimit ?? failedLimit ?? Self.activeCharacterLimit

        if let exclusion = sessionExclusions[path] {
            snapshots[path] = .ready(Self.excludedResult(
                for: root,
                limit: limit,
                exclusion: exclusion
            ))
            return
        }

        if let existing = work[path], existing.characterLimit == limit { return }
        if case .ready(let result) = snapshots[path], result.characterLimit == limit { return }

        startWork(
            root: root,
            path: path,
            characterLimit: limit,
            sourceManifest: sourceManifests[path],
            preparedContent: preparedContents[path],
            selectedEntryIDs: selections[path],
            retainsSnapshot: false
        )
    }

    func analysis(for root: URL, characterLimit: Int) async throws -> FolderAnalysisResult {
        let path = key(for: root)
        if let current = work[path], current.characterLimit == characterLimit {
            return try await current.task.value.result
        }
        if case .ready(let result) = snapshots[path],
           result.characterLimit == characterLimit {
            return result
        }
        prepare(root, characterLimit: characterLimit)
        guard let current = work[path], current.characterLimit == characterLimit else {
            if case .ready(let result) = snapshots[path],
               result.characterLimit == characterLimit {
                return result
            }
            throw FolderAnalysisError.cannotEnumerate
        }
        return try await current.task.value.result
    }

    /// A new top-level session owns its scans. Old work is cancelled so closing or
    /// replacing a large folder cannot keep traversing it in the background.
    func beginSession(with urls: [URL]) {
        cancelAll()
        let limits = SessionContextBudget.bodyLimits(
            for: urls,
            characterLimit: Self.activeCharacterLimit
        )
        var seenFolders: Set<String> = []
        var distinctFolderCount = 0
        for (index, url) in urls.enumerated() where FileInspector.isDirectory(url) {
            let path = key(for: url)
            guard seenFolders.insert(path).inserted else { continue }
            distinctFolderCount += 1

            let exclusion: SessionExclusion?
            if distinctFolderCount > Self.maxFoldersPerSession {
                exclusion = (
                    .sessionFolderLimit,
                    "Only the first \(Self.maxFoldersPerSession) folders in one session are scanned."
                )
            } else if limits[index] < Self.minimumFolderContextCharacters {
                exclusion = (
                    .sessionContextLimit,
                    "The shared context allowance was too small to inspect this folder safely."
                )
            } else {
                exclusion = nil
            }

            if let exclusion {
                sessionExclusions[path] = exclusion
                snapshots[path] = .ready(Self.excludedResult(
                    for: url,
                    limit: limits[index],
                    exclusion: exclusion
                ))
            } else {
                prepare(url, characterLimit: limits[index])
            }
        }
    }

    func cancelAll() {
        work.values.forEach { $0.task.cancel() }
        work.removeAll()
        snapshots.removeAll()
        selections.removeAll()
        sourceManifests.removeAll()
        preparedContents.removeAll()
        sessionExclusions.removeAll()
    }

    func cancel(_ root: URL) {
        let path = key(for: root)
        work[path]?.task.cancel()
        work[path] = nil
        snapshots[path] = nil
        selections[path] = nil
        sourceManifests[path] = nil
        preparedContents[path] = nil
        sessionExclusions.removeValue(forKey: path)
    }

    func remap(from old: URL, to new: URL) {
        cancel(old)
        if FileInspector.isDirectory(new) { prepare(new) }
    }

    static var activeCharacterLimit: Int {
        EntitlementStore.shared.isPremiumUnlocked
            ? FileContentExtractor.maxCharsPro
            : FileContentExtractor.maxChars
    }

    private static func excludedResult(
        for root: URL,
        limit: Int,
        exclusion: SessionExclusion
    ) -> FolderAnalysisResult {
        FolderContextBuilder.excludedRootResult(
            root: root,
            reason: exclusion.reason,
            characterLimit: limit,
            limitDescription: exclusion.description
        )
    }

    private func startWork(
        root: URL,
        path: String,
        characterLimit: Int,
        sourceManifest cachedSourceManifest: FolderManifest?,
        preparedContent cachedPreparedContent: FolderContextBuilder.PreparedContent?,
        selectedEntryIDs cachedSelectedEntryIDs: Set<String>?,
        retainsSnapshot: Bool
    ) {
        work[path]?.task.cancel()
        let id = UUID()
        if !retainsSnapshot {
            snapshots[path] = .scanning
        }

        let task = Task<PreparedAnalysis, Error>(priority: .userInitiated) {
            try Task.checkCancellation()

            let sourceManifest: FolderManifest
            if let cachedSourceManifest {
                sourceManifest = cachedSourceManifest
            } else {
                let scanTask = Task.detached(priority: .userInitiated) {
                    try FolderScanner.scan(root: root)
                }
                sourceManifest = try await withTaskCancellationHandler(
                    operation: { try await scanTask.value },
                    onCancel: { scanTask.cancel() }
                )
            }

            let preparedContent: FolderContextBuilder.PreparedContent
            if let cachedPreparedContent {
                preparedContent = cachedPreparedContent
            } else {
                let preparationTask = Task.detached(priority: .userInitiated) {
                    try await FolderContextBuilder.prepare(manifest: sourceManifest)
                }
                preparedContent = try await withTaskCancellationHandler(
                    operation: { try await preparationTask.value },
                    onCancel: { preparationTask.cancel() }
                )
            }

            let selectableEntryIDs = Self.selectableEntryIDs(
                in: sourceManifest,
                preparedContent: preparedContent
            )
            let selectedEntryIDs = cachedSelectedEntryIDs
                .map { $0.intersection(selectableEntryIDs) }
                ?? selectableEntryIDs
            try Task.checkCancellation()
            let buildTask = Task.detached(priority: .userInitiated) {
                FolderContextBuilder.assemble(
                    manifest: sourceManifest,
                    preparedContent: preparedContent,
                    characterLimit: characterLimit,
                    selectedEntryIDs: selectedEntryIDs
                )
            }
            let result = await withTaskCancellationHandler(
                operation: { await buildTask.value },
                onCancel: { buildTask.cancel() }
            )
            return PreparedAnalysis(
                sourceManifest: sourceManifest,
                preparedContent: preparedContent,
                selectedEntryIDs: selectedEntryIDs,
                result: result
            )
        }
        work[path] = Work(
            id: id,
            characterLimit: characterLimit,
            retainsSnapshot: retainsSnapshot,
            task: task
        )

        Task { [weak self] in
            do {
                let prepared = try await task.value
                guard let self, self.work[path]?.id == id else { return }
                self.work[path] = nil
                self.sourceManifests[path] = prepared.sourceManifest
                self.preparedContents[path] = prepared.preparedContent
                self.selections[path] = prepared.selectedEntryIDs
                self.snapshots[path] = .ready(prepared.result)
            } catch is CancellationError {
                guard let self, self.work[path]?.id == id else { return }
                let shouldRetainSnapshot = self.work[path]?.retainsSnapshot == true
                self.work[path] = nil
                if !shouldRetainSnapshot {
                    self.snapshots[path] = nil
                }
            } catch {
                guard let self, self.work[path]?.id == id else { return }
                self.work[path] = nil
                self.snapshots[path] = .failed(
                    error.localizedDescription,
                    characterLimit: characterLimit
                )
            }
        }
    }

    private nonisolated static func selectableEntryIDs(
        in sourceManifest: FolderManifest,
        preparedContent: FolderContextBuilder.PreparedContent
    ) -> Set<String> {
        Set(sourceManifest.entries.compactMap { entry in
            guard case .eligible = entry.status,
                  case .content = preparedContent.byEntryID[entry.id] else {
                return nil
            }
            return entry.id
        })
    }

    private func key(for root: URL) -> String {
        root.standardizedFileURL.path
    }
}
