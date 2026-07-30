import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

public struct ChatView: View {
    @ObservedObject private var viewModel: ChatViewModel
    private let onOpenProviderSettings: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.calendar) private var calendar
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    @ScaledMetric(relativeTo: .body) private var scaledListInset = 16
    @ScaledMetric(relativeTo: .caption) private var scaledParticipantAvatarSize =
        ChatParticipantLayout.baseAvatarSize
    @ScaledMetric(relativeTo: .body) private var scaledStoryContentInset =
        LorepiaSpacing.standard

    @State private var followsLatest = true
    @State private var isNearBottom = true
    @State private var lastBottomObservation: ChatBottomObservation?
    @State private var isRoomSettingsPresented = false
    @State private var inlineEditSession: ChatInlineEditSession?
    @State private var deletingMessage: ChatMessage?
    @State private var copiedMessageID: String?
    @State private var revealedActionsMessageID: String?
    @State private var revealedAt: Date?
    @State private var copyFeedback = 0
    @State private var composerEditorHeight: CGFloat = 0
    @State private var fullscreenComposerEditorHeight: CGFloat = 0
    @State private var composerExceedsExpansionLineLimit = false
    @State private var fullscreenComposerExceedsExpansionLineLimit = false
    @State private var isComposerExpanded = false
    @State private var composerAutomaticFocusID: UUID?
    @State private var fullscreenComposerAutomaticFocusID: UUID?
    /// Restored history is not newly arrived mail. Until the first transcript
    /// of a conversation has landed, messages appear in place instead of
    /// animating in, so opening a room never looks like it is rearranging.
    @State private var hasSettledInitialLoad = false
    @State private var initialLoadSettleGeneration: UInt = 0
    @State private var isSearchActive = false
    @State private var dayPickerAnchor: ChatDayPickerAnchor?
    @State private var floatingDayLabel: String?
    @State private var floatingDay: Date?
    @State private var dayMarkers: [ChatDayMarker] = []
    @State private var isTranscriptMovementActive = false
    @State private var isTranscriptScrolling = false
    @State private var scrollIdleGeneration: UInt = 0
    @State private var searchQuery = ""
    @State private var activeMatchID: String?
    @State private var pendingScrollTargetID: String?
    @FocusState private var isComposerFocused: Bool
    @FocusState private var isFullscreenComposerFocused: Bool

    public init(
        viewModel: ChatViewModel,
        onOpenProviderSettings: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.onOpenProviderSettings = onOpenProviderSettings
    }

    public var body: some View {
        ZStack {
            GeometryReader { geometry in
                Group {
                    if viewModel.character != nil {
                        messageList
                    } else if viewModel.isLoading {
                        ProgressView("대화를 준비하는 중")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView {
                            Label(
                                "대화를 선택하세요",
                                systemImage: "bubble.left.and.bubble.right"
                            )
                        } description: {
                            Text("채팅에서 캐릭터를 선택하면 저장된 대화를 이어갈 수 있습니다.")
                        }
                    }
                }
                .background {
                    ChatSurface.background.ignoresSafeArea()
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    // Searching borrows the keyboard, so the composer steps
                    // aside rather than competing for it, and the match
                    // navigator takes the same place the way a find bar does.
                    if !isSearchActive,
                       viewModel.character != nil,
                       !isComposerFullscreenPresented
                    {
                        composer(
                            restingSafeAreaInset:
                                geometry.safeAreaInsets.bottom
                        )
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if isSearchActive {
                        chatSearchNavigator
                    }
                }
                .chatConversationSearch(
                    text: $searchQuery,
                    isPresented: $isSearchActive,
                    isAvailable: viewModel.conversation != nil
                )
                .onChange(of: isSearchActive) { _, active in
                    if !active {
                        searchQuery = ""
                        activeMatchID = nil
                    }
                }
                .toolbar {
#if os(macOS)
                    if let character = viewModel.character {
                        ToolbarItem(placement: .principal) {
                            ChatToolbarIdentity(
                                character: character,
                                branch: branchSummary,
                                isEnabled: viewModel.conversation != nil
                            ) {
                                isRoomSettingsPresented = true
                            }
                        }
                    }

                    if viewModel.conversation != nil {
                        ToolbarItem(placement: .primaryAction) {
                            ChatRoomSettingsTrigger(
                                mode: viewModel.mode,
                                style: .toolbar,
                                isEnabled: viewModel.conversation != nil
                            ) {
                                isRoomSettingsPresented = true
                            }
                        }
                    }
#else
                    if viewModel.conversation != nil {
#if compiler(>=6.2)
                        if #available(iOS 26.0, *) {
                            DefaultToolbarItem(
                                kind: .search,
                                placement: .topBarTrailing
                            )
                        } else {
                            ToolbarItem(placement: .topBarTrailing) {
                                chatToolbarSearchFallback
                            }
                        }
#else
                        ToolbarItem(placement: .topBarTrailing) {
                            chatToolbarSearchFallback
                        }
#endif
                    }
#endif
                }
                .chatRoomTitle(name: viewModel.character?.name)
                .sheet(isPresented: $isRoomSettingsPresented) {
                    ChatRoomSettingsSheet(
                        mode: viewModel.mode,
                        branches: viewModel.branchOptions,
                        selectedBranchID: viewModel.activeBranchID,
                        isEnabled: viewModel.canManageBranches,
                        errorMessage: viewModel.errorMessage
                    ) { mode in
                        Task {
                            await viewModel.setMode(mode)
                        }
                    } onSelectBranch: { branchID in
                        Task {
                            await viewModel.selectBranch(id: branchID)
                        }
                    }
                }
                .sheet(item: $dayPickerAnchor) { anchor in
                    ChatDayPickerSheet(
                        availableDays: ChatTimeline.messageDays(
                            in: viewModel.messages,
                            calendar: timelineCalendar
                        ),
                        selectedDay: anchor.day,
                        calendar: timelineCalendar,
                        locale: locale
                    ) { day in
                        jumpToDay(day)
                    }
                }
                .confirmationDialog(
                    "이 메시지부터 삭제할까요?",
                    isPresented: Binding(
                        get: { deletingMessage != nil },
                        set: { isPresented in
                            if !isPresented {
                                deletingMessage = nil
                            }
                        }
                    ),
                    presenting: deletingMessage
                ) { message in
                    Button("현재 흐름에서 삭제", role: .destructive) {
                        Task {
                            await viewModel.removeMessage(
                                messageID: message.id
                            )
                        }
                        deletingMessage = nil
                    }
                    Button("취소", role: .cancel) {
                        deletingMessage = nil
                    }
                } message: { _ in
                    Text("이 메시지와 이후 대화를 현재 흐름에서 제거합니다. 다른 분기에는 영향이 없습니다.")
                }
                .chatDetailPlatformChrome()
                .chatCopyFeedback(trigger: copyFeedback)
                .task {
                    await viewModel.resumeEventPolling()
                    await viewModel.refreshProviderSelection()
                }
                .onChange(of: viewModel.conversation?.id) { _, _ in
                    discardInlineEdit()
                    resetComposerExpansion()
                }
                .onChange(of: viewModel.activeBranchID) { _, _ in
                    discardInlineEdit()
                }
                .onChange(of: viewModel.draft) { _, draft in
                    if draft.isEmpty, !isComposerFullscreenPresented {
                        resetComposerExpansion()
                    }
                }
                .onDisappear {
#if os(iOS)
                    guard !isComposerFullscreenPresented else {
                        return
                    }
#endif
                    initialLoadSettleGeneration &+= 1
                    isComposerFocused = false
                    discardInlineEdit()
                    viewModel.pauseEventPolling()
                }
#if os(iOS)
                .allowsHitTesting(!isComposerFullscreenPresented)
                .accessibilityHidden(isComposerFullscreenPresented)
#endif
            }

#if os(iOS)
            if isComposerFullscreenPresented {
                fullscreenComposer
                    .transition(.identity)
                    .zIndex(1)
            }
#endif
        }
#if os(iOS)
        .toolbar(
            isComposerFullscreenPresented ? .hidden : .visible,
            for: .navigationBar
        )
#endif
    }

    private var messageList: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    ZStack {
                        Color.clear
                            .frame(
                                maxWidth: .infinity,
                                minHeight: geometry.size.height
                            )
                            .accessibilityHidden(true)

                        LazyVStack(alignment: .leading, spacing: 0) {
                        conversationState

                        ForEach(
                            Array(viewModel.messages.enumerated()),
                            id: \.element.id
                        ) { index, message in
                            let previous = messageBefore(index)
                            let needsSeparator =
                                ChatTimeline.needsDateSeparator(
                                    before: message,
                                    after: previous,
                                    calendar: timelineCalendar
                                )
                            let joinsPrevious = ChatTimeline.canGroup(
                                previous: previous,
                                current: message,
                                calendar: timelineCalendar
                            )

                            if
                                needsSeparator,
                                let separatorText = ChatTimeline.separatorText(
                                    for: message,
                                    calendar: timelineCalendar,
                                    locale: locale
                                ),
                                let accessibilityText =
                                    ChatTimeline.accessibilityText(
                                        for: message,
                                        calendar: timelineCalendar,
                                        locale: locale
                                    )
                            {
                                ChatDaySeparator(
                                    text: separatorText,
                                    accessibilityText: accessibilityText
                                ) {
                                    presentDayPicker(anchoredAt: message)
                                }
                                .background {
                                    dayMarkerReporter(
                                        for: message,
                                        label: separatorText
                                    )
                                    // The Button owns 10pt of transparent
                                    // touch padding on each edge. Measure only
                                    // the visible capsule so its floating
                                    // hand-off still happens at the same spot.
                                    .padding(.vertical, 10)
                                }
                                // Above the slot the resting marker carries
                                // this day, so the separator stops drawing
                                // instead of being seen sliding off the top.
                                .opacity(separatorOpacity(forDayOf: message))
                                .transition(.opacity)
                            }

                            if showsStoryDivider(
                                before: message,
                                after: previous,
                                hasDateSeparator: needsSeparator
                            ) {
                                Divider()
                                    .frame(
                                        width: maximumStoryWidth(
                                            in: geometry.size.width
                                        )
                                    )
                                    .frame(maxWidth: .infinity)
                                    .accessibilityHidden(true)
                            }

                            messageRow(
                                message: message,
                                width: geometry.size.width,
                                joinsPrevious: joinsPrevious
                            )
                            .padding(
                                .top,
                                needsSeparator
                                    ? 0
                                    : messageTopSpacing(
                                        for: message,
                                        joinsPrevious: joinsPrevious
                                    )
                            )
                            .transition(messageTransition(for: message))
                            .id(message.id)

                            if let forkCount = forkCounts[message.id] {
                                ChatForkMarker(
                                    count: forkCount,
                                    gutter: railGutter
                                ) {
                                    isRoomSettingsPresented = true
                                }
                                .padding(.top, LorepiaSpacing.compact)
                                .transition(.opacity)
                            }
                        }

                        if let usageDescription = viewModel.usageDescription {
                            Text(usageDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .padding(.top, LorepiaSpacing.compact)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(ChatScrollAnchor.bottom)
                    }
                    .padding(.leading, railGutter)
                    .background(alignment: .leading) {
                        threadRail
                    }
                    .padding(.horizontal, transcriptHorizontalInset)
                    .padding(.top, LorepiaSpacing.compact)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: geometry.size.height,
                        alignment: timelineAlignment
                    )
                    .background {
                        GeometryReader { contentGeometry in
                            Color.clear.preference(
                                key: ChatLayoutPreferenceKey.self,
                                value: ChatLayoutMetrics(
                                    bottomY: contentGeometry.frame(
                                        in: .named(ChatCoordinateSpace.name)
                                    ).maxY,
                                    contentSize: contentGeometry.size
                                )
                            )
                        }
                    }
                        .animation(
                            reduceMotion || !hasSettledInitialLoad
                                ? nil
                                : .spring(duration: 0.42, bounce: 0.16),
                            value: viewModel.messages.count
                        )
                    }
                }
                .chatDefaultBottomAnchor()
                .coordinateSpace(name: ChatCoordinateSpace.name)
                .chatScrollActivity { isActive in
                    isTranscriptMovementActive = isActive
                    if isActive {
                        noteTranscriptScrolled()
                    }
                }
                .overlay(alignment: .top) {
                    if let floatingDayLabel, let floatingDay {
                        Button {
                            presentDayPicker(on: floatingDay)
                        } label: {
                            ChatDayCapsule(
                                text: floatingDayLabel,
                                showsChevron: true,
                                isElevated: true
                            )
                            .padding(.top, FloatingMarker.top)
                            .frame(minHeight: 44, alignment: .top)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .opacity(floatingMarkerIsVisible ? 1 : 0)
                        .allowsHitTesting(floatingMarkerIsVisible)
                        // The separators in the transcript carry the same
                        // label and the same action, so this transient copy
                        // stays out of the accessibility tree.
                        .accessibilityHidden(true)
                        // Only arriving and leaving are worth animating. The
                        // hand-off itself is a swap between identical
                        // capsules in the same place, so it needs no motion.
                        .animation(
                            reduceMotion ? nil : .easeOut(duration: 0.2),
                            value: isTranscriptScrolling
                        )
                    }
                }
                .onPreferenceChange(ChatDayMarkerPreferenceKey.self) { markers in
                    updateFloatingDay(with: markers)
                    if isTranscriptMovementActive {
                        noteTranscriptScrolled()
                    }
                }
                .chatInteractiveKeyboardDismissal()
                .onPreferenceChange(ChatLayoutPreferenceKey.self) { metrics in
                    let observation = ChatBottomObservation(
                        scrollState: scrollState,
                        viewportSize: geometry.size,
                        contentSize: metrics.contentSize
                    )
                    let contentOrViewportChanged =
                        lastBottomObservation == nil
                            || lastBottomObservation != observation
                    lastBottomObservation = observation

                    let nearBottom =
                        metrics.bottomY
                            <= geometry.size.height
                                + followThreshold(
                                    for: geometry.size.height
                                )
                    let wasNearBottom = isNearBottom
                    isNearBottom = nearBottom
                    if nearBottom {
                        followsLatest = true
                    } else if
                        wasNearBottom,
                        !contentOrViewportChanged
                    {
                        // A position-only change means the person scrolled,
                        // regardless of whether it came from touch, a wheel,
                        // a scroll bar, or an accessibility action.
                        followsLatest = false
                    }
                }
                .onChange(of: scrollState) { previous, current in
                    let shouldFollow =
                        followsLatest
                            || isNearBottom
                            || current.lastRole == .user
                    guard shouldFollow else {
                        return
                    }
                    followsLatest = true

                    if current.count > previous.count
                        || current.lastID != previous.lastID
                    {
                        scrollToBottom(
                            proxy,
                            animated: !reduceMotion
                        )
                    } else if current.lastTextLength
                        != previous.lastTextLength
                    {
                        // Streaming deltas keep the latest line visible without
                        // starting a new animation for every token.
                        scrollToBottom(proxy, animated: false)
                    }
                }
                .onChange(of: pendingScrollTargetID) { _, target in
                    guard let target else {
                        return
                    }
                    // Landing on a match means leaving the live tail, so the
                    // transcript stops chasing new messages until it returns.
                    followsLatest = false
                    withAnimation(
                        reduceMotion ? nil : .easeInOut(duration: 0.24)
                    ) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                    pendingScrollTargetID = nil
                }
                .onChange(of: geometry.size) { _, _ in
                    guard followsLatest else {
                        return
                    }
#if os(iOS)
                    // iOS 18+ keeps the bottom edge stable as the composer
                    // changes the viewport. A second imperative scroll after
                    // layout would visibly correct the transcript one frame
                    // later.
                    if #available(iOS 18.0, *) {
                        return
                    }
#endif
                    // Preserve the draft binding's resize transaction so the
                    // transcript and the bottom-anchored composer move as one
                    // layout instead of snapping in separate passes.
                    proxy.scrollTo(
                        ChatScrollAnchor.bottom,
                        anchor: .bottom
                    )
                }
                .onChange(
                    of: viewModel.conversation?.id,
                    initial: true
                ) { _, _ in
                    followsLatest = true
                    isNearBottom = true
                    lastBottomObservation = nil
                    hasSettledInitialLoad = false
                    scrollToBottom(proxy, animated: false)
                    initialLoadSettleGeneration &+= 1
                    let settleGeneration = initialLoadSettleGeneration
                    guard let conversationID = viewModel.conversation?.id else {
                        return
                    }
                    // Restoring reads from local storage, so the transcript
                    // lands well inside this window. Anything arriving after
                    // it is a real arrival and animates.
                    Task { @MainActor in
                        do {
                            try await Task.sleep(for: .milliseconds(150))
                        } catch {
                            return
                        }
                        guard settleGeneration == initialLoadSettleGeneration,
                              viewModel.conversation?.id == conversationID
                        else {
                            return
                        }
                        hasSettledInitialLoad = true
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                dismissComposerKeyboard()
                hideActions()
            }
        )
    }

    /// The rail the timeline hangs from. It marks where the thread can fork, so
    /// it only appears where forking is legible: the bubble timeline.
    @ViewBuilder
    private var threadRail: some View {
        if showsThreadRail {
            Capsule()
                .fill(Color.secondary.opacity(0.22))
                .frame(width: ChatThreadRail.width)
                .padding(.leading, (railGutter - ChatThreadRail.width) / 2)
                .padding(.vertical, LorepiaSpacing.tight)
                .accessibilityHidden(true)
        }
    }

    private var showsThreadRail: Bool {
        viewModel.mode == .chat && !forkCounts.isEmpty
    }

    private var railGutter: CGFloat {
        showsThreadRail ? ChatThreadRail.gutter : 0
    }

    @ViewBuilder
    private var conversationState: some View {
        if viewModel.isLoading {
            ProgressView("대화를 복원하는 중")
                .frame(maxWidth: .infinity)
                .padding(.vertical, LorepiaSpacing.roomy)
                .transition(.opacity)
        } else if viewModel.messages.isEmpty {
            ContentUnavailableView {
                Label("첫 메시지를 보내보세요", systemImage: "sparkles")
            } description: {
                if viewModel.requiresProviderConfiguration {
                    Text(viewModel.providerConfigurationMessage)
                } else {
                    Text("이 대화는 이 기기에만 저장됩니다.")
                }
            } actions: {
                if viewModel.requiresProviderConfiguration {
                    Button(
                        "프로바이더 설정",
                        action: openProviderSettings
                    )
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(
                        "chat-empty-provider-settings"
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, LorepiaSpacing.roomy)
            .transition(.opacity)
        }

        if let errorMessage = viewModel.errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lorepiaCard()
                .padding(.bottom, LorepiaSpacing.compact)
                .transition(.opacity)
        }
    }

    private var currentComposerExpansion: Bool {
        inlineEditSession?.isExpanded ?? isComposerExpanded
    }

    private var isComposerFullscreenPresented: Bool {
#if os(iOS)
        currentComposerExpansion
#else
        false
#endif
    }

#if os(iOS)
    private var fullscreenComposer: some View {
        ZStack(alignment: .topTrailing) {
            ChatSurface.background
                .ignoresSafeArea()

            composer(
                restingSafeAreaInset: 0,
                isFullscreen: true
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            fullscreenComposerCollapseButton
                .padding(.top, LorepiaSpacing.compact)
                .padding(
                    .trailing,
                    ChatComposerMetrics.horizontalEdgeInset
                )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("전체 화면 메시지 입력")
        .accessibilityIdentifier("chat-composer-fullscreen")
        .onAppear {
            focusFullscreenComposer()
        }
    }

    private var fullscreenComposerCollapseButton: some View {
        Button {
            dismissFullscreenComposer()
        } label: {
            LorepiaGlyphView(.collapse, size: 18)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .chatSearchStepSurface(isInteractive: true)
        .disabled(inlineEditSession?.isSaving == true)
        .accessibilityLabel(
            inlineEditSession == nil ? "입력창 축소" : "편집창 축소"
        )
        .accessibilityHint("전체 화면 입력을 닫고 대화로 돌아갑니다")
        .accessibilityIdentifier(
            inlineEditSession == nil
                ? "chat-composer-collapse"
                : "chat-composer-edit-collapse"
        )
    }
#endif

    private func composer(
        restingSafeAreaInset: CGFloat,
        isFullscreen: Bool = false
    ) -> some View {
        ChatComposer(
            draft: composerDraft,
            measuredEditorHeight:
                isFullscreen
                    ? $fullscreenComposerEditorHeight
                    : $composerEditorHeight,
            exceedsExpansionLineLimit:
                isFullscreen
                    ? $fullscreenComposerExceedsExpansionLineLimit
                    : $composerExceedsExpansionLineLimit,
            focus:
                isFullscreen
                    ? $isFullscreenComposerFocused
                    : $isComposerFocused,
            placeholder: composerPlaceholder,
            isEnabled: composerIsEnabled,
            canUseTools:
                inlineEditSession == nil && viewModel.canManageBranches,
            canChangeMode:
                inlineEditSession == nil && viewModel.canManageBranches,
            canChangeProviderProfile:
                inlineEditSession == nil
                    && viewModel.canChangeProviderProfile,
            canSubmit: composerCanSubmit,
            isGenerating:
                inlineEditSession == nil && viewModel.isGenerating,
            editSessionID: inlineEditSession?.token,
            automaticFocusID:
                (
                    isFullscreen
                        ? fullscreenComposerAutomaticFocusID
                        : composerAutomaticFocusID
                )?.uuidString
                    ?? inlineEditSession?.token.uuidString,
            isExpanded:
                currentComposerExpansion,
            isFullscreen: isFullscreen,
            isEditSaving: inlineEditSession?.isSaving ?? false,
            editSaveFailed: inlineEditSession?.saveFailed ?? false,
            mode: viewModel.mode,
            providerProfiles: viewModel.providerProfiles,
            selectedProviderProfileID:
                viewModel.selectedProviderProfileID,
            restingSafeAreaInset: restingSafeAreaInset,
            onSubmit: {
                if inlineEditSession == nil {
                    Task {
                        await viewModel.submitMessage()
                        if viewModel.draft.isEmpty {
                            resetComposerExpansion()
                        }
                    }
                } else {
                    saveInlineEdit()
                }
            },
            onCancel: {
                Task {
                    await viewModel.cancelGeneration()
                }
            },
            onCancelEdit: {
                cancelInlineEdit()
            },
            onToggleExpansion: {
                toggleComposerExpansion()
            },
            onModeChange: { mode in
                Task {
                    await viewModel.setMode(mode)
                }
            },
            onProviderProfileChange: { profileID in
                Task {
                    await viewModel.selectProviderProfile(id: profileID)
                }
            },
            onOpenConversationSettings: {
                isRoomSettingsPresented = true
            },
            onOpenProviderSettings: {
                openProviderSettings()
            }
        )
    }

    private func openProviderSettings() {
        dismissComposerKeyboard()
        onOpenProviderSettings()
    }

    private func dismissComposerKeyboard() {
        isComposerFocused = false
#if os(iOS)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
#endif
    }

    /// The branch shown beneath the character name, when more than one exists.
    ///
    /// The toolbar only has room for the position, so the branch name travels
    /// in the accessibility description and in the conversation settings sheet.
    private var branchSummary: ChatBranchSummary? {
        guard viewModel.branchOptions.count > 1,
              let activeBranchID = viewModel.activeBranchID,
              let index = viewModel.branchOptions.firstIndex(
                  where: { $0.id == activeBranchID }
              )
        else {
            return nil
        }
        let position = "\(index + 1)/\(viewModel.branchOptions.count)"
        return ChatBranchSummary(
            label: position,
            description:
                "\(viewModel.branchOptions[index].title), 분기 \(position)"
        )
    }

    /// One message: the bubble, and the action row it reveals when asked.
    @ViewBuilder
    private func messageRow(
        message: ChatMessage,
        width: CGFloat,
        joinsPrevious: Bool
    ) -> some View {
        if viewModel.mode == .story {
            storyMessageRow(message: message, width: width)
        } else {
            messageContent(
                message: message,
                width: width,
                showsSenderIdentity: !joinsPrevious
            )
            .onLongPressGesture(minimumDuration: 0.35) {
                revealActions(for: message)
            }
            // A popover leaves the transcript where it is: no row is inserted
            // under the message, so nothing below it moves.
            .chatMessageActionPopover(
                isPresented: Binding(
                    get: { revealedActionsMessageID == message.id },
                    set: { presented in
                        if !presented {
                            revealedActionsMessageID = nil
                        }
                    }
                ),
                message: message,
                isMutationEnabled: viewModel.canMutateMessage(message),
                isCopied: copiedMessageID == message.id
            ) { action in
                handleMessageAction(action, for: message)
            }
            // VoiceOver never performs a long press, so the same actions stay
            // reachable from the message itself.
            .accessibilityActions {
                ForEach(
                    ChatMessageActionPresentation.actions(for: message.role)
                        .filter { action in
                            action == .copy
                                ? !message.text.isEmpty
                                : viewModel.canMutateMessage(message)
                        }
                ) { action in
                    Button(action.title) {
                        handleMessageAction(action, for: message)
                    }
                }
            }
        }
    }

    private func storyMessageRow(
        message: ChatMessage,
        width: CGFloat
    ) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if let sender = chatParticipant(for: message) {
                    storyParticipantHeader(
                        sender,
                        message: message
                    )
                }

                messageContent(
                    message: message,
                    width: width,
                    showsSenderIdentity: false
                )

                if !ChatMessageActionPresentation.actions(
                    for: message.role
                ).isEmpty {
                    ChatMessageActionRow(
                        message: message,
                        isMutationEnabled: viewModel.canMutateMessage(message),
                        isCopied: copiedMessageID == message.id
                    ) { action in
                        handleMessageAction(action, for: message)
                    }
                    .frame(
                        maxWidth: messageActionMaximumWidth(
                            for: message,
                            in: width
                        ),
                        alignment: messageActionRowAlignment(for: message)
                    )
                    .frame(
                        maxWidth: .infinity,
                        alignment: messageActionContainerAlignment(for: message)
                    )
                }
            }
            .frame(
                width: storyContentWidth(in: width),
                alignment: .leading
            )
        }
        .frame(
            width: maximumStoryWidth(in: width),
            alignment: .center
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func storyParticipantHeader(
        _ sender: ChatParticipantIdentity,
        message: ChatMessage
    ) -> some View {
        HStack(spacing: ChatParticipantLayout.spacing) {
            LorepiaAvatar(
                symbolName: sender.symbolName,
                size: participantAvatarSize,
                name: sender.displayName
            )
            .accessibilityIdentifier(
                "chat-sender-avatar-\(message.role.rawValue)-\(message.id)"
            )

            Text(sender.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityIdentifier(
                    "chat-sender-name-\(message.role.rawValue)-\(message.id)"
                )

            Spacer(minLength: 0)
        }
        .padding(.top, LorepiaSpacing.standard)
    }

    private func messageContent(
        message: ChatMessage,
        width: CGFloat,
        showsSenderIdentity: Bool
    ) -> some View {
        let sender = chatParticipant(for: message)
        return ChatBubble(
            message: message,
            maximumWidth: maximumBubbleWidth(
                in: width,
                reservesSenderIdentity:
                    viewModel.mode == .chat && sender != nil
            ),
            storyMaximumWidth: storyContentWidth(in: width),
            mode: viewModel.mode,
            sender: sender,
            showsSenderIdentity: showsSenderIdentity,
            senderAvatarSize: participantAvatarSize,
            highlight: searchHighlight,
            isActiveMatch: activeMatchID == message.id
        )
        .contentShape(Rectangle())
        .accessibilityIdentifier(
            "chat-message-\(message.role.rawValue)-\(message.id)"
        )
    }

    private func chatParticipant(
        for message: ChatMessage
    ) -> ChatParticipantIdentity? {
        switch message.role {
        case .user:
            return ChatParticipantIdentity(
                displayName: "게스트",
                symbolName: "person.fill"
            )
        case .assistant:
            let name = viewModel.character?.name.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let symbolName = viewModel.character?.symbolName
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ChatParticipantIdentity(
                displayName:
                    name.flatMap { $0.isEmpty ? nil : $0 } ?? "캐릭터",
                symbolName:
                    symbolName.flatMap { $0.isEmpty ? nil : $0 }
                        ?? "person.crop.circle"
            )
        case .system, .notice:
            return nil
        }
    }

    private var searchHighlight: String {
        guard isSearchActive else {
            return ""
        }
        return searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Per-message actions

    private func revealActions(for message: ChatMessage) {
        guard !ChatMessageActionPresentation.actions(
            for: message.role
        ).isEmpty else {
            return
        }
        dismissComposerKeyboard()
#if os(iOS)
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
#endif
        revealedAt = Date()
        withAnimation(
            reduceMotion ? nil : .snappy(duration: 0.24, extraBounce: 0.08)
        ) {
            revealedActionsMessageID =
                revealedActionsMessageID == message.id ? nil : message.id
        }
    }

    private func hideActions() {
        guard revealedActionsMessageID != nil else {
            return
        }
        // Lifting the finger that opened the row also lands as a tap on the
        // transcript, which would close it in the same frame.
        if let revealedAt, Date().timeIntervalSince(revealedAt) < 0.6 {
            return
        }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
            revealedActionsMessageID = nil
        }
    }

    // MARK: - Jumping to a day

    /// Publishes where this day's separator sits in the viewport.
    @ViewBuilder
    private func dayMarkerReporter(
        for message: ChatMessage,
        label: String
    ) -> some View {
        if let date = ChatTimeline.date(from: message.createdAt) {
            let day = timelineCalendar.startOfDay(for: date)
            GeometryReader { geometry in
                Color.clear.preference(
                    key: ChatDayMarkerPreferenceKey.self,
                    value: [
                        ChatDayMarker(
                            day: day,
                            label: label,
                            minY: geometry.frame(
                                in: .named(ChatCoordinateSpace.name)
                            ).minY
                        ),
                    ]
                )
            }
        }
    }

    /// The slot the floating marker rests in, measured from the top of the
    /// viewport: its own top padding plus its height.
    private enum FloatingMarker {
        static let top = LorepiaSpacing.compact
        static let height: CGFloat = 24
        static var slotBottom: CGFloat {
            top + height
        }
    }

    /// A separator hides the moment it reaches the slot: from there on the
    /// resting marker shows the same capsule in the same place, so the two
    /// swap without anything appearing to move or slip away.
    private func separatorOpacity(forDayOf message: ChatMessage) -> Double {
        guard
            isTranscriptScrolling,
            let date = ChatTimeline.date(from: message.createdAt)
        else {
            return 1
        }
        let day = timelineCalendar.startOfDay(for: date)
        guard let minY = dayMarkers.first(where: { $0.day == day })?.minY
        else {
            return 1
        }
        return minY <= FloatingMarker.top ? 0 : 1
    }

    /// Whether the resting marker is drawn at all.
    ///
    /// It never leaves early: the arriving separator climbs all the way into
    /// the slot, and only when the two capsules sit exactly on top of each
    /// other does the separator stop drawing and this one take over its day.
    /// Same capsule, same place, so the exchange cannot be seen.
    private var floatingMarkerIsVisible: Bool {
        isTranscriptScrolling
    }

    private var floatingMarkerThreshold: CGFloat {
        FloatingMarker.top
    }

    /// The day the top of the transcript has scrolled into.
    ///
    /// The transcript is lazy, so only nearby separators report at all. An
    /// empty report means no day boundary is close, which leaves the day
    /// unchanged rather than unknown.
    private func updateFloatingDay(with markers: [ChatDayMarker]) {
        let ordered = markers.sorted { $0.minY < $1.minY }
        dayMarkers = ordered
        guard let topmost = ordered.first else {
            return
        }
        if let index = ChatTimeline.enteredMarkerIndex(
            markerOffsets: ordered.map(\.minY),
            threshold: floatingMarkerThreshold
        ) {
            floatingDay = ordered[index].day
            floatingDayLabel = ordered[index].label
            return
        }
        // The topmost separator still sits below the edge, so it opens the
        // next day: what fills the top is the day before it.
        floatingDay = ChatTimeline.dayBefore(
            topmost.day,
            in: viewModel.messages,
            calendar: timelineCalendar
        )
        floatingDayLabel = floatingDay.map {
            ChatTimeline.dayLabel(
                for: $0,
                calendar: timelineCalendar,
                locale: locale
            )
        }
    }

    /// The marker rides the scroll and leaves once it settles.
    private func noteTranscriptScrolled() {
        if !isTranscriptScrolling {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                isTranscriptScrolling = true
            }
        }
        scrollIdleGeneration &+= 1
        let generation = scrollIdleGeneration
        Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(700))
            } catch {
                return
            }
            guard generation == scrollIdleGeneration else {
                return
            }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.28)) {
                isTranscriptScrolling = false
            }
        }
    }

    private func presentDayPicker(anchoredAt message: ChatMessage) {
        guard let date = ChatTimeline.date(from: message.createdAt) else {
            return
        }
        presentDayPicker(on: timelineCalendar.startOfDay(for: date))
    }

    private func presentDayPicker(on day: Date) {
        isComposerFocused = false
        dayPickerAnchor = ChatDayPickerAnchor(day: day)
    }

    private func jumpToDay(_ day: Date) {
        guard let messageID = ChatTimeline.firstMessageID(
            on: day,
            in: viewModel.messages,
            calendar: timelineCalendar
        ) else {
            return
        }
        jump(to: messageID)
    }

    // MARK: - Searching the open conversation

    /// Messages on the active branch containing the query, oldest first.
    private var searchMatchIDs: [String] {
        let query = searchQuery.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !query.isEmpty else {
            return []
        }
        return viewModel.messages
            .filter { $0.text.localizedCaseInsensitiveContains(query) }
            .map(\.id)
    }

    private var activeMatchPosition: Int? {
        guard let activeMatchID else {
            return nil
        }
        return searchMatchIDs.firstIndex(of: activeMatchID)
    }

    private var searchStatusLabel: String? {
        guard !searchQuery.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            return nil
        }
        let matches = searchMatchIDs
        guard !matches.isEmpty else {
            return "결과 없음"
        }
        guard let position = activeMatchPosition else {
            return "\(matches.count)"
        }
        return "\(position + 1)/\(matches.count)"
    }

    /// Typing lands on the newest match, the one nearest where the transcript
    /// already is, and the chevrons walk out from there.
    private func syncActiveMatch() {
        let matches = searchMatchIDs
        guard let newest = matches.last else {
            activeMatchID = nil
            return
        }
        guard let activeMatchID, matches.contains(activeMatchID) else {
            jumpToMatch(newest)
            return
        }
    }

    /// The way through the matches: a pair stacked at the trailing edge, off
    /// to the side of the transcript rather than across the bottom of it.
    /// The field itself belongs to the navigation bar now.
    private var chatSearchNavigator: some View {
        VStack(spacing: LorepiaSpacing.compact) {
            if let searchStatusLabel {
                Text(searchStatusLabel)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("chat-room-search-status")
            }

            VStack(spacing: LorepiaSpacing.compact) {
                // Older matches sit above, so up walks back through the
                // conversation and down returns toward the newest.
                searchStepButton(
                    systemImage: "chevron.up",
                    label: "이전 결과",
                    offset: -1
                )

                searchStepButton(
                    systemImage: "chevron.down",
                    label: "다음 결과",
                    offset: 1
                )
            }
        }
        .padding(.trailing, listInset)
        .padding(.bottom, LorepiaSpacing.standard)
        // Branch changes, edits, deletion, and regeneration can replace the
        // result set without changing the query. Reconcile the active landing
        // point against the matches themselves.
        .onChange(of: searchMatchIDs) { _, _ in
            syncActiveMatch()
        }
    }

    private func searchStepButton(
        systemImage: String,
        label: String,
        offset: Int
    ) -> some View {
        Button {
            stepMatch(by: offset)
        } label: {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .chatSearchStepSurface(isInteractive: searchMatchIDs.count >= 2)
        .disabled(searchMatchIDs.count < 2)
        .accessibilityLabel(label)
        .accessibilityIdentifier(
            offset < 0
                ? "chat-search-previous-result"
                : "chat-search-next-result"
        )
    }

    private func openSearch() {
        isComposerFocused = false
        isSearchActive = true
    }

#if os(iOS)
    /// Older iOS releases do not expose a relocatable default search item.
    /// Keep the prepared glyph there while the system owns the field itself.
    private var chatToolbarSearchFallback: some View {
        Button {
            openSearch()
        } label: {
            LorepiaGlyphView(.search, size: 23)
        }
        .accessibilityLabel("대화 내 검색")
        .accessibilityIdentifier("chat-room-search-trigger")
    }
#endif

    /// Walks the match list. Without a landing point yet, the newest match is
    /// the one closest to where the transcript already sits.
    private func stepMatch(by offset: Int) {
        let matches = searchMatchIDs
        guard !matches.isEmpty else {
            return
        }
        guard let current = activeMatchPosition else {
            jumpToMatch(matches[matches.count - 1])
            return
        }
        let next = (current + offset + matches.count) % matches.count
        jumpToMatch(matches[next])
    }

    private func jumpToMatch(_ messageID: String) {
        activeMatchID = messageID
        jump(to: messageID)
    }

    private func jump(to messageID: String) {
        pendingScrollTargetID = messageID
    }

    /// Messages the conversation forks at, with how many branches leave them.
    private var forkCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for branch in viewModel.branches {
            guard let forkMessageID = branch.forkMessageID else {
                continue
            }
            counts[forkMessageID, default: 0] += 1
        }
        return counts
    }

    private func handleMessageAction(
        _ action: ChatMessageAction,
        for message: ChatMessage
    ) {
        // The row has done its job once an action is taken; copy keeps it up
        // long enough to show the checkmark it swaps in.
        if action != .copy {
            hideActions()
        }

        switch action {
        case .edit:
            guard message.role == .user,
                  viewModel.canMutateMessage(message)
            else {
                return
            }
            beginInlineEdit(message)
        case .copy:
            copyToClipboard(
                message.text,
                messageID: message.id
            )
        case .regenerate:
            guard message.role == .assistant,
                  viewModel.canMutateMessage(message)
            else {
                return
            }
            Task {
                await viewModel.regenerateAssistantMessage(
                    messageID: message.id
                )
            }
        case .branch:
            guard viewModel.canMutateMessage(message) else {
                return
            }
            Task {
                await viewModel.createBranch(afterMessageID: message.id)
            }
        case .delete:
            guard viewModel.canMutateMessage(message) else {
                return
            }
            deletingMessage = message
        }
    }

    private func copyToClipboard(
        _ text: String,
        messageID: String
    ) {
#if os(iOS)
        UIPasteboard.general.string = text
        UIAccessibility.post(
            notification: .announcement,
            argument: "메시지를 복사했습니다"
        )
#elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
#endif
        copyFeedback &+= 1
        let feedbackToken = copyFeedback
        withAnimation(
            reduceMotion ? nil : .smooth(duration: 0.2)
        ) {
            copiedMessageID = messageID
        }
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard copyFeedback == feedbackToken else {
                return
            }
            withAnimation(
                reduceMotion ? nil : .smooth(duration: 0.2)
            ) {
                copiedMessageID = nil
            }
        }
    }

    private func messageActionMaximumWidth(
        for message: ChatMessage,
        in containerWidth: CGFloat
    ) -> CGFloat {
        if viewModel.mode == .story, message.role != .notice {
            return storyContentWidth(in: containerWidth)
        }
        return maximumBubbleWidth(in: containerWidth)
    }

    private func messageActionRowAlignment(
        for message: ChatMessage
    ) -> Alignment {
        if viewModel.mode == .story {
            return .leading
        }
        return message.role == .user ? .trailing : .leading
    }

    private func messageActionContainerAlignment(
        for message: ChatMessage
    ) -> Alignment {
        if viewModel.mode == .story, message.role != .notice {
            return .center
        }
        if message.role == .user {
            return .trailing
        }
        return .leading
    }

    private var composerPlaceholder: String {
        if inlineEditSession != nil {
            return "메시지 편집"
        }
        if viewModel.conversation == nil {
            return "대화를 준비하는 중입니다"
        }
        if viewModel.isGenerating {
            return "응답을 기다리는 중입니다"
        }
        return "메시지"
    }

    private var composerDraft: Binding<String> {
        guard let editSession = inlineEditSession else {
            return Binding(
                get: {
                    viewModel.draft
                },
                set: { newValue in
                    viewModel.draft = newValue
                }
            )
        }

        let token = editSession.token
        let fallbackDraft = editSession.draft
        return Binding(
            get: {
                guard let currentSession = inlineEditSession,
                      currentSession.token == token
                else {
                    return fallbackDraft
                }
                return currentSession.draft
            },
            set: { newValue in
                guard var currentSession = inlineEditSession,
                      currentSession.token == token
                else {
                    return
                }
                currentSession.draft = newValue
                currentSession.saveFailed = false
                inlineEditSession = currentSession
            }
        )
    }

    private var composerIsEnabled: Bool {
        guard let session = inlineEditSession else {
            return viewModel.canEditDraft
        }
        return !session.isSaving && inlineEditTarget(for: session) != nil
    }

    private var composerCanSubmit: Bool {
        guard let session = inlineEditSession else {
            return viewModel.canSubmit
        }
        return !session.isSaving
            && !session.draft.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
            && inlineEditTarget(for: session) != nil
    }

    private func inlineEditTarget(
        for session: ChatInlineEditSession
    ) -> ChatMessage? {
        guard viewModel.conversation?.id == session.conversationID,
              viewModel.activeBranchID == session.branchID,
              let message = viewModel.messages.first(where: {
                  $0.id == session.messageID && $0.role == .user
              }),
              viewModel.canMutateMessage(message)
        else {
            return nil
        }
        return message
    }

    private func beginInlineEdit(_ message: ChatMessage) {
        guard message.role == .user,
              viewModel.canMutateMessage(message),
              let conversationID = viewModel.conversation?.id,
              let branchID = viewModel.activeBranchID
        else {
            return
        }

        inlineEditSession = ChatInlineEditSession(
            token: UUID(),
            conversationID: conversationID,
            branchID: branchID,
            messageID: message.id,
            draft: message.text
        )
        composerEditorHeight = 0
        isComposerFocused = false
    }

    private func cancelInlineEdit() {
        guard inlineEditSession?.isSaving != true else {
            return
        }
        discardInlineEdit()
    }

    private func discardInlineEdit() {
        guard inlineEditSession != nil else {
            return
        }
        updateComposerPresentationWithoutAnimation {
            inlineEditSession = nil
            composerEditorHeight = 0
        }
    }

    private func resetComposerExpansion() {
        updateComposerPresentationWithoutAnimation {
            isComposerExpanded = false
            composerExceedsExpansionLineLimit = false
            fullscreenComposerExceedsExpansionLineLimit = false
            composerEditorHeight = 0
            fullscreenComposerEditorHeight = 0
            composerAutomaticFocusID = nil
            fullscreenComposerAutomaticFocusID = nil
        }
    }

    private func toggleComposerExpansion() {
        setComposerExpansion(!currentComposerExpansion)
    }

    private func setComposerExpansion(_ isExpanded: Bool) {
        updateComposerPresentationWithoutAnimation {
            if inlineEditSession == nil {
                isComposerExpanded = isExpanded
                return
            }

            guard var session = inlineEditSession, !session.isSaving else {
                return
            }
            session.isExpanded = isExpanded
            inlineEditSession = session
        }
    }

    private func updateComposerPresentationWithoutAnimation(
        _ update: () -> Void
    ) {
#if os(iOS)
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, update)
#else
        update()
