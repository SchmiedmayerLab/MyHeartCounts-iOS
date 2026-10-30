//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Grove
import GroveAccount
import GroveTesting
@testable import MyHeartCounts
import Testing


private final class AccountReadinessClient: Module {
    let service: InMemoryAccountService

    @Dependency(Account.self)
    var account

    @MainActor
    init() {
        service = InMemoryAccountService()
    }
}


@Suite(.timeLimit(.minutes(1)))
@MainActor
struct AccountReadinessTests {
    @Test(arguments: [false, true])
    func cancellationReleasesWaitWithoutAnAccountChange(hasIncompleteDetails: Bool) async {
        let client = makeClient()
        if hasIncompleteDetails {
            var details = AccountDetails()
            details.accountId = "readiness-test"
            details.isIncomplete = true
            client.account.supplyUserDetails(details)
        }
        let (started, continuation) = AsyncStream.makeStream(of: Void.self)
        let waiting = Task { @MainActor in
            continuation.yield()
            continuation.finish()
            // Stay on the main actor until the real account wait suspends, before the test cancels it.
            await client.account.waitForAccountDetailsReady()
            return Task.isCancelled
        }
        defer { waiting.cancel() }
        for await _ in started { }
        waiting.cancel()
        #expect(await waiting.value)
        #expect(client.account.details?.isIncomplete == (hasIncompleteDetails ? true : nil))
    }

    @Test
    func completeDetailsReturnWithoutWaiting() async {
        let client = makeClient()
        var details = AccountDetails()
        details.accountId = "readiness-test"
        client.account.supplyUserDetails(details)

        await client.account.waitForAccountDetailsReady()
        #expect(client.account.details?.isIncomplete == false)
        #expect(!Task.isCancelled)
    }

    private func makeClient() -> AccountReadinessClient {
        let client = AccountReadinessClient()
        withDependencyResolution {
            AccountConfiguration(service: client.service, configuration: .default)
            client
        }
        return client
    }
}
