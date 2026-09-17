import DSHKit
import PhotosUI
import UniformTypeIdentifiers
import SwiftUI

// MARK: - Composer

/// The message composer: text, send/steer, stop, and `@` file references.
struct Composer: View {
    @Environment(ConnectionStore.self) private var store
    @Bindable var model: ChatModel
    /// Owned by the transcript, which re-pins its scroll position when the
    /// keyboard resizes the viewport.
    var isFocused: FocusState<Bool>.Binding

    @State private var suggestions: [FileReferenceCandidate] = []
    @State private var mentionQuery: String?
    @State private var suggestionTask: Task<Void, Never>?

    private var canSend: Bool {
        // A picture on its own is a complete prompt.
        !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !model.draftImages.isEmpty
    }

    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var isPickingPhotos = false
    @State private var isPickingFiles = false
    /// A file the Host cannot accept, reported rather than silently dropped.
    @State private var unsupportedFile: String?

    var body: some View {
        VStack(spacing: 0) {
            if !model.draftImages.isEmpty {
                draftStrip
                Hairline()
            }
            if !suggestions.isEmpty {
                suggestionList
                Hairline()
            }
            HStack(alignment: .bottom, spacing: DSHTheme.Spacing.tight) {
                field
                controls
            }
            .padding(.horizontal, DSHTheme.Spacing.tight)
            .padding(.vertical, DSHTheme.Spacing.tight)
        }
        .background(DSHTheme.layer1)
        .onChange(of: model.draft) { detectMention() }
        .onChange(of: pickedPhotos) { _, items in
            guard !items.isEmpty else { return }
            Task { await load(items) }
        }
        // Only images can travel: a picture reaches a session as an inline
        // prompt image, and the Host has no upload endpoint for anything else.
        .fileImporter(
            isPresented: $isPickingFiles,
            // Anything, not just images: a non-image is staged on the computer
            // by the link and named in the prompt, so the agent can read it.
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { await load(urls) }
            case .failure(let error):
                unsupportedFile = error.localizedDescription
            }
        }
        .alert("这个文件发不了", isPresented: .constant(unsupportedFile != nil)) {
            Button("好") { unsupportedFile = nil }
        } message: {
            Text("DSH 目前只接受图片附件（Host 没有其它文件的上传通道）。\n\(unsupportedFile ?? "")")
        }
    }

    /// The pictures queued for the next prompt, each removable.
    private var draftStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DSHTheme.Spacing.tight) {
                ForEach(model.draftImages) { image in
                    Image(uiImage: image.preview)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.small, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            Button {
                                model.removeDraftImage(id: image.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.white, DSHTheme.labelPrimary.opacity(0.7))
                            }
                            .padding(2)
                            .accessibilityIdentifier("composer.photo.remove")
                            .accessibilityLabel("移除这张图片")
                        }
                }
            }
            .padding(.horizontal, DSHTheme.Spacing.tight)
            .padding(.vertical, DSHTheme.Spacing.tight)
        }
        .accessibilityIdentifier("composer.photo.strip")
    }

    /// Reads the picked items into memory for the next prompt.
    private func load(_ items: [PhotosPickerItem]) async {
        var images: [UIImage] = []
        var names: [String] = []
        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data)
            else { continue }
            images.append(image)
            names.append("photo-\(index + 1).jpg")
        }
        model.addDraftImages(images, names: names)
        pickedPhotos = []
    }

    /// Reads files chosen from the Files app.
    ///
    /// Pictures ride the prompt as inline images — the Host keeps them as
    /// durable attachments. Everything else is uploaded to the computer and
    /// named in the prompt, because the Host cannot receive file bytes at all.
    private func load(_ urls: [URL]) async {
        var images: [UIImage] = []
        var names: [String] = []
        for url in urls {
            // Files outside the sandbox need an explicit scope.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                unsupportedFile = url.lastPathComponent
                continue
            }
            if let image = UIImage(data: data) {
                images.append(image)
                names.append(url.lastPathComponent)
            } else {
                await model.sendFile(named: url.lastPathComponent, data: data)
            }
        }
        model.addDraftImages(images, names: names)
    }

    private var field: some View {
        TextField(placeholder, text: $model.draft, axis: .vertical)
        .font(DSHTheme.Typography.body)
        .textFieldStyle(.plain)
        .lineLimit(1...8)
        .focused(isFocused)
        .accessibilityIdentifier("composer.field")
        .padding(.horizontal, DSHTheme.Spacing.standard)
        .padding(.vertical, DSHTheme.Spacing.tight)
        .background(DSHTheme.layer2)
        .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DSHTheme.Radius.panel, style: .continuous)
                .stroke(DSHTheme.border2, lineWidth: 1)
        )
        .onSubmit { submit() }
    }

    /// Deliberately constant.
    ///
    /// A `TextField(axis: .vertical)` whose placeholder changes while the field
    /// is focused redraws unreliably — it can come back blank. The activity is
    /// already shown in the transcript and in the control cluster, so the
    /// placeholder has no reason to move.
    private let placeholder = "给 DSH 发消息…"

    private var controls: some View {
        HStack(spacing: DSHTheme.Spacing.hairline) {
            if let uploading = model.isUploadingFile {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 34, height: 34)
                    .accessibilityIdentifier("composer.uploading")
                    .accessibilityLabel("正在上传 \(uploading)")
            }

            if model.activity == .submitting {
                // Nothing to stop yet: the host has not started a turn.
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 34, height: 34)
                    .accessibilityLabel("已发送，等待开始")
            }

            // Queue-or-steer is a separate decision from send-or-stop, so it
            // stays its own control: one button carrying both would have to
            // guess which the user meant.
            if model.isRunning {
                Button {
                    model.steerNext.toggle()
                } label: {
                    Image(systemName: model.steerNext ? "arrow.turn.right.down" : "text.append")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(model.steerNext ? DSHTheme.brand : DSHTheme.labelSecondary)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(DSHTheme.layer2))
                        .overlay(Circle().stroke(DSHTheme.border2, lineWidth: 1))
                }
                .accessibilityIdentifier("composer.steer")
                .accessibilityLabel(model.steerNext ? "切换为排队" : "切换为插入当前轮次")
            }

            attachControl
            primaryControl
        }
        .padding(.bottom, 2)
    }

    /// One entry point for attachments, with the two sources inside it.
    ///
    /// A clip and a photo icon side by side read as two unrelated features and
    /// took a third of the row; the difference is only where the file comes
    /// from, which is a choice worth making after the tap, not before.
    private var attachControl: some View {
        Menu {
            // The picker is presented as a value rather than by a button inside
            // the menu: a `PhotosPicker` needs to own its selection binding, so
            // it is bound here and opened by setting the state below.
            Button {
                isPickingPhotos = true
            } label: {
                Label("照片图库", systemImage: "photo.on.rectangle")
            }
            // Hidden when the connector cannot stage files: offering it would
            // produce a call the Host answers with 404, which reads as a bug
            // rather than as "this computer's connector is older".
            if store.supports(LinkHandshake.Capability.fileTransfer) {
                Button {
                    isPickingFiles = true
                } label: {
                    Label("文件", systemImage: "folder")
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(DSHTheme.labelSecondary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(DSHTheme.layer2))
                .overlay(Circle().stroke(DSHTheme.border2, lineWidth: 1))
        }
        .accessibilityIdentifier("composer.attach")
        .accessibilityLabel("添加图片或文件")
        .photosPicker(
            isPresented: $isPickingPhotos,
            selection: $pickedPhotos,
            maxSelectionCount: 8,
            matching: .images,
            photoLibrary: .shared()
        )
    }

    /// The right-hand button: send, queue, or stop, depending on the run.
    ///
    /// Stop lives here rather than beside it because it is the same decision —
    /// "act on the current run" — and a row of four controls made the common
    /// case (typing) feel crowded. What the button does is what it looks like:
    ///
    ///   idle, nothing to send   → inert arrow
    ///   idle, text or a picture → send
    ///   running, empty field    → stop
    ///   running, text typed     → send that queues or steers, marked as such
    private var primaryControl: some View {
        Button(action: primaryAction) {
            Image(systemName: primarySymbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(primaryForeground)
                .frame(width: 34, height: 34)
                .background(Circle().fill(primaryBackground))
        }
        .disabled(!primaryEnabled)
        .accessibilityIdentifier(model.isRunning && !canSend ? "composer.stop" : "composer.send")
        .accessibilityLabel(primaryLabel)
    }

    private var primaryAction: () -> Void {
        if model.isRunning && !canSend {
            return { Task { await model.cancel() } }
        }
        return submit
    }

    private var primarySymbol: String {
        if model.isRunning && !canSend { return "stop.fill" }
        // While a turn is open the message does not just go: it queues behind
        // the run or interrupts it, and the glyph says which.
        if model.isRunning { return model.steerNext ? "arrow.turn.right.down" : "text.append" }
        return "arrow.up"
    }

    private var primaryForeground: Color {
        if model.isRunning && !canSend { return .white }
        if canSend { return .white }
        return DSHTheme.labelDimmed
    }

    private var primaryBackground: Color {
        if model.isRunning && !canSend { return DSHTheme.danger }
        if canSend { return DSHTheme.brand }
        return DSHTheme.layer3
    }

    private var primaryEnabled: Bool {
        (model.isRunning && !canSend) || canSend
    }

    private var primaryLabel: String {
        if model.isRunning && !canSend { return "停止" }
        if model.isRunning { return model.steerNext ? "插入当前轮次" : "排队发送" }
        return "发送"
    }

    private func submit() {
        guard canSend else { return }
        suggestionTask?.cancel()
        suggestions = []
        mentionQuery = nil
        // Keep the keyboard up: sending a message is usually the start of the
        // next one, and a dismissed keyboard reads as the field having gone
        // away. Focus is set after the clear so the field does not collapse.
        isFocused.wrappedValue = true
        Task {
            await model.send()
            isFocused.wrappedValue = true
        }
    }

    // MARK: @ references

    private var suggestionList: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DSHTheme.Spacing.hairline) {
                ForEach(suggestions.prefix(12)) { candidate in
                    Button {
                        insert(candidate)
                    } label: {
                        HStack(spacing: DSHTheme.Spacing.hairline) {
                            Image(systemName: candidate.isDirectory ? "folder" : "doc")
                                .font(.system(size: 10))
                            Text(candidate.path)
                                .font(DSHTheme.Typography.micro)
                                .lineLimit(1)
                        }
                        .foregroundStyle(DSHTheme.labelPrimary)
                        .padding(.horizontal, DSHTheme.Spacing.tight)
                        .padding(.vertical, 5)
                        .background(DSHTheme.layer2)
                        .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.small, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DSHTheme.Spacing.tight)
            .padding(.vertical, DSHTheme.Spacing.hairline)
        }
    }

    /// Detects a trailing `@token` and refreshes suggestions for it.
    private func detectMention() {
        guard let token = Self.trailingMention(in: model.draft) else {
            mentionQuery = nil
            suggestions = []
            suggestionTask?.cancel()
            return
        }
        guard token != mentionQuery else { return }
        mentionQuery = token

        suggestionTask?.cancel()
        suggestionTask = Task {
            // Debounced: typing produces a query per keystroke.
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let results = await model.fileReferences(query: token)
            guard !Task.isCancelled else { return }
            suggestions = results
        }
    }

    private func insert(_ candidate: FileReferenceCandidate) {
        guard let range = model.draft.range(of: "@" + (mentionQuery ?? ""), options: .backwards) else { return }
        model.draft.replaceSubrange(range, with: candidate.path + " ")
        suggestions = []
        mentionQuery = nil
    }

    /// The `@`-prefixed token at the end of the draft, if any.
    static func trailingMention(in text: String) -> String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        let token = text[text.index(after: at)...]
        guard !token.contains(" "), !token.contains("\n") else { return nil }
        // Only treat it as a mention when it starts a word.
        if at > text.startIndex {
            let previous = text[text.index(before: at)]
            guard previous.isWhitespace || previous.isNewline else { return nil }
        }
        return String(token)
    }
}

