import Combine
import Foundation

@main
struct AppStoreObservationChecks {
    @MainActor
    static func main() {
        // The setup page observes this store, while helper state lives in its child.
        // Use the real controller's read-only refresh; never register or mutate a disk.
        let store = ReadOnlyAppStore(applicationIdentity: nil)
        let controller = store.writeController
        var pageInvalidations = 0
        var helperInvalidations = 0
        let pageSubscription = store.objectWillChange.sink { pageInvalidations += 1 }
        let helperSubscription = controller.objectWillChange.sink { helperInvalidations += 1 }

        controller.refreshHelperState()
        guard helperInvalidations > 0 else {
            fatalError("CHECK FAILED: helper refresh must publish its current result")
        }
        guard pageInvalidations > 0 else {
            fatalError("CHECK FAILED: the visible setup page must invalidate when helper refresh publishes, without navigation")
        }
        let firstRefreshInvalidations = pageInvalidations
        controller.refreshHelperState()
        guard pageInvalidations > firstRefreshInvalidations else {
            fatalError("CHECK FAILED: subsequent helper checks must still update the visible page")
        }
        withExtendedLifetime((pageSubscription, helperSubscription)) {}
        print("PASS: helper refresh updates the observed app store without page navigation")
    }
}
