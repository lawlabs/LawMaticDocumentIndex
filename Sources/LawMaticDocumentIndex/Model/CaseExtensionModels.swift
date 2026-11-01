import Foundation

/// Карточка дела сверх ядра `cases.title`. Поля — то, что Finder сейчас держит
/// в `CaseMetadata`; `participants_json` и `extra_json` оставляют запас
/// без смены DDL.
public struct CaseCardRecord: Equatable, Sendable {
    public var caseId: String
    public var caseNumber: String
    public var caseDescription: String
    public var goals: String
    public var tasks: String
    public var userRole: String
    public var strategy: String
    public var keyPoints: String
    public var risks: String
    public var expectedOutcome: String
    public var clientInstructions: String
    public var court: String
    public var category: String
    public var status: String
    public var legalicGuid: String
    public var lmpmGuid: String
    public var participantsJSON: String
    public var extraJSON: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        caseId: String,
        caseNumber: String = "",
        caseDescription: String = "",
        goals: String = "",
        tasks: String = "",
        userRole: String = "",
        strategy: String = "",
        keyPoints: String = "",
        risks: String = "",
        expectedOutcome: String = "",
        clientInstructions: String = "",
        court: String = "",
        category: String = "",
        status: String = "",
        legalicGuid: String = "",
        lmpmGuid: String = "",
        participantsJSON: String = "[]",
        extraJSON: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.caseId = caseId
        self.caseNumber = caseNumber
        self.caseDescription = caseDescription
        self.goals = goals
        self.tasks = tasks
        self.userRole = userRole
        self.strategy = strategy
        self.keyPoints = keyPoints
        self.risks = risks
        self.expectedOutcome = expectedOutcome
        self.clientInstructions = clientInstructions
        self.court = court
        self.category = category
        self.status = status
        self.legalicGuid = legalicGuid
        self.lmpmGuid = lmpmGuid
        self.participantsJSON = participantsJSON
        self.extraJSON = extraJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Строка списка дела: факт, доказательство, обстоятельство или задача.
///
/// Колонки `title`/`body` нужны для выборок без разбора JSON; полный объект
/// Finder кладёт в `payloadJSON`, чтобы dual-write не терял поля.
public enum CaseListKind: String, Sendable, CaseIterable {
    case fact
    case evidence
    case circumstance
    case lawyerTask
}

public struct CaseListItemRecord: Equatable, Sendable, Identifiable {
    public var id: String
    public var caseId: String
    public var kind: CaseListKind
    public var sortIndex: Int
    public var title: String
    public var body: String
    public var payloadJSON: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = "",
        caseId: String,
        kind: CaseListKind,
        sortIndex: Int = 0,
        title: String,
        body: String = "",
        payloadJSON: String = "{}",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.caseId = caseId
        self.kind = kind
        self.sortIndex = sortIndex
        self.title = title
        self.body = body
        self.payloadJSON = payloadJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct CaseTagRecord: Equatable, Sendable, Identifiable {
    public var id: String
    public var caseId: String
    public var sortIndex: Int
    public var name: String
    public var color: String?
    public var payloadJSON: String?
    public var createdAt: Date

    public init(
        id: String = "",
        caseId: String,
        sortIndex: Int = 0,
        name: String,
        color: String? = nil,
        payloadJSON: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.caseId = caseId
        self.sortIndex = sortIndex
        self.name = name
        self.color = color
        self.payloadJSON = payloadJSON
        self.createdAt = createdAt
    }
}

public struct DocumentUserMetadataRecord: Equatable, Sendable {
    public var documentId: String
    public var notes: String?
    public var importance: String
    public var confidentiality: String
    public var legalRelevance: String
    public var isEvidence: Bool
    public var evidenceDescription: String?
    public var tagsJSON: String
    public var payloadJSON: String?
    public var updatedAt: Date

