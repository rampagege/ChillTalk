import Foundation

/// Checks the current vocabulary against the user's own history, as a text-level test set:
/// - corrected records: would the errors the user fixed now be fixed automatically?
/// - accepted records: would the vocabulary now change text the user was happy with?
struct VocabularyReport {
    struct Miss: Identifiable, Hashable {
        var id: String { wrong + "→" + correct }
        let wrong: String
        let correct: String
    }

    struct OverCorrection: Identifiable {
        let id: UUID
        let before: String
        let after: String
    }

    var correctedRecords = 0
    var totalFixes = 0
    var nowFixed = 0
    var missed: [Miss] = []
    var acceptedRecords = 0
    var overCorrections: [OverCorrection] = []

    var fixRate: Double { totalFixes == 0 ? 0 : Double(nowFixed) / Double(totalFixes) }
}

@MainActor
enum VocabularyEvaluator {
    static let maxListed = 20

    static func evaluate(records: [DictationRecord], vocabulary: VocabularyStore) -> VocabularyReport {
        var report = VocabularyReport()
        var missed: [VocabularyReport.Miss] = []

        for record in records {
            let replayed = vocabulary.preview(record.finalText).text
            if let corrected = record.correctedText, corrected != record.finalText {
                report.correctedRecords += 1
                for fix in CorrectionDiff.substitutions(from: record.finalText, to: corrected) {
                    report.totalFixes += 1
                    if !replayed.contains(fix.wrong) && replayed.contains(fix.correct) {
                        report.nowFixed += 1
                    } else {
                        let miss = VocabularyReport.Miss(wrong: fix.wrong, correct: fix.correct)
                        if !missed.contains(miss) { missed.append(miss) }
                    }
                }
            } else {
                report.acceptedRecords += 1
                if replayed != record.finalText && report.overCorrections.count < maxListed {
                    report.overCorrections.append(.init(id: record.id, before: record.finalText, after: replayed))
                }
            }
        }
        report.missed = Array(missed.prefix(maxListed))
        return report
    }
}
