import Foundation
@preconcurrency import ActivityKit

/// 灵动岛 / 锁屏上的任务状态。审批也能在这里点。
@MainActor
final class TaskActivityManager {
    private var activity: Activity<PogentTaskActivity>?

    func start(runID: String, title: String, step: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = PogentTaskActivity(runID: runID, conversationTitle: title)
        let state = PogentTaskActivity.ContentState(stepTitle: step, stepIndex: 0, stepCount: 1)
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: Date().addingTimeInterval(600)),
                pushType: nil
            )
        } catch {
            activity = nil
        }
    }

    func update(step: String, index: Int, total: Int, approval: ApprovalRequest? = nil) async {
        guard let activity else { return }
        let state = PogentTaskActivity.ContentState(
            stepTitle: step,
            stepIndex: index,
            stepCount: total,
            awaitingApproval: approval != nil,
            approvalPrompt: approval?.detail,
            approvalRisk: approval?.risk.title
        )
        await activity.update(.init(state: state, staleDate: Date().addingTimeInterval(300)))
    }

    func finish(summary: String) async {
        guard let activity else { return }
        let state = PogentTaskActivity.ContentState(
            stepTitle: summary, stepIndex: 1, stepCount: 1, finished: true
        )
        await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(.now + 8))
        self.activity = nil
    }

    func stop() async {
        await activity?.end(nil, dismissalPolicy: .immediate)
        activity = nil
    }
}
