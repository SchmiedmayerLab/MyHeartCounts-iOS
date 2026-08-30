//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable file_types_order

import Foundation
import GroveFoundation
import GroveStudyDefinition
import MyHeartCountsShared
import SwiftUI


struct Article: Hashable, Identifiable, Sendable {
    enum ImageReference: Hashable, Sendable {
        case url(URL)
        case asset(String)
    }
    
    struct Tag: Hashable, Sendable {
        let title: String
        let color: Color
        
        init(title: String, color: Color) {
            self.title = String(title.trimmingLeadingAndTrailingWhitespace())
            self.color = color
        }
    }
    
    enum Status: String, Hashable, Sendable {
        case draft
        case published
    }
    
    let id: UUID
    let status: Status
    let title: String
    let date: Date?
    let tags: [Tag]
    let lede: String?
    let headerImage: ImageReference?
    let body: MarkdownDocument
    
    init(
        id: UUID,
        status: Status,
        title: String,
        date: Date? = nil,
        tags: [Tag] = [],
        lede: String? = nil,
        headerImage: ImageReference? = nil,
        body: MarkdownDocument
    ) {
        self.id = id
        self.status = status
        self.title = title
        self.date = date
        self.tags = tags.filter { !$0.title.isEmpty }
        self.lede = lede
        self.headerImage = headerImage
        self.body = body
    }
}


extension Article.Tag {
    private enum CodingKeys: CodingKey {
        case title
        case color
    }
    
    // periphery:ignore - implicitly called
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        color = Color(try container.decode(CodableColor.self, forKey: .color))
    }
    
    // periphery:ignore - implicitly called
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(CodableColor(color), forKey: .color)
    }
}


extension Article.ImageReference: RawRepresentable, Codable {
    typealias RawValue = String
    
    private enum DecodingError: Error {
        case unableToDecode(rawValue: String)
    }
    
    var rawValue: String {
        switch self {
        case .url(let url):
            url.absoluteURL.absoluteString
        case .asset(let name):
            name
        }
    }
    
    init?(rawValue: String) {
        if rawValue.starts(with: "https://"), let url = try? URL(rawValue, strategy: .url) {
            self = .url(url)
        } else {
            self = .asset(rawValue)
        }
    }
    
    init(from decoder: any Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(RawValue.self)
        if let value = Self(rawValue: rawValue) {
            self = value
        } else {
            throw DecodingError.unableToDecode(rawValue: rawValue)
        }
    }
    
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}


extension Article {
    init?(_ other: StudyDefinition.InformationalComponent, in studyBundle: StudyBundle, locale: Locale) {
        guard let url = studyBundle.resolve(other.fileRef, in: locale),
              let markdownDoc = try? MarkdownDocument(contentsOf: url) else {
            return nil
        }
        self.init(id: other.id, markdownDoc)
    }
    
    
    /// Creates a new Article from a `MarkdownDocument`, extracting information from the document's metadata.
    init(
        id: UUID,
        _ doc: MarkdownDocument,
        defaultStatus: Status = .published,
        fallbackHeaderImage: ImageReference? = .asset("stanford")
    ) {
        let metadata = doc.metadata
        self.init(
            id: id,
            status: metadata["status"].flatMap(Status.init(rawValue:)) ?? defaultStatus,
            title: metadata.title ?? "",
            date: metadata["date"].flatMap { try? Date($0, strategy: .iso8601) },
            tags: metadata["tags"].flatMap { value -> [Tag] in
                let tagTitles = value.split(separator: ",").map { $0.trimmingWhitespace() }
                return tagTitles.map { Tag(title: String($0), color: .blue) } // maybe also somehoe encode the colors?
            } ?? [],
            lede: metadata["lede"],
            headerImage: metadata["headerImage"].flatMap(ImageReference.init(rawValue:)) ?? fallbackHeaderImage,
            body: doc
        )
    }
    
    init?(contentsOf url: URL) {
        guard let document = try? MarkdownDocument(contentsOf: url),
              let id = document.metadata["id"].flatMap({ UUID(uuidString: $0) }) else {
            return nil
        }
        self.init(id: id, document)
    }
}


// MARK: Utility Views

struct TagView: View {
    private static let cornerRadius: CGFloat = 7
    let tag: Article.Tag
    
    var body: some View {
        Text(tag.title)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.white) // IDEA make this dependent on how dark/bright the tag color is?
            .padding(EdgeInsets(horizontal: 7, vertical: 3))
            .background(tag.color, in: RoundedRectangle(cornerRadius: Self.cornerRadius))
    }
}


extension Article {
    @ViewBuilder var imageView: some View {
        switch headerImage {
        case nil:
            Color.clear
        case .asset(let name):
            Image(name)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .scaledToFill()
        case .url(let url):
            AsyncImage(url: url)
        }
    }
}
