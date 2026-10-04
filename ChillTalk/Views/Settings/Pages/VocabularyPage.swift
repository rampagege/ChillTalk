import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct VocabularyPage: View {
    @EnvironmentObject private var vocabulary: VocabularyStore
    @EnvironmentObject private var model: SettingsModel
    @EnvironmentObject private var history: HistoryStore
    @State private var report: VocabularyReport?
    @State private var query = ""
    @State private var editing: VocabularyEntry?
    @State private var isAdding = false
    @State private var showPacks = false
    @State private var importMessage: String?

    private var filtered: [VocabularyEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return vocabulary.entries }
        return vocabulary.entries.filter { entry in
            entry.term.localizedCaseInsensitiveContains(q)
                || entry.misrecognitions.contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }

    var body: some View {
        SettingsPageView(title: String(localized: "词库"),
                         subtitle: String(localized: "人名、术语、产品名。识别时作为热词，识别错的写法会自动替换，润色时保持原样。")) {
            Card(title: String(localized: "背景说明")) {
                VStack(alignment: .leading, spacing: 8) {
                    ZStack(alignment: .topLeading) {
                        if model.recognitionContext.isEmpty {
                            Text("例如：我在医疗器械公司做产品，常聊 FDA 注册、CE 认证、临床试验、GLP-1 药物。")
                                .font(.system(size: 12.5))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 8)
                        }
                        TextEditor(text: Binding(
                            get: { model.recognitionContext },
                            set: { model.recognitionContext = String($0.prefix(SettingsManager.maxRecognitionContextLength)) }
                        ))
                        .font(.system(size: 12.5))
                        .scrollContentBackground(.hidden)
                        .frame(height: 64)
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Brand.field))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Brand.hairline))

                    HStack {
                        Text("告诉识别模型你平时聊什么领域，它会据此判断发音相近的词。支持阿里云百炼和 Soniox。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if model.recentlySaved == "recognitionContext" { SavedBadge() }
                        Text("\(model.recognitionContext.count)/\(SettingsManager.maxRecognitionContextLength)")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(14)
            }

            Card {
                CardRow(label: String(localized: "按发音自动纠正"),
                        detail: String(localized: "识别成同音或近音字时（如「四美格鲁泰」→「司美格鲁肽」）自动改成词库里的写法。三个字以上的词生效；两个字的词需标为重点词 ★"),
                        savedKey: "phoneticCorrection") {
                    Toggle("", isOn: $model.phoneticCorrection)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

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

                Text("\(vocabulary.entries.count) 个词")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize()

                Menu {
                    Button("行业词库…") { showPacks = true }
                    Divider()
                    Button("从文件导入…") { importFile() }
                    Button("导出到文件…") { exportFile() }
                        .disabled(vocabulary.entries.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("行业词库、导入、导出")

                Button {
                    isAdding = true
                } label: {
                    Label("添加", systemImage: "plus")
                }
                .buttonStyle(BrandButtonStyle())
            }

            if let message = importMessage {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Brand.mint)
            }

            Card {
                if filtered.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "character.book.closed")
                            .font(.system(size: 26))
                            .foregroundStyle(.tertiary)
                        Text(query.isEmpty ? String(localized: "在「历史」里纠正说错的词，或手动添加人名、术语。") : String(localized: "没有匹配「\(query)」的词"))
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { CardDivider() }
                            VocabularyRow(entry: entry) { editing = entry }
                        }
                    }
                }
            }

            Card(title: String(localized: "效果检验")) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(reportSummary)
                            .font(.system(size: 13, weight: .medium))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("用你在「历史」里纠正过的记录检验当前词库；没改过的记录用来发现误改。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Button(report == nil ? String(localized: "开始检验") : String(localized: "重新检验")) {
                        report = VocabularyEvaluator.evaluate(records: history.displayRecords, vocabulary: vocabulary)
                    }
                    .buttonStyle(BrandButtonStyle(prominent: report == nil))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                if let report = report, !report.missed.isEmpty {
                    CardDivider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("还没被自动纠正的错误")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        ForEach(report.missed) { miss in
                            HStack(spacing: 8) {
                                Text(miss.wrong).foregroundStyle(.secondary)
                                Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                                Text(miss.correct).fontWeight(.medium)
                                Spacer()
                                Button("加入词库") {
                                    vocabulary.add(term: miss.correct, misrecognitions: [miss.wrong], source: .correction)
                                    self.report = VocabularyEvaluator.evaluate(records: history.displayRecords, vocabulary: vocabulary)
                                }
                                .buttonStyle(BrandButtonStyle(prominent: false))
                            }
                            .font(.system(size: 12.5))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }

                if let report = report, !report.overCorrections.isEmpty {
                    CardDivider()
                    VStack(alignment: .leading, spacing: 6) {
                        Label("可能误改：这些你没改过的记录，按当前词库会被改动", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Brand.warning)
                        ForEach(report.overCorrections) { item in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.before).foregroundStyle(.secondary).strikethrough()
                                Text(item.after)
                            }
                            .font(.system(size: 12))
                            .lineLimit(1)
                        }
                        Text("如果是误改，可以关掉对应词的自动替换，或关闭「按发音自动纠正」。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }

            if vocabulary.entries.count > 300 {
                Label("词太多时热词之间会互相干扰，建议保留常用的几百个。", systemImage: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showPacks) {
            VocabularyPacksSheet()
        }
        .sheet(isPresented: $isAdding) {
            VocabularyEditor(title: String(localized: "添加词"), term: "", misrecognitions: "") { term, wrong in
                vocabulary.add(term: term, misrecognitions: wrong, source: .manual)
            }
        }
        .sheet(item: $editing) { entry in
            VocabularyEditor(title: String(localized: "编辑词"), term: entry.term,
                             misrecognitions: entry.misrecognitions.joined(separator: "，")) { term, wrong in
                var updated = entry
                updated.term = term
                updated.misrecognitions = wrong
                vocabulary.update(updated)
            }
        }
    }
}

extension VocabularyPage {
    private var reportSummary: String {
        guard let r = report else { return String(localized: "还没有检验") }
        if r.totalFixes == 0 {
            return String(localized: "历史里还没有纠正过的记录，先在「历史」里纠正几条再来检验。")
                + (r.overCorrections.isEmpty ? "" : String(localized: "（发现 \(r.overCorrections.count) 条可能误改）"))
        }
        let percent = Int((r.fixRate * 100).rounded())
        var text = String(localized: "\(r.totalFixes) 处纠正中，现在能自动纠正 \(r.nowFixed) 处（\(percent)%）")
        text += r.overCorrections.isEmpty ? String(localized: "，未发现误改") : String(localized: "，发现 \(r.overCorrections.count) 条可能误改")
        return text
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .commaSeparatedText, .tabSeparatedText]
        panel.message = String(localized: "每行一个词，可在后面用逗号列出常被识别成的写法")
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let items = VocabularyFile.parse(text)
        let added = vocabulary.addMany(items, source: .imported)
        flash(String(localized: "导入 \(items.count) 行，新增 \(added) 个词"))
    }

    private func exportFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = String(localized: "ChillTalk 词库.csv")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try VocabularyFile.export(vocabulary.entries).write(to: url, atomically: true, encoding: .utf8)
            flash(String(localized: "已导出 \(vocabulary.entries.count) 个词"))
        } catch {
            flash(String(localized: "导出失败：\(error.localizedDescription)"))
        }
    }

    private func flash(_ message: String) {
        importMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { importMessage = nil }
    }
}