    public init(
        documentId: String,
        notes: String? = nil,
        importance: String = "normal",
        confidentiality: String = "public",
        legalRelevance: String = "normal",
        isEvidence: Bool = false,
        evidenceDescription: String? = nil,
        tagsJSON: String = "[]",
        payloadJSON: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.documentId = documentId
        self.notes = notes
        self.importance = importance
        self.confidentiality = confidentiality
        self.legalRelevance = legalRelevance
        self.isEvidence = isEvidence
        self.evidenceDescription = evidenceDescription
        self.tagsJSON = tagsJSON
        self.payloadJSON = payloadJSON
        self.updatedAt = updatedAt
    }
}

public struct AnonymizationRunRecord: Equatable, Sendable, Identifiable {
    public var id: String
    public var documentId: String
    public var caseId: String?
    public var sourceTextVariantId: String?
    public var resultTextVariantId: String?
    public var status: String
    public var method: String?
    public var modelName: String?
    public var notes: String?
    public var rulesJSON: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = "",
        documentId: String,
        caseId: String? = nil,
        sourceTextVariantId: String? = nil,
        resultTextVariantId: String? = nil,
        status: String,
        method: String? = nil,
        modelName: String? = nil,
        notes: String? = nil,
        rulesJSON: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.documentId = documentId
        self.caseId = caseId
        self.sourceTextVariantId = sourceTextVariantId
        self.resultTextVariantId = resultTextVariantId
        self.status = status
        self.method = method
        self.modelName = modelName
        self.notes = notes
        self.rulesJSON = rulesJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct AnonymizationEntityRecord: Equatable, Sendable, Identifiable {
    public var id: String
    public var runId: String
    public var caseId: String?
    public var entityType: String
    public var entitySubtype: String?
    public var originalValue: String
    public var replacementValue: String
    public var normalizedOriginal: String?
    public var normalizedReplacement: String?
    public var legalRole: String?
    public var personGender: String?
    public var personKind: String?
    public var numberType: String?
    public var confidence: Double?
    public var metadataJSON: String?

    public init(
        id: String = "",
        runId: String,
        caseId: String? = nil,
        entityType: String,
        entitySubtype: String? = nil,
        originalValue: String,
        replacementValue: String,
        normalizedOriginal: String? = nil,
        normalizedReplacement: String? = nil,
        legalRole: String? = nil,
        personGender: String? = nil,
        personKind: String? = nil,
        numberType: String? = nil,
        confidence: Double? = nil,
        metadataJSON: String? = nil
    ) {
        self.id = id
        self.runId = runId
        self.caseId = caseId
        self.entityType = entityType
        self.entitySubtype = entitySubtype
        self.originalValue = originalValue
        self.replacementValue = replacementValue
        self.normalizedOriginal = normalizedOriginal
        self.normalizedReplacement = normalizedReplacement
        self.legalRole = legalRole
        self.personGender = personGender
        self.personKind = personKind
        self.numberType = numberType
        self.confidence = confidence
        self.metadataJSON = metadataJSON
    }
}

/// Связь двух документов внутри одного дела.
public struct DocumentRelationRecord: Equatable, Sendable, Identifiable {
    public var id: String
    public var caseId: String
    public var sourceDocumentId: String
    public var targetDocumentId: String
    public var relationType: String
    public var sortIndex: Int
    public var payloadJSON: String?
    public var createdAt: Date

    public init(
        id: String = "",
        caseId: String,
        sourceDocumentId: String,
        targetDocumentId: String,
        relationType: String,
        sortIndex: Int = 0,
        payloadJSON: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.caseId = caseId
        self.sourceDocumentId = sourceDocumentId
        self.targetDocumentId = targetDocumentId
        self.relationType = relationType
        self.sortIndex = sortIndex
        self.payloadJSON = payloadJSON
        self.createdAt = createdAt
    }
}

/// Конкретное вхождение замены: смещения в UTF-16, как в `variant_pages`.
public struct AnonymizationOccurrenceRecord: Equatable, Sendable, Identifiable {
    public var id: String
    public var entityId: String
    public var caseId: String?
    public var sourceTextVariantId: String?
    public var resultTextVariantId: String?
    public var originalFragment: String?
    public var replacementFragment: String?
    public var sourceStartOffset: Int?
    public var sourceEndOffset: Int?
    public var resultStartOffset: Int?
    public var resultEndOffset: Int?
    public var occurrenceIndex: Int?

    public init(
        id: String = "",
        entityId: String,
        caseId: String? = nil,
        sourceTextVariantId: String? = nil,
        resultTextVariantId: String? = nil,
        originalFragment: String? = nil,
        replacementFragment: String? = nil,
        sourceStartOffset: Int? = nil,
        sourceEndOffset: Int? = nil,
        resultStartOffset: Int? = nil,
        resultEndOffset: Int? = nil,
        occurrenceIndex: Int? = nil
    ) {
        self.id = id
        self.entityId = entityId
        self.caseId = caseId
        self.sourceTextVariantId = sourceTextVariantId
        self.resultTextVariantId = resultTextVariantId
        self.originalFragment = originalFragment
        self.replacementFragment = replacementFragment
        self.sourceStartOffset = sourceStartOffset
        self.sourceEndOffset = sourceEndOffset
        self.resultStartOffset = resultStartOffset
        self.resultEndOffset = resultEndOffset
        self.occurrenceIndex = occurrenceIndex
    }
}

extension CaseListKind {
    var tableName: String {
        switch self {
        case .fact: return "case_facts"
        case .evidence: return "case_evidences"
        case .circumstance: return "case_circumstances"
        case .lawyerTask: return "case_lawyer_tasks"
        }
    }
}
