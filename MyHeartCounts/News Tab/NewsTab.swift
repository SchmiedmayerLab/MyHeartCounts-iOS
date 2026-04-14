//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// periphery:ignore:all - API

import Foundation
import SFSafeSymbols
import SpeziStudy
import SpeziViews
import SwiftUI


struct NewsTab: RootViewTab {
    static var tabTitle: LocalizedStringResource { "News" }
    static var tabSymbol: SFSymbol { .newspaper }
    
    @Environment(\.colorScheme)
    private var colorScheme
    
    @Environment(NewsManager.self)
    private var newsManager
    
    @State private var isInitialLoad = false
    @State private var presentedArticle: Article?
    
    var body: some View {
        NavigationStack { // swiftlint:disable:this closure_body_length
            VStack {
                if isInitialLoad {
                    ProgressView("Fetching…")
                } else if newsManager.articles.isEmpty {
                    if let error = newsManager.loadingError {
                        ContentUnavailableView(
                            "No Internet",
                            systemSymbol: .networkSlash,
                            description: Text(String(describing: error))
                        )
                    } else {
                        ContentUnavailableView(
                            "No News Yet",
                            systemSymbol: .newspaper,
                            description: Text("Feel free to check back later!")
                        )
                    }
                } else {
                    makeContent(for: newsManager.articles)
                }
            }
            .navigationTitle("News")
            .toolbar {
                accountToolbarItem
            }
            .task {
                if newsManager.articles.isEmpty {
                    isInitialLoad = true
                    await newsManager.refresh()
                    isInitialLoad = false
                } else {
                    await newsManager.refresh()
                }
            }
            .refreshable {
                await newsManager.refresh()
            }
            .sheet(item: $presentedArticle) { article in
                ArticleSheet(article: article)
            }
        }
    }
    
    @ViewBuilder
    private func makeContent(for articles: [Article]) -> some View {
        Form {
            ForEach(articles) { article in
                Section {
                    Button {
                        presentedArticle = article
                    } label: {
                        ArticleCard(article: article)
                            .frame(height: 117)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(.zero)
                }
            }
            Section {
                Link(destination: MyHeartCounts.website()) {
                    Text({ () -> AttributedString in
                        var str = AttributedString(localized: "For more information and updates, visit myheartcounts.stanford.edu")
                        str.setAttributes(AttributeContainer().foregroundColor(colorScheme.textLabelForegroundStyle))
                        if let range = str.range(of: "myheartcounts.stanford.edu") {
                            str[range].setAttributes(
                                AttributeContainer().foregroundColor(Color.blue)
                            )
                        }
                        return str
                    }())
                    .font(.callout)
                }
            }
        }
    }
}