#endif
    }

#if os(iOS)
    private func focusFullscreenComposer() {
        isComposerFocused = false
        fullscreenComposerEditorHeight = 0
        fullscreenComposerExceedsExpansionLineLimit = false
        let focusID = UUID()
        fullscreenComposerAutomaticFocusID = focusID

        Task { @MainActor in
            await Task.yield()
            guard fullscreenComposerAutomaticFocusID == focusID else {
                return
            }
            isFullscreenComposerFocused = true
            try? await Task.sleep(for: .seconds(1))
            if fullscreenComposerAutomaticFocusID == focusID {
                fullscreenComposerAutomaticFocusID = nil
            }
        }
    }

    private func dismissFullscreenComposer() {
        guard isComposerFullscreenPresented else {
            return
        }

        isFullscreenComposerFocused = false
        fullscreenComposerAutomaticFocusID = nil
        fullscreenComposerEditorHeight = 0
        setComposerExpansion(false)
        requestComposerFocusAfterFullscreenDismissal()
    }

    private func requestComposerFocusAfterFullscreenDismissal() {
        let focusID = UUID()
        composerAutomaticFocusID = focusID

        Task { @MainActor in
            await Task.yield()
            guard composerAutomaticFocusID == focusID else {
                return
            }
            isComposerFocused = true
            try? await Task.sleep(for: .seconds(1))
            if composerAutomaticFocusID == focusID {
                composerAutomaticFocusID = nil
            }
        }
    }
