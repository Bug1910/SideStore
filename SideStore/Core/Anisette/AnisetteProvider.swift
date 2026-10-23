//
//  AnisetteProvider.swift
//  SideStore
//
//  Created by Magesh K on 8/9/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import CryptoKit
import SideSign

enum AnisetteProvider {
    static func fetch(handler: AnisetteServerHandler? = nil) async throws -> ALTAnisetteData {
        if UserDefaults.standard.useOnDeviceAnisette {
            debugLog("[AnisetteProvider] Fetching anisette via On-Device Anisette (ODA)...")
            return try await OnDeviceAnisetteManager.shared.fetchAnisetteData()
        } else {
            debugLog("[AnisetteProvider] Fetching anisette via remote server...")
            return try await fetchRemote(handler: handler)
        }
    }

    private static func fetchRemote(handler: AnisetteServerHandler? = nil) async throws -> ALTAnisetteData {
        let serverUrlStrings = await AnisetteServersManager.shared.getActiveServerURLs()
        let servers = serverUrlStrings.compactMap { URL(string: $0) }
        guard !servers.isEmpty else {
            throw AnisetteError.noServersConfigured
        }

        let lastServer = UserDefaults.standard.menuAnisetteURL
        let startIndex = servers.firstIndex(where: { $0.absoluteString == lastServer }) ?? 0

        let existingBlob = AnisetteConfigManager.shared.anisetteAdiBlob.flatMap { Data(base64Encoded: $0) }
        let identifier = await AnisetteConfigManager.shared.resolveDeviceIdentifier()
        let headers = await AnisetteConfigManager.shared.makeRequestHeaders()

        let rotationDisabled = UserDefaults.standard.disableAnisetteRotation
        let primaryServer = servers[startIndex]

        let onError: @Sendable (Error) async throws -> Bool = { error in
            if let anisetteError = error as? SideSign.AnisetteError,
               case .outdatedV1Server(let serverURL, _) = anisetteError {
                if UserDefaults.standard.defaultServerURL == serverURL.absoluteString {
                    return true
                }
                if let handler = handler {
                    let shouldContinue = try await handler.warnOutdatedAnisetteServer()
                    if shouldContinue {
                        UserDefaults.standard.defaultServerURL = serverURL.absoluteString
                    }
                    return shouldContinue
                }
            }
            return false
        }
        let onSuccess: @Sendable (URL) -> Void = { successfulServer in
            UserDefaults.standard.menuAnisetteURL = successfulServer.absoluteString
            debugLog("[AnisetteProvider] Successfully fetched Anisette data from \(successfulServer.absoluteString)")
        }

        let result: (data: ALTAnisetteData, newAdiBlob: Data?)

        // [AutoRefresh] Only the single-server case (Auto Rotation off) and only non-interactive callers
        // (handler == nil, i.e. AuthManager.getAuthenticatedSession used by refresh) get the 6s cap + backup.
        // With rotation on, SideSign's own failover already walks the other servers; the interactive
        // sign-in flow keeps the original behaviour. Needs proper testing on device.
        if rotationDisabled && handler == nil {
            result = try await AutoRefreshAnisette.fetchGuarded(
                primary: primaryServer,
                activeServers: servers,
                identifier: identifier,
                fetchPrimary: {
                    // A throw-away manager per request: a request that is abandoned after the timeout can
                    // only write into its own instance's (unlocked) cache, never the shared one.
                    try await SideSign.AnisetteDataManager().fetchAnisetteDataWithFailover(
                        servers: [primaryServer],
                        startIndex: 0,
                        identifier: identifier,
                        existingAdiBlob: existingBlob,
                        headers: headers,
                        onError: onError,
                        onSuccess: onSuccess
                    )
                },
                fetchBackup: { backupServer in
                    // No onSuccess here, so menuAnisetteURL (the user's choice) is never changed.
                    try await SideSign.AnisetteDataManager().fetchAnisetteData(
                        mode: .remote(server: backupServer),
                        identifier: identifier,
                        existingAdiBlob: existingBlob,
                        headers: headers
                    )
                }
            )
        } else {
            result = try await SideSign.AnisetteDataManager.shared.fetchAnisetteDataWithFailover(
                servers: rotationDisabled ? [primaryServer] : servers,
                startIndex: startIndex,
                identifier: identifier,
                existingAdiBlob: existingBlob,
                headers: headers,
                onError: onError,
                onSuccess: onSuccess
            )
        }

        if let freshBlob = result.newAdiBlob {
            AnisetteConfigManager.shared.anisetteAdiBlob = freshBlob.base64EncodedString()
        }

        return result.data
    }
}