private struct VocabularyPacksSheet: View {
    @EnvironmentObject private var vocabulary: VocabularyStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("行业词库")
                    .font(.system(size: 15, weight: .semibold))
                Text("一键加入常用术语，已有的词不会重复。加入后可以在词库里删改。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(Array(VocabularyPack.all.enumerated()), id: \.element.id) { index, pack in
                    if index > 0 { CardDivider() }
                    let have = pack.terms.filter { vocabulary.contains(term: $0) }.count
                    HStack(spacing: 12) {
                        Image(systemName: pack.icon)
                            .font(.system(size: 14))
                            .foregroundStyle(Brand.mint)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pack.name)
                                .font(.system(size: 13, weight: .medium))
                            Text(pack.terms.prefix(6).joined(separator: "、") + "…")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 12)
                        if have == pack.terms.count {
                            Label("已加入", systemImage: "checkmark")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Brand.mint)
                        } else {
                            Button(have > 0 ? String(localized: "补全 \(pack.terms.count - have) 个") : String(localized: "加入 \(pack.terms.count) 个")) {
                                vocabulary.addMany(pack.terms.map { ($0, []) }, source: .pack)
                            }
                            .buttonStyle(BrandButtonStyle(prominent: have == 0))
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Brand.card))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Brand.hairline))

            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(BrandButtonStyle(prominent: false))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480)
        .tint(Brand.mint)
    }
}