#endif

    private func saveInlineEdit() {
        guard var session = inlineEditSession,
              composerCanSubmit
        else {
            return
        }

        let replacementText = session.draft.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let token = session.token
        session.isSaving = true
        session.saveFailed = false
        inlineEditSession = session

        Task {
            let succeeded = await viewModel.editUserMessage(
                messageID: session.messageID,
                replacementText: replacementText
            )
            guard var currentSession = inlineEditSession,
                  currentSession.token == token
            else {
                return
            }

            if succeeded {
                discardInlineEdit()
            } else {
                currentSession.isSaving = false
                currentSession.saveFailed = true
                inlineEditSession = currentSession
#if os(iOS)
                if isComposerFullscreenPresented {
                    focusFullscreenComposer()
                } else {
                    isComposerFocused = true
                }
#else
                isComposerFocused = true
#endif
            }
        }
    }

    private var listInset: CGFloat {
        min(max(scaledListInset, 12), 28)
    }

    private var transcriptHorizontalInset: CGFloat {
#if os(iOS)
        if viewModel.mode == .story {
            return ChatComposerMetrics.horizontalEdgeInset
        }
#endif
        return listInset
    }

    private var storyContentInset: CGFloat {
        min(max(scaledStoryContentInset, 12), 28)
    }

    private var participantAvatarSize: CGFloat {
        min(
            max(
                scaledParticipantAvatarSize,
                ChatParticipantLayout.minimumAvatarSize
            ),
            ChatParticipantLayout.maximumAvatarSize
        )
    }

    private func followThreshold(for viewportHeight: CGFloat) -> CGFloat {
        min(max(viewportHeight * 0.14, 72), 160)
    }

    private func maximumBubbleWidth(
        in containerWidth: CGFloat,
        reservesSenderIdentity: Bool = false
    ) -> CGFloat {
        let availableWidth = max(
            containerWidth
                - (transcriptHorizontalInset * 2)
                - railGutter,
            0
        )
        let senderLane: CGFloat =
            reservesSenderIdentity
                ? participantAvatarSize
                    + ChatParticipantLayout.spacing
                : 0
        let messageLane = max(availableWidth - senderLane, 0)
        let ratio: CGFloat

        if dynamicTypeSize.isAccessibilitySize {
            ratio = 1
        } else if horizontalSizeClass == .compact {
            ratio = reservesSenderIdentity ? 0.86 : 0.82
        } else {
            ratio = reservesSenderIdentity ? 0.72 : 0.68
        }

        let readableMaximum: CGFloat =
            horizontalSizeClass == .compact ? 520 : 680
        return min(messageLane * ratio, readableMaximum)
    }

    private func maximumStoryWidth(in containerWidth: CGFloat) -> CGFloat {
        let availableWidth = max(
            containerWidth
                - (transcriptHorizontalInset * 2)
                - railGutter,
            0
        )

#if os(iOS)
        return availableWidth
#else
        if dynamicTypeSize.isAccessibilitySize
            || horizontalSizeClass == .compact
        {
            return availableWidth
        }

        return availableWidth * 0.72
#endif
    }

    private func storyContentWidth(in containerWidth: CGFloat) -> CGFloat {
        max(
            maximumStoryWidth(in: containerWidth)
                - (storyContentInset * 2),
            0
        )
    }

    private var scrollState: ChatScrollState {
        let lastMessage = viewModel.messages.last
        return ChatScrollState(
            count: viewModel.messages.count,
            lastID: lastMessage?.id,
            lastTextLength: lastMessage?.text.count ?? 0,
            lastRole: lastMessage?.role
        )
    }

    private var timelineAlignment: Alignment {
        viewModel.messages.isEmpty ? .center : .bottom
    }

    private var timelineCalendar: Calendar {
        var localCalendar = calendar
        localCalendar.timeZone = timeZone
        return localCalendar
    }

    private func messageTransition(
        for message: ChatMessage
    ) -> AnyTransition {
        guard hasSettledInitialLoad else {
            // Restoring a conversation is not an arrival. Place the transcript
            // rather than flying every bubble in at once.
            return .identity
        }
        if reduceMotion {
            return .opacity
        }

        let insertion = AnyTransition.modifier(
            active: ChatMessageInsertionModifier(
                role: message.role,
                isActive: true
            ),
            identity: ChatMessageInsertionModifier(
                role: message.role,
                isActive: false
            )
        )
        return .asymmetric(insertion: insertion, removal: .opacity)
    }

    private func messageBefore(_ index: Int) -> ChatMessage? {
        guard index > viewModel.messages.startIndex else {
            return nil
        }
        return viewModel.messages[index - 1]
    }

    /// Story entries carry their own vertical reading space around the divider,
    /// while chat mode retains its compact speaker grouping.
    private func messageTopSpacing(
        for message: ChatMessage,
        joinsPrevious: Bool
    ) -> CGFloat {
        if viewModel.mode == .story,
           message.role != .system,
           message.role != .notice
        {
            return 0
        }
        return joinsPrevious ? 2 : 10
    }

    /// A date marker already separates days, and notices keep their capsule
    /// treatment. The quiet rule is only for adjacent pieces of story prose.
    private func showsStoryDivider(
        before message: ChatMessage,
        after previous: ChatMessage?,
        hasDateSeparator: Bool
    ) -> Bool {
        guard viewModel.mode == .story,
              !hasDateSeparator,
              message.role == .user || message.role == .assistant,
              let previous,
              previous.role == .user || previous.role == .assistant
        else {
            return false
        }
        return true
    }

    private func scrollToBottom(
        _ proxy: ScrollViewProxy,
        animated: Bool
    ) {
        if animated {
            withAnimation(.spring(duration: 0.38, bounce: 0.08)) {
                proxy.scrollTo(ChatScrollAnchor.bottom, anchor: .bottom)
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(ChatScrollAnchor.bottom, anchor: .bottom)
            }
        }
    }
}

