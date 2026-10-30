//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import FirebaseFirestore
import ModelsR4
@testable import MyHeartCounts
import Testing


@Suite
struct QuestionnairePersistenceTests {
    @Test
    @MainActor
    func responseIsReadableWhileServerAcknowledgementIsUnavailable() async throws {
        try await withQueryTestFirestore { firestore in
            let document = firestore.document("users/participant/questionnaireResponses/offline")
            let response = QuestionnaireResponse(status: FHIRPrimitive(.completed))

            try MyHeartCountsStandard.enqueueQuestionnaireResponse(response, to: document)

            let snapshot = try await document.getDocument(source: .cache)
            #expect(snapshot.exists)
            #expect(snapshot.data()?["status"] as? String == "completed")
            #expect(snapshot.metadata.hasPendingWrites)
        }
    }
}
