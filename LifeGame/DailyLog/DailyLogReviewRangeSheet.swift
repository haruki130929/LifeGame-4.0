import SwiftUI

struct DailyLogReviewRangeSheet: View {
    /// 不含照片的輕量紀錄，只用來挑日期區間（見 DailyLogRecord.summary）
    let allEntries: [DailyLogEntry]
    /// 把選中的那幾筆換成含照片的完整版。沒有它，檢視畫面的照片會全部不見。
    let loadFull: (UUID) -> DailyLogEntry?

    @Environment(\.dismiss) private var dismiss
    
    @State private var startDate: Date = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
    @State private var endDate: Date = .now
    
    @State private var appliedStart: Date? = nil
    @State private var appliedEnd: Date? = nil
    
    var body: some View {
        NavigationStack {
            Group {
                if let s = appliedStart, let e = appliedEnd {
                    DailyLogReviewListView(entries: filteredEntries(from: s, to: e))
                } else {
                    Form {
                        Section("選擇時間期限") {
                            DatePicker("開始日期", selection: $startDate, displayedComponents: .date)
                            DatePicker("結束日期", selection: $endDate, displayedComponents: .date)
                            
                            Button {
                                let (s, e) = normalizedRange(start: startDate, end: endDate)
                                appliedStart = s
                                appliedEnd = e
                            } label: {
                                Label("套用並檢視", systemImage: "eye")
                            }
                        }
                        
                        Section {
                            Text("會完整列出此期間內所有每日紀錄，直接用滾輪滑動檢視。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("檢視每日紀錄")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("關閉") { dismiss() }
                }
                if appliedStart != nil {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("重選區間") {
                            appliedStart = nil
                            appliedEnd = nil
                        }
                    }
                }
            }
        }
    }
    
    private func normalizedRange(start: Date, end: Date) -> (Date, Date) {
        let cal = Calendar.current
        let s = cal.startOfDay(for: min(start, end))
        let e = cal.startOfDay(for: max(start, end))
        return (s, e)
    }
    
    private func filteredEntries(from start: Date, to end: Date) -> [DailyLogEntry] {
        let cal = Calendar.current
        let startDay = cal.startOfDay(for: start)
        let endDay = cal.startOfDay(for: end)
        
        return allEntries
            .filter { entry in
                let d = cal.startOfDay(for: entry.date)
                return d >= startDay && d <= endDay
            }
            .sorted { $0.date < $1.date }
            // 只有真的要看的那幾天才去撈照片，不是整個資料庫
            .map { loadFull($0.id) ?? $0 }
    }
}

// MARK: - 滾動清單頁
private struct DailyLogReviewListView: View {
    let entries: [DailyLogEntry]
    /// 與主列表共用的檢視字體大小（由「＋」選單的「字體大小」調整）
    @AppStorage(DailyLogTextSize.storageKey) private var textSizeIndex: Int = DailyLogTextSize.defaultIndex

    var body: some View {
        if entries.isEmpty {
            ContentUnavailableView("沒有資料", systemImage: "tray", description: Text("此期間沒有每日紀錄。"))
                .padding()
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(entries) { entry in
                        DailyLogFullReviewCard(entry: entry,
                                               textScale: DailyLogTextSize.scale(forIndex: textSizeIndex))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
        }
    }
}

// MARK: - 單筆完整檢視卡片
struct DailyLogFullReviewCard: View {
    let entry: DailyLogEntry
    /// 匯出 PDF 用：照片改用不滑動的換行格狀排列（ScrollView 在離螢幕渲染時抓不到內容）
    var forExport: Bool = false
    /// 檢視字級倍率（匯出 PDF 不傳 → 維持 1.0 固定字級）
    var textScale: Double = 1.0
    @EnvironmentObject private var moduleStore: QuestionModuleStore

    /// 內文字體（footnote 13 級 × 倍率）
    private var fBody: Font { .system(size: 13 * textScale) }
    /// 小字體（caption 12 級 × 倍率）
    private var fSmall: Font { .system(size: 12 * textScale) }

    // ✅ 照片放大預覽狀態
    @State private var isPreviewPresented = false
    @State private var previewIndex = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            Divider().opacity(0.5)

            reviewSection(for: .basic, hardcoded: basicBlock)
            // moodBlock 原本合併 moodMental + moodChange，拆開處理
            if !isCustomized(.moodMental) && !isCustomized(.moodChange) {
                moodBlock
            } else {
                reviewSection(for: .moodMental)
                reviewSection(for: .moodChange)
            }
            reviewSection(for: .anxiety, hardcoded: anxietyBlock)
            reviewSection(for: .impulse, hardcoded: impulseBlock)
            reviewSection(for: .sleep, hardcoded: sleepBlock)
            reviewSection(for: .studyFocus, hardcoded: studyBlock)
            reviewSection(for: .body, hardcoded: bodyBlock)
            reviewSection(for: .observation, hardcoded: observationBlock)

            // 自訂模組
            ForEach(moduleStore.enabledCustomModules) { module in
                customModuleReviewBlock(module: module)
            }
            
            if !entry.photos.isEmpty {
                SectionTitle(String(localized: "照片（\(entry.photos.count)）"))
                if forExport {
                    exportPhotosGrid
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Array(entry.photos.enumerated()), id: \.element.id) { index, p in
                                VStack(alignment: .leading, spacing: 6) {
                                    if let uiImage = UIImage(data: p.imageData) {
                                        ZStack(alignment: .bottomTrailing) {
                                            Image(uiImage: uiImage)
                                                .resizable()
                                                .scaledToFill()
                                                .frame(width: 160, height: 110)
                                                .clipped()
                                                .clipShape(RoundedRectangle(cornerRadius: 12))

                                            // ✅ 放大提示圖示
                                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                                .font(fSmall)
                                                .foregroundStyle(.white)
                                                .padding(5)
                                                .background(.black.opacity(0.35))
                                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                                .padding(6)
                                        }
                                        // ✅ 點擊放大
                                        .onTapGesture {
                                            previewIndex = index
                                            isPreviewPresented = true
                                        }
                                    }
                                    if !p.caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        Text(p.caption)
                                            .font(fSmall)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 160, alignment: .leading)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        // 把字級倍率往下傳，讓 SectionTitle 等子元件跟著縮放
        .environment(\.dailyLogTextScale, textScale)
        // ✅ 全螢幕預覽（複用 DailyLogPhotosSection 裡的 PhotoFullscreenPreview）
        .fullScreenCover(isPresented: $isPreviewPresented) {
            PhotoFullscreenPreview(
                photos: entry.photos,
                currentIndex: $previewIndex
            )
        }
    }
    
    // MARK: - 匯出用照片排列（不滑動、自動換行，3 張一列）

    private var exportPhotosGrid: some View {
        let columns = 3
        let rows: [[DailyLogPhoto]] = stride(from: 0, to: entry.photos.count, by: columns).map { start in
            Array(entry.photos[start..<min(start + columns, entry.photos.count)])
        }
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 10) {
                    ForEach(row) { p in
                        exportPhotoCell(p)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func exportPhotoCell(_ p: DailyLogPhoto) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let uiImage = UIImage(data: p.imageData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 160, height: 110)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            if !p.caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(p.caption)
                    .font(fSmall)
                    .foregroundStyle(.secondary)
                    .frame(width: 160, alignment: .leading)
            }
        }
    }

    private var header: some View {
        HStack {
            Text(entry.date, format: .dateTime.year().month().day())
                .font(.system(size: 17 * textScale, weight: .semibold))
            Spacer()
            Text(entry.weather.displayName)
                .font(.system(size: 15 * textScale))
                .foregroundStyle(.secondary)
        }
    }
    
    // MARK: - Blocks
    
    private var basicBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(String(localized: "基本"))
            Text("起床：\(timeText(entry.wakeTime))")
            Text("上床：\(timeText(entry.bedTime))")
        }
        .font(fBody)
        .foregroundStyle(.secondary)
    }
    
    private var moodBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(String(localized: "情緒與心理狀態"))
            chipLine([
                String(localized: "情緒 \(entry.overallMoodScore)/10"),
                String(localized: "焦慮 \(entry.anxietyScore)/10"),
                String(localized: "疲勞 \(entry.fatigueScore)/10")
            ])
            
            if entry.moodChangeType == .higher {
                Text("情緒變化：變高")
                if !entry.moodChangeReasons.isEmpty {
                    Text("原因：\(join(entry.moodChangeReasons.map{$0.displayName}, otherText: entry.moodChangeReasons.contains(.other) ? entry.moodChangeOtherText : ""))")
                }
                if !entry.moodChangeDurationText.isEmpty {
                    Text("持續時間：\(entry.moodChangeDurationText)")
                }
                if !entry.stabilizeMethodsForMoodChange.isEmpty {
                    Text("穩定方式：\(join(entry.stabilizeMethodsForMoodChange.map{$0.displayName}, otherText: entry.stabilizeMethodsForMoodChange.contains(.other) ? entry.stabilizeOtherTextForMoodChange : ""))")
                }
            } else {
                Text("情緒變化：穩定")
            }
        }
        .font(fBody)
        .foregroundStyle(.secondary)
    }
    
    private var anxietyBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(String(localized: "是否出現焦慮"))
            Text("程度：\(entry.anxietyLevel.displayName)")
            
            if entry.anxietyLevel != .none {
                if !entry.anxietyReasons.isEmpty {
                    Text("原因：\(join(entry.anxietyReasons.map{$0.displayName}, otherText: entry.anxietyReasons.contains(.other) ? entry.anxietyOtherText : ""))")
                }
                if !entry.anxietyDurationText.isEmpty {
                    Text("持續時間：\(entry.anxietyDurationText)")
                }
                if !entry.anxietySymptoms.isEmpty {
                    Text("表現：\(join(entry.anxietySymptoms.map{$0.displayName}, otherText: entry.anxietySymptoms.contains(.other) ? entry.anxietySymptomOtherText : ""))")
                }
                if !entry.stabilizeMethodsForAnxiety.isEmpty {
                    Text("穩定方式：\(join(entry.stabilizeMethodsForAnxiety.map{$0.displayName}, otherText: entry.stabilizeMethodsForAnxiety.contains(.other) ? entry.stabilizeOtherTextForAnxiety : ""))")
                }
            }
        }
        .font(fBody)
        .foregroundStyle(.secondary)
    }
    
    private var impulseBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(String(localized: "衝動行為"))
            
            if entry.impulseSeverities.isEmpty {
                Text("無")
                    .font(fBody)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entry.impulseSeverities.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { sev in
                    let set = entry.impulseTypesBySeverity[sev] ?? []
                    let names = set.map { $0.rawValue }
                    let other = set.contains(.other) ? (entry.impulseOtherTextBySeverity[sev] ?? "") : ""
                    Text("\(sev.displayName)：\(join(names, otherText: other))")
                        .font(fBody)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    
    private var sleepBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(String(localized: "睡眠狀況"))
            Text("入睡所需時間：\(entry.sleepLatency.displayName)")
            Text("睡眠時長：\(sleepHoursText)")
            Text("睡眠品質：\(entry.sleepQuality.shortDisplayName)")
        }
        .font(fBody)
        .foregroundStyle(.secondary)
    }
    
    private var studyBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(String(localized: "課業與專注力"))
            Text("待辦完成：\(entry.todoCompletion.displayName)")
            
            if entry.todoCompletion == .partial {
                Text("部分完成：\(entry.todoPartialDone)/\(entry.todoPartialTotal) 項")
            }
            
            Text("專注度：\(entry.focusQuality.displayName)")
            
            if entry.focusQuality == .cannotFocus {
                if !entry.cannotFocusReasons.isEmpty {
                    Text("可能原因：\(join(entry.cannotFocusReasons.map{$0.displayName}, otherText: entry.cannotFocusReasons.contains(.other) ? entry.cannotFocusOtherText : ""))")
                }
            }
            
            if entry.unfinished {
                Text("未完成：\(entry.unfinishedCount)/\(entry.unfinishedTotal) 項")
                if !entry.difficultyReasons.isEmpty {
                    Text("困難：\(join(entry.difficultyReasons.map{$0.displayName}, otherText: entry.difficultyReasons.contains(.other) ? entry.difficultyOtherText : ""))")
                }
            } else {
                Text("未完成事項：無")
            }
        }
        .font(fBody)
        .foregroundStyle(.secondary)
    }
    
    private var bodyBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(String(localized: "身體狀況"))

            if entry.painAreas.isEmpty {
                Text("不適：無")
            } else {
                let list = entry.painAreas.map { area -> String in
                    let score = entry.painScoreByArea[area] ?? 1
                    return "\(area.rawValue)（\(score)/10）"
                }
                Text("不適：\(list.joined(separator: "、"))")
            }

            Text("注意到身體狀況：\(entry.bodyNoticeTiming.displayName)")
            if entry.bodyNoticeTiming == .none && !entry.bodyLateReasons.isEmpty {
                Text("原因：\(join(entry.bodyLateReasons.map{$0.displayName}, otherText: entry.bodyLateReasons.contains(.other) ? entry.bodyLateOtherText : ""))")
            }
        }
        .font(fBody)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var observationBlock: some View {
        if !entry.specialObservation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SectionTitle(String(localized: "特別觀察"))
                Text(entry.specialObservation)
            }
            .font(fBody)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - 動態模組回顧

    /// 檢查某個內建模組是否有自訂問題
    private func isCustomized(_ kind: ModuleKind) -> Bool {
        guard let module = moduleStore.modules.first(where: { $0.kind == kind }) else { return false }
        return !(module.questions?.isEmpty ?? true)
    }

    /// 根據模組狀態選擇硬編碼或動態顯示
    @ViewBuilder
    private func reviewSection(for kind: ModuleKind, hardcoded: some View) -> some View {
        if isCustomized(kind), let module = moduleStore.modules.first(where: { $0.kind == kind }) {
            customModuleReviewBlock(module: module)
        } else {
            hardcoded
        }
    }

    /// 無硬編碼版本（只在自訂時顯示）
    @ViewBuilder
    private func reviewSection(for kind: ModuleKind) -> some View {
        if isCustomized(kind), let module = moduleStore.modules.first(where: { $0.kind == kind }) {
            customModuleReviewBlock(module: module)
        }
    }

    /// 動態渲染模組回顧
    private func customModuleReviewBlock(module: DailyLogModule) -> some View {
        let questions = module.displayQuestions
        return VStack(alignment: .leading, spacing: 6) {
            SectionTitle(module.displayTitle)
            ForEach(questions) { q in
                if let answer = entry.customAnswers.first(where: { $0.questionId == q.id }) {
                    answerLine(question: q, answer: answer)
                }
            }
        }
        .font(fBody)
        .foregroundStyle(.secondary)
    }

    /// 渲染單一問題的答案
    @ViewBuilder
    private func answerLine(question: QuestionDefinition, answer: CustomAnswer) -> some View {
        switch question.type {
        case .slider, .numberInput:
            if let v = answer.intValue {
                Text("\(question.title)：\(v)")
            }
        case .singleSelect:
            if let v = answer.stringValue, !v.isEmpty {
                let otherSuffix: String = {
                    if v == "其他", let otherText = answer.otherText, !otherText.isEmpty {
                        return "（\(otherText)）"
                    }
                    return ""
                }()
                Text("\(question.title)：\(v)\(otherSuffix)")
            }
        case .multiSelect:
            if let arr = answer.stringArrayValue, !arr.isEmpty {
                let text = joinCustom(arr, otherText: answer.otherText ?? "")
                Text("\(question.title)：\(text)")
            }
        case .freeText:
            if let v = answer.stringValue, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("\(question.title)：\(v)")
            }
        case .timePicker:
            if let d = answer.dateValue {
                Text("\(question.title)：\(d.formatted(date: .omitted, time: .shortened))")
            }
        case .nestedMultiSelect:
            if let nested = answer.nestedValue {
                ForEach(Array(nested.keys.sorted()), id: \.self) { group in
                    if let items = nested[group], !items.isEmpty {
                        let otherText = answer.nestedOtherText?[group] ?? ""
                        Text("\(group)：\(joinCustom(items, otherText: otherText))")
                    }
                }
            }
        case .photo:
            EmptyView()
        }
    }

    /// 合併多選文字（處理「其他」）
    private func joinCustom(_ items: [String], otherText: String) -> String {
        let trimmed = otherText.trimmingCharacters(in: .whitespacesAndNewlines)
        // items 可能是 enum 的 displayName（已在地化）或使用者資料裡的原始字串（永遠是「其他」），
        // 兩種都要認得，否則切到英文/日文時「其他」會篩不掉。
        let otherLabel = String(localized: "其他")
        let isOther: (String) -> Bool = { $0 == otherLabel || $0 == "其他" }
        var base = items.filter { !isOther($0) }
        if items.contains(where: isOther), !trimmed.isEmpty {
            base.append(String(localized: "其他：\(trimmed)"))
        } else if items.contains(where: isOther) {
            base.append(otherLabel)
        }
        return base.isEmpty ? "--" : base.joined(separator: String(localized: "、"))
    }

    // MARK: - Helpers
    
    private func timeText(_ t: OptionalLogTime) -> String {
        switch t {
        case .unknown: return String(localized: "忘記")
        case .time(let d): return d.formatted(date: .omitted, time: .shortened)
        }
    }
    
    private var sleepHoursText: String {
        switch entry.sleepHours {
        case .unknown: return String(localized: "忘記")
        case .value(let h): return String(localized: "\(String(format: "%.1f", h)) 小時")
        }
    }
    
    private func join(_ items: [String], otherText: String) -> String {
        let trimmedOther = otherText.trimmingCharacters(in: .whitespacesAndNewlines)
        let otherLabel = String(localized: "其他")
        let isOther: (String) -> Bool = { $0 == otherLabel || $0 == "其他" }
        var base = items.filter { !isOther($0) }
        if items.contains(where: isOther), !trimmedOther.isEmpty {
            base.append(String(localized: "其他：\(trimmedOther)"))
        } else if items.contains(where: isOther) {
            base.append(otherLabel)
        }
        return base.isEmpty ? "--" : base.joined(separator: String(localized: "、"))
    }
    
    private func chipLine(_ items: [String]) -> some View {
        HStack(spacing: 8) {
            ForEach(items, id: \.self) { s in
                Text(s)
                    .font(fSmall)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
            }
            Spacer(minLength: 0)
        }
    }
}

private struct SectionTitle: View {
    let text: String
    /// 由檢視卡片透過 environment 傳入的字級倍率（預設 1.0）
    @Environment(\.dailyLogTextScale) private var scale
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 15 * scale, weight: .semibold))
            .foregroundStyle(.primary)
    }
}
