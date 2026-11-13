import BackgroundTasks
import UIKit
import UserNotifications

/// Keeps a save to the Photos app running after the app is closed.
///
/// iOS 26+: a continued processing task, which the system shows with its own progress UI
/// (title, subtitle, progress ring, stop button) at the top of the screen and on the Lock
/// Screen, for as long as the save keeps making progress.
/// Earlier, or when the system won't run one now: the usual ~30 seconds of background time,
/// then the save stops and a notification says it carries on from where it was.
@MainActor
final class BackgroundSave {
    static let shared = BackgroundSave()

    /// Info.plist BGTaskSchedulerPermittedIdentifiers has this with ".*".
    private static let prefix = "com.hantaehee.greveryday.save"

    /// The running BGContinuedProcessingTask (typed loosely for iOS 17–25).
    private var task: AnyObject?
    /// The identifier submitted for the current save, to tell a late-starting task of an
    /// earlier save apart from the current one.
    private var submittedID: String?
    private var fallbackID: UIBackgroundTaskIdentifier = .invalid
    private var stop: (() -> Void)?
    private var lastUpdate = Date.distantPast
    private var latest = LibraryModel.TransferSummary()
    /// Set when the system, not the user, ended the save.
    private(set) var stoppedBySystem = false

    /// Called when a save starts, while the app is in front. `stop` cancels the save.
    func begin(count: Int, stop: @escaping () -> Void) {
        self.stop = stop
        stoppedBySystem = false
        lastUpdate = .distantPast
        latest = LibraryModel.TransferSummary()
        latest.count = count
        requestNotifications()
        beginFallback()
        if #available(iOS 26.0, *) { submit(count: count) }
    }

    /// Whether update(_:) would pass anything on now; lets the caller skip adding up the totals.
    var wantsUpdate: Bool { Date().timeIntervalSince(lastUpdate) >= 0.5 }

