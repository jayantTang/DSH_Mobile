#if os(macOS)
import Foundation
import XCTest
@testable import DSHFoundation

/// 钥匙串的并发写：写进去的值必须还能原样读出来（不丢、不串、不半截）。
///
/// 只在 macOS 上跑：裸 xctest 包在 iOS 仿真器上没有钥匙串 entitlement（-34018），
/// 与 `FoundationSmokeTests` 同一口径。
///
/// 所有账号都用 `dsh-unit-test.` 前缀（真实账号不会这么叫），收尾必删。
/// 断言消息一律 ASCII：check:i18n 扫整棵 Modules 树。
@MainActor
final class KeychainConcurrencyTests: XCTestCase {

    private var accounts: [String] = []
    private let run: String = String(UUID().uuidString.prefix(8))

    override func tearDown() {
        for account in accounts { Keychain.remove(account) }
        accounts = []
        super.tearDown()
    }

    /// 一个本次运行专用的账号，用前先清干净（上一次中断的残留）。
    private func makeAccount(_ label: String) -> String {
        let account = "dsh-unit-test.concurrency.\(run).\(label)"
        accounts.append(account)
        Keychain.remove(account)
        return account
    }

    func test_consecutive_writes_to_one_account_keep_the_last_value() throws {
        let account = makeAccount("same-account")

        for index in 0..<50 {
            try Keychain.set("value-\(index)", for: account)
        }

        XCTAssertEqual(Keychain.get(account), "value-49",
                       "after a run of writes the last one is the value that reads back")
    }

    func test_concurrent_writes_to_distinct_accounts_keep_every_value() async {
        let pairs = (0..<24).map { index in
            (account: makeAccount("distinct-\(index)"), value: "value-\(index)")
        }

        let failures = await withTaskGroup(of: String?.self) { group -> [String] in
            for pair in pairs {
                group.addTask {
                    do {
                        try Keychain.set(pair.value, for: pair.account)
                        return nil
                    } catch {
                        return "\(pair.account): \(error)"
                    }
                }
            }
            var collected: [String] = []
            for await failure in group { if let failure { collected.append(failure) } }
            return collected
        }

        XCTAssertEqual(failures, [], "every concurrent write to its own account must succeed")
        for pair in pairs {
            XCTAssertEqual(Keychain.get(pair.account), pair.value,
                           "account \(pair.account) must keep the value written to it")
        }
    }

    /// 同一账号上的写风暴。`Keychain.set` 是"先 update、没有就 add"两步，两个任务同时
    /// 走了 add 就会撞上 `errSecDuplicateItem`（-25299）——那条写不是丢了，是被后写的
    /// 顶掉了，所以这里只断言**最后一定有一个可读的、确实是写进去过的值**，
    /// 不去断言每个任务都必须成功（那会变成一条 flaky 用例）。
    func test_a_write_storm_on_one_account_leaves_one_of_the_written_values() async {
        let account = makeAccount("storm")
        let written = (0..<24).map { "storm-\($0)" }

        await withTaskGroup(of: Void.self) { group in
            for value in written {
                group.addTask { try? Keychain.set(value, for: account) }
            }
        }

        let stored = Keychain.get(account)
        XCTAssertNotNil(stored, "a storm of writes must still leave a readable value")
        XCTAssertTrue(written.contains(stored ?? ""),
                      "the stored value must be one of the written ones, got \(stored ?? "nil")")
    }
}
#endif
