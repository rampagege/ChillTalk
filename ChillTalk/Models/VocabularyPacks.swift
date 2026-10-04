import Foundation

/// Curated starter vocabularies. Chinese terms also get pronunciation matching; English
/// terms mainly work as hot words.
struct VocabularyPack: Identifiable {
    let id: String
    let name: String
    let icon: String
    let terms: [String]

    static let all: [VocabularyPack] = [
        VocabularyPack(id: "software", name: String(localized: "互联网 / 软件开发"), icon: "chevron.left.forwardslash.chevron.right", terms: [
            "GitHub", "GitLab", "Git", "Docker", "Kubernetes", "K8s", "Linux", "macOS", "iOS", "Android",
            "API", "SDK", "CI/CD", "DevOps", "Redis", "MySQL", "PostgreSQL", "MongoDB", "Kafka", "Nginx",
            "TypeScript", "JavaScript", "Python", "Swift", "Golang", "React", "Vue", "Node.js", "Next.js",
            "Figma", "Jira", "Linear", "Notion", "Slack", "飞书", "钉钉", "企业微信",
            "微服务", "中间件", "灰度发布", "回滚", "埋点", "并发", "幂等", "鉴权", "接口", "联调", "提测", "排期", "复盘"
        ]),
        VocabularyPack(id: "ai", name: String(localized: "AI / 大模型"), icon: "sparkles", terms: [
            "OpenAI", "ChatGPT", "GPT", "Claude", "Anthropic", "Gemini", "Llama", "Qwen", "通义千问", "DeepSeek",
            "深度求索", "豆包", "文心一言", "Kimi", "智谱", "Midjourney", "Stable Diffusion", "Hugging Face",
            "LLM", "RAG", "Agent", "MCP", "Prompt", "Token", "Embedding", "Transformer", "LoRA", "RLHF",
            "微调", "推理", "向量数据库", "多模态", "大语言模型", "上下文窗口", "幻觉", "蒸馏", "量化", "智能体"
        ]),
        VocabularyPack(id: "medical", name: String(localized: "医疗 / 医药"), icon: "cross.case", terms: [
            "司美格鲁肽", "替尔泊肽", "利拉鲁肽", "二甲双胍", "阿托伐他汀", "阿司匹林", "布洛芬", "对乙酰氨基酚",
            "奥美拉唑", "头孢曲松", "阿莫西林", "胰岛素", "糖化血红蛋白", "GLP-1", "PD-1", "CAR-T", "mRNA",
            "FDA", "NMPA", "CE 认证", "GMP", "临床试验", "随机对照试验", "适应症", "禁忌症", "不良反应",
            "药代动力学", "生物等效性", "仿制药", "创新药", "医疗器械", "注册证", "病理", "影像科", "核磁共振", "CT"
        ]),
        VocabularyPack(id: "finance", name: String(localized: "金融 / 投资"), icon: "chart.line.uptrend.xyaxis", terms: [
            "市盈率", "市净率", "净资产收益率", "现金流", "息税折旧摊销前利润", "EBITDA", "ROE", "ROI", "IRR",
            "IPO", "VC", "PE", "LP", "GP", "估值", "对赌协议", "尽职调查", "投资条款清单", "Term Sheet",
            "可转债", "期权", "期货", "对冲", "杠杆", "做空", "流动性", "量化交易", "港股", "美股", "科创板", "北交所",
            "美联储", "降息", "加息", "通胀", "国债收益率"
        ]),
        VocabularyPack(id: "legal", name: String(localized: "法律"), icon: "building.columns", terms: [
            "民法典", "公司法", "劳动合同法", "著作权法", "专利法", "商标法", "个人信息保护法", "数据安全法",
            "仲裁", "诉讼", "管辖权", "诉讼时效", "不可抗力", "违约金", "定金", "保证金", "连带责任",
            "知识产权", "竞业限制", "保密协议", "NDA", "尽职调查", "股权代持", "法定代表人", "实际控制人",
            "律师函", "起诉状", "答辩状", "判决书", "裁定书", "强制执行"
        ])
    ]
}

/// Plain-text vocabulary files: one term per line, optionally followed by misrecognitions,
/// separated by commas or tabs. Lines starting with # are ignored.
///
///     Linear,令尼亚,宁尼尔
///     司美格鲁肽
enum VocabularyFile {
    static func parse(_ text: String) -> [(term: String, misrecognitions: [String])] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            let parts = trimmed.split(whereSeparator: { ",，\t".contains($0) })
                .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
                .filter { !$0.isEmpty }
            guard let term = parts.first else { return nil }
            return (term, Array(parts.dropFirst()))
        }
    }

    static func export(_ entries: [VocabularyEntry]) -> String {
        let header = "# ChillTalk 词库：正确写法,常被识别成…\n"
        return header + entries.map { ([$0.term] + $0.misrecognitions).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }
}
