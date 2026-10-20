import DSHChatDomain
import DSHKit
import Observation
import XCTest

/// CatalogState 拆分后的钉子：UI 仍读 model.currentSelection，存储在 catalogState。
@MainActor
final class CatalogStateTests: XCTestCase {

    func testForwardedSelectionComesFromCatalogState() {
        let model = ChatModel()
        model.catalogState.currentSelection = ModelSelection(provider: "p", model: "m")
        XCTAssertEqual(model.currentSelection?.model, "m")
    }

    func testResetClearsSelectionAndPermissions() {
        let state = CatalogState()
        state.currentSelection = ModelSelection(provider: "p", model: "m")
        state.currentPermission = "read"
        state.reset()
        XCTAssertNil(state.currentSelection)
        XCTAssertNil(state.currentPermission)
        XCTAssertTrue(state.permissionOptions.isEmpty)
    }

    func testObservationOfForwardedSelectionFires() async {
        let model = ChatModel()
        let changed = expectation(description: "selection change observed")
        withObservationTracking {
            _ = model.currentSelection
        } onChange: {
            changed.fulfill()
        }
        model.catalogState.currentSelection = ModelSelection(provider: "p", model: "m")
        await fulfillment(of: [changed], timeout: 1)
    }
}
