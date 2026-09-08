import Foundation
import NTFSLiteCore
import NTFSLiteSystem
import NTFSLitePresentation

@main enum ReadOnlyProjectionProbe {
    static func main() async throws {
        let capture = try ReadOnlyDiskObserver().capture()
        let observationTask = Task {
            var last: DiskInventoryObservation?
            for await event in capture.events {
                if case let .observation(value) = event { last = value }
            }
            return last
        }
        try await Task.sleep(for: .seconds(3))
        let drained = await capture.stopAndDrain()
        guard let observation = await observationTask.value else { fatalError("no observation") }
        let dashboard = ReadOnlyDashboardPresenter.presentation(
            for: observation, setupAssessment: SetupAssessment(issues: [.conflictScanIncomplete]),
            isSetupRefreshing: false
        )
        let records = observation.physicalDisks.flatMap(\.volumes)
        let summary: [String: Any] = [
            "drained": drained,
            "topLevelIssueCount": observation.issues.count,
            "candidateCount": records.compactMap(\.candidate).count,
            "nativeIdentitySupplementUsed": records.contains { $0.evidence.volumeUUID == nil && $0.candidate != nil },
            "coordinatorInventoryPresent": observation.coordinatorInventory != nil,
            "dashboardTitle": dashboard.title,
            "dashboardDetail": dashboard.detail,
            "displayedVolumeCount": dashboard.volumes.count,
            "displayedAccess": dashboard.volumes.map(\.accessText),
            "purposeUnconfirmed": dashboard.volumes.allSatisfy { $0.detail.contains("用途未确认") },
            "writeControlsAvailable": dashboard.writeControlsAvailable,
            "scope": "production observation and presentation; no window or Setup validation"
        ]
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys, .prettyPrinted])
        print(String(decoding: data, as: UTF8.self))
    }
}