// MARK: - [AutoRefresh] anisette timeout + backup server

struct AutoRefreshAnisetteTimeoutError: LocalizedError {
    let server: String
    let seconds: TimeInterval

    var errorDescription: String? {
        "Anisette server \(server) did not respond within \(Int(seconds)) seconds."
    }
}

enum AutoRefreshAnisette {
    typealias FetchResult = (data: ALTAnisetteData, newAdiBlob: Data?)

    /// Measured on device (2026-10-22): responses slower than ~16s always failed, under ~4s almost always worked.
    static let timeoutSeconds: TimeInterval = 6
    /// Same lifetime as SideSign's own remote cache (Constants.Anisette.remoteCacheDuration).
    static let cacheSeconds: TimeInterval = 30
    /// Safety net in case the end-of-refresh reset is missed.
    static let stickySeconds: TimeInterval = 300

    /// Backup candidates, in order. Both are listed in https://servers.sidestore.io/servers.json, both are v3
    /// servers and both report the same Mac ADI client_info (MacBookPro13,3 / Mac OS X 10.12.6 16G29).
    /// The first one that is not the primary is used.
    static let backupServerCandidates = [
        "https://mac-ani.jkcoxson.com",   // "jkcoxson" (Mac ADI)
        "https://new.ani.sidestore.io"    // "SideStore (New)"
    ]

    /// SHA-256 of the machine ID (X-Apple-I-MD-M) last returned by the user's own server. Only the hash is
    /// stored and it is never logged. A backup answer is accepted only if its machine ID hashes the same,
    /// which rejects SideSign's silent v1 fallback (shared machine ID) and any re-provisioned identity.
    private static let primaryMachineIDHashKey = "AutoRefresh.primaryMachineIDHash"

    private struct CacheEntry {
        let server: String
        let identifier: UUID
        let data: ALTAnisetteData
        let timestamp: Date
    }

    private static let lock = NSLock()
    private static var cache: CacheEntry?
    private static var stickyBackup: (server: URL, since: Date)?

    // MARK: State (all access under `lock`)

