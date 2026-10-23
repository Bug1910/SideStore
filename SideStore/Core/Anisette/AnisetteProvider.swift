//
//  AnisetteProvider.swift
//  SideStore
//
//  Created by Magesh K on 8/9/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
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

        let provider = SideSign.AnisetteDataManager.shared
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
        let fetchPrimary: @Sendable () async throws -> (data: ALTAnisetteData, newAdiBlob: Data?) = {
            try await provider.fetchAnisetteDataWithFailover(
                servers: rotationDisabled ? [primaryServer] : servers,
                startIndex: startIndex,
                identifier: identifier,
                existingAdiBlob: existingBlob,
                headers: headers,
                onError: onError,
                onSuccess: onSuccess
            )
        }

        let result: (data: ALTAnisetteData, newAdiBlob: Data?)

        // [AutoRefresh] Only the single-server case (Auto Rotation off) and only non-interactive callers
        // (handler == nil, i.e. AuthManager.getAuthenticatedSession used by refresh) get the 6s cap + backup.
        // With rotation on, SideSign's own failover already walks the other servers; the interactive
        // sign-in flow keeps the original behaviour. Needs proper testing on device.
        if rotationDisabled && handler == nil {
            let started = Date()
            do {
                result = try await AutoRefreshAnisette.withTimeout(
                    seconds: AutoRefreshAnisette.timeoutSeconds,
                    server: primaryServer.absoluteString,
                    operation: fetchPrimary
                )
                debugLog("[AutoRefresh] Anisette from \(primaryServer.absoluteString) took \(AutoRefreshAnisette.elapsed(since: started))")
            } catch let timeout as AutoRefreshAnisetteTimeoutError {
                debugLog("[AutoRefresh] Anisette server \(timeout.server) timed out after \(AutoRefreshAnisette.elapsed(since: started)); trying backup once")
                result = try await AutoRefreshAnisette.fetchFromBackup(
                    primary: primaryServer,
                    activeServers: servers,
                    existingAdiBlob: existingBlob,
                    fetch: { backupServer in
                        // Direct single-server fetch: no onSuccess, so menuAnisetteURL (the user's choice) is untouched.
                        try await provider.fetchAnisetteData(
                            mode: .remote(server: backupServer),
                            identifier: identifier,
                            existingAdiBlob: existingBlob,
                            headers: headers
                        )
                    }
                )
            }
        } else {
            result = try await fetchPrimary()
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
    /// Measured on device (2026-10-22): responses slower than ~16s always failed, under ~4s almost always worked.
    static let timeoutSeconds: TimeInterval = 6

    /// Backup candidates, in order. Both are listed in https://servers.sidestore.io/servers.json, both are v3
    /// servers and both report the same Mac ADI client_info (MacBookPro13,3 / Mac OS X 10.12.6 16G29),
    /// so the stored adi.pb should stay usable on either. The first one that is not the primary is used.
    static let backupServerCandidates = [
        "https://mac-ani.jkcoxson.com",   // "jkcoxson" (Mac ADI)
        "https://new.ani.sidestore.io"    // "SideStore (New)"
    ]

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

    /// Fetches once from the backup server without touching the user's selected server (menuAnisetteURL).
    /// If the backup hands out a *different* adi.pb (it re-provisioned a new device identity), the result
    /// is discarded so the stored identity is never replaced by this fallback.
    static func fetchFromBackup(
        primary: URL,
        activeServers: [URL],
        existingAdiBlob: Data?,
        fetch: @escaping @Sendable (URL) async throws -> (data: ALTAnisetteData, newAdiBlob: Data?)
    ) async throws -> (data: ALTAnisetteData, newAdiBlob: Data?) {
        guard let backup = backupServer(for: primary, activeServers: activeServers) else {
            throw AutoRefreshAnisetteTimeoutError(server: primary.absoluteString, seconds: timeoutSeconds)
        }

        let started = Date()
        let result: (data: ALTAnisetteData, newAdiBlob: Data?)
        do {
            result = try await withTimeout(seconds: timeoutSeconds, server: backup.absoluteString) {
                try await fetch(backup)
            }
        } catch {
            debugLog("[AutoRefresh] Backup anisette server \(backup.absoluteString) failed after \(elapsed(since: started)): \(type(of: error))")
            throw error
        }

        if let newBlob = result.newAdiBlob, newBlob != existingAdiBlob {
            debugLog("[AutoRefresh] Backup anisette server \(backup.absoluteString) returned a new device identity; discarding it")
            SideSign.AnisetteDataManager.shared.clearCache()
            throw AutoRefreshAnisetteTimeoutError(server: primary.absoluteString, seconds: timeoutSeconds)
        }
        debugLog("[AutoRefresh] Backup anisette server \(backup.absoluteString) succeeded in \(elapsed(since: started))")
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
    static let maxRetries = 2
    static let delaySeconds: UInt64 = 3

    /// Apple developer services resultCode seen in the device log when anisette was slow (2026-10-22).
    /// SideSign surfaces it as ServerError.underlyingError(code:message:) (DeveloperPortalAPI.swift:382/496).
    static let appleSessionResultCode = 1100

    /// Returns a short, log-safe reason if `error` is worth retrying, nil otherwise.
    /// Wrong password, locked account, App ID limit etc. are NOT matched and are never retried.
    static func transientReason(_ error: Error) -> String? {
        if let timeout = error as? AutoRefreshAnisetteTimeoutError {
            return "anisette timeout (\(timeout.server))"
        }
        if let serverError = error as? SideSign.ServerError,
           case .underlyingError(let code, _) = serverError,
           code == appleSessionResultCode {
            return "Apple resultCode \(code)"
        }
        if let anisetteError = error as? SideSign.AnisetteError {
            switch anisetteError {
            case .allServersFailed:
                return "anisette allServersFailed"
            case .badServerResponse(let statusCode, _) where (500...599).contains(statusCode):
                return "anisette HTTP \(statusCode)"
            default:
                return nil
            }
        }
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return "URLError timedOut"
        }
        return nil
    }

    /// Runs `operation`, retrying up to `maxRetries` times on transient errors. Before each retry only the
    /// in-memory anisette header cache is cleared (adi.pb, sign-in state and Keychain are left alone).
    static func run<T>(_ label: String, enabled: Bool = true, _ operation: () async throws -> T) async throws -> T {
        guard enabled else { return try await operation() }
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch {
                guard attempt < maxRetries, let reason = transientReason(error) else {
                    if attempt > 0 {
                        debugLog("[AutoRefresh] \(label): giving up after \(attempt) retries (\(type(of: error)))")
                    }
                    throw error
                }
                attempt += 1
                debugLog("[AutoRefresh] \(label): \(reason); clearing anisette cache, retry \(attempt)/\(maxRetries) in \(delaySeconds)s")
                SideSign.AnisetteDataManager.shared.clearCache()
                try await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
            }
        }
    }
}

extension PipelineOperationContext {
    /// True for pipelines that only renew provisioning profiles (refresh / legacy activate),
    /// i.e. the AppManager.refresh path. Install/update pipelines keep their original behaviour.
    var isRefreshPipeline: Bool {
        pipelineSteps.contains(where: { $0.step == .refreshApp })
    }
}
