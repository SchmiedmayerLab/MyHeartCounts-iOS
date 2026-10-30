//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFoundation
import GroveViews
import SwiftUI


struct ArticleCard: View {
    let article: Article
    
    var body: some View {
        VStack(alignment: .leading) {
            HStack(alignment: .top) {
                Text(article.title)
                    .font(.title2.bold())
                if let date = article.date {
                    Spacer()
                    Text(DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let lede = article.lede {
                Text(lede)
            }
        }
        .padding()
        .background(Material.regular)
        .background {
            article.imageView
        }
    }
}
