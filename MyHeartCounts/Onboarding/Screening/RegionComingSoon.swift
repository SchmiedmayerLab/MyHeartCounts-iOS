//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import FirebaseFunctions
import Foundation
import MyHeartCountsShared
import SFSafeSymbols
@_spi(APISupport)
import Spezi
import SpeziFirebaseAccount
import SpeziFoundation
import SpeziOnboarding
import SpeziViews
import SwiftUI


struct RegionComingSoon: View {
    enum RegionAvailabilityStatus {
        /// The study will be launched soon in the selected region
        case comingSoon
        /// The study won't be launched in the selected region
        case notSupported
        
        fileprivate var displayTitle: LocalizedStringResource {
            switch self {
            case .comingSoon:
                "Coming Soon"
            case .notSupported:
                "Region Not Yet Supported"
            }
        }
    }
    
    
    @Environment(\.locale)
    private var locale
    
    let selectedRegion: Locale.Region
    let availabilityStatus: RegionAvailabilityStatus
    
    @State private var emailAddress = ""
    @FocusState private var emailTextFieldIsFocused
    @State private var showInvalidEmailAlert = false
    @State private var showSuccessfullyAddedEmailAlert = false
    @State private var viewState: ViewState = .idle
    
    
    var body: some View {
        OnboardingPage(
            symbol: symbol,
            title: availabilityStatus.displayTitle,
            description: """
                The My Heart Counts study isn't yet available in \(locale.localizedStringWithDefinitiveArticle(for: selectedRegion)).
                
                Add your email below and we'll update you when it launches in your region.
                """
        ) {
            VStack(spacing: 24) {
                TextField("Email…", text: $emailAddress)
                    .focused($emailTextFieldIsFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.plain)
                    .padding()
                    .background(.background.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                AsyncButton(state: $viewState) {
                    try await notifyMe()
                } label: {
                    HStack {
                        Spacer()
                        Text("Notify Me")
                        Spacer()
                    }
                    .bold()
                    .frame(maxWidth: .infinity, minHeight: 38)
                }
                .buttonStyleGlassProminent()
            }
            Spacer(minLength: 24)
            Link2(MyHeartCounts.website(.homepage, for: selectedRegion)) {
                HStack {
                    Text("INELIGIBLE_LEARN_MORE")
                    Spacer()
                    Image(systemSymbol: .arrowUpRight)
                        .accessibilityHidden(true)
                }
            }
        }
        .viewStateAlert(state: $viewState)
        .scrollDismissesKeyboard(.interactively)
        .alert("Invalid Email Address", isPresented: $showInvalidEmailAlert) {
            Button("OK") {
                showInvalidEmailAlert = false
            }
        } message: {
            Text("Please enter a valid email address and try again.")
        }
        .alert("You're on the List", isPresented: $showSuccessfullyAddedEmailAlert) {
            Button("OK") {
                showSuccessfullyAddedEmailAlert = false
            }
        } message: {
            Text("We've saved your email and will notify you when My Heart Counts becomes available in your region.")
        }
    }
    
    private var symbol: SFSymbol {
        switch selectedRegion.continent {
        case .americas:
            .globeAmericas
        case .europe, .africa:
            .globeEuropeAfrica
        case .asia, .oceania:
            .globeAsiaAustralia
        default:
            .globe
        }
    }
    
    private func notifyMe() async throws {
        guard !emailAddress.isEmpty else {
            // tapping "Notify Me" if nothing is entered nudges the user to provide their email.
            emailTextFieldIsFocused = true
            return
        }
        let pattern = /^[A-Z0-9a-z.!#$%&'*+\-\/=?^_`{|}~]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/
        guard emailAddress.wholeMatch(of: pattern) != nil else {
            showInvalidEmailAlert = true
            return
        }
        if !Spezi.didLoadFirebase {
            Spezi.loadFirebase(for: .unitedStates)
            try? await Task.sleep(for: .seconds(1))
        }
        guard let spezi = SpeziAppDelegate.spezi, let accountService = spezi.module(FirebaseAccountService.self) else {
            throw NSError(mhcErrorCode: .unspecified, localizedDescription: "Something went wrong")
        }
        try await accountService.signUpAnonymously()
        do {
            _ = try await Functions.functions()
                .httpsCallable("joinWaitlist")
                .call([
                    "region": selectedRegion.identifier,
                    "email": emailAddress
                ])
            showSuccessfullyAddedEmailAlert = true
        } catch {
            try? await accountService.logout()
            throw error
        }
    }
}


extension Locale {
    /// Regions that need to be prefixed with "the" in English.
    private static let regionsNeedingEnglishDefinitiveArticle: Set<Locale.Region> = [
        .unitedStates, .unitedKingdom, .netherlands, .philippines,
        .bahamas, .maldives, .unitedArabEmirates, .congoKinshasa, .congoBrazzaville,
        .gambia, .côteDIvoire, .southSudan
    ]
    
    /// Spanish: region -> article (only regions that conventionally take one)
    private static let spanishDefiniteArticleMapping: [Locale.Region: String] = [
        .unitedStates: "los",
        .unitedKingdom: "el",
        .india: "la",
        .philippines: "las",
        .netherlands: "los",
        .bahamas: "las",
        .maldives: "las",
        .unitedArabEmirates: "los",
        .yemen: "el",
        .ecuador: "el",
        .peru: "el"
    ]
    
    func localizedStringWithDefinitiveArticle(for region: Locale.Region) -> String {
        let name = self.localizedString(forRegionCode: region.identifier) ?? region.identifier
        switch self.language.languageCode?.identifier {
        case "en":
            if Self.regionsNeedingEnglishDefinitiveArticle.contains(region) {
                return "the \(name)"
            }
        case "es":
            if let article = Self.spanishDefiniteArticleMapping[region] {
                return "\(article) \(name)"
            }
        default:
            break
        }
        return name
    }
}


#Preview {
    RegionComingSoon(selectedRegion: .unitedKingdom, availabilityStatus: .comingSoon)
}

#Preview {
    RegionComingSoon(selectedRegion: .germany, availabilityStatus: .notSupported)
}