    private static func withLock<R>(_ body: () -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Clears only the in-memory header cache (used before a retry).
    static func clearCache() {
        withLock { cache = nil }
    }

    /// Called at the start and end of AppManager.refresh: forget the cache and the sticky backup.
    static func resetForRefresh() {
        withLock {
            cache = nil
            stickyBackup = nil
        }
    }

    private static func cachedData(identifier: UUID) -> (server: String, data: ALTAnisetteData)? {
        withLock {
            guard let entry = cache, entry.identifier == identifier,
                  Date().timeIntervalSince(entry.timestamp) < cacheSeconds else { return nil }
            return (entry.server, entry.data)
        }
    }

    private static func store(_ data: ALTAnisetteData, server: URL, identifier: UUID) {
        withLock {
            cache = CacheEntry(server: server.absoluteString, identifier: identifier, data: data, timestamp: Date())
        }
    }

    private static func currentStickyBackup() -> URL? {
        withLock {
            guard let sticky = stickyBackup else { return nil }
            if Date().timeIntervalSince(sticky.since) > stickySeconds {
                stickyBackup = nil
                return nil
            }
            return sticky.server
        }
    }

    private static func setStickyBackup(_ server: URL?) {
        withLock { stickyBackup = server.map { (server: $0, since: Date()) } }
    }

    private static func machineIDHash(_ data: ALTAnisetteData) -> String {
        SHA256.hash(data: Data(data.machineID.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func rememberPrimaryMachineID(_ data: ALTAnisetteData) {
        UserDefaults.standard.set(machineIDHash(data), forKey: primaryMachineIDHashKey)
    }

    /// true only when we have a recorded hash from the primary and the backup's machine ID matches it.
    private static func backupMatchesPrimary(_ data: ALTAnisetteData) -> Bool {
        guard let known = UserDefaults.standard.string(forKey: primaryMachineIDHashKey), !known.isEmpty else {
            return false
        }
        return known == machineIDHash(data)
    }

    static func elapsed(since start: Date) -> String {
        String(format: "%.1fs", Date().timeIntervalSince(start))
    }

    static func backupServer(for primary: URL, activeServers: [URL]) -> URL? {
        let slash = CharacterSet(charactersIn: "/")
        let primaryString = primary.absoluteString.trimmingCharacters(in: slash)
        let candidates = backupServerCandidates.filter { $0 != primaryString }
        let active = Set(activeServers.map { $0.absoluteString.trimmingCharacters(in: slash) })
        let preferred = candidates.first(where: { active.contains($0) }) ?? candidates.first
        return preferred.flatMap { URL(string: $0) }
    }

    // MARK: Fetch

    static func fetchGuarded(
        primary: URL,
        activeServers: [URL],
        identifier: UUID,
        fetchPrimary: @escaping @Sendable () async throws -> FetchResult,
        fetchBackup: @escaping @Sendable (URL) async throws -> FetchResult
    ) async throws -> FetchResult {
        if let cached = cachedData(identifier: identifier) {
            debugLog("[AutoRefresh] Reusing cached anisette from \(cached.server)")
            return (cached.data, nil)
        }

        // Once the primary timed out during this refresh and a verified backup answered, keep using it
        // so every Apple call does not pay another 6s wait.
        if let sticky = currentStickyBackup() {
            do {
                return try await fetchVerifiedBackup(sticky, primary: primary, identifier: identifier, fetchBackup: fetchBackup)
            } catch {
                setStickyBackup(nil)
                throw error
            }
        }

        let started = Date()
        do {
            let result = try await withTimeout(seconds: timeoutSeconds, server: primary.absoluteString, operation: fetchPrimary)
            rememberPrimaryMachineID(result.data)
            store(result.data, server: primary, identifier: identifier)
            debugLog("[AutoRefresh] Anisette from \(primary.absoluteString) took \(elapsed(since: started))")
            return result
        } catch let timeout as AutoRefreshAnisetteTimeoutError {
            debugLog("[AutoRefresh] Anisette server \(timeout.server) timed out after \(elapsed(since: started)); trying backup once")
            guard let backup = backupServer(for: primary, activeServers: activeServers) else {
                throw timeout
            }
            let result = try await fetchVerifiedBackup(backup, primary: primary, identifier: identifier, fetchBackup: fetchBackup)
            setStickyBackup(backup)
            return result
        }
    }

    /// Fetches from the backup with the same 6s cap and accepts it only if its machine ID matches the
    /// primary's. On mismatch (v1 fallback / different identity) or no recorded primary, it is a failure.
    private static func fetchVerifiedBackup(
        _ backup: URL,
        primary: URL,
        identifier: UUID,
        fetchBackup: @escaping @Sendable (URL) async throws -> FetchResult
    ) async throws -> FetchResult {
        let started = Date()
        let result: FetchResult
        do {
            result = try await withTimeout(seconds: timeoutSeconds, server: backup.absoluteString) {
                try await fetchBackup(backup)
            }
        } catch {
            debugLog("[AutoRefresh] Backup anisette server \(backup.absoluteString) failed after \(elapsed(since: started)): \(type(of: error))")
            throw error
        }

        guard backupMatchesPrimary(result.data) else {
            debugLog("[AutoRefresh] Backup anisette server \(backup.absoluteString) machine ID does not match the primary (or primary unknown); discarding")
            throw AutoRefreshAnisetteTimeoutError(server: primary.absoluteString, seconds: timeoutSeconds)
        }
        store(result.data, server: backup, identifier: identifier)
        debugLog("[AutoRefresh] Backup anisette server \(backup.absoluteString) verified, took \(elapsed(since: started))")
        // Never persist an adi.pb coming from the backup.
        return (result.data, nil)
    }

    /// Races `operation` against a timer. Uses unstructured tasks so we return on time even if the
    /// underlying request ignores cancellation (a task group would wait for the child to finish).
    static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        server: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let gate = AutoRefreshResumeGate()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let work = Task {
                do {
                    let value = try await operation()
                    if gate.claim() { continuation.resume(returning: value) }
                } catch {
                    if gate.claim() { continuation.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if gate.claim() {
                    work.cancel()
                    continuation.resume(throwing: AutoRefreshAnisetteTimeoutError(server: server, seconds: seconds))
                }
            }
        }
    }
}

/// Makes sure a continuation is resumed exactly once.
final class AutoRefreshResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

// MARK: - [AutoRefresh] retry transient errors during refresh

enum AutoRefreshRetry {
    /// Timeouts / 5xx / allServersFailed.
    static let maxRetries = 2
    /// Apple resultCode 1100: meaning not confirmed (SideSign has no mapping for it), so only one retry.
    static let maxRetriesForAppleCode = 1
    static let delaySeconds: UInt64 = 3

    /// Apple developer services resultCode seen in the device log when anisette was slow (2026-10-22).
    /// SideSign surfaces it as ServerError.underlyingError(code:message:) (DeveloperPortalAPI.swift:382/496).
    static let appleSessionResultCode = 1100

    /// Returns a short, log-safe reason and the retry budget if `error` is worth retrying, nil otherwise.
    /// Wrong password, locked account, App ID limit etc. are NOT matched and are never retried.
    static func transient(_ error: Error) -> (reason: String, maxRetries: Int)? {
        if let timeout = error as? AutoRefreshAnisetteTimeoutError {
            return ("anisette timeout (\(timeout.server))", maxRetries)
        }
        if let serverError = error as? SideSign.ServerError,
           case .underlyingError(let code, _) = serverError,
           code == appleSessionResultCode {
            return ("Apple resultCode \(code)", maxRetriesForAppleCode)
        }
        if let anisetteError = error as? SideSign.AnisetteError {
            switch anisetteError {
            case .allServersFailed:
                return ("anisette allServersFailed", maxRetries)
            case .badServerResponse(let statusCode, _) where (500...599).contains(statusCode):
                return ("anisette HTTP \(statusCode)", maxRetries)
            default:
                return nil
            }
        }
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return ("URLError timedOut", maxRetries)
        }
        return nil
    }

    /// Runs `operation`, retrying on transient errors. Before each retry only the in-memory anisette
    /// header caches are cleared (adi.pb, sign-in state and Keychain are left alone).
    static func run<T>(_ label: String, enabled: Bool = true, _ operation: () async throws -> T) async throws -> T {
        guard enabled else { return try await operation() }
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch {
                guard let info = transient(error), attempt < info.maxRetries else {
                    if attempt > 0 {
                        debugLog("[AutoRefresh] \(label): giving up after \(attempt) retries (\(type(of: error)))")
                    }
                    throw error
                }
                attempt += 1
                debugLog("[AutoRefresh] \(label): \(info.reason); clearing anisette cache, retry \(attempt)/\(info.maxRetries) in \(delaySeconds)s")
                SideSign.AnisetteDataManager.shared.clearCache()
                AutoRefreshAnisette.clearCache()
                try await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
            }
        }
    }
}

extension PipelineOperationContext {
    /// True for pipelines that only renew provisioning profiles (refresh / legacy activate / legacy restore),
    /// i.e. the AppManager.refresh path. Install/update pipelines keep their original behaviour.
    var isRefreshPipeline: Bool {
        pipelineSteps.contains(where: { $0.step == .refreshApp })
    }
}
