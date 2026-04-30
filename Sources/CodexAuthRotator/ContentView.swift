import AppKit
import CodexAuthRotatorCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("codexAuthRotator.sidebarVisible") private var isSidebarVisible = true
    @AppStorage("codexAuthRotator.sidebarViewMode") private var sidebarViewModeRawValue = SidebarViewMode.cards.rawValue
    @AppStorage("codexAuthRotator.compactSidebarSort") private var compactSidebarSortRawValue = CompactSidebarSort.nameAscending.rawValue
    @AppStorage("codexAuthRotator.compactSidebarUsageDisplay") private var compactSidebarUsageDisplayRawValue = CompactSidebarUsageDisplay.remaining.rawValue
    @AppStorage("codexAuthRotator.separateFullyUsedSidebarAccounts") private var separateFullyUsedSidebarAccounts = true
    @AppStorage(AppPreferenceKey.splitWeeklyLeftByPlanType) private var splitWeeklyLeftByPlanType = false
    @AppStorage("codexAuthRotator.topControlsRowMode") private var topControlsRowModeRawValue = TopControlsRowMode.automatic.rawValue
    @AppStorage("codexAuthRotator.topControlsExpandedWhenSidebarOpen") private var topControlsExpandedWhenSidebarOpen = false
    @State private var pendingSwitchGroup: DuplicateGroup?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isShowingWarningsPopover = false
    @State private var isShowingAccountUsageReturnMenu = false
    @State private var isShowingUsageQueuePopover = false
    @State private var isShowingFiveHourStartQueuePopover = false
    @State private var selectedSidebarGroupIDs = Set<String>()
    @State private var usageQueueSelection = Set<String>()
    @State private var fiveHourStartQueueSelection = Set<String>()
    @State private var sidebarEmailSearchText = ""
    @State private var sidebarSearchFocusTrigger = 0
    @State private var topControlsWidth: CGFloat = 960

    private enum TopControlsLabelMode {
        case full
        case short
        case iconOnly
    }

    private enum TopControlEmphasis {
        case standard
        case prominent
    }

    private enum CompactSidebarColumnLayout {
        static let usageWidth: CGFloat = 72
        static let resetWidth: CGFloat = 112
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarList
                .navigationSplitViewColumnWidth(
                    min: MainWindowLayout.sidebarMinimumWidth,
                    ideal: MainWindowLayout.sidebarIdealWidth,
                    max: MainWindowLayout.sidebarMaximumWidth
                )
        } detail: {
            VStack(spacing: 0) {
                topControlsBar
                newAccountSignInStatusBar

                if let group = selectedSidebarGroup {
                    detailView(for: group)
                } else if isSidebarSearchActive, !store.groups.isEmpty {
                    ContentUnavailableView(
                        "No Matching Accounts",
                        systemImage: "magnifyingglass",
                        description: Text("Try a different email fragment.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        "No Accounts Found",
                        systemImage: "tray",
                        description: Text("Point the app at your auth folder and it will pull the saved accounts into one place.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear {
            setSidebarVisible(isSidebarVisible, animated: false)
            syncSidebarSelectionFromStoreIfNeeded()
        }
        .onChange(of: columnVisibility) { _, newValue in
            isSidebarVisible = newValue != .detailOnly
        }
        .onChange(of: selectedSidebarGroupIDs) { oldValue, newValue in
            let primaryGroupID = SidebarSelectionCoordinator.primaryGroupID(
                for: newValue,
                previousSelection: oldValue,
                currentPrimaryGroupID: store.selectedGroupID,
                orderedGroupIDs: sidebarGroupsInDisplayOrder.map(\.id)
            )
            if primaryGroupID == nil, isSidebarSearchActive {
                return
            }
            store.selectedGroupID = primaryGroupID
        }
        .onChange(of: store.selectedGroupID) { _, _ in
            syncSidebarSelectionFromStoreIfNeeded()
        }
        .onChange(of: splitWeeklyLeftByPlanType) { _, newValue in
            store.setSuggestedGroupKindPreferenceEnabled(newValue)
        }
        .onChange(of: sidebarGroupsInDisplayOrder.map(\.id)) { _, _ in
            reconcileSidebarSelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusAccountSearch)) { _ in
            focusAccountSearch()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { _ in
            toggleSidebar()
        }
        .background {
            WindowStateRestorer(
                frameAutosaveName: NSWindow.FrameAutosaveName(MainWindowLayout.autosaveName),
                splitViewAutosaveName: NSSplitView.AutosaveName(MainWindowLayout.splitViewAutosaveName),
                minimumSize: CGSize(
                    width: MainWindowLayout.minimumWidth,
                    height: MainWindowLayout.minimumHeight
                )
            )
        }
        .alert("Switch Account?", isPresented: Binding(
            get: { pendingSwitchGroup != nil },
            set: { if !$0 { pendingSwitchGroup = nil } }
        )) {
            Button("Cancel", role: .cancel) {
                pendingSwitchGroup = nil
            }
            Button("Switch") {
                if let pendingSwitchGroup {
                    Task {
                        await store.switchToGroup(pendingSwitchGroup)
                    }
                    self.pendingSwitchGroup = nil
                }
            }
        } message: {
            if let pendingSwitchGroup {
                Text("Codex and CodexBar will be closed if they are open, your active auth file will be swapped, and only the apps that were running will be reopened.")
                    .bold()
                + Text("\n\nTarget: \(pendingSwitchGroup.primaryRecord.identity.name)")
                + Text(" • \(pendingSwitchGroup.primaryRecord.identity.useLabel ?? "No use label")")
            }
        }
    }

    private var sidebarList: some View {
        List(selection: $selectedSidebarGroupIDs) {
            switch sidebarListPresentation {
            case .searchResults(let groups):
                ForEach(groups) { group in
                    sidebarRowView(for: group)
                        .tag(group.id)
                }
            case .sectioned(let sections):
                Section {
                    headerPanel
                        .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 8, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }

                if !sections.primaryGroups.isEmpty || (sections.fiveHourUsedGroups.isEmpty && sections.fullyUsedGroups.isEmpty) {
                    Section {
                        if sidebarViewMode == .compact {
                            compactSectionHeader()
                                .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }

                        ForEach(sections.primaryGroups) { group in
                            sidebarRowView(for: group)
                                .tag(group.id)
                        }
                    } header: {
                        if sidebarViewMode != .compact {
                            EmptyView()
                        }
                    }
                }

                if !sections.fiveHourUsedGroups.isEmpty {
                    Section {
                        if sidebarViewMode == .compact {
                            compactSectionHeader(title: "5-Hour Used Up")
                                .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }

                        ForEach(sections.fiveHourUsedGroups) { group in
                            sidebarRowView(for: group)
                                .tag(group.id)
                        }
                    } header: {
                        if sidebarViewMode != .compact {
                            sidebarFiveHourUsedSectionHeader
                        }
                    }
                }

                if !sections.fullyUsedGroups.isEmpty {
                    Section {
                        if sidebarViewMode == .compact {
                            compactSectionHeader(title: "Used Up")
                                .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }

                        ForEach(sections.fullyUsedGroups) { group in
                            sidebarRowView(for: group)
                                .tag(group.id)
                        }
                    } header: {
                        if sidebarViewMode != .compact {
                            sidebarFullyUsedSectionHeader
                        }
                    }
                }

                if !store.unbackedEmailFolders.isEmpty {
                    Section {
                        ForEach(store.unbackedEmailFolders) { folder in
                            unbackedEmailFolderRow(folder)
                                .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                    } header: {
                        sidebarUnbackedEmailFoldersSectionHeader
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            sidebarSearchBar
        }
    }

    private var sidebarSearchBar: some View {
        VStack(spacing: 0) {
            SidebarSearchField(
                text: $sidebarEmailSearchText,
                focusTrigger: sidebarSearchFocusTrigger,
                placeholder: "Search email"
            )
            .frame(height: 28)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()
        }
        .background(.regularMaterial)
    }

    private var sidebarViewMode: SidebarViewMode {
        get { SidebarViewMode(rawValue: sidebarViewModeRawValue) ?? .cards }
        nonmutating set { sidebarViewModeRawValue = newValue.rawValue }
    }

    private var compactSidebarSort: CompactSidebarSort {
        CompactSidebarSort(rawValue: compactSidebarSortRawValue) ?? .nameAscending
    }

    private var compactSidebarUsageDisplay: CompactSidebarUsageDisplay {
        get { CompactSidebarUsageDisplay(rawValue: compactSidebarUsageDisplayRawValue) ?? .remaining }
        nonmutating set { compactSidebarUsageDisplayRawValue = newValue.rawValue }
    }

    private var topControlsRowMode: TopControlsRowMode {
        get { TopControlsRowMode(rawValue: topControlsRowModeRawValue) ?? .automatic }
        nonmutating set { topControlsRowModeRawValue = newValue.rawValue }
    }

    private var topControlsCount: Int {
        sidebarViewMode == .compact ? 12 : 10
    }

    private var isSidebarOpen: Bool {
        columnVisibility != .detailOnly
    }

    private var isTopControlsExpanded: Bool {
        isSidebarOpen && topControlsExpandedWhenSidebarOpen
    }

    private var topControlsBar: some View {
        let resolvedRows = resolvedTopControlsRowCount(for: topControlsWidth)
        let labelMode = isTopControlsExpanded
            ? TopControlsLabelMode.full
            : topControlsLabelMode(
                for: topControlsWidth,
                rows: resolvedRows,
                controlCount: topControlsCount
            )

        return Group {
            if !isTopControlsExpanded && resolvedRows == 1 {
                HStack(alignment: .top, spacing: 12) {
                    topControlsPrimaryCluster(labelMode: labelMode)
                    topControlsSecondaryCluster(labelMode: labelMode)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    topControlsPrimaryCluster(labelMode: labelMode)
                    topControlsSecondaryCluster(labelMode: labelMode)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        topControlsWidth = proxy.size.width
                    }
                    .onChange(of: proxy.size.width) { _, newValue in
                        topControlsWidth = newValue
                    }
            }
        }
    }

    private func focusAccountSearch() {
        setSidebarVisible(true, animated: true)
        sidebarSearchFocusTrigger += 1
    }

    private func topControlsPrimaryCluster(labelMode: TopControlsLabelMode) -> some View {
        topControlsCluster(accent: .accentColor) {
            topControlButton(
                title: "Toggle Sidebar",
                shortTitle: "Sidebar",
                systemImage: "sidebar.leading",
                labelMode: labelMode
            ) {
                toggleSidebar()
            }

            topControlButton(
                title: "Choose Folder",
                shortTitle: "Folder",
                systemImage: "folder",
                labelMode: labelMode
            ) {
                store.chooseAuthRoot()
            }

            topControlButton(
                title: sidebarViewMode == .cards ? "Compact View" : "Card View",
                shortTitle: sidebarViewMode == .cards ? "Compact" : "Cards",
                systemImage: sidebarViewMode.systemImage,
                labelMode: labelMode
            ) {
                sidebarViewMode = sidebarViewMode == .cards ? .compact : .cards
            }

            topControlButton(
                title: "Populate Storage",
                shortTitle: "Populate",
                systemImage: store.populateStorageFolderEnabled ? "square.stack.3d.up.fill" : "square.stack.3d.up",
                labelMode: labelMode
            ) {
                store.setPopulateStorageFolderEnabled(!store.populateStorageFolderEnabled)
            }

            newAccountSignInButton(labelMode: labelMode)

            topControlHelpIfNeeded(
                styledTopControl(
                    Button {
                        Task {
                            await store.refresh(manual: true)
                        }
                    } label: {
                        topControlsRefreshLabel(labelMode: labelMode)
                    },
                    emphasis: .prominent
                )
                .disabled(store.isRefreshing || store.isSwitching),
                title: "Refresh Now",
                labelMode: labelMode
            )
        }
    }

    private func topControlsSecondaryCluster(labelMode: TopControlsLabelMode) -> some View {
        topControlsCluster {
            usageQueueButton(labelMode: labelMode)
            fiveHourStartQueueButton(labelMode: labelMode)

            if sidebarViewMode == .compact {
                topControlMenu(
                    title: "Sort Accounts",
                    shortTitle: "Sort",
                    systemImage: "arrow.up.arrow.down",
                    labelMode: labelMode
                ) {
                    Picker("Sort", selection: $compactSidebarSortRawValue) {
                        ForEach(CompactSidebarSort.allCases, id: \.rawValue) { sort in
                            Text(sort.label)
                                .tag(sort.rawValue)
                        }
                    }
                }

                topControlMenu(
                    title: "Usage: \(compactSidebarUsageDisplay.shortLabel)",
                    shortTitle: "Usage \(compactSidebarUsageDisplay.shortLabel)",
                    systemImage: "percent",
                    labelMode: labelMode
                ) {
                    Picker("Usage", selection: Binding(
                        get: { compactSidebarUsageDisplay },
                        set: { compactSidebarUsageDisplay = $0 }
                    )) {
                        ForEach(CompactSidebarUsageDisplay.allCases, id: \.rawValue) { display in
                            Text(display.label)
                                .tag(display)
                        }
                    }
                }
            }

            topControlMenu(
                title: "Refresh \(store.refreshInterval.label)",
                shortTitle: "Refresh \(store.refreshInterval.label)",
                systemImage: "timer",
                labelMode: labelMode
            ) {
                Picker("Refresh Every", selection: Binding(
                    get: { store.refreshInterval },
                    set: { store.setRefreshInterval($0) }
                )) {
                    ForEach(RefreshIntervalOption.allCases, id: \.rawValue) { option in
                        Text(option.label)
                            .tag(option)
                    }
                }
            }

            topControlMenu(
                title: topControlsRowMode.label,
                shortTitle: "Rows \(topControlsRowMode.shortLabel)",
                systemImage: "rectangle.split.3x1",
                labelMode: labelMode
            ) {
                Picker("Toolbar Rows", selection: Binding(
                    get: { topControlsRowMode },
                    set: { topControlsRowMode = $0 }
                )) {
                    ForEach(TopControlsRowMode.allCases, id: \.rawValue) { mode in
                        Text(mode.label)
                            .tag(mode)
                    }
                }
            }
        }
    }

    private var isSidebarSearchActive: Bool {
        SidebarEmailSearch.normalizedQuery(sidebarEmailSearchText) != nil
    }

    private var allSortedGroups: [DuplicateGroup] {
        if sidebarViewMode == .compact {
            return SidebarPresentation.compactSortedGroups(
                groups: store.groups,
                statusesByTrackingKey: store.displayedStatusesByTrackingKey,
                sort: compactSidebarSort
            )
        }

        return store.groups.sorted { lhs, rhs in
            let leftActive = isTrackedCodexGroup(lhs)
            let rightActive = isTrackedCodexGroup(rhs)
            if leftActive != rightActive {
                return leftActive
            }

            let leftSuggested = lhs.id == store.suggestedGroupID
            let rightSuggested = rhs.id == store.suggestedGroupID
            if leftSuggested != rightSuggested {
                return leftSuggested
            }

            return lhs.primaryRecord.identity.name.localizedCaseInsensitiveCompare(rhs.primaryRecord.identity.name) == .orderedAscending
        }
    }

    private var filteredSidebarGroups: [DuplicateGroup] {
        SidebarEmailSearch.filteredGroups(allSortedGroups, query: sidebarEmailSearchText)
    }

    private var sidebarGroupSections: SidebarGroupSections {
        if isSidebarSearchActive {
            return SidebarGroupSections(
                primaryGroups: filteredSidebarGroups,
                fiveHourUsedGroups: [],
                fullyUsedGroups: []
            )
        }

        return SidebarPresentation.sectionedGroups(
            groups: filteredSidebarGroups,
            statusesByTrackingKey: store.displayedStatusesByTrackingKey,
            separatesFullyUsedGroups: separateFullyUsedSidebarAccounts
        )
    }

    private var sidebarListPresentation: SidebarListPresentation {
        SidebarListPresentation.make(
            isSearchActive: isSidebarSearchActive,
            filteredGroups: filteredSidebarGroups,
            sectionedGroups: sidebarGroupSections
        )
    }

    private var primarySidebarGroups: [DuplicateGroup] {
        sidebarGroupSections.primaryGroups
    }

    private var fiveHourUsedSidebarGroups: [DuplicateGroup] {
        sidebarGroupSections.fiveHourUsedGroups
    }

    private var fullyUsedSidebarGroups: [DuplicateGroup] {
        sidebarGroupSections.fullyUsedGroups
    }

    private func resolvedTopControlsRowCount(for width: CGFloat) -> Int {
        if let fixedRows = topControlsRowMode.maximumRows {
            return fixedRows
        }

        switch width {
        case ..<720:
            return 3
        case ..<1_020:
            return 2
        default:
            return 1
        }
    }

    private func topControlsLabelMode(
        for width: CGFloat,
        rows: Int,
        controlCount: Int
    ) -> TopControlsLabelMode {
        let controlsPerRow = max(1, Int(ceil(Double(controlCount) / Double(max(rows, 1)))))
        let availableRowWidth = max(width - CGFloat(max(controlsPerRow - 1, 0)) * 8, 0)
        let estimatedWidthPerControl = availableRowWidth / CGFloat(controlsPerRow)

        switch estimatedWidthPerControl {
        case 170...:
            return .full
        case 116...:
            return .short
        default:
            return .iconOnly
        }
    }

    private func topControlsRefreshLabel(labelMode: TopControlsLabelMode) -> some View {
        Group {
            if store.isRefreshing {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)

                    if labelMode != .iconOnly {
                        Text(labelMode == .full ? "Refreshing" : "Refresh")
                    }
                }
            } else {
                topControlLabel(
                    title: "Refresh Now",
                    shortTitle: "Refresh",
                    systemImage: "arrow.clockwise",
                    labelMode: labelMode
                )
            }
        }
    }

    private func newAccountSignInButton(labelMode: TopControlsLabelMode) -> some View {
        let title = store.isNewAccountSignInRunning ? "Cancel Sign In" : "Add Codex Account"
        let helpTitle = store.newAccountSignInStatusMessage ?? title

        return topControlHelpIfNeeded(
            styledTopControl(
                Button {
                    if store.isNewAccountSignInRunning {
                        store.cancelNewCodexSignIn()
                    } else {
                        store.beginNewCodexSignIn()
                    }
                } label: {
                    newAccountSignInLabel(
                        title: title,
                        labelMode: labelMode
                    )
                }
            )
            .disabled(store.isSwitching || (store.isManualActionBusy && !store.isNewAccountSignInRunning)),
            title: helpTitle,
            labelMode: labelMode
        )
    }

    @ViewBuilder
    private func newAccountSignInLabel(
        title: String,
        labelMode: TopControlsLabelMode
    ) -> some View {
        if store.isNewAccountSignInRunning {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)

                if labelMode != .iconOnly {
                    Text(labelMode == .full ? title : "Cancel")
                }
            }
        } else {
            topControlLabel(
                title: title,
                shortTitle: "Add Account",
                systemImage: "person.crop.circle.badge.plus",
                labelMode: labelMode
            )
        }
    }

    @ViewBuilder
    private var newAccountSignInStatusBar: some View {
        if let message = store.newAccountSignInStatusMessage {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
        }
    }

    private func usageQueueButton(labelMode: TopControlsLabelMode) -> some View {
        let title = store.isUsageCheckQueueRunning
            ? "Usage Queue (\(store.queuedUsageCheckTrackingKeys.count) left)"
            : "Usage Queue"
        let shortTitle = store.isUsageCheckQueueRunning
            ? "Queue \(store.queuedUsageCheckTrackingKeys.count)"
            : "Usage Queue"
        let systemImage = store.isUsageCheckQueueRunning ? "clock.badge.checkmark" : "checklist"
        let isDisabled = (batchDispatchGroups.isEmpty && !store.isUsageCheckQueueRunning)
            || (store.isManualActionBusy && !store.isUsageCheckQueueRunning)

        return topControlHelpIfNeeded(
            styledTopControl(
                Button {
                    isShowingFiveHourStartQueuePopover = false
                    seedUsageQueueSelectionIfNeeded()
                    isShowingUsageQueuePopover.toggle()
                } label: {
                    topControlLabel(
                        title: title,
                        shortTitle: shortTitle,
                        systemImage: systemImage,
                        labelMode: labelMode
                    )
                }
            )
            .disabled(isDisabled)
            .popover(isPresented: $isShowingUsageQueuePopover, arrowEdge: .top) {
                usageQueuePopover
            },
            title: title,
            labelMode: labelMode
        )
    }

    private func fiveHourStartQueueButton(labelMode: TopControlsLabelMode) -> some View {
        let title = store.isFiveHourStartQueueRunning
            ? "Start 5h Queue (\(store.queuedFiveHourStartTrackingKeys.count) left)"
            : "Start 5h Queue"
        let shortTitle = store.isFiveHourStartQueueRunning
            ? "Start 5h \(store.queuedFiveHourStartTrackingKeys.count)"
            : "Start 5h"
        let systemImage = store.isFiveHourStartQueueRunning ? "timer.circle" : "timer"
        let isDisabled = (batchDispatchGroups.isEmpty && !store.isFiveHourStartQueueRunning)
            || (store.isManualActionBusy && !store.isFiveHourStartQueueRunning)

        return topControlHelpIfNeeded(
            styledTopControl(
                Button {
                    isShowingUsageQueuePopover = false
                    seedFiveHourStartQueueSelectionIfNeeded()
                    isShowingFiveHourStartQueuePopover.toggle()
                } label: {
                    topControlLabel(
                        title: title,
                        shortTitle: shortTitle,
                        systemImage: systemImage,
                        labelMode: labelMode
                    )
                }
            )
            .disabled(isDisabled)
            .popover(isPresented: $isShowingFiveHourStartQueuePopover, arrowEdge: .top) {
                fiveHourStartQueuePopover
            },
            title: title,
            labelMode: labelMode
        )
    }

    private func topControlButton(
        title: String,
        shortTitle: String,
        systemImage: String,
        labelMode: TopControlsLabelMode,
        emphasis: TopControlEmphasis = .standard,
        action: @escaping () -> Void
    ) -> some View {
        topControlHelpIfNeeded(
            styledTopControl(
                Button(action: action) {
                    topControlLabel(
                        title: title,
                        shortTitle: shortTitle,
                        systemImage: systemImage,
                        labelMode: labelMode
                    )
                },
                emphasis: emphasis
            ),
            title: title,
            labelMode: labelMode
        )
    }

    private func topControlMenu<MenuContent: View>(
        title: String,
        shortTitle: String,
        systemImage: String,
        labelMode: TopControlsLabelMode,
        @ViewBuilder content: () -> MenuContent
    ) -> some View {
        topControlHelpIfNeeded(
            styledTopControl(
                Menu {
                    content()
                } label: {
                    topControlLabel(
                        title: title,
                        shortTitle: shortTitle,
                        systemImage: systemImage,
                        labelMode: labelMode
                    )
                }
            ),
            title: title,
            labelMode: labelMode
        )
    }

    @ViewBuilder
    private func topControlLabel(
        title: String,
        shortTitle: String,
        systemImage: String,
        labelMode: TopControlsLabelMode
    ) -> some View {
        switch labelMode {
        case .full:
            Label(title, systemImage: systemImage)
        case .short:
            Label(shortTitle, systemImage: systemImage)
        case .iconOnly:
            Image(systemName: systemImage)
        }
    }

    @ViewBuilder
    private func topControlHelpIfNeeded<V: View>(
        _ view: V,
        title: String,
        labelMode: TopControlsLabelMode
    ) -> some View {
        if labelMode == .full {
            view
        } else {
            view.help(title)
        }
    }

    @ViewBuilder
    private func styledTopControl<V: View>(
        _ view: V,
        emphasis: TopControlEmphasis = .standard
    ) -> some View {
        if emphasis == .prominent {
            view
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        } else {
            view
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private func topControlsCluster<Content: View>(
        accent: Color? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        WrappingFlowLayout(spacing: 8, rowSpacing: 8) {
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            toggleTopControlsExpandedIfAllowed()
        }
        .background(topControlsClusterBackground(accent: accent))
    }

    private func topControlsClusterBackground(accent: Color?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

        return shape
            .fill(Color(nsColor: .controlBackgroundColor).opacity(accent == nil ? 0.72 : 0.92))
            .overlay {
                if let accent {
                    shape.fill(accent.opacity(0.05))
                }
            }
            .overlay {
                shape.strokeBorder(
                    (accent ?? Color(nsColor: .separatorColor)).opacity(accent == nil ? 0.35 : 0.22),
                    lineWidth: 1
                )
            }
    }

    private func toggleTopControlsExpandedIfAllowed() {
        guard isSidebarOpen else {
            return
        }

        topControlsExpandedWhenSidebarOpen.toggle()
    }

    private var batchDispatchGroups: [DuplicateGroup] {
        allSortedGroups
    }

    private var sidebarGroupsInDisplayOrder: [DuplicateGroup] {
        primarySidebarGroups + fiveHourUsedSidebarGroups + fullyUsedSidebarGroups
    }

    private var selectedSidebarGroup: DuplicateGroup? {
        if let selectedGroupID = store.selectedGroupID,
           let group = sidebarGroupsInDisplayOrder.first(where: { $0.id == selectedGroupID }) {
            return group
        }

        return sidebarGroupsInDisplayOrder.first(where: { selectedSidebarGroupIDs.contains($0.id) })
    }

    private var selectedSidebarTrackingKeys: Set<String> {
        Set(
            batchDispatchGroups
                .filter { selectedSidebarGroupIDs.contains($0.id) }
                .map(\.trackingKey)
        )
    }

    private var usageQueuePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Usage Check Queue")
                .font(.headline)

            Text("Pick saved accounts to check. The app runs one usage check at a time and waits 5 seconds between each dispatch.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if store.isUsageCheckQueueRunning {
                VStack(alignment: .leading, spacing: 4) {
                    if let checkingTrackingKey = store.checkingTrackingKey,
                       let checkingGroup = store.group(matchingTrackingKey: checkingTrackingKey) {
                        Text("Checking now: \(checkingGroup.primaryRecord.identity.name)")
                            .font(.caption.weight(.semibold))
                    }

                    Text("\(store.queuedUsageCheckTrackingKeys.count) account(s) left in the queue.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            HStack(spacing: 8) {
                Button("Select All") {
                    usageQueueSelection = Set(batchDispatchGroups.map(\.trackingKey))
                }
                .disabled(batchDispatchGroups.isEmpty || store.isManualActionBusy)

                Button("Clear") {
                    usageQueueSelection.removeAll()
                }
                .disabled(usageQueueSelection.isEmpty || store.isManualActionBusy)

                Spacer(minLength: 0)
            }
            .controlSize(.small)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(batchDispatchGroups) { group in
                        Toggle(isOn: Binding(
                            get: { usageQueueSelection.contains(group.trackingKey) },
                            set: { isSelected in
                                if isSelected {
                                    usageQueueSelection.insert(group.trackingKey)
                                } else {
                                    usageQueueSelection.remove(group.trackingKey)
                                }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.primaryRecord.identity.name)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)

                                Text(group.primaryRecord.identity.useLabel ?? shortAccountTag(for: group.accountID))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(store.isManualActionBusy)
                    }
                }
            }
            .frame(width: 360, height: min(CGFloat(max(batchDispatchGroups.count, 1)) * 34, 260))

            HStack(spacing: 8) {
                Button("Dispatch Selected") {
                    store.dispatchUsageChecks(for: orderedUsageQueueSelection)
                    isShowingUsageQueuePopover = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(orderedUsageQueueSelection.isEmpty || store.isManualActionBusy)

                if !batchDispatchGroups.isEmpty {
                    Button("Dispatch All") {
                        store.dispatchUsageChecks(for: batchDispatchGroups.map(\.trackingKey))
                        usageQueueSelection = Set(batchDispatchGroups.map(\.trackingKey))
                        isShowingUsageQueuePopover = false
                    }
                    .disabled(store.isManualActionBusy)
                }

                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .frame(width: 392, alignment: .leading)
        .onAppear {
            seedUsageQueueSelectionIfNeeded()
        }
    }

    private var fiveHourStartQueuePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Start 5h Queue")
                .font(.headline)

            Text("Pick saved accounts to send a tiny isolated Codex request. The app runs one start at a time and waits 5 seconds between each dispatch.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if store.isFiveHourStartQueueRunning {
                VStack(alignment: .leading, spacing: 4) {
                    if let startingTrackingKey = store.startingFiveHourTrackingKey,
                       let startingGroup = store.group(matchingTrackingKey: startingTrackingKey) {
                        Text("Starting now: \(startingGroup.primaryRecord.identity.name)")
                            .font(.caption.weight(.semibold))
                    }

                    Text("\(store.queuedFiveHourStartTrackingKeys.count) account(s) left in the queue.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            HStack(spacing: 8) {
                Button("Select All") {
                    fiveHourStartQueueSelection = Set(batchDispatchGroups.map(\.trackingKey))
                }
                .disabled(batchDispatchGroups.isEmpty || store.isManualActionBusy)

                Button("Clear") {
                    fiveHourStartQueueSelection.removeAll()
                }
                .disabled(fiveHourStartQueueSelection.isEmpty || store.isManualActionBusy)

                Spacer(minLength: 0)
            }
            .controlSize(.small)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(batchDispatchGroups) { group in
                        Toggle(isOn: Binding(
                            get: { fiveHourStartQueueSelection.contains(group.trackingKey) },
                            set: { isSelected in
                                if isSelected {
                                    fiveHourStartQueueSelection.insert(group.trackingKey)
                                } else {
                                    fiveHourStartQueueSelection.remove(group.trackingKey)
                                }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.primaryRecord.identity.name)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)

                                Text(group.primaryRecord.identity.useLabel ?? shortAccountTag(for: group.accountID))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(store.isManualActionBusy)
                    }
                }
            }
            .frame(width: 360, height: min(CGFloat(max(batchDispatchGroups.count, 1)) * 34, 260))

            HStack(spacing: 8) {
                Button("Dispatch Selected") {
                    store.dispatchFiveHourStarts(for: orderedFiveHourStartQueueSelection)
                    isShowingFiveHourStartQueuePopover = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(orderedFiveHourStartQueueSelection.isEmpty || store.isManualActionBusy)

                if !batchDispatchGroups.isEmpty {
                    Button("Dispatch All") {
                        store.dispatchFiveHourStarts(for: batchDispatchGroups.map(\.trackingKey))
                        fiveHourStartQueueSelection = Set(batchDispatchGroups.map(\.trackingKey))
                        isShowingFiveHourStartQueuePopover = false
                    }
                    .disabled(store.isManualActionBusy)
                }

                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .frame(width: 392, alignment: .leading)
        .onAppear {
            seedFiveHourStartQueueSelectionIfNeeded()
        }
    }

    private func seedUsageQueueSelectionIfNeeded() {
        let fallbackTrackingKey = store.group(withID: store.selectedGroupID)?.trackingKey
        usageQueueSelection = SidebarSelectionCoordinator.queueSelection(
            existingSelection: usageQueueSelection,
            sidebarSelection: selectedSidebarTrackingKeys,
            hasSidebarSelection: !selectedSidebarGroupIDs.isEmpty,
            validTrackingKeys: Set(batchDispatchGroups.map(\.trackingKey)),
            fallbackTrackingKey: fallbackTrackingKey
        )
    }

    private func seedFiveHourStartQueueSelectionIfNeeded() {
        let fallbackTrackingKey = store.group(withID: store.selectedGroupID)?.trackingKey
        fiveHourStartQueueSelection = SidebarSelectionCoordinator.queueSelection(
            existingSelection: fiveHourStartQueueSelection,
            sidebarSelection: selectedSidebarTrackingKeys,
            hasSidebarSelection: !selectedSidebarGroupIDs.isEmpty,
            validTrackingKeys: Set(batchDispatchGroups.map(\.trackingKey)),
            fallbackTrackingKey: fallbackTrackingKey
        )
    }

    private var orderedUsageQueueSelection: [String] {
        SidebarSelectionCoordinator.orderedQueueTrackingKeys(
            selection: usageQueueSelection,
            orderedTrackingKeys: batchDispatchGroups.map(\.trackingKey)
        )
    }

    private var orderedFiveHourStartQueueSelection: [String] {
        SidebarSelectionCoordinator.orderedQueueTrackingKeys(
            selection: fiveHourStartQueueSelection,
            orderedTrackingKeys: batchDispatchGroups.map(\.trackingKey)
        )
    }

    private func syncSidebarSelectionFromStoreIfNeeded() {
        let orderedVisibleGroupIDs = sidebarGroupsInDisplayOrder.map(\.id)

        if let selectedGroupID = store.selectedGroupID,
           orderedVisibleGroupIDs.contains(selectedGroupID) {
            guard !selectedSidebarGroupIDs.contains(selectedGroupID) else {
                return
            }

            selectedSidebarGroupIDs = [selectedGroupID]
            return
        }

        guard selectedSidebarGroupIDs.isEmpty else {
            return
        }

        let visibleSelection = SidebarSelectionCoordinator.visibleSelection(
            currentSelection: [],
            currentPrimaryGroupID: store.selectedGroupID,
            orderedVisibleGroupIDs: orderedVisibleGroupIDs
        )
        guard !visibleSelection.isEmpty else {
            return
        }

        selectedSidebarGroupIDs = visibleSelection
    }

    private func reconcileSidebarSelection() {
        let filteredSelection = SidebarSelectionCoordinator.visibleSelection(
            currentSelection: selectedSidebarGroupIDs,
            currentPrimaryGroupID: store.selectedGroupID,
            orderedVisibleGroupIDs: sidebarGroupsInDisplayOrder.map(\.id)
        )

        if filteredSelection != selectedSidebarGroupIDs {
            selectedSidebarGroupIDs = filteredSelection
            return
        }

        if filteredSelection.isEmpty {
            return
        }

        guard let selectedGroupID = store.selectedGroupID,
              !filteredSelection.contains(selectedGroupID) else {
            return
        }

        store.selectedGroupID = SidebarSelectionCoordinator.primaryGroupID(
            for: filteredSelection,
            previousSelection: [],
            currentPrimaryGroupID: nil,
            orderedGroupIDs: sidebarGroupsInDisplayOrder.map(\.id)
        )
    }

    private var headerPanel: some View {
        let quotaSummary = SidebarPresentation.quotaSummary(
            groups: store.groups,
            statusesByTrackingKey: store.displayedStatusesByTrackingKey,
            liveStatus: store.liveStatus,
            currentLiveStatus: store.currentLiveStatus
        )
        let usageReturnItems = SidebarPresentation.usageReturnItems(
            groups: store.groups,
            statusesByTrackingKey: store.displayedStatusesByTrackingKey,
            liveStatus: store.liveStatus,
            currentLiveStatus: store.currentLiveStatus
        )

        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Saved Accounts")
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)

                Text(store.authRootPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                if let lastRefreshDate = store.lastRefreshDate {
                    Text("Updated \(relativeDate(lastRefreshDate))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            quotaSummaryView(
                summary: quotaSummary,
                usageReturnItems: usageReturnItems,
                splitsWeeklyRemainingByPlanType: splitWeeklyLeftByPlanType
            )

            Toggle("Split weekly left by free vs other", isOn: $splitWeeklyLeftByPlanType)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.caption.weight(.semibold))

            Toggle("Separate limited accounts into sections", isOn: $separateFullyUsedSidebarAccounts)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.caption.weight(.semibold))

            VStack(alignment: .leading, spacing: 10) {
                if let liveStatus = store.liveStatus,
                   let liveSaveDestination = store.liveSaveDestination {
                    currentLivePanel(
                        liveStatus: liveStatus,
                        status: store.currentLiveStatus,
                        destination: liveSaveDestination
                    )
                }

                if store.activeTrackingKey != nil,
                   let suggestedGroup = store.group(withID: store.suggestedGroupID),
                   suggestedGroup.trackingKey != store.activeTrackingKey {
                    Divider()
                }

                if let suggested = store.group(withID: store.suggestedGroupID),
                   let status = store.displayedStatus(for: suggested),
                   suggested.trackingKey != store.activeTrackingKey {
                    statusPanel(
                        title: "Suggested next",
                        group: suggested,
                        status: status,
                        accent: .blue,
                        actionTitle: "Switch"
                    ) {
                        pendingSwitchGroup = suggested
                    }
                }
            }

            if let lastError = store.lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if !store.renameWarnings.isEmpty {
                warningsSummaryButton
            }
        }
        .padding(16)
        .background(sidebarSurface(cornerRadius: 18))
    }

    @ViewBuilder
    private func sidebarRowView(for group: DuplicateGroup) -> some View {
        if sidebarViewMode == .compact {
            compactRowView(for: group)
                .contentShape(Rectangle())
                .simultaneousGesture(sidebarSelectAccountClickGesture(for: group))
                .simultaneousGesture(sidebarOpenCodexDoubleClickGesture(for: group))
                .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        } else {
            rowView(for: group)
                .contentShape(Rectangle())
                .simultaneousGesture(sidebarSelectAccountClickGesture(for: group))
                .simultaneousGesture(sidebarOpenCodexDoubleClickGesture(for: group))
                .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
    }

    private func sidebarSelectAccountClickGesture(for group: DuplicateGroup) -> some Gesture {
        TapGesture(count: 1)
            .onEnded {
                selectSidebarAccountFromClick(group)
            }
    }

    private func sidebarOpenCodexDoubleClickGesture(for group: DuplicateGroup) -> some Gesture {
        TapGesture(count: 2)
            .onEnded {
                openCodexFromSidebar(for: group)
            }
    }

    private func selectSidebarAccountFromClick(_ group: DuplicateGroup) {
        let oldSelection = selectedSidebarGroupIDs
        let modifierFlags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
        let togglesMembership = modifierFlags.contains(.command)
        let extendsRange = modifierFlags.contains(.shift) && !togglesMembership
        let orderedGroupIDs = sidebarGroupsInDisplayOrder.map(\.id)
        let nextSelection = SidebarSelectionCoordinator.clickSelection(
            currentSelection: oldSelection,
            clickedGroupID: group.id,
            currentPrimaryGroupID: store.selectedGroupID,
            orderedGroupIDs: orderedGroupIDs,
            extendsRange: extendsRange,
            togglesMembership: togglesMembership
        )
        let primaryGroupID = SidebarSelectionCoordinator.primaryGroupID(
            for: nextSelection,
            previousSelection: oldSelection,
            currentPrimaryGroupID: store.selectedGroupID,
            orderedGroupIDs: orderedGroupIDs
        )

        selectedSidebarGroupIDs = nextSelection
        store.selectedGroupID = primaryGroupID
    }

    private func openCodexFromSidebar(for group: DuplicateGroup) {
        selectedSidebarGroupIDs = [group.id]
        store.selectedGroupID = group.id

        guard canOpenCodexSession(for: group) else {
            return
        }

        Task {
            await store.openCodex(for: group)
        }
    }

    private func canOpenCodexSession(for group: DuplicateGroup) -> Bool {
        FileManager.default.fileExists(atPath: group.primaryRecord.authFileURL.path)
            && !store.isSwitching
            && !store.isOpeningCodex(for: group)
            && !store.isCodexSessionOpen(for: group)
    }

    private func unbackedEmailFolderRow(_ folder: AuthStoreUnbackedEmailFolder) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(folder.email)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)

                    if let warning = folder.warning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }

                Text("No Codex account behind this folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(sidebarSurface(cornerRadius: 12))
        .help([folder.relativePath, folder.warning].compactMap(\.self).joined(separator: "\n"))
    }

    private var warningsSummaryButton: some View {
        Button {
            isShowingWarningsPopover.toggle()
        } label: {
            HStack(spacing: 8) {
                Label("Warnings", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)

                Text("\(store.renameWarnings.count)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.14), in: Capsule())
                    .foregroundStyle(.orange)

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(sidebarSurface(accent: .orange, cornerRadius: 12))
        .popover(isPresented: $isShowingWarningsPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 8) {
                    Label("Warnings", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)

                    Text("\(store.renameWarnings.count)")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.14), in: Capsule())
                        .foregroundStyle(.orange)

                    Spacer(minLength: 0)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(store.renameWarnings.enumerated()), id: \.offset) { index, warning in
                            Text("\(index + 1). \(warning)")
                                .font(.caption)
                                .lineLimit(nil)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(
                                    Color.primary.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                )
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 140, idealHeight: 220, maxHeight: 320)
            }
            .padding(16)
            .frame(width: 620, alignment: .leading)
        }
    }

    private func currentLivePanel(
        liveStatus: LiveCodexStatus,
        status: AccountStatus?,
        destination: AuthSaveDestination
    ) -> some View {
        let showsShortWindow = supportsShortWindow(for: liveStatus)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                badge("CURRENT", color: .green)

                VStack(alignment: .leading, spacing: 2) {
                    Text(currentLiveAccountName(from: liveStatus))
                        .font(.headline)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(currentLiveAccountSubtitle(from: liveStatus))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .layoutPriority(1)
            }

            VStack(alignment: .leading, spacing: 8) {
                if showsShortWindow {
                    currentLiveQuotaLine(
                        title: "5h",
                        value: StatusDisplayFormatter.shortWindowUsageLabel(
                            status: status,
                            isApplicable: showsShortWindow
                        ),
                        reset: StatusDisplayFormatter.hourlyResetLabel(
                            status: status,
                            isApplicable: showsShortWindow
                        )
                    )
                }

                currentLiveQuotaLine(
                    title: "Week",
                    value: StatusDisplayFormatter.usagePercentLabel(
                        status?.weeklyUsagePercent,
                        state: status?.weeklyWindowState
                    ),
                    reset: StatusDisplayFormatter.weeklyResetLabel(status: status, fallbackResetToken: nil)
                )

                Text(StatusDisplayFormatter.currentLiveStatusSummaryLabel(status: status))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(saveDestinationLabel(for: destination))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(destinationDisplayPath(for: destination))
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            currentLiveActionBar(destination: destination)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(sidebarSurface(accent: .green, cornerRadius: 14))
    }

    private func quotaSummaryView(
        summary: SidebarQuotaSummary,
        usageReturnItems: [SidebarUsageReturnItem],
        splitsWeeklyRemainingByPlanType: Bool
    ) -> some View {
        let chipLayout = SidebarPresentation.quotaSummaryChipLayout(
            summary: summary,
            splitsWeeklyRemainingByPlanType: splitsWeeklyRemainingByPlanType
        )

        return HStack(spacing: 0) {
            ForEach(chipLayout) { item in
                if item.leadingSpacing > 0 {
                    Color.clear
                        .frame(width: item.leadingSpacing)
                }

                if item.chip.title == "Accounts" {
                    accountSummaryChip(
                        title: item.chip.title,
                        value: item.chip.value,
                        usageReturnItems: usageReturnItems
                    )
                } else {
                    summaryChip(title: item.chip.title, value: item.chip.value)
                }
            }
        }
    }

    private func summaryChip(title: String, value: String) -> some View {
        summaryChipContent(title: title, value: value)
            .background(sidebarSurface(cornerRadius: 12))
    }

    private func accountSummaryChip(
        title: String,
        value: String,
        usageReturnItems: [SidebarUsageReturnItem]
    ) -> some View {
        Button {
            isShowingAccountUsageReturnMenu.toggle()
        } label: {
            summaryChipContent(title: title, value: value)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(sidebarSurface(cornerRadius: 12))
        .popover(isPresented: $isShowingAccountUsageReturnMenu, arrowEdge: .bottom) {
            accountUsageReturnMenu(usageReturnItems)
        }
        .help("Show usage return timers")
    }

    private func summaryChipContent(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(value)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func accountUsageReturnMenu(_ items: [SidebarUsageReturnItem]) -> some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            VStack(alignment: .leading, spacing: 8) {
                accountUsageReturnHeader

                Divider()

                if items.isEmpty {
                    Text("No active timers")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(items) { item in
                                accountUsageReturnRow(item, now: context.date)
                            }
                        }
                    }
                    .frame(maxHeight: 280)
                }
            }
            .padding(12)
            .frame(width: 310, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var accountUsageReturnHeader: some View {
        HStack(spacing: 8) {
            Text("Kind")
                .frame(width: 42, alignment: .leading)
            Text("Type")
                .frame(width: 64, alignment: .leading)
            Spacer(minLength: 6)
            Text("%")
                .frame(width: 38, alignment: .trailing)
            Text("Timer")
                .frame(width: 86, alignment: .trailing)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    private func accountUsageReturnRow(
        _ item: SidebarUsageReturnItem,
        now: Date
    ) -> some View {
        HStack(spacing: 8) {
            Text(item.kind.label)
                .frame(width: 42, alignment: .leading)
            Text(item.accountType)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 64, alignment: .leading)
            Spacer(minLength: 6)
            Text("\(item.usedPercent)%")
                .frame(width: 38, alignment: .trailing)
            Text(StatusDisplayFormatter.countdownLabel(until: item.resetAt, now: now))
                .monospacedDigit()
                .frame(width: 86, alignment: .trailing)
        }
        .font(.caption)
        .foregroundStyle(.primary)
    }

    private func compactSectionHeader(title: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: title == nil ? 0 : 6) {
            if let title {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            }

            compactListHeader
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(sidebarSurface(cornerRadius: 12))
        }
        .textCase(nil)
    }

    @ViewBuilder
    private var sidebarFiveHourUsedSectionHeader: some View {
        if sidebarViewMode == .compact {
            compactSectionHeader(title: "5-Hour Used Up")
        } else {
            Text("5-Hour Used Up")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(nil)
        }
    }

    @ViewBuilder
    private var sidebarFullyUsedSectionHeader: some View {
        if sidebarViewMode == .compact {
            compactSectionHeader(title: "Used Up")
        } else {
            Text("Used Up")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(nil)
        }
    }

    private var sidebarUnbackedEmailFoldersSectionHeader: some View {
        Text("Folders Without Accounts")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
    }

    private var compactListHeader: some View {
        HStack(spacing: 10) {
            compactHeaderText("ID")
                .frame(maxWidth: .infinity, alignment: .leading)
            compactHeaderColumn("5-Hr", width: CompactSidebarColumnLayout.usageWidth)
            compactHeaderColumn("5-Hr Reset", width: CompactSidebarColumnLayout.resetWidth)
            compactHeaderColumn("Week", width: CompactSidebarColumnLayout.usageWidth)
            compactHeaderColumn("Week Reset", width: CompactSidebarColumnLayout.resetWidth)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(nil)
    }

    private func compactHeaderText(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func compactHeaderColumn(
        _ text: String,
        width: CGFloat
    ) -> some View {
        compactHeaderText(text)
            .frame(width: width, alignment: .center)
    }

    private func compactRowView(for group: DuplicateGroup) -> some View {
        let status = store.displayedStatus(for: group)
        let showsShortWindow = supportsShortWindow(for: group)
        let fallbackShortWindowUsage = store.suppressesFolderFallback(for: group)
            ? nil
            : group.primaryRecord.parsedFolderName.shortWindowUsage
        let fallbackShortResetToken = store.suppressesFolderFallback(for: group)
            ? nil
            : group.primaryRecord.parsedFolderName.shortWindowResetToken
        let fallbackWeeklyUsage = store.suppressesFolderFallback(for: group)
            ? nil
            : group.primaryRecord.parsedFolderName.weeklyUsage
        let fallbackResetToken = store.suppressesFolderFallback(for: group)
            ? nil
            : group.primaryRecord.parsedFolderName.resetToken
        let isSelected = isSidebarGroupSelected(group)

        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(group.primaryRecord.identity.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(sidebarPrimaryForeground(selected: isSelected))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if isCurrentLiveGroup(group) {
                        badge("ACTIVE", color: .green, selected: isSelected)
                    } else if store.isCodexSessionOpen(for: group) {
                        badge("OPEN", color: .green, selected: isSelected)
                    } else if group.id == store.suggestedGroupID {
                        badge("NEXT", color: .blue, selected: isSelected)
                    }

                    if store.automaticRefreshWarning(for: group) != nil {
                        badge("PAUSED", color: .orange, selected: isSelected)
                    }
                }

                HStack(spacing: 6) {
                    Text(shortAccountTag(for: group.accountID))
                        .font(.caption2.monospaced())
                        .foregroundStyle(sidebarSecondaryForeground(selected: isSelected))

                    if let useLabel = group.primaryRecord.identity.useLabel, !useLabel.isEmpty {
                        Text(useLabel)
                            .font(.caption2)
                            .foregroundStyle(sidebarSecondaryForeground(selected: isSelected))
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            compactValue(
                StatusDisplayFormatter.shortWindowUsageLabel(
                    status: status,
                    fallbackUsedPercent: fallbackShortWindowUsage,
                    display: compactSidebarUsageDisplay,
                    isApplicable: showsShortWindow
                ),
                selected: isSelected
            )
                .frame(width: CompactSidebarColumnLayout.usageWidth, alignment: .center)
            compactValue(
                StatusDisplayFormatter.compactHourlyResetLabel(
                    status: status,
                    fallbackResetToken: fallbackShortResetToken,
                    isApplicable: showsShortWindow
                ),
                selected: isSelected
            )
                .frame(width: CompactSidebarColumnLayout.resetWidth, alignment: .center)
            compactValue(
                StatusDisplayFormatter.compactUsagePercentLabel(
                    fromUsedPercent: status?.weeklyUsagePercent,
                    fallbackUsedPercent: fallbackWeeklyUsage,
                    display: compactSidebarUsageDisplay,
                    state: status?.weeklyWindowState
                ),
                selected: isSelected
            )
                .frame(width: CompactSidebarColumnLayout.usageWidth, alignment: .center)
            compactValue(
                StatusDisplayFormatter.compactWeeklyResetLabel(
                    status: status,
                    fallbackResetToken: fallbackResetToken
                ),
                selected: isSelected
            )
            .frame(width: CompactSidebarColumnLayout.resetWidth, alignment: .center)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            sidebarSurface(
                accent: sidebarAccent(for: group),
                selected: isSelected,
                cornerRadius: 12
            )
        )
    }

    private func compactValue(_ text: String, selected: Bool = false) -> some View {
        Text(text)
            .font(.caption.monospacedDigit())
            .foregroundStyle(sidebarPrimaryForeground(selected: selected))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
    }

    private func rowView(for group: DuplicateGroup) -> some View {
        let status = store.displayedStatus(for: group)
        let fallbackShortResetToken = store.suppressesFolderFallback(for: group)
            ? nil
            : group.primaryRecord.parsedFolderName.shortWindowResetToken
        let fallbackWeeklyUsage = store.suppressesFolderFallback(for: group)
            ? nil
            : group.primaryRecord.parsedFolderName.weeklyUsage
        let fallbackResetToken = store.suppressesFolderFallback(for: group)
            ? nil
            : group.primaryRecord.parsedFolderName.resetToken
        let isSelected = isSidebarGroupSelected(group)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.primaryRecord.identity.name)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(sidebarPrimaryForeground(selected: isSelected))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if let useLabel = group.primaryRecord.identity.useLabel {
                        Text(useLabel)
                            .font(.callout)
                            .foregroundStyle(sidebarSecondaryForeground(selected: isSelected))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 6) {
                    if isCurrentLiveGroup(group) {
                        badge("ACTIVE", color: .green, selected: isSelected)
                    } else if store.isCodexSessionOpen(for: group) {
                        badge("OPEN", color: .green, selected: isSelected)
                    } else if group.id == store.suggestedGroupID {
                        badge("NEXT", color: .blue, selected: isSelected)
                    }

                    if store.automaticRefreshWarning(for: group) != nil {
                        badge("AUTO PAUSED", color: .orange, selected: isSelected)
                    }

                    Text(shortAccountTag(for: group.accountID))
                        .font(.caption.monospaced())
                        .foregroundStyle(sidebarSecondaryForeground(selected: isSelected))
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    metricLabel("Weekly", selected: isSelected)
                    metricValue(
                        StatusDisplayFormatter.compactWeeklyUsage(
                            status: status,
                            fallbackWeeklyUsage: fallbackWeeklyUsage
                        ),
                        selected: isSelected
                    )
                    metricLabel("Reset", selected: isSelected)
                    metricValue(
                        StatusDisplayFormatter.compactResetSummary(
                            status: status,
                            fallbackShortResetToken: fallbackShortResetToken,
                            fallbackResetToken: fallbackResetToken
                        ),
                        selected: isSelected
                    )
                }

                GridRow {
                    metricLabel("Status", selected: isSelected)
                    metricValue(StatusDisplayFormatter.availabilityLabel(status: status), selected: isSelected)
                    metricLabel("Fresh", selected: isSelected)
                    metricValue(StatusDisplayFormatter.freshnessLabel(status: status), selected: isSelected)
                }
            }

            if group.isDuplicateGroup {
                Text("Saved copies: \(group.records.count)")
                    .font(.caption2)
                    .foregroundStyle(sidebarWarningForeground(selected: isSelected))
            }

            if let automaticRefreshWarning = store.automaticRefreshWarning(for: group) {
                Text(automaticRefreshWarning)
                    .font(.caption2)
                    .foregroundStyle(sidebarWarningForeground(selected: isSelected))
                    .lineLimit(2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            sidebarSurface(
                accent: sidebarAccent(for: group),
                selected: isSelected,
                cornerRadius: 16
            )
        )
    }

    private func detailView(for group: DuplicateGroup) -> some View {
        let status = store.displayedStatus(for: group)
        let showsShortWindow = supportsShortWindow(for: group)
        let hasAuthFile = FileManager.default.fileExists(atPath: group.primaryRecord.authFileURL.path)
        let isCheckingUsage = store.checkingTrackingKey == group.trackingKey
        let isStartingFiveHour = store.startingFiveHourTrackingKey == group.trackingKey
        let isOpeningCodex = store.isOpeningCodex(for: group)
        let isCodexSessionOpen = store.isCodexSessionOpen(for: group)
        let fallbackShortWindowUsage = store.suppressesFolderFallback(for: group)
            ? nil
            : group.primaryRecord.parsedFolderName.shortWindowUsage
        let fallbackShortResetToken = store.suppressesFolderFallback(for: group)
            ? nil
            : group.primaryRecord.parsedFolderName.shortWindowResetToken
        let fallbackWeeklyUsage = store.suppressesFolderFallback(for: group)
            ? nil
            : group.primaryRecord.parsedFolderName.weeklyUsage
        let fallbackResetToken = store.suppressesFolderFallback(for: group)
            ? nil
            : group.primaryRecord.parsedFolderName.resetToken

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.primaryRecord.identity.name)
                                .font(.largeTitle.weight(.semibold))

                            if let useLabel = group.primaryRecord.identity.useLabel {
                                Text(useLabel)
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 8) {
                            Button {
                                Task {
                                    await store.checkUsage(for: group)
                                }
                            } label: {
                                if isCheckingUsage {
                                    HStack(spacing: 6) {
                                        ProgressView()
                                            .controlSize(.small)
                                        Text("Checking...")
                                    }
                                } else {
                                    Text("Check Usage")
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(store.isSwitching || store.isManualActionBusy || !hasAuthFile)

                            Button {
                                Task {
                                    await store.startFiveHourWindow(for: group)
                                }
                            } label: {
                                if isStartingFiveHour {
                                    HStack(spacing: 6) {
                                        ProgressView()
                                            .controlSize(.small)
                                        Text("Starting...")
                                    }
                                } else {
                                    Text("Start 5h")
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(store.isSwitching || store.isManualActionBusy || !hasAuthFile)

                            Button {
                                Task {
                                    await store.openCodex(for: group)
                                }
                            } label: {
                                if isOpeningCodex {
                                    HStack(spacing: 6) {
                                        ProgressView()
                                            .controlSize(.small)
                                        Text("Opening...")
                                    }
                                } else if isCodexSessionOpen {
                                    Text("Codex Open")
                                } else {
                                    Text("Open Codex")
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(!canOpenCodexSession(for: group))

                            Button("Switch to This Account") {
                                pendingSwitchGroup = group
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(store.isSwitching || store.isManualActionBusy || group.trackingKey == store.activeTrackingKey)
                        }
                    }

                    Text("Account tag \(shortAccountTag(for: group.accountID))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)

                    if let manualCheckError = store.manualCheckError(for: group) {
                        Text(manualCheckError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if let manualCheckWarning = store.manualCheckWarning(for: group) {
                        Text(manualCheckWarning)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    if let manualStartError = store.manualFiveHourStartError(for: group) {
                        Text(manualStartError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if let manualStartWarning = store.manualFiveHourStartWarning(for: group) {
                        Text(manualStartWarning)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    if let codexSessionError = store.codexSessionError(for: group) {
                        Text(codexSessionError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if let codexSessionWarning = store.codexSessionWarning(for: group) {
                        Text(codexSessionWarning)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                    metricCard(
                        "Weekly usage",
                        StatusDisplayFormatter.usagePercentLabel(
                            status?.weeklyUsagePercent ?? fallbackWeeklyUsage,
                            state: status?.weeklyWindowState
                        ),
                        icon: "chart.bar.fill"
                    )
                    metricCard(
                        "Weekly reset",
                        StatusDisplayFormatter.weeklyResetLabel(
                            status: status,
                            fallbackResetToken: fallbackResetToken
                        ),
                        icon: "calendar"
                    )
                    if showsShortWindow {
                        metricCard(
                            "Hourly usage",
                            StatusDisplayFormatter.shortWindowUsageLabel(
                                status: status,
                                fallbackUsedPercent: fallbackShortWindowUsage,
                                isApplicable: showsShortWindow
                            ),
                            icon: "speedometer"
                        )
                        metricCard(
                            "Hourly reset",
                            StatusDisplayFormatter.hourlyResetLabel(
                                status: status,
                                fallbackResetToken: fallbackShortResetToken,
                                isApplicable: showsShortWindow
                            ),
                            icon: "clock"
                        )
                    }
                    metricCard(
                        "Availability",
                        StatusDisplayFormatter.availabilityLabel(status: status),
                        icon: "bolt.fill"
                    )
                    metricCard(
                        "Freshness",
                        StatusDisplayFormatter.freshnessLabel(status: status),
                        icon: "eye"
                    )
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Source Folders")
                        .font(.headline)

                    ForEach(group.records, id: \.id) { record in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.relativeFolderPath)
                                .font(.body.monospaced())
                            Text(record.authFileURL.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }

                if group.isDuplicateGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Saved Account Copies")
                            .font(.headline)
                        Text("These folders belong to the same saved account. The app keeps them grouped so you can review where copies came from without pretending they are separate quota pools.")
                            .foregroundStyle(.secondary)
                    }
                }

                if let status, let nextAvailabilityAt = status.nextAvailabilityAt, status.availableNow == false {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Recovery")
                            .font(.headline)
                        Text("This account is currently tapped out. It should be usable again around \(absoluteDate(nextAvailabilityAt)).")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func metricCard(_ title: String, _ value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func statusPanel(
        title: String,
        group: DuplicateGroup,
        status: AccountStatus,
        accent: Color,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        let fallbackShortResetToken = store.suppressesFolderFallback(for: group)
            ? nil
            : group.primaryRecord.parsedFolderName.shortWindowResetToken
        let fallbackWeeklyUsage = store.suppressesFolderFallback(for: group)
            ? nil
            : group.primaryRecord.parsedFolderName.weeklyUsage
        let fallbackResetToken = store.suppressesFolderFallback(for: group)
            ? nil
            : group.primaryRecord.parsedFolderName.resetToken

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                badge(title == "Suggested next" ? "NEXT" : title.uppercased(), color: accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.primaryRecord.identity.name)
                        .font(.headline)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(group.primaryRecord.identity.useLabel ?? "No use label")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(1)
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    statusFactLine(
                        "Weekly",
                        StatusDisplayFormatter.compactWeeklyUsage(
                            status: status,
                            fallbackWeeklyUsage: fallbackWeeklyUsage
                        )
                    )
                    statusFactLine(
                        "Reset",
                        StatusDisplayFormatter.compactResetSummary(
                            status: status,
                            fallbackShortResetToken: fallbackShortResetToken,
                            fallbackResetToken: fallbackResetToken
                        )
                    )
                }

                GridRow {
                    statusFactLine("Status", StatusDisplayFormatter.availabilityLabel(status: status))
                    statusFactLine("Fresh", StatusDisplayFormatter.freshnessLabel(status: status))
                }
            }

            if let actionTitle {
                HStack {
                    Spacer(minLength: 0)

                    Button(actionTitle) {
                        action?()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(store.isSwitching)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(sidebarSurface(accent: accent, cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded {
                    guard actionTitle != nil, let action, !store.isSwitching else {
                        return
                    }

                    action()
                }
        )
    }

    @ViewBuilder
    private func currentLiveActionBar(destination: AuthSaveDestination) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if destination.isCustom {
                Button("Use Automatic") {
                    store.clearLiveSaveDestinationOverride()
                }
                .controlSize(.small)
            }

            Button("Change Save Folder") {
                store.chooseLiveSaveDestination()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func badge(_ text: String, color: Color, selected: Bool = false) -> some View {
        let selectedText = Color(nsColor: .alternateSelectedControlTextColor)

        return Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(selected ? selectedText.opacity(0.18) : color.opacity(0.14), in: Capsule())
            .foregroundStyle(selected ? selectedText : color)
    }

    private func currentLiveQuotaLine(title: String, value: String, reset: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)

            Text("resets")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text(reset)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
    }

    private func statusFactLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metricLabel(_ label: String, selected: Bool = false) -> some View {
        Text(label)
            .font(.caption)
            .foregroundStyle(sidebarSecondaryForeground(selected: selected))
    }

    private func metricValue(_ value: String, selected: Bool = false) -> some View {
        Text(value)
            .font(.caption.weight(.semibold))
            .foregroundStyle(sidebarPrimaryForeground(selected: selected))
            .lineLimit(1)
            .minimumScaleFactor(0.9)
    }

    private func sidebarPrimaryForeground(selected: Bool) -> Color {
        selected ? Color(nsColor: .alternateSelectedControlTextColor) : Color(nsColor: .labelColor)
    }

    private func sidebarSecondaryForeground(selected: Bool) -> Color {
        selected ? Color(nsColor: .alternateSelectedControlTextColor).opacity(0.82) : Color(nsColor: .secondaryLabelColor)
    }

    private func sidebarWarningForeground(selected: Bool) -> Color {
        selected ? Color(nsColor: .alternateSelectedControlTextColor) : .orange
    }

    private func isSidebarGroupSelected(_ group: DuplicateGroup) -> Bool {
        selectedSidebarGroupIDs.contains(group.id)
    }

    private func sidebarAccent(for group: DuplicateGroup) -> Color? {
        if isTrackedCodexGroup(group) {
            return .green
        }

        if group.id == store.suggestedGroupID {
            return .blue
        }

        if isSidebarGroupSelected(group) {
            return .accentColor
        }

        return nil
    }

    private func sidebarSurface(
        accent: Color? = nil,
        selected: Bool = false,
        cornerRadius: CGFloat
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let selectionFill = Color(nsColor: .selectedContentBackgroundColor)
        let baseFill = selected ? selectionFill : Color(nsColor: .controlBackgroundColor)
        let borderColor = selected
            ? selectionFill.opacity(0.62)
            : Color(nsColor: .separatorColor).opacity(0.38)

        return shape
            .fill(baseFill.opacity(selected ? 1 : 0.84))
            .overlay {
                if let accent, !selected {
                    shape.fill(accent.opacity(0.045))
                }
            }
            .overlay {
                shape.strokeBorder(borderColor, lineWidth: 1)
            }
    }

    private func isCurrentLiveGroup(_ group: DuplicateGroup) -> Bool {
        SidebarPresentation.isActive(
            group: group,
            groups: store.groups,
            liveStatus: store.liveStatus
        )
    }

    private func isTrackedCodexGroup(_ group: DuplicateGroup) -> Bool {
        isCurrentLiveGroup(group) || store.isCodexSessionOpen(for: group)
    }

    private func shortAccountTag(for accountID: String) -> String {
        let suffix = String(accountID.suffix(6)).uppercased()
        return "#\(suffix)"
    }

    private func currentLiveAccountName(from liveStatus: LiveCodexStatus) -> String {
        if let email = liveStatus.email, !email.isEmpty {
            return email
        }
        return "Current Codex Auth \(shortAccountTag(for: liveStatus.accountID))"
    }

    private func currentLiveAccountSubtitle(from liveStatus: LiveCodexStatus) -> String {
        let parts: [String] = [
            liveStatus.workspaceName,
            liveStatus.planType?.capitalized,
            shortAccountTag(for: liveStatus.accountID),
        ]
        .compactMap { value in
            guard let value, !value.isEmpty else {
                return nil
            }
            return value
        }

        return parts.isEmpty ? "Live auth from Codex" : parts.joined(separator: " • ")
    }

    private func supportsShortWindow(for group: DuplicateGroup) -> Bool {
        StatusResolver.supportsShortWindow(
            planType: effectivePlanType(for: group),
            baseLabel: group.primaryRecord.parsedFolderName.baseLabel
        )
    }

    private func supportsShortWindow(for liveStatus: LiveCodexStatus) -> Bool {
        StatusResolver.supportsShortWindow(
            planType: liveStatus.planType
        )
    }

    private func effectivePlanType(for group: DuplicateGroup) -> String? {
        if store.liveStatus?.trackingKey == group.trackingKey {
            return store.liveStatus?.planType ?? group.primaryRecord.planType
        }
        return group.primaryRecord.planType
    }

    private func saveDestinationLabel(for destination: AuthSaveDestination) -> String {
        switch destination.kind {
        case .customOverride:
            return "Saving to custom folder:"
        case .existingTracked:
            return "Saving to tracked folder:"
        case .emptyPlaceholder:
            return "Saving to matched empty folder:"
        case .newFolder:
            return "Saving to new folder on next switch:"
        }
    }

    private func destinationDisplayPath(for destination: AuthSaveDestination) -> String {
        let rootURL = URL(fileURLWithPath: store.authRootPath, isDirectory: true).standardizedFileURL
        let folderURL = destination.folderURL.standardizedFileURL
        let rootPath = rootURL.path
        let folderPath = folderURL.path

        if folderPath == rootPath {
            return folderPath
        }

        if folderPath.hasPrefix(rootPath + "/") {
            return String(folderPath.dropFirst(rootPath.count + 1))
        }

        return folderPath
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func absoluteDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func toggleSidebar() {
        setSidebarVisible(columnVisibility == .detailOnly, animated: true)
    }

    private func setSidebarVisible(_ visible: Bool, animated: Bool) {
        let update = {
            columnVisibility = visible ? .all : .detailOnly
            isSidebarVisible = visible
        }

        if animated {
            withAnimation(.easeInOut(duration: 0.2), update)
        } else {
            update()
        }
    }
}