/// Marks the message a conversation forks at.
///
/// The count comes from the branches the core reports for this conversation, so
/// the timeline shows where the thread splits instead of hiding it in a menu.
private struct ChatForkMarker: View {
    let count: Int
    let gutter: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                node
                Text("여기서 \(count + 1)개로 갈라짐")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .padding(.leading, -gutter)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("분기 \(count + 1)개로 갈라지는 지점")
        .accessibilityHint("대화 설정을 열어 분기를 전환합니다")
        .accessibilityIdentifier("chat-fork-marker")
    }

    private var node: some View {
        LorepiaGlyphView(.branch, size: 15)
            .foregroundStyle(.secondary)
            .frame(
                width: ChatThreadRail.nodeSize,
                height: ChatThreadRail.nodeSize
            )
            .background(LorepiaColor.incomingFill, in: Circle())
            .overlay {
                Circle().strokeBorder(ChatSurface.background, lineWidth: 2)
            }
            .frame(width: max(gutter, ChatThreadRail.nodeSize))
            .accessibilityHidden(true)
    }
}

/// Shared sizing for the composer.
///
/// The 44 pt touch target is the base unit. The editor band and control rail
/// are always present; only the measured editor height changes as text wraps.
/// Glyphs and emphasized circles stay fixed while the shared Liquid Glass
/// surface reflows around them.
enum ChatComposerMetrics {
    /// Keep the compact editor at five lines. Longer drafts can be expanded
    /// explicitly without making every room's composer dominate the screen.
    static let expansionLineLimit = 5

#if os(iOS)
    /// Visible primary-action circle inside its larger touch target.
    static let control: CGFloat = 32
#else
    static let control: CGFloat = 28
#endif

