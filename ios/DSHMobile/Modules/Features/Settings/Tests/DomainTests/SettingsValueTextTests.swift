import DSHKit
@testable import DSHSettingsDomain
import XCTest

/// The pure mappings in `SettingsModels.swift`: the one-line value a collapsed
/// row shows, and the label tables the settings screen reads.
///
/// Several expectations are the Chinese literal itself. That is not a locale
/// slip: these strings are localization keys, and neither `DSHSettingsDomain` nor
/// the test bundle ships a `Localizable.strings`, so `String(localized:)` returns
/// the key. The assertions that would change with the system language are phrased
/// around relations instead (a known key differs from its raw form, the two
/// `preference` labels differ) so they hold wherever the suite runs.
final class SettingsValueTextTests: XCTestCase {

    /// `summary(_:)`: scalars, the empty markers, and the point where a
    /// collection stops being listed and starts being counted.
    func test_summary_renders_scalars_and_collections() {
        let summary = SettingsValueText.summary

        XCTAssertEqual(summary(nil), "—", "a missing value and a null one look the same")
        XCTAssertEqual(summary(.null), "—")
        XCTAssertEqual(summary(.bool(true)), "开")
        XCTAssertEqual(summary(.bool(false)), "关")
        XCTAssertEqual(summary(.string("dark")), "dark",
                       "a raw string is shown as itself; naming an enum value is the detail row's job")
        XCTAssertEqual(summary(.string("")), "（空）")
        XCTAssertEqual(summary(.int(7)), "7")
        XCTAssertEqual(summary(.double(6.0)), "6")

        XCTAssertEqual(summary(.array([])), "（空列表）")
        XCTAssertEqual(summary(.array([.string("a"), .string("b")])), "a、b",
                       "up to three scalars are listed")
        XCTAssertEqual(summary(.array([.int(1), .int(2), .int(3)])), "1、2、3")
        XCTAssertEqual(summary(.array([.int(1), .int(2), .int(3), .int(4)])), "4 项",
                       "a longer list is counted instead of listed")
        XCTAssertEqual(summary(.array([.object([:]), .object([:])])), "2 项",
                       "a non-scalar list is counted even when it is short")

        XCTAssertEqual(summary(.object([:])), "（空对象）")
        XCTAssertEqual(summary(.object(["b": .int(2), "a": .int(1)])), "a、b",
                       "object keys are sorted, so the row does not reshuffle between reads")
        XCTAssertEqual(summary(.object(["d": .int(4), "c": .int(3), "b": .int(2), "a": .int(1)])),
                       "a、b、c …", "past three keys the rest is elided")
    }

    /// `numberText(_:)`: a whole number stays whole, a fraction keeps its digits,
    /// and a size gets grouped. `pretty(_:)` is the raw disclosure beside them.
    func test_number_text_and_pretty_print() throws {
        let number = SettingsValueText.numberText

        XCTAssertEqual(number(.int(42)), "42")
        XCTAssertEqual(number(.double(6.0)), "6",
                       "a whole number from the host must not grow a decimal tail on the row")
        XCTAssertNotEqual(number(.double(6.5)), "6")
        XCTAssertEqual(number(.double(6.5)).filter(\.isNumber), "65",
                       "a fraction keeps its digits")
        XCTAssertEqual(number(.string("none")), "\"none\"",
                       "a value with no number in it falls back to its raw form")

        let grouped = number(.int(1_000_000))
        XCTAssertEqual(grouped.filter(\.isNumber), "1000000")
        XCTAssertGreaterThan(grouped.count, 7, "a byte or token size is grouped for readability")

        let pretty = SettingsValueText.pretty(.object(["b": .string("/tmp/a"), "a": .int(1)]))
        XCTAssertTrue(pretty.contains("\n"), "a raw disclosure is pretty-printed")
        let a = try XCTUnwrap(pretty.range(of: "\"a\""))
        let b = try XCTUnwrap(pretty.range(of: "\"b\""))
        XCTAssertLessThan(a.lowerBound, b.lowerBound, "keys come out sorted")
        XCTAssertFalse(pretty.contains("\\/"), "a path stays readable instead of being escaped")
    }

    /// `SettingsLabels`: an unknown key falls back to itself, a known one does not,
    /// and the scan order puts the primary choices first.
    func test_labels_fall_back_to_the_raw_key_and_rank_fields_for_scanning() {
        XCTAssertEqual(SettingsLabels.namespaceTitle("no-such-namespace"), "no-such-namespace")
        let title = SettingsLabels.namespaceTitle("ui-theme")
        XCTAssertFalse(title.isEmpty)
        XCTAssertNotEqual(title, "ui-theme", "a namespace the desktop client names is translated")

        XCTAssertEqual(SettingsLabels.valueLabel(.string("no-such-value"), fallback: "—"),
                       "no-such-value")
        XCTAssertEqual(SettingsLabels.valueLabel(.int(1), fallback: "—"), "—",
                       "only a string has a value label to look up")
        XCTAssertNotEqual(SettingsLabels.valueLabel(.string("dark"), fallback: "—"), "dark")

        XCTAssertEqual(SettingsLabels.fieldLabel("no-such-field", namespace: "x",
                                                 path: ["no-such-field"]),
                       "no-such-field")
        XCTAssertNotEqual(
            SettingsLabels.fieldLabel("preference", namespace: "ui-theme", path: ["preference"]),
            SettingsLabels.fieldLabel("preference", namespace: "locale", path: ["preference"]),
            "the same field name means different things in two namespaces"
        )

        XCTAssertLessThan(SettingsLabels.sortRank("enabled"), SettingsLabels.sortRank("provider"))
        XCTAssertLessThan(SettingsLabels.sortRank("provider"), SettingsLabels.sortRank("model"))
        XCTAssertLessThan(SettingsLabels.sortRank("model"), SettingsLabels.sortRank("maxTokens"))
        XCTAssertEqual(SettingsLabels.sortRank("no-such-field"), 100,
                       "everything unlisted lands in the same trailing group")

        XCTAssertNil(SettingsLabels.patternHint([:]), "no pattern in the schema, no hint on the row")
        XCTAssertNotNil(SettingsLabels.patternHint(["pattern": .string("^[a-z]+$")]))
    }
}
