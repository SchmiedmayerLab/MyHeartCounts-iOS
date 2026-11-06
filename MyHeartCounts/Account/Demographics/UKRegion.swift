//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation


enum UKRegion: Hashable, Codable, Sendable {
    case notSet
    case england(County)
    case scotland(County)
    case wales(County)
    case northernIreland(County)
    
    var displayTitle: LocalizedStringResource {
        switch self {
        case .notSet:
            "Not Set"
        case .england(let county):
            "England (\(county.name))"
        case .scotland(let county):
            "Scotland (\(county.name))"
        case .wales(let county):
            "Wales (\(county.name))"
        case .northernIreland(let county):
            "Northern Ireland (\(county.name))"
        }
    }
    
    var county: County? {
        switch self {
        case .notSet:
            nil
        case .england(let county), .scotland(let county), .wales(let county), .northernIreland(let county):
            county
        }
    }
    
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let stringValue = try container.decode(String.self)
        if stringValue == "notSet" {
            self = .notSet
            return
        }
        guard let separatorIdx = stringValue.firstIndex(of: ":"), separatorIdx < stringValue.endIndex else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unable to parse '\(stringValue)'"))
        }
        let regionName = stringValue[stringValue.startIndex..<separatorIdx]
        let countyName = stringValue[stringValue.index(after: separatorIdx)...]
        let county = County(name: String(countyName))
        switch regionName {
        case "england":
            self = .england(county)
        case "scotland":
            self = .scotland(county)
        case "wales":
            self = .wales(county)
        case "northernIreland":
            self = .northernIreland(county)
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unknown region '\(regionName)'"))
        }
    }
    
    func encode(to encoder: any Encoder) throws {
        let stringValue = switch self {
        case .notSet:
            "notSet"
        case .england(let county):
            "england:\(county.name)"
        case .scotland(let county):
            "scotland:\(county.name)"
        case .wales(let county):
            "wales:\(county.name)"
        case .northernIreland(let county):
            "northernIreland:\(county.name)"
        }
        var container = encoder.singleValueContainer()
        try container.encode(stringValue)
    }
}


extension UKRegion {
    struct County: Hashable, Codable, Identifiable, Sendable {
        let name: String // Intentionally not localizing these...
        
        var id: Self { self }
        
        init(name: String) {
            self.name = name
        }
        
        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            name = try container.decode(String.self)
        }
        
        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(name)
        }
    }
}


extension UKRegion.County {
    // periphery:ignore - ???
    static let preferNotToSay = Self(name: "Prefer not to state")
    
    static let englishCounties: [Self] = [
        Self(name: "Avon"),
        Self(name: "Bedfordshire"),
        Self(name: "Berkshire"),
        Self(name: "Buckinghamshire"),
        Self(name: "Cambridgeshire"),
        Self(name: "Cheshire"),
        Self(name: "Cleveland"),
        Self(name: "Cornwall"),
        Self(name: "County Durham"),
        Self(name: "Cumbria"),
        Self(name: "Derbyshire"),
        Self(name: "Devon"),
        Self(name: "Dorset"),
        Self(name: "East Sussex"),
        Self(name: "Essex"),
        Self(name: "Gloucestershire"),
        Self(name: "Hampshire"),
        Self(name: "Herefordshire"),
        Self(name: "Hertfordshire"),
        Self(name: "Isle of Wight"),
        Self(name: "Kent"),
        Self(name: "Lancashire"),
        Self(name: "Leicestershire"),
        Self(name: "Lincolnshire"),
        Self(name: "London"),
        Self(name: "Merseyside"),
        Self(name: "Middlesex"),
        Self(name: "Norfolk"),
        Self(name: "North Humberside"),
        Self(name: "North Yorkshire"),
        Self(name: "Northamptonshire"),
        Self(name: "Northumberland"),
        Self(name: "Nottinghamshire"),
        Self(name: "Oxfordshire"),
        Self(name: "Shropshire"),
        Self(name: "Somerset"),
        Self(name: "South Humberside"),
        Self(name: "South Yorkshire"),
        Self(name: "Staffordshire"),
        Self(name: "Suffolk"),
        Self(name: "Surrey"),
        Self(name: "Tyne and Wear"),
        Self(name: "Warwickshire"),
        Self(name: "West Midlands"),
        Self(name: "West Sussex"),
        Self(name: "West Yorkshire"),
        Self(name: "Wiltshire"),
        Self(name: "Worcestershire")
    ]
    
    static let scottishCounties: [Self] = [
        Self(name: "Aberdeenshire"),
        Self(name: "Angus"),
        Self(name: "Argyll"),
        Self(name: "Ayrshire"),
        Self(name: "Banffshire"),
        Self(name: "Berwickshire"),
        Self(name: "Caithness"),
        Self(name: "Clackmannanshire"),
        Self(name: "Dumfriesshire"),
        Self(name: "Dunbartonshire"),
        Self(name: "East Lothian"),
        Self(name: "Fife"),
        Self(name: "Inverness-shire"),
        Self(name: "Isle of Arran"),
        Self(name: "Isle of Barra"),
        Self(name: "Isle of Benbecula"),
        Self(name: "Isle of Bute"),
        Self(name: "Isle of Canna"),
        Self(name: "Isle of Coll"),
        Self(name: "Isle of Colonsay"),
        Self(name: "Isle of Cumbrae"),
        Self(name: "Isle of Eigg"),
        Self(name: "Isle of Gigha"),
        Self(name: "Isle of Harris"),
        Self(name: "Isle of Iona"),
        Self(name: "Isle of Islay"),
        Self(name: "Isle of Jura"),
        Self(name: "Isle of Lewis"),
        Self(name: "Isle of Mull"),
        Self(name: "Isle of North Uist"),
        Self(name: "Isle of Rhum"),
        Self(name: "Isle of Scalpay"),
        Self(name: "Isle of Skye"),
        Self(name: "Isle of South Uist"),
        Self(name: "Isle of Tiree"),
        Self(name: "Kincardineshire"),
        Self(name: "Kinross-shire"),
        Self(name: "Kirkcudbrightshire"),
        Self(name: "Lanarkshire"),
        Self(name: "Midlothian"),
        Self(name: "Morayshire"),
        Self(name: "Nairnshire"),
        Self(name: "Orkney"),
        Self(name: "Peeblesshire"),
        Self(name: "Perthshire"),
        Self(name: "Renfrewshire"),
        Self(name: "Ross-shire"),
        Self(name: "Roxburghshire"),
        Self(name: "Selkirkshire"),
        Self(name: "Shetland"),
        Self(name: "Stirlingshire"),
        Self(name: "Sutherland"),
        Self(name: "West Lothian"),
        Self(name: "Wigtownshire")
    ]
    
    static let welshCounties: [Self] = [
        Self(name: "Clwyd"),
        Self(name: "Dyfed"),
        Self(name: "Gwent"),
        Self(name: "Gwynedd"),
        Self(name: "Mid Glamorgan"),
        Self(name: "Powys"),
        Self(name: "South Glamorgan"),
        Self(name: "West Glamorgan")
    ]
    
    static let northernIrishCounties: [Self] = [
        Self(name: "Antrim"),
        Self(name: "Armagh"),
        Self(name: "Down"),
        Self(name: "Fermanagh"),
        Self(name: "Londonderry"),
        Self(name: "Tyrone")
    ]
}