// MARK: - Model picker

/// Model and reasoning-effort selection for the current session.
struct ModelPickerSheet: View {
    @Bindable var model: ChatModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let catalog = model.catalog {
                    ForEach(catalog.groups ?? []) { group in
                        Section(group.name ?? group.id) {
                            ForEach(group.models ?? []) { descriptor in
                                row(group: group, descriptor: descriptor)
                            }
                        }
                    }
                    if let failures = catalog.failures, !failures.isEmpty {
                        Section("不可用的提供方") {
                            ForEach(Array(failures.enumerated()), id: \.offset) { _, failure in
                                Text(failure.message ?? failure.provider ?? "未知错误")
                                    .font(DSHTheme.Typography.caption)
                                    .foregroundStyle(DSHTheme.labelTertiary)
                            }
                        }
                    }
                } else {
                    ProgressView().controlSize(.small)
                }

                if !model.permissionOptions.isEmpty {
                    Section("权限预设") {
                        ForEach(model.permissionOptions, id: \.value) { option in
                            HStack {
                                Text(option.name)
                                    .font(DSHTheme.Typography.body)
                                Spacer()
                                if option.value == model.currentPermission {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(DSHTheme.brand)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { model.setPermissionLocally(option.value) }
                        }
                        Text("权限预设由电脑端 session 决定，此处仅显示当前值。")
                            .font(DSHTheme.Typography.micro)
                            .foregroundStyle(DSHTheme.labelTertiary)
                    }
                }
            }
            .navigationTitle("模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func row(group: ModelProviderGroup, descriptor: ModelDescriptor) -> some View {
        let efforts = descriptor.reasoning?.efforts ?? []
        VStack(alignment: .leading, spacing: DSHTheme.Spacing.hairline) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(descriptor.displayName)
                        .font(DSHTheme.Typography.bodyStrong)
                    Text(group.name ?? group.id)
                        .font(DSHTheme.Typography.micro)
                        .foregroundStyle(DSHTheme.labelTertiary)
                }
                Spacer()
                if model.currentSelection?.model == descriptor.id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(DSHTheme.brand)
                }
            }
            if !efforts.isEmpty {
                HStack(spacing: DSHTheme.Spacing.hairline) {
                    ForEach(efforts) { effort in
                        Button {
                            Task {
                                await model.selectModel(
                                    ModelSelection(
                                        provider: group.id,
                                        model: descriptor.id,
                                        reasoningEffort: effort.id
                                    )
                                )
                            }
                        } label: {
                            Text(effort.name ?? effort.id)
                                .font(DSHTheme.Typography.micro)
                                .foregroundStyle(
                                    model.currentSelection?.model == descriptor.id
                                        && model.currentSelection?.reasoningEffort == effort.id
                                        ? DSHTheme.brand
                                        : DSHTheme.labelSecondary
                                )
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(DSHTheme.layer2)
                                .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.small, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            Task {
                await model.selectModel(
                    ModelSelection(
                        provider: group.id,
                        model: descriptor.id,
                        reasoningEffort: descriptor.reasoning?.efforts?.first?.id
                    )
                )
            }
        }
    }
}

// MARK: - Question prompt

/// Renders a `user-questions/request` waterfall as a native question sheet.
struct UserQuestionSheet: View {
    let prompt: HostEventHub.Pending
    let questions: UserQuestionsRequest
    let model: ChatModel

    @Environment(\.dismiss) private var dismiss
    @State private var selections: [String: Set<String>] = [:]
    @State private var customs: [String: String] = [:]
    @State private var isSubmitting = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DSHTheme.Spacing.section) {
                    ForEach(questions.questions) { question in
                        VStack(alignment: .leading, spacing: DSHTheme.Spacing.tight) {
                            if let header = question.header {
                                Text(header)
                                    .font(DSHTheme.Typography.micro)
                                    .foregroundStyle(DSHTheme.brand)
                                    .textCase(.uppercase)
                            }
                            Text(question.question)
                                .font(DSHTheme.Typography.bodyStrong)
                                .foregroundStyle(DSHTheme.labelPrimary)
                                .fixedSize(horizontal: false, vertical: true)

                            if let detail = question.detail {
                                Text(detail)
                                    .font(DSHTheme.Typography.caption)
                                    .foregroundStyle(DSHTheme.labelSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            ForEach(question.options ?? []) { option in
                                optionRow(question: question, option: option)
                            }

                            customAnswerField(question: question)
                        }
                    }

                    if let error {
                        Text(error)
                            .font(DSHTheme.Typography.caption)
                            .foregroundStyle(DSHTheme.danger)
                    }
                }
                .padding(DSHTheme.Spacing.loose)
            }
            .background(DSHTheme.background)
            .navigationTitle(prompt.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("让电脑处理") {
                        Task {
                            await model.pass(prompt)
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isSubmitting { ProgressView().controlSize(.mini) } else { Text("提交") }
                    }
                    .disabled(isSubmitting || !isAnswerable)
                }
            }
        }
    }

    /// The free-text answer, under every question — options or not.
    ///
    /// The desktop composer has this row for a reason: an option list is a menu,
    /// not the whole answer space, and the host's own tool takes an "Other"
    /// answer for any question. The phone used to show the field *only* when a
    /// question had no options, i.e. exactly never in the case where the user
    /// most often has something to add.
    ///
    /// With options it is a row (icon + inline field) that reads as one more
    /// choice; without them it is the block field the question is answered in.
    @ViewBuilder
    private func customAnswerField(question: UserQuestionsRequest.Question) -> some View {
        let hasOptions = !(question.options ?? []).isEmpty
        let text = customBinding(for: question.id)
        let typed = !(customs[question.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty

        if hasOptions {
            HStack(alignment: .top, spacing: DSHTheme.Spacing.tight) {
                Image(systemName: question.allowsMultiple
                      ? (typed ? "checkmark.square.fill" : "square")
                      : "square.and.pencil")
                    .font(.system(size: 15))
                    .foregroundStyle(typed ? DSHTheme.brand : DSHTheme.labelDimmed)
                TextField("输入你的答案", text: text, axis: .vertical)
                    .font(DSHTheme.Typography.body)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .submitLabel(.done)
                    .onSubmit { submitIfAnswerable() }
                    .accessibilityIdentifier("question.custom.\(question.id)")
                Spacer(minLength: 0)
            }
            .padding(DSHTheme.Spacing.tight)
            .background(
                RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous)
                    .fill(typed ? DSHTheme.brandSubtle : DSHTheme.layer1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous)
                    .stroke(typed ? DSHTheme.brand.opacity(0.5) : DSHTheme.border1, lineWidth: 1)
            )
        } else {
            TextField("输入你的答案", text: text, axis: .vertical)
                .font(DSHTheme.Typography.body)
                .textFieldStyle(.plain)
                .lineLimit(2...6)
                .padding(DSHTheme.Spacing.tight)
                .background(DSHTheme.layer2)
                .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous))
                .accessibilityIdentifier("question.custom.\(question.id)")
        }
    }

    /// Enter in the answer field submits, the way the desktop composer does.
    private func submitIfAnswerable() {
        guard isAnswerable, !isSubmitting else { return }
        Task { await submit() }
    }

    @ViewBuilder
    private func optionRow(question: UserQuestionsRequest.Question, option: UserQuestionsRequest.Option) -> some View {        let isSelected = selections[question.id]?.contains(option.label) ?? false
        Button {
            toggle(question: question, label: option.label)
        } label: {
            HStack(alignment: .top, spacing: DSHTheme.Spacing.tight) {
                Image(systemName: symbol(for: question, selected: isSelected))
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? DSHTheme.brand : DSHTheme.labelDimmed)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(DSHTheme.Typography.body)
                        .foregroundStyle(DSHTheme.labelPrimary)
                        .multilineTextAlignment(.leading)
                    if let description = option.description {
                        Text(description)
                            .font(DSHTheme.Typography.caption)
                            .foregroundStyle(DSHTheme.labelSecondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(DSHTheme.Spacing.tight)
            .background(
                RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous)
                    .fill(isSelected ? DSHTheme.brandSubtle : DSHTheme.layer1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous)
                    .stroke(isSelected ? DSHTheme.brand.opacity(0.5) : DSHTheme.border1, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func symbol(for question: UserQuestionsRequest.Question, selected: Bool) -> String {
        if question.allowsMultiple {
            return selected ? "checkmark.square.fill" : "square"
        }
        return selected ? "largecircle.fill.circle" : "circle"
    }

    private func toggle(question: UserQuestionsRequest.Question, label: String) {
        var current = selections[question.id] ?? []
        if question.allowsMultiple {
            if current.contains(label) { current.remove(label) } else { current.insert(label) }
        } else {
            // A single-select choice replaces the typed answer, exactly as the
            // desktop composer clears its custom field when an option is chosen.
            current = current.contains(label) ? [] : [label]
            customs[question.id] = ""
        }
        selections[question.id] = current
    }

    private func customBinding(for id: String) -> Binding<String> {
        Binding(
            get: { customs[id] ?? "" },
            set: { typed in
                customs[id] = typed
                // Typing an answer clears a single-select tick: the two are one
                // choice, and sending both would answer the question twice.
                if !typed.trimmingCharacters(in: .whitespaces).isEmpty,
                   let question = questions.questions.first(where: { $0.id == id }),
                   !question.allowsMultiple {
                    selections[id] = []
                }
            }
        )
    }

    private var isAnswerable: Bool {
        questions.questions.contains { question in
            !(selections[question.id]?.isEmpty ?? true)
                || !(customs[question.id]?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
        }
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }

        // The encoding lives in DSHKit so it can be tested against the shapes the
        // desktop sends; the sheet only says what the user left on screen.
        let drafts = questions.questions.map { question in
            UserQuestionDraft(
                id: question.id,
                selected: Array(selections[question.id] ?? []),
                custom: customs[question.id] ?? "",
                allowsMultiple: question.allowsMultiple
            )
        }
        await model.answer(prompt, answers: UserQuestionsAnswer(drafts: drafts))
        if let failure = model.lastError {
            error = failure
        } else {
            dismiss()
        }
    }
}

/// Fallback sheet for prompt kinds without a bespoke UI.
struct GenericPromptSheet: View {
    let prompt: HostEventHub.Pending
    let model: ChatModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DSHTheme.Spacing.standard) {
                    Text("电脑端正在等待回应。这类请求目前需要在电脑端处理，或直接继续该轮次。")
                        .font(DSHTheme.Typography.caption)
                        .foregroundStyle(DSHTheme.labelSecondary)
                    Text(prompt.request.compactDescription)
                        .font(DSHTheme.Typography.code)
                        .foregroundStyle(DSHTheme.labelPrimary)
                        .textSelection(.enabled)
                        .padding(DSHTheme.Spacing.tight)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(DSHTheme.codeBackground)
                        .clipShape(RoundedRectangle(cornerRadius: DSHTheme.Radius.medium, style: .continuous))
                }
                .padding(DSHTheme.Spacing.loose)
            }
            .background(DSHTheme.background)
            .navigationTitle(prompt.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("继续等待") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("放行") {
                        Task {
                            try? await model.answer(prompt, answers: UserQuestionsAnswer(answers: []))
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}
