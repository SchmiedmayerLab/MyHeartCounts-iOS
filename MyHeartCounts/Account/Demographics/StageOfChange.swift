//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import MHCStudyDefinition


struct StageOfChangeOption: Hashable, Identifiable, Sendable {
    let id: String
    let title: LocalizedStringResource?
    let text: LocalizedStringResource
    
    /// The option's short label: its letter in the Stanford study, and its title in the Imperial study.
    func label(for studyVariant: StudyVariant) -> LocalizedStringResource {
        studyVariant.localized(stanford: "\(id.uppercased())", imperial: title ?? "\(id.uppercased())")
    }
}


extension StageOfChangeOption: Codable {
    init?(id: ID) {
        if let option = (Self.allOptions + [.notSet]).first(where: { $0.id == id }) {
            self = option
        } else {
            return nil
        }
    }
    
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let id = try container.decode(ID.self)
        if let option = Self(id: id) {
            self = option
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unknown id '\(id)'"))
        }
    }
    
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(id)
    }
}


extension StageOfChangeOption {
    static let notSet = Self(id: "0", title: nil, text: "Not Set")
    
    static let allOptions: [Self] = [
        Self(id: "a", title: "STAGE_OF_CHANGE_OPTION_A_TITLE", text: "STAGE_OF_CHANGE_OPTION_A"),
        Self(id: "b", title: "STAGE_OF_CHANGE_OPTION_B_TITLE", text: "STAGE_OF_CHANGE_OPTION_B"),
        Self(id: "c", title: "STAGE_OF_CHANGE_OPTION_C_TITLE", text: "STAGE_OF_CHANGE_OPTION_C"),
        Self(id: "d", title: "STAGE_OF_CHANGE_OPTION_D_TITLE", text: "STAGE_OF_CHANGE_OPTION_D"),
        Self(id: "e", title: "STAGE_OF_CHANGE_OPTION_E_TITLE", text: "STAGE_OF_CHANGE_OPTION_E"),
        Self(id: "f", title: "STAGE_OF_CHANGE_OPTION_F_TITLE", text: "STAGE_OF_CHANGE_OPTION_F"),
        Self(id: "g", title: "STAGE_OF_CHANGE_OPTION_G_TITLE", text: "STAGE_OF_CHANGE_OPTION_G"),
        Self(id: "h", title: "STAGE_OF_CHANGE_OPTION_H_TITLE", text: "STAGE_OF_CHANGE_OPTION_H"),
        Self(id: "i", title: "STAGE_OF_CHANGE_OPTION_I_TITLE", text: "STAGE_OF_CHANGE_OPTION_I")
    ]
}