    /// Visible clearance between a control and the surface rim.
    static let inset: CGFloat = 8

    /// Space between a control and the editable text.
    static let gap: CGFloat = 10

    /// Touch target the controls are centered in.
    static let target: CGFloat = 44

#if os(iOS)
    /// iOS glass uses its measured layout bounds without a vertical inset.
    static let glassVerticalInset: CGFloat = 0
#else
    static let glassVerticalInset: CGFloat = 2
#endif

    /// The open surface keeps one horizontal placement.
    static let horizontalEdgeInset: CGFloat = 12

    /// Vertical placement follows the native keyboard.
    static let restingBottomInset: CGFloat = 34
    static let keyboardBottomInset: CGFloat = 12

    /// Extra layout owned by the container, outside the measured glass shape.
    /// Liquid Glass renders past its nominal bounds while settling, so the
    /// surrounding safe-area inset must not end exactly at the visible rim.
    static let glassRenderHeadroom: CGFloat = 4

    /// The surface keeps a stable corner radius while its editor grows.
    static let cornerRadius: CGFloat = 24

    /// Leading and trailing rail padding that lands the circles on `inset`.
    static var railHorizontalPadding: CGFloat {
        max(inset - (target - control) / 2, 0)
    }

    /// Bottom rail padding that lands the circles on `inset` from the rim.
    static var railBottomPadding: CGFloat {
        max(inset + glassVerticalInset - (target - control) / 2, 0)
    }

    /// The always-open surface contains one editor band and one control rail.
    static var minimumSurfaceHeight: CGFloat {
        control + (inset + glassVerticalInset) * 2 + target
    }

    /// Glass edge to text; the editor owns a row above the controls.
    static var fieldHorizontalInset: CGFloat {
        inset + gap
    }

    /// The caret begins slightly above the editor's horizontal inset.
    static let fieldTopInset: CGFloat = 16

    /// Keeps the one-line editor and its 44pt control rail within 92pt.
    static let fieldRailSpacing: CGFloat = 8
}

enum ChatThreadRail {
    static let width: CGFloat = 2
    static let gutter: CGFloat = 24
    static let nodeSize: CGFloat = 24
}

struct ChatBranchSummary: Equatable {
    let label: String
    let description: String
}

private struct ChatParticipantIdentity: Equatable {
    let displayName: String
    let symbolName: String
}

private enum ChatParticipantLayout {
    static let baseAvatarSize: CGFloat = 32
    static let minimumAvatarSize: CGFloat = 28
    static let maximumAvatarSize: CGFloat = 44
    static let spacing: CGFloat = 8
}

#if os(macOS)
/// The window-title identity for the Mac room, where the navigation bar's
/// title and subtitle lines do not exist.
private struct ChatToolbarIdentity: View {
    let character: LibraryCharacter
    let branch: ChatBranchSummary?
    let isEnabled: Bool
    let action: () -> Void

    @ScaledMetric(relativeTo: .caption) private var scaledAvatarSize = 28
    @ScaledMetric(relativeTo: .caption) private var scaledSymbolSize = 15

    var body: some View {
        ViewThatFits(in: .vertical) {
            VStack(spacing: 1) {
                compactSymbol
                Text(character.name)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }

            HStack(spacing: 6) {
                compactSymbol
                Text(character.name)
                    .font(.headline)
                    .lineLimit(1)
            }

            Text(character.name)
                .font(.headline)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(character.name)
    }

    private var compactSymbol: some View {
        Image(systemName: character.symbolName)
            .font(
                .system(
                    size: min(max(scaledSymbolSize, 13), 20),
                    weight: .semibold
                )
            )
            .foregroundStyle(.tint)
            .frame(
                width: min(max(scaledAvatarSize, 26), 36),
                height: min(max(scaledAvatarSize, 26), 36)
            )
            .background(
                Color.accentColor.opacity(0.12),
                in: Circle()
            )
    }

    private var accessibilityLabel: String {
        "\(character.name), 대화 설정"
    }
}
#endif

private struct ChatInlineEditSession {
    let token: UUID
    let conversationID: String
    let branchID: String
    let messageID: String
    var draft: String
    var isExpanded = false
    var isSaving = false
    var saveFailed = false
}

private struct ChatComposer: View {
    @Binding var draft: String
    @Binding var measuredEditorHeight: CGFloat
    @Binding var exceedsExpansionLineLimit: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var sendFeedback = 0
    @State private var isSoftwareKeyboardVisible = false

    let focus: FocusState<Bool>.Binding
    let placeholder: String
    let isEnabled: Bool
    let canUseTools: Bool
    let canChangeMode: Bool
    let canChangeProviderProfile: Bool
    let canSubmit: Bool
    let isGenerating: Bool
    let editSessionID: UUID?
    let automaticFocusID: String?
    let isExpanded: Bool
    let isFullscreen: Bool
    let isEditSaving: Bool
    let editSaveFailed: Bool
    let mode: ConversationMode
    let providerProfiles: [ProviderProfile]
    let selectedProviderProfileID: String?
    let restingSafeAreaInset: CGFloat
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onCancelEdit: () -> Void
    let onToggleExpansion: () -> Void
    let onModeChange: (ConversationMode) -> Void
    let onProviderProfileChange: (String) -> Void
    let onOpenConversationSettings: () -> Void
    let onOpenProviderSettings: () -> Void

    @ScaledMetric(relativeTo: .body) private var scaledVerticalInset = 6
    @ScaledMetric(relativeTo: .body) private var scaledFieldPadding = 16
    @ScaledMetric(relativeTo: .body) private var scaledSendSymbol = 18
    @ScaledMetric(relativeTo: .body) private var scaledMinimumFieldHeight = 22

    @ViewBuilder
    var body: some View {
#if os(iOS)
        Group {
            if isFullscreen {
                fullscreenComposerLayout
            } else {
                composerLayout
            }
        }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIResponder.keyboardWillChangeFrameNotification
                )
            ) { notification in
                updateKeyboardVisibility(from: notification)
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIResponder.keyboardWillHideNotification
                )
            ) { _ in
                setSoftwareKeyboardVisible(false)
            }
#else
        composerLayout
#endif
    }

#if os(iOS)
    private var fullscreenComposerLayout: some View {
        GeometryReader { geometry in
            let topInset =
                ChatComposerMetrics.target + LorepiaSpacing.standard
            let bottomInset =
                ChatComposerMetrics.target + LorepiaSpacing.compact
            let editorHeight = max(
                geometry.size.height - topInset - bottomInset,
                minimumEditorHeight
            )

            ZStack(alignment: .topLeading) {
                messageField
                    .frame(
                        width: max(
                            geometry.size.width
                                - ChatComposerMetrics.fieldHorizontalInset * 2,
                            0
                        ),
                        height: editorHeight,
                        alignment: .topLeading
                    )
                    .offset(
                        x: ChatComposerMetrics.fieldHorizontalInset,
                        y: topInset
                    )

                sendControl
                    .frame(width: 44, height: 44)
                    .offset(
                        x: geometry.size.width
                            - ChatComposerMetrics.horizontalEdgeInset
                            - 44,
                        y: geometry.size.height - bottomInset
                    )
            }
            .frame(
                width: geometry.size.width,
                height: geometry.size.height,
                alignment: .topLeading
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("메시지 입력 영역")
        .accessibilityValue(isEditing ? "메시지 편집 중" : "입력 준비")
        .accessibilityIdentifier("chat-composer-surface")
        .chatSendFeedback(trigger: sendFeedback)
    }
#endif

    private var composerLayout: some View {
        composerRow
            // Preserve the measured surface geometry while giving its animated
            // Liquid Glass pixels room on the leading, trailing, and lower
            // edges. The compensating width and lower padding keep every
            // control and visual inset at the same coordinate.
            .padding(.horizontal, ChatComposerMetrics.glassRenderHeadroom)
            .padding(.bottom, ChatComposerMetrics.glassRenderHeadroom)
            .containerRelativeFrame(.horizontal, alignment: .center) {
                availableWidth,
                _ in
                constrainedWidth(for: availableWidth)
                    + ChatComposerMetrics.glassRenderHeadroom * 2
            }
            // Liquid Glass draws slightly beyond its layout bounds while it
            // morphs. Leave rendering headroom so the upper rim is never cut.
            .padding(.top, 16)
            .padding(
                .bottom,
                bottomInset
                    - restingSafeAreaOffset
                    - ChatComposerMetrics.glassRenderHeadroom
            )
#if !os(iOS)
            .animation(
                reduceMotion ? nil : .smooth(duration: 0.24),
                value: isFocused
            )
#endif
    }

    @ViewBuilder
    private var composerRow: some View {
#if os(iOS)
        inputSurface
            .frame(maxWidth: .infinity)
#else
        HStack(alignment: .bottom, spacing: 8) {
            if !isEditing {
                toolsMenu
            }
            inputSurface
        }
        .frame(maxWidth: .infinity)
#endif
    }

    @ViewBuilder
    private var inputSurface: some View {
#if os(iOS)
        iosInputSurface
#else
        HStack(alignment: .bottom, spacing: 0) {
            if isEditing {
                editCancelControl
            }

            messageField
                .padding(.leading, isEditing ? 2 : fieldPadding)
                .padding(.trailing, 2)
                .padding(.vertical, verticalInset)

            if isEditing {
                expansionControl
            }

            sendControl
        }
        .padding(.trailing, 2)
        .frame(minHeight: 44)
        .chatComposerSurface(isInteractive: isEnabled || canUseTools)
        .chatComposerBorder(
            isEmphasized: isFocused && isEnabled,
            isEnabled: isEnabled || canUseTools,
            contrast: colorSchemeContrast
        )
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.2),
            value: isFocused
        )
        .chatSendFeedback(trigger: sendFeedback)
#endif
    }

