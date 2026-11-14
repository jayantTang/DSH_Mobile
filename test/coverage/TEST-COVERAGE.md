# 全量需求测试覆盖

> 由 `node test/coverage/check-test-coverage.mjs` 生成。只有 ✅ 代表精确测试文件与断言标记都存在；🟠 只是套件级映射，不得当作已完成。

汇总：共 52 条 · ✅ verified 43 · 🟡 partial 0 · 🟠 suite-only 9 · ❌ gap 0

| SR | 状态 | 精确测试证据 | 负责套件 | 缺口 |
|---|---|---|---|---|
| SR-01.01 | ✅ verified | `plugins/mobile-link/test/cli-enroll.test.js`：`open enrollment works without an invite code` | `requirements`、`connector`、`relay-go`、`ui-connection` |  |
| SR-01.02 | 🟠 suite-only | — | `requirements`、`connector` | 只有套件级映射，未逐测试 |
| SR-01.03 | ✅ verified | `plugins/mobile-link/test/state.test.js`：`mintPairCode posts to the prefixed relay` | `requirements`、`ios-dshkit`、`connector`、`relay-go`、`ui-connection` |  |
| SR-01.04 | ✅ verified | `ios/DSHMobile/DSHKit/Tests/DSHKitTests/LinkCarrierSocketLifecycleTests.swift`：`socket 自己断了` | `requirements`、`ios-dshkit` |  |
| SR-01.05 | ✅ verified | `plugins/mobile-link/test/plugin.test.js`：`GET /mobile-link/devices returns the full paired roster` | `requirements`、`connector`、`relay-go` |  |
| SR-01.06 | ✅ verified | `ios/DSHMobile/Modules/Features/Connection/Tests/DomainTests/ConnectionProfileTests.swift`：`test_only_the_direct_transport_avoids_the_relay` | `requirements`、`ui-connection` |  |
| SR-01.07 | ✅ verified | `test/acceptance/07-relay-reconnect.md`：`TC-MOB-93` | `requirements`、`ui-connection` |  |
| SR-01.08 | ✅ verified | `ios/DSHMobile/Modules/Features/Connection/Tests/DomainTests/ConnectionDomainStoreTests.swift`：`test_saved_profiles_round_trip_through_a_defaults_domain` | `requirements`、`ui-connection` |  |
| SR-01.09 | ✅ verified | `ios/DSHMobile/Modules/Features/Connection/Tests/DomainTests/ConnectionProfileTests.swift`：`test_the_state_flags_are_mutually_exclusive` | `requirements`、`ui-connection` |  |
| SR-01.10 | ✅ verified | `relay-go/internal/wsapi/wsapi_test.go`：`TestTheDeviceLimitIs4021OnTheWire` | `requirements`、`relay-go` |  |
| SR-01.11 | 🟠 suite-only | — | `requirements`、`ui-connection` | 只有套件级映射，未逐测试 |
| SR-02.01 | ✅ verified | `ios/DSHMobile/Modules/Features/Chat/Tests/DomainTests/ChatModelTransportTests.swift`：`test_open_subscribes_to_the_session_the_summary_names` | `requirements`、`ios-dshkit`、`connector`、`ui-chat` |  |
| SR-02.02 | 🟠 suite-only | — | `requirements`、`ui-chat` | 只有套件级映射，未逐测试 |
| SR-02.03 | ✅ verified | `ios/DSHMobile/Modules/Core/Tests/HostEventHubTests.swift`：`test_a_waiting_prompt_is_promoted_and_kept_by_session` | `requirements`、`ios-dshkit`、`connector`、`ui-chat` |  |
| SR-02.04 | ✅ verified | `ios/DSHMobile/Modules/Features/Chat/Tests/DomainTests/ChatModelTransportTests.swift`：`test_send_puts_the_prompt_on_the_wire`<br>`ios/DSHMobile/Modules/Features/Chat/Tests/DomainTests/ChatModelTransportTests.swift`：`test_cancel_names_the_open_session` | `requirements`、`ios-modules`、`connector` |  |
| SR-02.05 | ✅ verified | `ios/DSHMobile/Modules/Features/Chat/Tests/DomainTests/ChatModelQueueTests.swift`：`test_a_queued_send_is_optimistic` | `requirements`、`ios-modules` |  |
| SR-02.06 | ✅ verified | `ios/DSHMobile/Modules/Features/Chat/Tests/DomainTests/SearchStateTests.swift`：`SearchStateTests` | `requirements`、`ios-modules` |  |
| SR-02.07 | ✅ verified | `ios/DSHMobile/Modules/Features/Chat/Tests/DomainTests/AttachmentLoadFailureTests.swift`：`AttachmentLoadFailureTests` | `requirements`、`connector`、`send-image`、`doubao-image` |  |
| SR-02.08 | ✅ verified | `ios/DSHMobile/DSHMobileTests/SessionAlertsTests.swift`：`testTurnEndRequestCarriesSessionRouteAndIdentifier` | `requirements`、`ios-app-unit`、`relay-go` |  |
| SR-02.09 | ✅ verified | `ios/DSHMobile/DSHMobileTests/SessionAlertsTests.swift`：`testSameEventUsesTheSameIdentifier` | `requirements`、`ios-app-unit` |  |
| SR-02.10 | 🟠 suite-only | — | `requirements`、`ios-modules`、`ui-chat` | 只有套件级映射，未逐测试 |
| SR-02.11 | ✅ verified | `ios/DSHMobile/Modules/Features/Chat/Tests/DomainTests/AttachmentLoadFailureTests.swift`：`AttachmentLoadFailureTests` | `requirements`、`send-image` |  |
| SR-02.12 | ✅ verified | `ios/DSHMobile/Modules/Features/Chat/Tests/DomainTests/ChatModelProcessFoldTests.swift`：`test_a_completed_turn_folds_on_the_model_surface` | `requirements`、`ios-modules`、`ui-chat` |  |
| SR-02.13 | ✅ verified | `ios/DSHMobile/Modules/Features/Sessions/Tests/DomainTests/SessionListCreateVisibilityTests.swift`：`test_created_session_is_visible_before_the_host_lists_it` | `requirements`、`ios-modules` |  |
| SR-02.14 | ✅ verified | `ios/DSHMobile/Modules/Features/Sessions/Tests/DomainTests/SessionListCombinationTests.swift`：`test_archiving_the_session_that_is_open` | `requirements`、`ios-modules` |  |
| SR-02.15 | ✅ verified | `ios/DSHMobile/Modules/Features/Sessions/Tests/DomainTests/SessionListDigestActivityTests.swift`：`test_j_an_incremental_digest_keeps_the_child_counts` | `requirements`、`ios-modules` |  |
| SR-03.01 | ✅ verified | `ios/DSHMobile/Modules/Features/Files/Tests/DomainTests/WorkspaceFilesModelTests.swift`：`test_the_root_listing_asks_for_dot` | `requirements`、`ios-dshkit`、`connector` |  |
| SR-03.02 | ✅ verified | `ios/DSHMobile/Modules/Features/Files/Tests/DomainTests/GitModelTests.swift`：`GitModelTests` | `requirements`、`ios-dshkit`、`connector` |  |
| SR-03.03 | ✅ verified | `ios/DSHMobile/Modules/Features/Files/Tests/DomainTests/WorkspaceFilesModelTests.swift`：`test_a_file_reads_page_by_page` | `requirements`、`ios-modules`、`ui-files` |  |
| SR-03.04 | ✅ verified | `ios/DSHMobile/DSHKit/Tests/DSHKitTests/RelayFileTransferTests.swift`：`downloadLands` | `requirements`、`ios-modules`、`ui-files` |  |
| SR-03.05 | ✅ verified | `ios/DSHMobile/DSHKit/Tests/DSHKitTests/OutgoingFilesTests.swift`：`OutgoingFilesTests` | `requirements`、`ios-modules`、`connector` |  |
| SR-03.06 | ✅ verified | `test/acceptance/08-text-wrap.md`：`TC-MOB-201` | `requirements`、`ui-files` |  |
| SR-04.01 | 🟠 suite-only | — | `requirements`、`scripts` | 只有套件级映射，未逐测试 |
| SR-04.02 | ✅ verified | `scripts/release/ota-version.test.mjs`：`构建号是北京时间` | `requirements`、`scripts`、`release-plan` |  |
| SR-04.03 | 🟠 suite-only | — | `requirements`、`scripts` | 只有套件级映射，未逐测试 |
| SR-05.01 | ✅ verified | `ios/DSHMobile/Modules/Features/Feedback/Tests/DomainTests/FeedbackDraftLengthTests.swift`：`FeedbackDraftLengthTests` | `requirements`、`mail` |  |
| SR-05.02 | ✅ verified | `ios/DSHMobile/Modules/Features/Feedback/Tests/DomainTests/FeedbackCenterTests.swift`：`FeedbackCenterTests` | `requirements`、`ios-modules`、`mail` |  |
| SR-05.03 | ✅ verified | `ios/DSHMobile/Modules/Features/Feedback/Tests/DomainTests/FeedbackAttachmentLoaderTests.swift`：`FeedbackAttachmentLoaderTests` | `requirements`、`mail` |  |
| SR-06.01 | 🟠 suite-only | — | `requirements`、`ios-modules` | 只有套件级映射，未逐测试 |
| SR-06.02 | ✅ verified | `ios/DSHMobile/Modules/Features/Settings/Tests/DomainTests/SettingsCredentialTests.swift`：`test_credential_writes_require_a_connected_settings_host` | `requirements`、`ios-modules` |  |
| SR-06.03 | 🟠 suite-only | — | `requirements`、`ios-modules` | 只有套件级映射，未逐测试 |
| SR-06.04 | ✅ verified | `test/acceptance/06-about.md`：`TC-UI-103` | `requirements`、`ios-app-unit` |  |
| SR-06.05 | ✅ verified | `scripts/dev/check-diagnostics.test.mjs`：`agent-secret` | `requirements`、`ios-modules` |  |
| SR-06.06 | 🟠 suite-only | — | `requirements`、`ios-modules` | 只有套件级映射，未逐测试 |
| SR-07.01 | ✅ verified | `test/acceptance/09-ipad-layout.md`：`TC-IPAD-09` | `requirements`、`ui-ipad`、`ios-build` |  |
| SR-07.02 | ✅ verified | `scripts/dev/check-localization.mjs`：`hardcoded-string` | `requirements`、`static-loc` |  |
| SR-08.01 | ✅ verified | `ios/DSHMobile/Modules/Features/Chat/Tests/DomainTests/ChatModelDisruptionTests.swift`：`test_reopening_the_same_session_folds_its_replayed_records_once`<br>`test/acceptance/07-relay-reconnect.md`：`TC-MOB` | `requirements`、`ios-modules` |  |
| SR-08.02 | ✅ verified | `ios/DSHMobile/DSHKit/Tests/DSHKitTests/RelayFileTransferTests.swift`：`shortDownloadIsRejected`<br>`ios/DSHMobile/DSHKit/Tests/DSHKitTests/WorkspaceFileCacheTests.swift`：`testExistingDropsDebrisWhenTheSizeDisagrees` | `requirements`、`ios-dshkit`、`relay-go` |  |
| SR-08.03 | ✅ verified | `relay-go/internal/wsapi/wsapi_test.go`：`TestRevokedDeviceTokenCannotOpenASocket` | `requirements`、`relay-go` |  |
| SR-08.04 | ✅ verified | `relay-go/internal/hub/opacity_test.go`：`TestFramePayloadDoesNotEnterRelayLogs`<br>`scripts/dev/check-diagnostics.test.mjs`：`agent-secret`<br>`scripts/verify/check-relay-tls.mjs`：`plain` | `requirements`、`relay-go`、`scripts` |  |
| SR-08.05 | ✅ verified | `ios/DSHMobile/DSHMobileUITests/PerformanceBaselineTests.swift`：`testLongTextScrollHitches`<br>`test/performance/check-performance.mjs`：`p95` | `requirements`、`performance` |  |
| SR-08.06 | ✅ verified | `ios/DSHMobile/DSHMobileTests/SessionAlertsTests.swift`：`testTurnEndRequestCarriesSessionRouteAndIdentifier`<br>`relay-go/internal/wsapi/wsapi_test.go`：`TestANotifyFrameOverTheAgentSocketOnlyPushesTheOfflineDevice`<br>`scripts/verify/check-apns.mjs`：`push-test` | `requirements`、`ios-app-unit` |  |
