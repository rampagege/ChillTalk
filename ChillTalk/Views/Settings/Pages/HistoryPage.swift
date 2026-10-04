import SwiftUI

struct HistoryPage: View {
    @EnvironmentObject private var history: HistoryStore
    @State private var query = ""
    @State private var confirmClear = false
    /// Rows shown; grows by `pageSize` with "显示更多". Search always covers everything.
    @State private var visibleCount = HistoryPage.pageSize
    static let pageSize = 50

    private var filtered: [DictationRecord] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return history.displayRecords }
        return history.displayRecords.filter {
            $0.displayText.localizedCaseInsensitiveContains(q) || $0.rawText.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        SettingsPageView(title: String(localized: "历史"), subtitle: String(localized: "最近 \(HistoryStore.maxRecords) 条结果，只保存在这台 Mac 上。")) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    TextField("搜索", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Brand.field))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Brand.hairline))

                Toggle("保存历史", isOn: $history.isHistoryEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 12.5))

                Button("清空") { confirmClear = true }
                    .buttonStyle(BrandButtonStyle(prominent: false))
                    .disabled(history.records.isEmpty)
            }
            .onChange(of: query) { visibleCount = Self.pageSize }
            .confirmationDialog("清空全部历史记录？", isPresented: $confirmClear) {
                Button("清空", role: .destructive) { history.clearHistory() }
            } message: {
                Text("用量统计会保留。此操作无法撤销。")
            }

            Card {
                if filtered.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 26))
                            .foregroundStyle(.tertiary)
                        Text(emptyText)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    let shown = filtered.prefix(visibleCount)
                    LazyVStack(spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, record in
                            if index > 0 { CardDivider() }
                            HistoryRow(record: record)
                        }
                    }
                    if filtered.count > shown.count {
                        CardDivider()
                        Button {
                            visibleCount += Self.pageSize
                        } label: {
                            Text("显示更多（还有 \(filtered.count - shown.count) 条）")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(Brand.mint)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var emptyText: String {
        if !query.isEmpty { return String(localized: "没有匹配「\(query)」的记录") }
        return history.isHistoryEnabled ? String(localized: "还没有记录") : String(localized: "历史记录已关闭，新的结果不会被保存")
    }
}

private struct HistoryRow: View {
    let record: DictationRecord
    @EnvironmentObject private var history: HistoryStore
    @State private var isHovered = false
    @State private var isExpanded = false
    @State private var copied = false
    @State private var isEditing = false
    @State private var draft = ""
    @State private var candidates: [CorrectionCandidate] = []
    @State private var showCandidates = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(record.date, format: .dateTime.month().day().hour().minute())
                            .font(.system(size: 11).monospacedDigit())
                        Text("·")
                        Text(record.asrProvider)
                        if record.polished {
                            Text("·")
                            Text("已润色")
                        }
                        if let device = record.deviceName {
                            Text("·")
                            Label(device, systemImage: "laptopcomputer")
                        }
                        if record.correctedText != nil {
                            Text("·")
                            Text("已纠正").foregroundStyle(Brand.mint)
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                    if isEditing {
                        TextEditor(text: $draft)
                            .font(.system(size: 13))
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .frame(minHeight: 60)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Brand.field))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Brand.mint.opacity(0.6)))
                        HStack(spacing: 8) {
                            Text("改好后保存，说错的词可以记进词库")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("取消") { isEditing = false }
                                .buttonStyle(BrandButtonStyle(prominent: false))
                            Button("保存") { saveCorrection() }
                                .buttonStyle(BrandButtonStyle())
                                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    } else {
                        Text(record.displayText)
                            .font(.system(size: 13))
                            .lineLimit(isExpanded ? nil : 2)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 8)
                if !isEditing {
                    HStack(spacing: 12) {
                        if !record.isFromOtherDevice {
                            Button {
                                draft = record.displayText
                                isEditing = true
                            } label: {
                                Label("纠正", systemImage: "pencil")
                            }
                        }
                        Button {
                            copyToPasteboard(record.displayText)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                        } label: {
                            Label(copied ? String(localized: "已复制") : String(localized: "复制"), systemImage: copied ? "checkmark" : "doc.on.doc")
                                .foregroundStyle(copied ? Brand.mint : .secondary)
                        }
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                    .opacity(isHovered || copied ? 1 : 0)
                }
            }

            if isExpanded && !isEditing && record.displayText != record.rawText {
                VStack(alignment: .leading, spacing: 4) {
                    Text("识别原文")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(record.rawText)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Brand.field))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .background(isHovered && !isEditing ? Brand.hairline.opacity(0.5) : Color.clear)
        .onHover { isHovered = $0 }
        .onTapGesture {
            guard !isEditing else { return }
            withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
        }
        .sheet(isPresented: $showCandidates) {
            CorrectionSheet(candidates: $candidates)
        }
    }

    private func saveCorrection() {
        let original = record.displayText
        let corrected = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditing = false
        guard corrected != original else { return }
        history.correct(id: record.id, text: corrected)
        // Handy for pasting the fixed text back where it went.
        copyToPasteboard(corrected)

        candidates = CorrectionDiff.substitutions(from: original, to: corrected)
            .map { CorrectionCandidate(wrong: $0.wrong, correct: $0.correct) }
        showCandidates = !candidates.isEmpty
    }
}

struct CorrectionCandidate: Identifiable {
    let id = UUID()
    var isSelected = true
    var wrong: String
    var correct: String
}

/// "记住这些纠正？" — lets the user pick and adjust the substitutions found in their edit.
private struct CorrectionSheet: View {
    @Binding var candidates: [CorrectionCandidate]
    @EnvironmentObject private var vocabulary: VocabularyStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("记住这些纠正？")
                    .font(.system(size: 15, weight: .semibold))
                Text("以后识别时会优先认出右边的词，左边的写法会自动替换。纠正后的文字已复制到剪贴板。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 8) {
                ForEach($candidates) { $candidate in
                    HStack(spacing: 8) {
                        Toggle("", isOn: $candidate.isSelected)
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                        BrandTextField(placeholder: String(localized: "识别成"), text: $candidate.wrong, width: 130)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        BrandTextField(placeholder: String(localized: "正确写法"), text: $candidate.correct, width: 150)
                    }
                    .opacity(candidate.isSelected ? 1 : 0.5)
                }
            }

            HStack {
                Spacer()
                Button("跳过") { dismiss() }
                    .buttonStyle(BrandButtonStyle(prominent: false))
                    .keyboardShortcut(.cancelAction)
                Button("记住") {
                    for c in candidates where c.isSelected {
                        vocabulary.add(term: c.correct, misrecognitions: [c.wrong], source: .correction)
                    }
                    dismiss()
                }
                .buttonStyle(BrandButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!candidates.contains { $0.isSelected && !$0.correct.trimmingCharacters(in: .whitespaces).isEmpty })
            }
        }
        .padding(22)
        .frame(width: 400)
        .tint(Brand.mint)
    }
}