#if os(iOS)
    private var iosInputSurface: some View {
        // The editor and accessory rail are always open. Focus only presents
        // the native keyboard; it never changes the composer's own structure.
        ZStack(alignment: .bottom) {
            messageField
                .padding(
                    .leading,
                    fieldHorizontalInset
                )
                .padding(
                    .trailing,
                    fieldHorizontalInset
                )
                .padding(
                    .top,
                    fieldTopInset
                )
                .padding(
                    .bottom,
                    ChatComposerMetrics.target
                        + ChatComposerMetrics.railBottomPadding
                        + fieldRailSpacing
                )
                .layoutPriority(1)

            composerControlRail
        }
        .frame(minHeight: ChatComposerMetrics.minimumSurfaceHeight)
        // This is a composite control surface, not one giant button. Let its
        // child controls own press feedback so a control tap never scales the
        // entire composer.
        .chatComposerSurface(isInteractive: false)
        .chatComposerBorder(
            isEmphasized: isFocused && isEnabled,
            isEnabled: isEnabled || canUseTools,
            contrast: colorSchemeContrast
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("메시지 입력 영역")
        .accessibilityValue(isEditing ? "메시지 편집 중" : "입력 준비")
        .accessibilityIdentifier("chat-composer-surface")
        .chatSendFeedback(trigger: sendFeedback)
    }

    private var composerControlRail: some View {
        HStack(spacing: 0) {
            if !isFullscreen {
                if isEditing {
                    editCancelControl
                    editStatus
                } else {
                    toolsMenu
                    modelMenuControl
                    modeMenuControl
                }
            }

            Spacer(minLength: 4)

            if !isFullscreen, showsExpansionControl {
                expansionControl
            }
            sendControl
        }
        .padding(.horizontal, controlRailHorizontalInset)
        .frame(height: ChatComposerMetrics.target)
        .padding(
            .bottom,
            ChatComposerMetrics.railBottomPadding
        )
    }
#endif

    @ViewBuilder
    private var messageField: some View {
#if os(iOS)
        if isFullscreen {
            iosMessageEditor
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
        } else {
            iosMessageEditor
                .frame(
                    height: max(
                        measuredEditorHeight,
                        minimumEditorHeight
                    ),
                    alignment: .bottom
                )
        }
#else
        TextField(
            placeholder,
            text: $draft,
            axis: .vertical
        )
        .lineLimit(minimumEditorLines ... maximumEditorLines)
        .submitLabel(.send)
        .focused(focus)
        .id(editorIdentity)
        .accessibilityIdentifier("chat-composer-field")
        .accessibilityLabel(placeholder)
        .disabled(!isEnabled)
        .onSubmit(submit)
#endif
    }

#if os(iOS)
    private var iosMessageEditor: some View {
        ChatComposerEditor(
            text: $draft,
            measuredHeight: $measuredEditorHeight,
            exceedsExpansionLineLimit: $exceedsExpansionLineLimit,
            focus: focus,
            placeholder: placeholder,
            isEnabled: isEnabled,
            minimumLines: minimumEditorLines,
            maximumLines: maximumEditorLines,
            expansionLineLimit: ChatComposerMetrics.expansionLineLimit,
            fillsAvailableHeight: isFullscreen,
            automaticFocusID: automaticFocusID,
            animatesHeightChanges:
                !reduceMotion && automaticFocusID == nil,
            onSubmit: submit,
            onEndEditing: {
                setSoftwareKeyboardVisible(false)
            }
        )
        .id(editorIdentity)
    }
#endif

    @ViewBuilder
    private var sendControl: some View {
        if isEditing {
            Button(action: submit) {
                editSaveLabel
            }
            .buttonStyle(ChatComposerSendButtonStyle())
            .disabled(!canSubmit)
            .accessibilityLabel(
                isEditSaving ? "편집 저장 중" : "편집 저장"
            )
            .accessibilityHint("수정한 메시지로 새 대화 흐름을 만듭니다")
            .accessibilityIdentifier("chat-composer-edit-save")
        } else if isGenerating {
            Button(action: onCancel) {
                cancelLabel
            }
            .buttonStyle(ChatComposerSendButtonStyle())
            .accessibilityLabel("생성 중지")
            .accessibilityHint("현재 모델 응답 생성을 중단합니다")
            .accessibilityIdentifier("chat-composer-cancel")
        } else {
            Button(action: submit) {
                sendLabel
            }
            .buttonStyle(ChatComposerSendButtonStyle())
            .disabled(!canSubmit)
            .accessibilityLabel("메시지 보내기")
        }
    }

    private var editCancelControl: some View {
        Button(action: onCancelEdit) {
            LorepiaGlyphView(.close, size: 17)
                .frame(
                    width: ChatComposerMetrics.control,
                    height: ChatComposerMetrics.control
                )
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(isEditSaving)
        .accessibilityLabel("편집 취소")
        .accessibilityHint("수정 내용을 버리고 원래 작성 중이던 메시지로 돌아갑니다")
        .accessibilityIdentifier("chat-composer-edit-cancel")
    }

    private var expansionControl: some View {
        Button(action: onToggleExpansion) {
            LorepiaGlyphView(
                isExpanded ? .collapse : .expand,
                size: 18
            )
            .frame(
                width: ChatComposerMetrics.control,
                height: ChatComposerMetrics.control
            )
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(isEditSaving)
        .accessibilityLabel(
            isExpanded
                ? "\(expansionControlName) 축소"
                : "\(expansionControlName) 확대"
        )
        .accessibilityHint(
            expansionControlHint
        )
        .accessibilityIdentifier(expansionControlIdentifier)
    }

    private var editStatus: some View {
        Text(editSaveFailed ? "저장 실패" : "메시지 편집")
            .font(.caption.weight(.medium))
            .foregroundStyle(editSaveFailed ? Color.red : Color.secondary)
            .lineLimit(1)
            .accessibilityIdentifier(
                editSaveFailed
                    ? "chat-message-edit-failure"
                    : "chat-composer-edit-status"
            )
    }

    @ViewBuilder
    private var toolsMenu: some View {
#if os(iOS)
        toolsMenuControl
#else
        toolsMenuControl
            .chatComposerAccessorySurface(isInteractive: canUseTools)
            .chatComposerAccessoryBorder(
                isEnabled: canUseTools,
                contrast: colorSchemeContrast
            )
#endif
    }

    @ViewBuilder
    private var toolsMenuControl: some View {
        Menu {
            Button(action: onOpenConversationSettings) {
                Label(
                    "대화 설정",
                    systemImage: "slider.horizontal.3"
                )
            }
            .accessibilityIdentifier("chat-composer-tools-settings")

            Button(action: onOpenProviderSettings) {
                Label(
                    "프로바이더 설정",
                    systemImage: "gearshape"
                )
            }
            .accessibilityIdentifier(
                "chat-composer-tools-provider-settings"
            )
        } label: {
            toolsControlLabel
        }
        .buttonStyle(.plain)
        .disabled(!canUseTools)
        .accessibilityLabel("추가")
        .accessibilityHint("대화 또는 프로바이더 설정 메뉴를 엽니다")
        .accessibilityIdentifier("chat-composer-tools")
    }

    private var toolsControlLabel: some View {
        LorepiaGlyphView(.plus, size: 18)
            .frame(
                width: ChatComposerMetrics.control,
                height: ChatComposerMetrics.control
            )
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

#if os(iOS)
    private var modelMenuControl: some View {
        Menu {
            if providerProfiles.isEmpty {
                Button("설정된 프로바이더 없음", systemImage: "cpu") {}
                    .disabled(true)
            } else {
                Picker(
                    "앱 전체 기본 모델",
                    selection: providerProfileSelection
                ) {
                    ForEach(providerProfiles) { profile in
                        Label(
                            providerTitle(profile),
                            systemImage: "cpu"
                        )
                            .tag(Optional(profile.id))
                            .accessibilityIdentifier(
                                "chat-composer-model-option-\(profile.id)"
                            )
                    }
                }
                .pickerStyle(.inline)
                .disabled(!canChangeProviderProfile)
            }

            Divider()

            Button(action: onOpenProviderSettings) {
                Label("프로바이더 설정", systemImage: "gearshape")
            }
            .accessibilityIdentifier("chat-composer-provider-settings")
        } label: {
            HStack(spacing: 4) {
                Text(
                    selectedProviderProfile.map(providerTitle)
                        ?? "프로바이더 설정"
                )
                    .lineLimit(1)
                    .truncationMode(.middle)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(maxWidth: 148)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("앱 전체 기본 모델")
        .accessibilityValue(
            selectedProviderProfile.map(providerTitle)
                ?? "선택 안 됨"
        )
        .accessibilityHint("기본 모델을 선택하거나 프로바이더 설정을 엽니다")
        .accessibilityIdentifier("chat-composer-model")
    }

    private var modeMenuControl: some View {
        Menu {
            Picker("응답 방식", selection: modeSelection) {
                ForEach(ConversationMode.allCases) { option in
                    Label(option.title, systemImage: option.systemImage)
                        .tag(option)
                        .accessibilityIdentifier(
                            "chat-composer-mode-option-\(option.rawValue)"
                        )
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: mode.systemImage)
                Text(mode.title)
                    .lineLimit(1)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canChangeMode)
        .accessibilityLabel("응답 방식")
        .accessibilityValue("\(mode.title) 모드")
        .accessibilityHint("채팅과 스토리 응답 방식을 선택합니다")
        .accessibilityIdentifier("chat-composer-mode")
    }

    private var providerProfileSelection: Binding<String?> {
        Binding(
            get: {
                selectedProviderProfileID
            },
            set: { profileID in
                guard
                    let profileID,
                    profileID != selectedProviderProfileID
                else {
                    return
                }
                onProviderProfileChange(profileID)
            }
        )
    }

    private var modeSelection: Binding<ConversationMode> {
        Binding(
            get: {
                mode
            },
            set: { option in
                guard option != mode else {
                    return
                }
                onModeChange(option)
            }
        )
    }
#endif

    private var selectedProviderProfile: ProviderProfile? {
        guard let selectedProviderProfileID else {
            return nil
        }
        return providerProfiles.first {
            $0.id == selectedProviderProfileID
        }
    }

    private func providerTitle(_ profile: ProviderProfile) -> String {
        "\(profile.displayName) · \(profile.model)"
    }

    private var isFocused: Bool {
        focus.wrappedValue
    }

    private var isEditing: Bool {
        editSessionID != nil
    }

    private var showsExpansionControl: Bool {
#if os(iOS)
        !isFullscreen && (isExpanded || exceedsExpansionLineLimit)
#else
        isEditing
#endif
    }

    private var expansionControlName: String {
        isEditing ? "편집창" : "입력창"
    }

    private var expansionControlIdentifier: String {
        let state = isExpanded ? "collapse" : "expand"
        return isEditing
            ? "chat-composer-edit-\(state)"
            : "chat-composer-\(state)"
    }

    private var expansionControlHint: String {
#if os(iOS)
        "전체 화면 입력을 엽니다"
#else
        isExpanded
            ? "입력 영역의 높이를 줄입니다"
            : "입력 영역의 높이를 늘립니다"
#endif
    }

    private var editorIdentity: String {
        let identity =
            editSessionID.map { "edit-\($0.uuidString)" } ?? "compose"
        return isFullscreen ? "fullscreen-\(identity)" : identity
    }

    private var minimumEditorLines: Int {
        guard isExpanded else {
            return 1
        }
#if os(iOS)
        if verticalSizeClass == .compact
            || dynamicTypeSize.isAccessibilitySize
        {
            return 4
        }
#endif
        return 6
    }

    private var maximumEditorLines: Int {
        if isFullscreen {
            return 1_000
        }
        if !isExpanded {
            return ChatComposerMetrics.expansionLineLimit
        }
#if os(iOS)
        if verticalSizeClass == .compact {
            return 6
        }
        if dynamicTypeSize.isAccessibilitySize {
            return 8
        }
        return 10
#else
        return 10
#endif
    }

    private func constrainedWidth(for availableWidth: CGFloat) -> CGFloat {
        let insetWidth = max(
            availableWidth - (horizontalInset(for: availableWidth) * 2),
            0
        )
#if os(iOS)
        // Phone widths remain fluid while the open surface keeps one inset.
        return insetWidth
#else
        return min(insetWidth, 720)
#endif
    }

    private func horizontalInset(for availableWidth: CGFloat) -> CGFloat {
#if os(iOS)
        ChatComposerMetrics.horizontalEdgeInset
#else
        min(max(availableWidth * 0.07, 20), 32)
#endif
    }

    private var controlRailHorizontalInset: CGFloat {
        ChatComposerMetrics.railHorizontalPadding
    }

    private var fieldHorizontalInset: CGFloat {
        ChatComposerMetrics.fieldHorizontalInset
    }

    private var fieldTopInset: CGFloat {
        ChatComposerMetrics.fieldTopInset
    }

    private var fieldRailSpacing: CGFloat {
        ChatComposerMetrics.fieldRailSpacing
    }

    private var bottomInset: CGFloat {
#if os(iOS)
        // The surface structure stays open. Only its platform-owned clearance
        // changes when the native software keyboard actually covers the bottom.
        let visualInset = isSoftwareKeyboardVisible
            ? ChatComposerMetrics.keyboardBottomInset
            : ChatComposerMetrics.restingBottomInset
        return max(
            visualInset - ChatComposerMetrics.glassVerticalInset,
            0
        )
#else
        12
#endif
    }

    private var restingSafeAreaOffset: CGFloat {
#if os(iOS)
        isSoftwareKeyboardVisible ? 0 : max(restingSafeAreaInset, 0)
#else
        0
#endif
    }

    private var verticalInset: CGFloat {
        min(max(scaledVerticalInset, 4), 10)
    }

    private var minimumEditorHeight: CGFloat {
        max(scaledMinimumFieldHeight, 20)
    }

    private var fieldPadding: CGFloat {
        min(max(scaledFieldPadding, 12), 18)
    }

    private var sendLabel: some View {
        ZStack {
            Circle()
                .fill(sendBackgroundStyle)
                .frame(
                    width: primaryActionCircleDiameter,
                    height: primaryActionCircleDiameter
                )

            LorepiaGlyphView(
                .send,
                size: ChatComposerMetrics.control
            )
            .foregroundStyle(sendForegroundStyle)
        }
            .frame(
                width: primaryActionContentDiameter,
                height: primaryActionContentDiameter
            )
            .chatSendGlyphEffect(
                trigger: sendFeedback,
                reduceMotion: reduceMotion
            )
            .animation(
                reduceMotion
                    ? nil
                    : .snappy(duration: 0.2, extraBounce: 0.04),
                value: canSubmit
            )
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }

    private var editSaveLabel: some View {
        ZStack {
            Circle()
                .fill(sendBackgroundStyle)
                .frame(
                    width: primaryActionCircleDiameter,
                    height: primaryActionCircleDiameter
                )

            if isEditSaving {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            } else {
                LorepiaGlyphView(
                    .check,
                    size: ChatComposerMetrics.control * 0.58
                )
                .foregroundStyle(sendForegroundStyle)
            }
        }
        .frame(
            width: primaryActionContentDiameter,
            height: primaryActionContentDiameter
        )
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
    }

    private var cancelLabel: some View {
        Image(systemName: "stop.fill")
            .font(
                .system(
                    size: min(max(scaledSendSymbol, 15), 18),
                    weight: .semibold
                )
            )
            .foregroundStyle(Color.white)
            .frame(
                width:
                    isFullscreen
                        ? ChatComposerMetrics.target
                        : ChatComposerMetrics.control,
                height:
                    isFullscreen
                        ? ChatComposerMetrics.target
                        : ChatComposerMetrics.control
            )
            .background(LorepiaColor.ember, in: Circle())
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }

    private var primaryActionCircleDiameter: CGFloat {
        isFullscreen
            ? ChatComposerMetrics.target
            : ChatComposerMetrics.control * 22 / 24
    }

    private var primaryActionContentDiameter: CGFloat {
        max(ChatComposerMetrics.control, primaryActionCircleDiameter)
    }

    private var sendForegroundStyle: Color {
        guard canSubmit else {
            return Color.primary.opacity(
                colorSchemeContrast == .increased ? 0.62 : 0.34
            )
        }
        return .white
    }

    private var sendBackgroundStyle: AnyShapeStyle {
        if canSubmit {
            return AnyShapeStyle(Color.black)
        }
        return AnyShapeStyle(
            Color.primary.opacity(
                colorSchemeContrast == .increased ? 0.14 : 0.07
            )
        )
    }

#if os(iOS)
    @MainActor
    private func updateKeyboardVisibility(from notification: Notification) {
        guard
            let frame = notification.userInfo?[
                UIResponder.keyboardFrameEndUserInfoKey
            ] as? CGRect,
            let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows)
                .first(where: \.isKeyWindow)
        else {
            return
        }

        let frameInWindow = window.convert(
            frame,
            from: window.screen.coordinateSpace
        )
        let overlap = window.bounds.intersection(frameInWindow)
        let coversWindowBottom =
            abs(frameInWindow.maxY - window.bounds.maxY) <= 2
        setSoftwareKeyboardVisible(
            !overlap.isNull
                && overlap.height > 0
                && coversWindowBottom
        )
    }

    @MainActor
    private func setSoftwareKeyboardVisible(_ visible: Bool) {
        // A hide transition from a previous dismissal can finish after the
        // field has already been focused again. Let the current focus request
        // win so that stale keyboard notifications cannot drop the composer.
        if !visible && isFocused {
            return
        }
        isSoftwareKeyboardVisible = visible
    }
#endif

    private func submit() {
        guard canSubmit else {
            return
        }
        sendFeedback &+= 1
        onSubmit()
    }
}

private struct ChatBubble: View {
    let message: ChatMessage
    let maximumWidth: CGFloat
    let storyMaximumWidth: CGFloat
    let mode: ConversationMode
    let sender: ChatParticipantIdentity?
    let showsSenderIdentity: Bool
    let senderAvatarSize: CGFloat
    var highlight: String = ""
    var isActiveMatch = false

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    @ScaledMetric(relativeTo: .body) private var scaledHorizontalPadding = 14
    @ScaledMetric(relativeTo: .body) private var scaledVerticalPadding = 7
    @ScaledMetric(relativeTo: .body) private var scaledStoryLineSpacing = 5
    @ScaledMetric(relativeTo: .body) private var scaledStoryVerticalPadding =
        LorepiaSpacing.compact
    @ScaledMetric(relativeTo: .caption2) private var scaledTimestampDrop = 1

    var body: some View {
        Group {
            if message.role == .system || message.role == .notice {
                notice
            } else if isStoryProse {
                storyProse
            } else if isStoryUserLine {
                storyUserLine
            } else {
                bubble
            }
        }
    }

    /// The message text with its timestamp riding at the end of the last line.
    ///
    /// The stamp is concatenated a second time as a clear run so the layout
    /// engine reserves exactly its width: it stays on the last line when there
    /// is room and drops to a line of its own when there is not. The visible
    /// stamp is then overlaid on that reserved space.
    @ViewBuilder
    private var bubbleBody: some View {
        let text = Text(highlightedText)
            .font(.body)

        if let timeLabel {
            (
                text
                    + Text("\u{2005}\u{2005}")
                    + Text(timeLabel)
                        .font(.caption2)
                        .foregroundStyle(.clear)
            )
            // Selection is deliberately off inside bubbles: it claims the
            // long press the action row is opened with, and copying whole
            // messages is what that row is for.
            .overlay(alignment: .bottomTrailing) {
                Text(timeLabel)
                    .font(.caption2)
                    .foregroundStyle(timestampStyle)
                    // Riding a few points below the last baseline lets the
                    // stamp sit in the bubble's bottom inset, so it reads as
                    // metadata rather than as the tail of the sentence.
                    .offset(y: scaledTimestampDrop)
                    .accessibilityHidden(true)
            }
        } else {
            text
        }
    }

    /// The message text with search hits marked.
    ///
    /// The bubble the search has landed on burns brighter than the rest, so
    /// stepping through results is legible without moving anything.
    private var highlightedText: AttributedString {
        highlightedText(in: message.text.isEmpty ? "…" : message.text)
    }

    private func highlightedText(in source: String) -> AttributedString {
        guard !highlight.isEmpty else {
            return AttributedString(source)
        }

        var result = AttributedString()
        var remainder = Substring(source)
        while let hit = remainder.range(
            of: highlight,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) {
            result += AttributedString(remainder[..<hit.lowerBound])
            var marked = AttributedString(remainder[hit])
            // The landed-on hit takes a solid band; both sides keep dark text,
            // which reads over either bubble fill.
            marked.backgroundColor = LorepiaColor.highlight
                .opacity(isActiveMatch ? 1 : 0.4)
            if isActiveMatch {
                marked.foregroundColor = .black
            }
            result += marked
            remainder = remainder[hit.upperBound...]
        }
        result += AttributedString(remainder)
        return result
    }

    /// Only settled messages carry a time. A streaming reply has no send time
    /// yet, and its status line already says what it is doing.
    private var timeLabel: String? {
        guard message.status == .complete,
              let date = ChatTimeline.date(from: message.createdAt)
        else {
            return nil
        }
        return date.formatted(.dateTime.hour().minute())
    }

    private var timestampStyle: Color {
        .secondary
    }

    private var isStoryProse: Bool {
        mode == .story && message.role == .assistant
    }

    private var isStoryUserLine: Bool {
        mode == .story && message.role == .user
    }

    @ViewBuilder
    private var bubble: some View {
        if let sender {
            participantBubble(sender)
        } else {
            standaloneBubble
        }
    }

    private func participantBubble(
        _ sender: ChatParticipantIdentity
    ) -> some View {
        HStack(alignment: .top, spacing: ChatParticipantLayout.spacing) {
            if message.role == .user {
                Spacer(minLength: 0)
            } else {
                participantAvatar(sender)
            }

            VStack(alignment: participantAlignment, spacing: 4) {
                if showsSenderIdentity {
                    Text(sender.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityIdentifier(
                            "chat-sender-name-\(message.role.rawValue)-\(message.id)"
                        )
                }

                bubbleSurface
            }
            .frame(maxWidth: maximumWidth, alignment: alignment)

            if message.role == .user {
                participantAvatar(sender)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var standaloneBubble: some View {
        HStack(spacing: 0) {
            if message.role == .user {
                Spacer(minLength: 0)
            }

            bubbleSurface

            if message.role != .user {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var bubbleSurface: some View {
        VStack(alignment: .leading, spacing: 4) {
            bubbleBody
            if message.status != .complete {
                Text(statusText)
                    .font(.caption2)
                    .opacity(0.75)
            }
        }
        .padding(.horizontal, horizontalPadding)
        // Korean glyphs sit low in the line box, so equal padding leaves the
        // ink noticeably higher than it looks. The two halves are shifted
        // until the gaps above and below the text read the same.
        .padding(.top, verticalPadding - lineBoxOpticalShift)
        .padding(.bottom, verticalPadding + lineBoxOpticalShift)
        .foregroundStyle(foregroundStyle)
        .background(backgroundStyle, in: bubbleShape)
        .frame(maxWidth: maximumWidth, alignment: alignment)
    }

    @ViewBuilder
    private func participantAvatar(
        _ sender: ChatParticipantIdentity
    ) -> some View {
        if showsSenderIdentity {
            LorepiaAvatar(
                symbolName: sender.symbolName,
                size: senderAvatarSize,
                name: sender.displayName
            )
            .accessibilityIdentifier(
                "chat-sender-avatar-\(message.role.rawValue)-\(message.id)"
            )
        } else {
            Color.clear
                .frame(width: senderAvatarSize, height: senderAvatarSize)
                .accessibilityHidden(true)
        }
    }

    private var participantAlignment: HorizontalAlignment {
        message.role == .user ? .trailing : .leading
    }

    private var storyProse: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(highlightedText)
                .font(.system(.body, design: .serif))
                .lineSpacing(scaledStoryLineSpacing)
                .textSelection(.enabled)

            if message.status != .complete {
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.primary)
        .padding(.vertical, scaledStoryVerticalPadding)
        .frame(width: storyMaximumWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// The reader's own story entry keeps the accent text color while sharing
    /// the same leading rail as the profile, prose, and action row.
    private var storyUserLine: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(highlightedText)
                .font(.system(.body, design: .serif))
                .lineSpacing(scaledStoryLineSpacing)
                .foregroundStyle(LorepiaColor.loreAccent)
                .textSelection(.enabled)

            if message.status != .complete {
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, scaledStoryVerticalPadding)
        .frame(width: storyMaximumWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var notice: some View {
        Text(
            highlightedText(
                in: message.text.isEmpty ? statusText : message.text
            )
        )
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding / 2)
            .background(
                ChatSurface.incomingMessage,
                in: Capsule()
            )
            .frame(maxWidth: maximumWidth)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(accessibilityText)
    }

    private var alignment: Alignment {
        message.role == .user ? .trailing : .leading
    }

    private var bubbleShape: ChatBubbleShape {
        ChatBubbleShape(
            isOutgoing: message.role == .user
        )
    }

    private var horizontalPadding: CGFloat {
        min(max(scaledHorizontalPadding, 12), 20)
    }

    /// Half the measured gap between the ink's top and bottom margins.
    ///
    /// The stamp is the lowest ink in the bubble, so the bottom carries a
    /// little extra to keep its margin level with the text's at the top.
    private var lineBoxOpticalShift: CGFloat {
        1.0
    }

    private var verticalPadding: CGFloat {
        min(max(scaledVerticalPadding, 7), 16)
    }

    /// Both sides read as body text.
    ///
    /// The reply is what gets read; the reader's own line only has to be
    /// found again. Neither is worth spending legibility on white-on-colour.
    private var foregroundStyle: Color {
        .primary
    }

    private var backgroundStyle: Color {
        message.role == .user
            ? LorepiaColor.outgoingFill
            : ChatSurface.incomingMessage
    }

    private var statusText: String {
        switch message.status {
        case .pending:
            "생성 중"
        case .cancelled:
            "취소됨"
        case .failed:
            "실패"
        case .complete:
            "완료"
        case .notice:
            "안내"
        }
    }

    private var accessibilityText: String {
        let speaker = switch message.role {
        case .user:
            sender?.displayName ?? "나"
        case .assistant:
            sender?.displayName ?? "캐릭터"
        case .system:
            "시스템"
        case .notice:
            "안내"
        }
        let status = message.status == .complete ? "" : ", \(statusText)"
        let timestamp =
            mode != .story
                && (message.role == .user || message.role == .assistant)
                ? timeLabel.map { ", \($0)" } ?? ""
                : ""
        return "\(speaker): \(message.text)\(status)\(timestamp)"
    }

}

struct ChatBubbleShape: Shape {
    struct CornerRadii: Equatable {
        let topLeading: CGFloat
        let bottomLeading: CGFloat
        let bottomTrailing: CGFloat
        let topTrailing: CGFloat
    }

    let isOutgoing: Bool

    func path(in rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0 else {
            return Path()
        }

        let radii = resolvedRadii(in: rect)
        return UnevenRoundedRectangle(
            topLeadingRadius: radii.topLeading,
            bottomLeadingRadius: radii.bottomLeading,
            bottomTrailingRadius: radii.bottomTrailing,
            topTrailingRadius: radii.topTrailing,
            style: .continuous
        )
        .path(in: rect)
    }

    func resolvedRadii(in rect: CGRect) -> CornerRadii {
        let largeRadius = min(18, rect.width / 2, rect.height / 2)
        let tightRadius = min(4, largeRadius)

        if isOutgoing {
            return CornerRadii(
                topLeading: largeRadius,
                bottomLeading: largeRadius,
                bottomTrailing: tightRadius,
                topTrailing: largeRadius
            )
        }

        return CornerRadii(
            topLeading: tightRadius,
            bottomLeading: largeRadius,
            bottomTrailing: largeRadius,
            topTrailing: largeRadius
        )
    }
}

private struct ChatMessageInsertionModifier: ViewModifier {
    let role: ChatMessage.Role
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isActive ? 0 : 1)
            .blur(radius: isActive ? 2.5 : 0)
            .scaleEffect(
                isActive ? scale : 1,
                anchor: anchor
            )
            .offset(
                x: isActive ? horizontalOffset : 0,
                y: isActive ? verticalOffset : 0
            )
    }

    private var anchor: UnitPoint {
        role == .user ? .bottomTrailing : .bottomLeading
    }

    private var scale: CGFloat {
        switch role {
        case .user:
            0.82
        case .assistant:
            0.92
        case .system, .notice:
            0.98
        }
    }

    private var horizontalOffset: CGFloat {
        switch role {
        case .user:
            14
        case .assistant:
            -8
        case .system, .notice:
            0
        }
    }

    private var verticalOffset: CGFloat {
        switch role {
        case .user:
            24
        case .assistant:
            14
        case .system, .notice:
            6
        }
    }
}

private struct ChatComposerSendButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(
                reduceMotion
                    ? 1
                    : (configuration.isPressed ? 0.86 : 1)
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(
                reduceMotion
                    ? nil
                    : .spring(duration: 0.18, bounce: 0.24),
                value: configuration.isPressed
            )
    }
}

private struct ChatScrollState: Equatable {
    let count: Int
    let lastID: String?
    let lastTextLength: Int
    let lastRole: ChatMessage.Role?
}

private struct ChatBottomObservation: Equatable {
    let scrollState: ChatScrollState
    let viewportSize: CGSize
    let contentSize: CGSize
}

private enum ChatScrollAnchor {
    static let bottom = "chat-bottom-anchor"
}

private enum ChatCoordinateSpace {
    static let name = "chat-scroll-coordinate-space"
}

private enum ChatSurface {
    /// The reading canvas the palette defines, on both platforms. iOS used to
    /// substitute `systemBackground` here, which quietly discarded the warm
    /// page the design system was built around.
    static var background: Color {
        LorepiaColor.paper
    }

    /// One value on both platforms now that the palette carries the same
    /// neutral the system gray was standing in for.
    static var incomingMessage: Color {
        LorepiaColor.incomingFill
    }
}

private struct ChatLayoutMetrics: Equatable {
    let bottomY: CGFloat
    let contentSize: CGSize
}

private struct ChatLayoutPreferenceKey: PreferenceKey {
    static let defaultValue = ChatLayoutMetrics(
        bottomY: .greatestFiniteMagnitude,
        contentSize: .zero
    )

    static func reduce(
        value: inout ChatLayoutMetrics,
        nextValue: () -> ChatLayoutMetrics
    ) {
        value = nextValue()
    }
}

/// Keeps the measured Liquid Glass surface around its 44 pt hit targets.
private struct ChatComposerFieldGlassShape: Shape {
    func path(in rect: CGRect) -> Path {
        let visualRect = rect.insetBy(
            dx: 0,
            dy: ChatComposerMetrics.glassVerticalInset
        )
        return RoundedRectangle(
            cornerRadius: min(
                ChatComposerMetrics.cornerRadius,
                visualRect.height / 2
            ),
            style: .continuous
        )
        .path(in: visualRect)
    }
}

/// Messages left-aligns a 40 pt glass circle inside its 44 pt tool target.
private struct ChatComposerAccessoryGlassShape: Shape {
    func path(in rect: CGRect) -> Path {
        let diameter = max(min(rect.width, rect.height) - 4, 0)
        let visualRect = CGRect(
            x: rect.minX,
            y: rect.midY - (diameter / 2),
            width: diameter,
            height: diameter
        )
        return Circle().path(in: visualRect)
    }
}

private extension View {
    @ViewBuilder
    func chatDefaultBottomAnchor() -> some View {
#if os(iOS)
        if #available(iOS 18.0, *) {
            defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .defaultScrollAnchor(.bottom, for: .alignment)
        } else {
            self
        }
#else
        self
#endif
    }

    @ViewBuilder
    func chatDetailPlatformChrome() -> some View {
#if os(iOS)
        toolbar(.hidden, for: .tabBar)
#else
        self
#endif
    }

    /// Names the room in the navigation bar. macOS keeps its principal
    /// identity view, where the window title is already spoken for.
    @ViewBuilder
    func chatRoomTitle(name: String?) -> some View {
#if os(iOS)
        navigationTitle(name ?? "")
#else
        self
#endif
    }

    @ViewBuilder
    func chatInteractiveKeyboardDismissal() -> some View {
#if os(iOS)
        scrollDismissesKeyboard(.interactively)
#else
        self
#endif
    }

    /// iOS 26 owns the complete minimized toolbar-search transition. Older
    /// iOS releases request the navigation bar's principal section. macOS
    /// keeps its existing platform-default searchable presentation.
    @ViewBuilder
    func chatConversationSearch(
        text: Binding<String>,
        isPresented: Binding<Bool>,
        isAvailable: Bool
    ) -> some View {
#if os(iOS)
        if isAvailable {
#if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                searchable(
                    text: text,
                    isPresented: isPresented,
                    placement: .toolbar,
                    prompt: Text("대화 내 검색")
                )
                .searchToolbarBehavior(.minimize)
            } else {
                searchable(
                    text: text,
                    isPresented: isPresented,
                    placement: .toolbarPrincipal,
                    prompt: Text("대화 내 검색")
                )
            }
#else
            searchable(
                text: text,
                isPresented: isPresented,
                placement: .toolbarPrincipal,
                prompt: Text("대화 내 검색")
            )
#endif
        } else {
            self
        }
#else
        searchable(
            text: text,
            isPresented: isPresented,
            prompt: Text("대화 내 검색")
        )
#endif
    }

    /// Layout preferences also move during initial anchoring, keyboard
    /// changes, and message insertion. Only a real scroll phase (or the
    /// platform fallback drag) may reveal the floating day marker.
    @ViewBuilder
    func chatScrollActivity(
        onChange: @escaping (Bool) -> Void
    ) -> some View {
#if os(iOS)
        if #available(iOS 18.0, *) {
            onScrollPhaseChange { _, phase in
                onChange(phase.isScrolling)
            }
        } else {
            simultaneousGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { _ in onChange(true) }
                    .onEnded { _ in onChange(false) }
            )
        }
#elseif os(macOS)
        if #available(macOS 15.0, *) {
            onScrollPhaseChange { _, phase in
                onChange(phase.isScrolling)
            }
        } else {
            simultaneousGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { _ in onChange(true) }
                    .onEnded { _ in onChange(false) }
            )
        }
#else
        self
#endif
    }

    @ViewBuilder
    func chatComposerSurface(isInteractive: Bool) -> some View {
#if os(iOS)
#if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            glassEffect(
                .regular.interactive(isInteractive),
                in: ChatComposerFieldGlassShape()
            )
        } else {
            background(
                .regularMaterial,
                in: ChatComposerFieldGlassShape()
            )
        }
#else
        background(
            .regularMaterial,
            in: ChatComposerFieldGlassShape()
        )
#endif
#else
        background(
            .regularMaterial,
            in: ChatComposerFieldGlassShape()
        )
#endif
    }

    @ViewBuilder
    func chatSearchStepSurface(isInteractive: Bool) -> some View {
#if os(iOS) && compiler(>=6.2)
        if #available(iOS 26.0, *) {
            glassEffect(
                .regular.interactive(isInteractive),
                in: Circle()
            )
        } else {
            background(.regularMaterial, in: Circle())
        }
#else
        background(.regularMaterial, in: Circle())
#endif
    }

    @ViewBuilder
    func chatComposerAccessorySurface(isInteractive: Bool) -> some View {
#if os(iOS)
#if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            glassEffect(
                .regular.interactive(isInteractive),
                in: ChatComposerAccessoryGlassShape()
            )
        } else {
            background(
                .regularMaterial,
                in: ChatComposerAccessoryGlassShape()
            )
        }
