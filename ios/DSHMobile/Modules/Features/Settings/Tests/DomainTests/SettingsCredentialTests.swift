import DSHSettingsDomain
import DSHTestingSupport
import XCTest

@MainActor
final class SettingsCredentialTests: XCTestCase {

    func test_an_empty_credential_is_rejected_before_any_call() async {
        let carrier = FakeCarrier()
        let harness = SettingsHarness.make(carrier: carrier)

        do {
            try await harness.model.setCredential(ref: "openai/apiKey", value: "   ")
            XCTFail("empty credential must be rejected")
        } catch {
            XCTAssertTrue(carrier.calls.isEmpty, "the host must not see an empty write")
        }
    }

    func test_credential_writes_require_a_connected_settings_host() async {
        let model = SettingsModel()

        do {
            try await model.setCredential(ref: "openai/apiKey", value: "sk-test")
            XCTFail("no settings host must refuse the write")
        } catch {
            // expected: not authenticated / no host
        }

        do {
            try await model.clearCredential(ref: "openai/apiKey")
            XCTFail("no settings host must refuse the clear")
        } catch {
            // expected
        }
    }
}
