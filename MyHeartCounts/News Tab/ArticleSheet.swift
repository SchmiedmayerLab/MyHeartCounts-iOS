//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFoundation
import GroveStudyDefinition
import GroveViews
import MarkdownUI
import SwiftUI


struct ArticleSheet: View {
    let article: Article
    @AsyncStreamTracked private var navbarTitleViewHeight: CGFloat?
    @AsyncStreamTracked private var articleTitleLabelFrame: CGRect?
    @AsyncStreamTracked private var scrollViewOffset: CGPoint = .zero
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    GeometryReader {
                        Color.red.preference(
                            key: ScrollViewOffsetKey.self,
                            value: $0.frame(in: .scrollView).origin
                        )
                    }
                    .frame(height: 0)
                    .onPreferenceChange(ScrollViewOffsetKey.self) { offset in
                        $scrollViewOffset.yield(offset)
                    }
                    scrollViewContent
                        .coordinateSpace(.named("scrollViewContent"))
                }
            }
            // telling the scroll view to ignore the top safe area causes it to place its content underneath the navigation bar,
            // which we want since that in turn causes SwiftUI to make the navigation bar transparent when the scroll view is
            // scrolled all the way to the top, and to gradually make it opaque as you scroll down.
            .ignoresSafeArea(edges: .top)
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    DismissButton()
                }
                ToolbarItem(placement: .principal) {
                    navigationTitleView
                }
            }
        }
        .task { await $scrollViewOffset.startTracking() }
        .task { await $navbarTitleViewHeight.startTracking() }
        .task { await $articleTitleLabelFrame.startTracking() }
    }
    
    @ViewBuilder private var navigationTitleView: some View {
        let navBarHeight: CGFloat = 56
        VStack(spacing: 0) { // swiftlint:disable:this closure_body_length
            Color.clear
                .frame(width: 0, height: { () -> CGFloat in
                    guard let navbarTitleViewHeight else {
                        return 0
                    }
                    guard let articleTitleLabelFrame = articleTitleLabelFrame.map({
                        CGRect(
                            x: $0.minX,
                            y: $0.midY - 0.5 * navbarTitleViewHeight,
                            width: $0.width,
                            height: navbarTitleViewHeight
                        )
                    }) else {
                        return 0
                    }
                    let scrollViewY = -scrollViewOffset.y + navBarHeight
                    if scrollViewY < articleTitleLabelFrame.minY {
                        return navbarTitleViewHeight
                    } else if scrollViewY >= articleTitleLabelFrame.maxY {
                        return 0
                    } else {
                        let diff = scrollViewY - articleTitleLabelFrame.minY
                        return navbarTitleViewHeight - diff
                    }
                }())
            VStack {
                Text(article.title)
                    .font(.headline)
                if let date = article.date {
                    Text(DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .none))
                        .font(.subheadline)
                }
            }
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: NavbarTitleViewHeight.self, value: geometry.size.height)
                }
                .onPreferenceChange(NavbarTitleViewHeight.self) { height in
                    $navbarTitleViewHeight.yield(height)
                }
            }
        }
        .frame(height: navbarTitleViewHeight, alignment: .top)
        .clipped()
    }
    
    @ViewBuilder private var scrollViewContent: some View {
        VStack(spacing: 0) {
            headlineImage
            Divider()
            MarkdownView(document: article.body)
                .padding([.horizontal, .top])
        }
    }
    
    @ViewBuilder private var headlineImage: some View {
        // swiftlint:disable closure_body_length
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 7) {
                Text(article.title)
                    .font(.title.bold())
                    .frame(alignment: .leading)
                    .background {
                        GeometryReader {
                            Color.clear.preference(
                                key: ArticleTitleLabelFrame.self,
                                value: $0.frame(in: .named("scrollViewContent"))
                            )
                        }
                        .frame(height: 0)
                        .onPreferenceChange(ArticleTitleLabelFrame.self) { frame in
                            $articleTitleLabelFrame.yield(frame)
                        }
                    }
                HStack {
                    if let date = article.date {
                        Text(DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none))
                            .foregroundStyle(.secondary)
                            .layoutPriority(1)
                    }
                    Spacer()
                    let tags = HStack {
                        ForEach(article.tags.indices, id: \.self) { tagIdx in
                            TagView(tag: article.tags[tagIdx])
                        }
                    }
                    ViewThatFits {
                        tags
                        ScrollView(.horizontal) {
                            tags
                        }
                        .scrollIndicators(.hidden)
                        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.thinMaterial)
        }
        .frame(height: 271)
        .background {
            article.imageView
                .frame(height: 271) // this shouldn't be necessary???!!!
                .clipped()
        }
        // swiftlint:enable closure_body_length
    }
}


extension ArticleSheet {
    private struct ArticleTitleLabelFrame: PreferenceKey {
        static let defaultValue: CGRect? = nil
        static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
            value = nextValue()
        }
    }
    
    private struct NavbarTitleViewHeight: PreferenceKey {
        static let defaultValue: CGFloat? = nil
        static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
            value = nextValue()
        }
    }
    
    private struct ScrollViewOffsetKey: PreferenceKey {
        static let defaultValue: CGPoint = .zero
        static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) {
            value = nextValue()
        }
    }
}
