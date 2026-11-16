// Pogent — shared task activity attributes.
// 同一个文件同时编进 App 与 Widget Extension 两个 target。

import ActivityKit
import Foundation

public struct PogentTaskActivity: ActivityAttributes {

    public struct ContentState: Codable, Hashable {
        public var stepTitle: String
        public var stepIndex: Int
        public var stepCount: Int
        public var awaitingApproval: Bool
        public var approvalPrompt: String?
        public var approvalRisk: String?
        public var finished: Bool

        public init(
            stepTitle: String,
            stepIndex: Int,
            stepCount: Int,
            awaitingApproval: Bool = false,
            approvalPrompt: String? = nil,
            approvalRisk: String? = nil,
            finished: Bool = false
        ) {
            self.stepTitle = stepTitle
            self.stepIndex = stepIndex
            self.stepCount = stepCount
            self.awaitingApproval = awaitingApproval
            self.approvalPrompt = approvalPrompt
            self.approvalRisk = approvalRisk
            self.finished = finished
        }
    }

    public var runID: String
    public var conversationTitle: String

    public init(runID: String, conversationTitle: String) {
        self.runID = runID
        self.conversationTitle = conversationTitle
    }
}

public enum PogentShared {
    public static let appGroup = "group.bot.pogent"
    public static let widgetKind = "PogentStatusWidget"
    public static let activityAttributes = "PogentTaskActivity"
}