#else
        background(.regularMaterial, in: ChatComposerAccessoryGlassShape())
#endif
#else
        background(.regularMaterial, in: ChatComposerAccessoryGlassShape())
#endif
    }

    @ViewBuilder
    func chatContactHeaderSurface(isInteractive: Bool) -> some View {
#if os(iOS)
#if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            glassEffect(
                .regular.interactive(isInteractive),
                in: Capsule()
            )
        } else {
            background(.regularMaterial, in: Capsule())
        }
#else
        background(.regularMaterial, in: Capsule())
#endif
#else
        background(.regularMaterial, in: Capsule())
#endif
    }

    @ViewBuilder
    func chatComposerAccessoryBorder(
        isEnabled: Bool,
        contrast: ColorSchemeContrast
    ) -> some View {
#if os(iOS) && compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self
        } else {
            overlay {
                ChatComposerAccessoryGlassShape()
                    .stroke(
                        Color.primary.opacity(
                            contrast == .increased
                                ? 0.2
                                : (isEnabled ? 0.08 : 0.04)
                        ),
                        lineWidth: contrast == .increased ? 1 : 0.5
                    )
            }
        }
#else
        overlay {
            ChatComposerAccessoryGlassShape()
                .stroke(
                    Color.primary.opacity(
                        contrast == .increased
                            ? 0.2
                            : (isEnabled ? 0.08 : 0.04)
                    ),
                    lineWidth: contrast == .increased ? 1 : 0.5
                )
        }