private struct VocabularyRow: View {
    let entry: VocabularyEntry
    let onEdit: () -> Void
    @EnvironmentObject private var vocabulary: VocabularyStore
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.term)
                    .font(.system(size: 13.5, weight: .semibold))
                if entry.misrecognitions.isEmpty {
                    Text("仅作为热词")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                } else {
                    Text(entry.misrecognitions.joined(separator: "、") + (entry.autoReplace ? String(localized: " → 自动替换") : String(localized: " · 不替换")))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            Button {
                var updated = entry
                updated.isKey = !(entry.isKey ?? false)
                vocabulary.update(updated)
            } label: {
                Image(systemName: entry.isKey == true ? "star.fill" : "star")
                    .font(.system(size: 12))
                    .foregroundStyle(entry.isKey == true ? Brand.warning : .secondary)
            }
            .buttonStyle(.plain)
            .opacity(entry.isKey == true || isHovered ? 1 : 0)
            .disabled(entry.isKey != true && vocabulary.keyTermCount >= VocabularyStore.maxKeyTerms)
            .help(entry.isKey == true ? String(localized: "取消重点词") : String(localized: "设为重点词：识别时最高优先级（最多 \(VocabularyStore.maxKeyTerms) 个）"))
            if entry.hitCount > 0 {
                Text("替换 \(entry.hitCount) 次")
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if !entry.misrecognitions.isEmpty {
                Toggle("", isOn: Binding(
                    get: { entry.autoReplace },
                    set: { value in
                        var updated = entry
                        updated.autoReplace = value
                        vocabulary.update(updated)
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("自动替换")
            }
            Button {
                vocabulary.delete(id: entry.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0)
            .help("删除")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .background(isHovered ? Brand.hairline.opacity(0.5) : Color.clear)
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onEdit)
    }
}

/// Add/edit sheet. Misrecognitions are entered comma-separated.
private struct VocabularyEditor: View {
    let title: String
    @State var term: String
    @State var misrecognitions: String
    let onSave: (String, [String]) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("正确写法")
                    .font(.system(size: 12, weight: .medium))
                BrandTextField(placeholder: String(localized: "例如 Linear"), text: $term, width: 320)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("常被识别成（可选，用逗号分隔）")
                    .font(.system(size: 12, weight: .medium))
                BrandTextField(placeholder: String(localized: "例如 令尼亚，宁尼尔"), text: $misrecognitions, width: 320)
                Text("少于 2 个字的写法不会自动替换，避免误伤正常用词。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(BrandButtonStyle(prominent: false))
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    onSave(term, Self.split(misrecognitions))
                    dismiss()
                }
                .buttonStyle(BrandButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(term.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 380)
        .tint(Brand.mint)
    }

    static func split(_ text: String) -> [String] {
        text.split(whereSeparator: { ",，、;；\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
