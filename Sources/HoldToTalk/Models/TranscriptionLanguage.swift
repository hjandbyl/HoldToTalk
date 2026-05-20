import Foundation

enum TranscriptionLanguage: String, CaseIterable, Identifiable, Sendable {
    case auto
    case zh
    case en
    case ja
    case id
    case es
    case pt
    case de
    case fr
    case ko
    case fil
    case ms
    case th
    case ar
    case it
    case bn
    case el
    case nl
    case ru
    case tr
    case vi
    case pl
    case ro
    case ne
    case uk
    case yue

    var id: String { rawValue }

    static let volcengineLanguages: [TranscriptionLanguage] = [
        .auto,
        .zh,
        .en,
        .ja,
        .id,
        .es,
        .pt,
        .de,
        .fr,
        .ko,
        .fil,
        .ms,
        .th,
        .ar,
        .it,
        .bn,
        .el,
        .nl,
        .ru,
        .tr,
        .vi,
        .pl,
        .ro,
        .ne,
        .uk,
        .yue
    ]

    static let sherpaOnnxLanguages: [TranscriptionLanguage] = [
        .auto,
        .zh,
        .en,
        .yue,
        .ja,
        .ko
    ]

    var title: String {
        switch self {
        case .auto: return L10n.tr("Auto")
        case .zh: return L10n.tr("Chinese (zh-CN)")
        case .en: return L10n.tr("English (en-US)")
        case .ja: return L10n.tr("Japanese (ja-JP)")
        case .id: return L10n.tr("Indonesian (id-ID)")
        case .es: return L10n.tr("Spanish (es-MX)")
        case .pt: return L10n.tr("Portuguese (pt-BR)")
        case .de: return L10n.tr("German (de-DE)")
        case .fr: return L10n.tr("French (fr-FR)")
        case .ko: return L10n.tr("Korean (ko-KR)")
        case .fil: return L10n.tr("Filipino (fil-PH)")
        case .ms: return L10n.tr("Malay (ms-MY)")
        case .th: return L10n.tr("Thai (th-TH)")
        case .ar: return L10n.tr("Arabic (ar-SA)")
        case .it: return L10n.tr("Italian (it-IT)")
        case .bn: return L10n.tr("Bengali (bn-BD)")
        case .el: return L10n.tr("Greek (el-GR)")
        case .nl: return L10n.tr("Dutch (nl-NL)")
        case .ru: return L10n.tr("Russian (ru-RU)")
        case .tr: return L10n.tr("Turkish (tr-TR)")
        case .vi: return L10n.tr("Vietnamese (vi-VN)")
        case .pl: return L10n.tr("Polish (pl-PL)")
        case .ro: return L10n.tr("Romanian (ro-RO)")
        case .ne: return L10n.tr("Nepali (ne-NP)")
        case .uk: return L10n.tr("Ukrainian (uk-UA)")
        case .yue: return L10n.tr("Cantonese (yue-CN)")
        }
    }

    var sherpaOnnxLanguageCode: String {
        switch self {
        case .auto:
            return "auto"
        case .zh:
            return "zh"
        case .en:
            return "en"
        case .yue:
            return "yue"
        case .ja:
            return "ja"
        case .ko:
            return "ko"
        default:
            return "auto"
        }
    }

    var volcengineLanguageCode: String? {
        switch self {
        case .auto:
            return nil
        case .zh:
            return "zh-CN"
        case .en:
            return "en-US"
        case .ja:
            return "ja-JP"
        case .id:
            return "id-ID"
        case .es:
            return "es-MX"
        case .pt:
            return "pt-BR"
        case .de:
            return "de-DE"
        case .fr:
            return "fr-FR"
        case .ko:
            return "ko-KR"
        case .fil:
            return "fil-PH"
        case .ms:
            return "ms-MY"
        case .th:
            return "th-TH"
        case .ar:
            return "ar-SA"
        case .it:
            return "it-IT"
        case .bn:
            return "bn-BD"
        case .el:
            return "el-GR"
        case .nl:
            return "nl-NL"
        case .ru:
            return "ru-RU"
        case .tr:
            return "tr-TR"
        case .vi:
            return "vi-VN"
        case .pl:
            return "pl-PL"
        case .ro:
            return "ro-RO"
        case .ne:
            return "ne-NP"
        case .uk:
            return "uk-UA"
        case .yue:
            return "yue-CN"
        }
    }
}
