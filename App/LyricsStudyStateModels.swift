import CoreGraphics
import Foundation
import ShinAIProvider
import ShinAppleKit
import ShinAppServices

/// 歌词文本选区快照：锚定到文档、修订版、稳定行 ID 与视口坐标。
struct LyricsWordSelection: Equatable, Sendable {
    let documentId: UUID
    let documentRevision: Int
    let lineId: UUID
    let lineText: String
    let lineTranslation: String?
    let startMs: Int64?
    let surface: String
    let utf16Location: Int
    let utf16Length: Int
    let anchorRectInScrollViewport: CGRect
}

/// 划词学习详情 Popover 状态。
struct WordPopoverState: Identifiable, Equatable {
    let id: UUID
    let documentId: UUID
    let documentRevision: Int
    let lineId: UUID
    let lineText: String
    let lineTranslation: String?
    let startMs: Int64?
    let surface: String
    let utf16Location: Int
    let utf16Length: Int
    let anchorRectInScrollViewport: CGRect
    let localResult: LocalDictionaryLookupResult
    let formattedDictionary: FormattedDictionaryEntry?
    var isLoadingAI: Bool = false
    var aiExplanation: AIWordExplanation?
    var aiErrorMessage: String?
    var draftGeneralMeaning: String = ""
    var draftContextualMeaning: String = ""
    var draftUserNote: String = ""
    var hasEditedGeneralMeaning: Bool = false
    var hasEditedContextualMeaning: Bool = false
    var isSaving: Bool = false
    var savedEntryId: UUID?
    var saveSuccessMessage: String?
    var saveErrorMessage: String?

    init(
        id: UUID,
        documentId: UUID,
        documentRevision: Int,
        lineId: UUID,
        lineText: String,
        lineTranslation: String?,
        startMs: Int64?,
        surface: String,
        utf16Location: Int,
        utf16Length: Int,
        anchorRectInScrollViewport: CGRect,
        localResult: LocalDictionaryLookupResult,
        formattedDictionary: FormattedDictionaryEntry? = nil,
        isLoadingAI: Bool = false,
        aiExplanation: AIWordExplanation? = nil,
        aiErrorMessage: String? = nil,
        draftGeneralMeaning: String = "",
        draftContextualMeaning: String = "",
        draftUserNote: String = "",
        hasEditedGeneralMeaning: Bool = false,
        hasEditedContextualMeaning: Bool = false,
        isSaving: Bool = false,
        savedEntryId: UUID? = nil,
        saveSuccessMessage: String? = nil,
        saveErrorMessage: String? = nil
    ) {
        self.id = id
        self.documentId = documentId
        self.documentRevision = documentRevision
        self.lineId = lineId
        self.lineText = lineText
        self.lineTranslation = lineTranslation
        self.startMs = startMs
        self.surface = surface
        self.utf16Location = utf16Location
        self.utf16Length = utf16Length
        self.anchorRectInScrollViewport = anchorRectInScrollViewport
        self.localResult = localResult
        self.formattedDictionary = formattedDictionary
        self.isLoadingAI = isLoadingAI
        self.aiExplanation = aiExplanation
        self.aiErrorMessage = aiErrorMessage
        self.draftGeneralMeaning = draftGeneralMeaning
        self.draftContextualMeaning = draftContextualMeaning
        self.draftUserNote = draftUserNote
        self.hasEditedGeneralMeaning = hasEditedGeneralMeaning
        self.hasEditedContextualMeaning = hasEditedContextualMeaning
        self.isSaving = isSaving
        self.savedEntryId = savedEntryId
        self.saveSuccessMessage = saveSuccessMessage
        self.saveErrorMessage = saveErrorMessage
    }
}

/// 整句学习解析与笔记 Popover 状态。
struct LinePopoverState: Identifiable, Equatable {
    let id: UUID
    let documentId: UUID
    var documentRevision: Int
    let lineId: UUID
    let lineText: String
    let lineTranslation: String?
    let startMs: Int64?
    let anchorRectInScrollViewport: CGRect
    var existingNote: LineStudyNote?
    var isLoadingAI: Bool = false
    var aiExplanation: AILineExplanation?
    var aiErrorMessage: String?
    var draftGrammarSummary: String = ""
    var draftSingingTips: String = ""
    var draftCulturalNote: String = ""
    var usedAIForDraft: Bool = false
    var hasEditedAfterAI: Bool = false
    var isSavingNote: Bool = false
    var saveSuccessMessage: String?
    var saveErrorMessage: String?
}

/// 单句歌词 / 注音 / 译文快捷编辑 Popover 状态。
struct LineQuickEditState: Identifiable, Equatable {
    let id: UUID
    let documentId: UUID
    let documentRevision: Int
    let lineId: UUID
    let startMs: Int64?
    let originalText: String
    let initialPronunciation: String
    let initialPronunciationStyle: PronunciationStyle
    let hadInitialPronunciation: Bool
    let initialTranslation: String
    let pronunciationNeedsReview: Bool
    let translationNeedsReview: Bool
    let anchorRectInScrollViewport: CGRect
    var draftText: String
    var draftPronunciation: String
    var draftPronunciationStyle: PronunciationStyle
    var draftTranslation: String
    var isSaving: Bool = false
    var errorMessage: String?

    var textChanged: Bool { draftText != originalText }

    var trimmedPronunciation: String {
        draftPronunciation.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var pronunciationChanged: Bool {
        trimmedPronunciation != initialPronunciation
            || (!trimmedPronunciation.isEmpty && hadInitialPronunciation
                && draftPronunciationStyle != initialPronunciationStyle)
    }

    var trimmedTranslation: String {
        draftTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var translationChanged: Bool { trimmedTranslation != initialTranslation }

    var hasChanges: Bool {
        textChanged || pronunciationChanged || translationChanged
    }
}

/// 歌词行右键或浮动条展示单句 / AB 循环入口所需的可用状态快照。
struct LyricsLineLoopMenuState: Equatable, Sendable {
    let canSingleLineLoop: Bool
    let isCurrentSingleLineLoop: Bool
    let hasPendingAnchor: Bool
    let canSetAnchor: Bool
    let canCompleteABLoop: Bool
}
