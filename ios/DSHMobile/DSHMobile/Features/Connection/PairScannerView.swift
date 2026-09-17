import DSHKit
import SwiftUI
import Vision
import VisionKit

/// Scanning the pairing QR the computer shows.
///
/// The camera half is deliberately small and platform-guarded: `DataScanner` is
/// unavailable in the simulator, so the view has to be honest about that rather
/// than present a black rectangle. The parse → pair half is the same code the
/// pasted-code field and the `dsh://pair?…` launch hook use, so the scanner is
/// never the only way in.
struct PairScannerView: View {
    /// Called with the payload a scanner read.
    let onPayload: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    CameraScanner { payload in
                        onPayload(payload)
                        dismiss()
                    } onFailure: { failure in
                        message = failure
                    }
                    .ignoresSafeArea(edges: .bottom)
                } else {
                    unavailable
                }
            }
            .navigationTitle("扫码配对")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    /// Shown when there is no usable camera — the simulator, or a device whose
    /// camera the user has not allowed.
    private var unavailable: some View {
        VStack(alignment: .leading, spacing: DSHTheme.Spacing.standard) {
            Label("这台设备无法使用取景器", systemImage: "camera.fill")
                .font(DSHTheme.Typography.bodyStrong)
                .foregroundStyle(DSHTheme.labelPrimary)

            Text(DataScannerViewController.isSupported
                 ? "相机不可用（可能是权限未开启，或相机正被其他 App 占用）。你仍然可以返回后手动输入配对码。"
                 : "模拟器没有相机。扫码取景只能在真机上使用；请返回后用配对码连接，或直接在电脑端打开配对页面。")
                .font(DSHTheme.Typography.caption)
                .foregroundStyle(DSHTheme.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let message {
                Text(message)
                    .font(DSHTheme.Typography.caption)
                    .foregroundStyle(DSHTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(DSHTheme.Spacing.loose)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSHTheme.background)
    }
}

/// The camera preview and its QR detection, wrapped for SwiftUI.
private struct CameraScanner: UIViewControllerRepresentable {
    let onPayload: (String) -> Void
    let onFailure: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        guard !controller.isScanning else { return }
        do {
            try controller.startScanning()
        } catch {
            onFailure("无法启动相机：\(error.localizedDescription)")
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onPayload: onPayload) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onPayload: (String) -> Void
        private var handled = false

        init(onPayload: @escaping (String) -> Void) {
            self.onPayload = onPayload
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            // One pairing attempt per presentation: a code that fails to claim
            // stays on screen while the camera keeps seeing it, and resubmitting
            // it in a loop would hammer the relay for no reason.
            guard !handled else { return }
            for item in addedItems {
                guard case .barcode(let barcode) = item,
                      let payload = barcode.payloadStringValue
                else { continue }
                handled = true
                onPayload(payload)
                return
            }
        }
    }
}

/// Decides what a scanned string means.
///
/// A QR could be one of the `dsh://` links the app understands, or it could be
/// a bare URL, or a pairing code someone printed next to a relay address. The
/// strict form wins; the loose forms are accepted because a hand-made label
/// should not be a dead end.
enum PairPayload {
    enum Parsed: Equatable {
        case link(ConnectLink)
        case code(String)
    }

    static func parse(_ raw: String) -> Parsed? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let url = URL(string: text), let link = ConnectLink(url: url) {
            return .link(link)
        }
        // A bare pairing code, with or without its dash.
        let code = text.uppercased()
        let compact = code.filter { $0.isLetter || $0.isNumber }
        if compact.count == 8, compact.allSatisfy({ $0.isNumber || ($0.isLetter && $0.isUppercase) }) {
            return .code("\(compact.prefix(4))-\(compact.suffix(4))")
        }
        return nil
    }
}
