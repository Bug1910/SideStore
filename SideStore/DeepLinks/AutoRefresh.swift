//
//  AutoRefresh.swift
//  SideStore
//
//  Lets `sidestore://refresh-all` and "app opened while something is about to expire"
//  run the exact same path as the "Refresh All" button in My Apps
//  (MyAppsViewController.performRefreshAllApps), then posts a local notification with the result.
//
//  Logging rule: never log Apple ID, password, tokens or anisette data here.
//

@preconcurrency import UIKit
import UserNotifications
import CoreData

@MainActor
enum AutoRefresh
{
    enum Source: String
    {
        case url
        case foreground
    }

    nonisolated static let requestNotification = Notification.Name(Bundle.Info.appbundleIdentifier + ".AutoRefreshRequestNotification")

    // Refresh when anything expires within this interval.
    static let expiryThreshold: TimeInterval = 2 * 24 * 60 * 60
    // Minimum interval between two automatic (foreground) attempts.
    static let minimumAttemptInterval: TimeInterval = 30 * 60

    private static let lastAttemptDateKey = "autoRefreshLastAttemptDate"
    private static let inFlightSinceKey = "autoRefreshInFlightSince"
    private static let resultNotificationIdentifier = "sidestore-auto-refresh-result"

    // Request waiting for My Apps to be on screen (cold launch, other tab selected, etc.).
    private(set) static var pendingSource: Source?

    static func request(_ source: Source)
    {
        debugLog("[AutoRefresh] request(source: \(source.rawValue))")
        self.pendingSource = source
        NotificationCenter.default.post(name: AutoRefresh.requestNotification, object: nil)
    }

    static func consumePendingSource() -> Source?
    {
        let source = self.pendingSource
        self.pendingSource = nil
        return source
    }

    /// Called whenever the app becomes active. Requests a refresh-all if enabled,
    /// something expires within `expiryThreshold`, and the last automatic attempt was > 30 minutes ago.
    static func requestIfExpiringSoon()
    {
        guard UserDefaults.standard.isAutoRefreshOnOpenEnabled else { return }
        guard UserDefaults.standard.hasCompletedOnboarding else { return }
        guard DatabaseManager.shared.isStarted else { return }
        guard self.pendingSource == nil else { return }

        let now = Date()
        if let lastAttempt = UserDefaults.standard.object(forKey: self.lastAttemptDateKey) as? Date,
           now.timeIntervalSince(lastAttempt) < self.minimumAttemptInterval
        {
            debugLog("[AutoRefresh] skip: last automatic attempt was \(Int(now.timeIntervalSince(lastAttempt)))s ago")
            return
        }

        let installedApps = InstalledApp.fetchAppsForRefreshingAll(in: DatabaseManager.shared.viewContext)
        guard let earliest = installedApps.map({ $0.expirationDate }).min() else { return }

        let remaining = earliest.timeIntervalSince(now)
        guard remaining <= self.expiryThreshold else {
            debugLog("[AutoRefresh] skip: earliest expiration in \(Int(remaining / 3600))h")
            return
        }

        debugLog("[AutoRefresh] earliest expiration in \(Int(remaining / 3600))h, requesting refresh-all")
        UserDefaults.standard.set(now, forKey: self.lastAttemptDateKey)
        self.request(.foreground)
    }

    static func markStarted(_ source: Source)
    {
        debugLog("[AutoRefresh] starting refresh-all (source: \(source.rawValue))")
        let now = Date()
        UserDefaults.standard.set(now, forKey: self.inFlightSinceKey)
        // Any started run (URL or automatic) counts for the 30-minute throttle.
        UserDefaults.standard.set(now, forKey: self.lastAttemptDateKey)
    }

    /// If the previous run never reported back (e.g. SideStore was terminated while refreshing itself),
    /// tell the user the current expiration instead of staying silent.
    static func reportInterruptedRunIfNeeded()
    {
        guard UserDefaults.standard.object(forKey: self.inFlightSinceKey) != nil else { return }
        UserDefaults.standard.removeObject(forKey: self.inFlightSinceKey)
        guard DatabaseManager.shared.isStarted else { return }

        debugLog("[AutoRefresh] previous refresh-all did not report a result")

        var body = "上次續簽沒有回報結果（SideStore 可能在續簽自己時被系統重開）。"
        if let altStoreApp = InstalledApp.fetchAltStore(in: DatabaseManager.shared.viewContext)
        {
            body += "SideStore 目前到期：" + self.format(altStoreApp.expirationDate)
        }
        self.postNotification(title: "SideStore 續簽結果不明", body: body)
    }

    static func handleCompletion(_ result: Result<[String: Result<InstalledApp, Error>], Error>)
    {
        UserDefaults.standard.removeObject(forKey: self.inFlightSinceKey)

        switch result
        {
        case .failure(let error):
            let nsError = error as NSError
            debugLog("[AutoRefresh] failed before refreshing: \(nsError.domain) \(nsError.code)")
            self.postNotification(title: "SideStore 續簽失敗", body: "失敗：" + nsError.localizedDescription)

        case .success(let results):
            var expirationDates = [Date]()
            var failures = [(String, Error)]()
            var cancelledCount = 0

            for (bundleID, appResult) in results
            {
                switch appResult
                {
                case .success(let installedApp):
                    // installedApp belongs to the refresh group's background context:
                    // only take its objectID (thread-safe) and read the saved value on the main-queue viewContext.
                    let viewContext = DatabaseManager.shared.viewContext
                    if let app = try? viewContext.existingObject(with: installedApp.objectID) as? InstalledApp
                    {
                        viewContext.refresh(app, mergeChanges: true)
                        expirationDates.append(app.expirationDate)
                    }

                case .failure(let error) where error is CancellationError:
                    cancelledCount += 1

                case .failure(let error):
                    failures.append((bundleID, error))
                }
            }

            debugLog("[AutoRefresh] finished: \(results.count) apps, \(failures.count) failed, \(cancelledCount) cancelled")

            if let failure = failures.first
            {
                let nsError = failure.1 as NSError
                debugLog("[AutoRefresh] first failure: \(failure.0) \(nsError.domain) \(nsError.code)")

                let title = failures.count == 1 ? "SideStore 續簽失敗" : "SideStore 續簽失敗（\(failures.count) 個 App）"
                self.postNotification(title: title, body: "失敗：" + nsError.localizedDescription)
            }
            else if results.count > cancelledCount
            {
                let fallback = InstalledApp.fetchAppsForRefreshingAll(in: DatabaseManager.shared.viewContext).map { $0.expirationDate }.min()
                if let earliest = expirationDates.min() ?? fallback
                {
                    self.postNotification(title: "SideStore 續簽成功", body: "續簽成功：到期 " + self.format(earliest))
                }
                else
                {
                    self.postNotification(title: "SideStore 續簽成功", body: "續簽成功")
                }
            }
            else if cancelledCount > 0
            {
                self.postNotification(title: "SideStore 續簽已取消", body: "失敗：已取消")
            }
        }
    }
}

private extension AutoRefresh
{
    static func format(_ date: Date) -> String
    {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func postNotification(title: String, body: String)
    {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        // Same identifier so a newer result replaces the older one.
        let request = UNNotificationRequest(identifier: self.resultNotificationIdentifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