    func update(_ summary: LibraryModel.TransferSummary) {
        lastUpdate = Date()
        latest = summary
        if #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask {
            apply(summary, to: task)
        }
    }

    /// Called when the save is over (finished, cancelled, or stopped by the system).
    func end(_ summary: LibraryModel.TransferSummary, unsaved: [String] = []) {
        DebugLog.write("background save: end done \(summary.done) failed \(summary.failed) cancelled \(summary.cancelled) waiting \(summary.waiting), app \(UIApplication.shared.applicationState.rawValue)")
        latest = summary
        if #available(iOS 26.0, *) {
            if let task = task as? BGContinuedProcessingTask {
                apply(summary, to: task)
                let left = summary.failed + summary.cancelled + summary.waiting
                if left == 0 {
                    task.updateTitle("저장 완료", subtitle: "\(summary.done)장을 사진 앱에 저장했어요")
                } else {
                    task.updateTitle(stoppedBySystem ? "저장 멈춤" : "저장 완료",
                                     subtitle: "\(summary.done)장 저장 · \(left)장 못 함")
                }
                task.setTaskCompleted(success: !stoppedBySystem)
            } else if let id = submittedID {
                // Not started yet; it would only show an empty progress UI.
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: id)
            }
        }
        task = nil
        submittedID = nil
        stop = nil
        if UIApplication.shared.applicationState != .active { notify(summary, unsaved: unsaved) }
        endFallback()
    }

    // MARK: - iOS 26 continued processing

    @available(iOS 26.0, *)
    private func submit(count: Int) {
        let id = "\(Self.prefix).\(UUID().uuidString)"
        // Submitting a request with no handler registered aborts the app, so never do that.
        guard register(id) else {
            DebugLog.write("background save: could not register \(id)")
            return
        }
        let request = BGContinuedProcessingTaskRequest(identifier: id, title: Self.title, subtitle: "\(count)장 준비 중")
        // Start now or not at all: a save that starts later, on its own, would surprise.
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            submittedID = id
            DebugLog.write("background save: submitted \(id)")
        } catch {
            DebugLog.write("background save: submit failed: \(error.localizedDescription)")
        }
    }

    @available(iOS 26.0, *)
    /// One handler per submitted identifier. Registering the wildcard itself ("….save.*") is
    /// refused at run time (iOS 27.2 returned false), while each concrete identifier under the
    /// Info.plist wildcard registers; each save uses a new UUID, so none is registered twice.
    private func register(_ id: String) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { task in
            guard let task = task as? BGContinuedProcessingTask else { return task.setTaskCompleted(success: false) }
            MainActor.assumeIsolated { BackgroundSave.shared.started(task) }
        }
    }

    @available(iOS 26.0, *)
    private func started(_ task: BGContinuedProcessingTask) {
        DebugLog.write("background save: started \(task.identifier), current \(submittedID ?? "-")")
        guard task.identifier == submittedID, stop != nil else {
            // The save already ended (or this is an old request).
            task.setTaskCompleted(success: true)
            return
        }
        self.task = task
        task.expirationHandler = {
            // The stop button, or the system ending it (too slow, low power, …).
            Task { @MainActor in BackgroundSave.shared.expire() }
        }
        apply(latest, to: task)
    }

    @available(iOS 26.0, *)
    private func apply(_ s: LibraryModel.TransferSummary, to task: BGContinuedProcessingTask) {
        // Thousandths: the totals are partly estimates and keep changing, the ring only
        // needs the fraction.
        task.progress.totalUnitCount = 1000
        task.progress.completedUnitCount = Int64(s.fraction * 1000)
        task.updateTitle(Self.title, subtitle: Self.subtitle(s))
    }

    private func expire() {
        DebugLog.write("background save: expired (stop button or system)")
        stoppedBySystem = true
        stop?()
    }

    private static let title = "사진 앱에 저장 중"

    private static func subtitle(_ s: LibraryModel.TransferSummary) -> String {
        var parts = ["\(min(s.finished + 1, s.count))/\(s.count)장"]
        if let left = s.secondsLeft { parts.append(remaining(left)) }
        return parts.joined(separator: " · ")
    }

    nonisolated static func remaining(_ seconds: Double) -> String {
        if seconds < 60 { return "1분 이내" }
        if seconds < 3600 { return "약 \(Int((seconds / 60).rounded()))분 남음" }
        return "약 \(Int(seconds / 3600))시간 \(Int(seconds.truncatingRemainder(dividingBy: 3600) / 60))분 남음"
    }

    // MARK: - Fallback: background time

    private func beginFallback() {
        endFallback()
        fallbackID = UIApplication.shared.beginBackgroundTask(withName: "사진 저장") {
            MainActor.assumeIsolated {
                let shared = BackgroundSave.shared
                DebugLog.write("background save: background time ran out, continued task \(shared.task == nil ? "none" : "running")")
                // The continued processing task keeps the app running; nothing to stop.
                if shared.task == nil {
                    shared.stoppedBySystem = true
                    shared.stop?()
                }
                shared.endFallback()
            }
        }
    }

    private func endFallback() {
        guard fallbackID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(fallbackID)
        fallbackID = .invalid
    }

    // MARK: - Notifications

    private func requestNotifications() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    private func notify(_ s: LibraryModel.TransferSummary, unsaved: [String]) {
        let left = s.failed + s.cancelled + s.waiting
        guard s.done > 0 || left > 0 else { return }
        let content = UNMutableNotificationContent()
        if stoppedBySystem, left > 0 {
            content.title = "저장이 멈췄어요"
            content.body = "\(s.done)장을 저장했어요. 앱을 열면 남은 \(left)장을 이어서 저장할 수 있어요."
        } else if left > 0 {
            content.title = "\(s.done)장 저장, \(left)장은 저장하지 못했어요"
            let names = unsaved.prefix(3).joined(separator: ", ") + (unsaved.count > 3 ? " 외 \(unsaved.count - 3)장" : "")
            content.body = "\(names) — 앱에서 다시 저장할 수 있어요."
        } else {
            content.title = "저장을 마쳤어요"
            content.body = "\(s.done)장을 사진 앱에 저장했어요."
        }
        content.sound = .default
        let request = UNNotificationRequest(identifier: "save-finished", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