#endif
    }

    /// Draws a hairline around the composer only where the platform needs one.
    ///
    /// Liquid Glass already reads as a container, and the guidance is to avoid
    /// custom borders on it, so the stroke is limited to older releases.
    @ViewBuilder
    func chatComposerBorder(
        isEmphasized: Bool,
        isEnabled: Bool,
        contrast: ColorSchemeContrast
    ) -> some View {
#if os(iOS) && compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self
        } else {
            chatComposerStroke(
                isEmphasized: isEmphasized,
                isEnabled: isEnabled,
                contrast: contrast
            )
        }
#else
        chatComposerStroke(
            isEmphasized: isEmphasized,
            isEnabled: isEnabled,
            contrast: contrast
        )
#endif
    }

    func chatComposerStroke(
        isEmphasized: Bool,
        isEnabled: Bool,
        contrast: ColorSchemeContrast
    ) -> some View {
        let opacity: Double = if contrast == .increased {
            0.24
        } else if isEmphasized {
            0.16
        } else {
            isEnabled ? 0.08 : 0.04
        }
        return overlay {
            ChatComposerFieldGlassShape()
            .stroke(
                Color.primary.opacity(opacity),
                lineWidth: contrast == .increased ? 1 : 0.5
            )
        }
    }

    @ViewBuilder
    func chatSendGlyphEffect(
        trigger: Int,
        reduceMotion: Bool
    ) -> some View {
        if reduceMotion {
            self
        } else {
            phaseAnimator(
                [false, true, false],
                trigger: trigger
            ) { content, isLifted in
                content
                    .scaleEffect(isLifted ? 0.84 : 1)
                    .offset(y: isLifted ? -1.5 : 0)
            } animation: { isLifted in
                isLifted
                    ? .easeOut(duration: 0.08)
                    : .snappy(
                        duration: 0.2,
                        extraBounce: 0.08
                    )
            }
        }
    }

    @ViewBuilder
    func chatSendFeedback(trigger: Int) -> some View {
#if os(iOS)
        sensoryFeedback(
            .impact(weight: .light, intensity: 0.65),
            trigger: trigger
        )
#else
        self
#endif
    }

    @ViewBuilder
    func chatCopyFeedback(trigger: Int) -> some View {
#if os(iOS)
        sensoryFeedback(.success, trigger: trigger)
#else
        self
#endif
    }
}
