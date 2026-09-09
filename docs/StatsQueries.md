<!--

This source file is part of the My Heart Counts iOS open-source project

SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)

SPDX-License-Identifier: MIT

-->

# Reading stats

`StatsStore` provides the same stats processing to SwiftUI views, Spezi modules, and background tasks. It is loaded with the Firebase modules. Query construction and result values do not require SwiftUI; the store coordinates account state on the main actor, and document processing runs off the main actor.

Query API types are nested under `StatsStore`, including `Request`, `Snapshot`, `Subscription`, and the source/read/interval policies. Stored metadata types are nested under `StatsDocument`; these Swift namespaces do not change the document schema.

The [User Data Statistics section of the MHC data spec](MHCDataSpec.md#user-data-statistics) is authoritative for storage locations, monthly document structure, source identifiers, and entry fields, including [optional average metadata](MHCDataSpec.md#optional-average-metadata).

The HealthKit writer and stats reader share the `StatsDocument.Aggregate`, `.Quantity`, and `.BloodPressure` entry payloads. `StatsDocument.Entry` wraps them in `.aggregate`, `.quantity`, and `.bloodPressure` enum cases. Aggregates contain either a sum or a min/max/average summary, with optional average weights on the summary. Custom coding preserves the existing flat JSON fields without adding enum case names. Invalid entry shapes, dates, or units are skipped and counted while the rest of the month remains readable.

```swift
@Dependency(StatsStore.self) private var stats

let request = StatsStore.Request.quantity(
    metric: .heartRate,
    timeRange: .last(days: 7),
    aggregationKind: .avg,
    sourcePolicy: .automatic
)

let snapshot = try await stats.fetch(request, readPolicy: .serverOrCache)

let updates = await stats.updates(for: request)
for try await snapshot in updates {
    // snapshot.elements, snapshot.diagnostics, snapshot.contributingSourceIDs
}
```

`fetch` is a one-shot read. `.server` requires the server, `.cache` reads only the local cache, and `.serverOrCache` attempts the server with Firestore's cache fallback. `isFromCache` and `hasPendingWrites` describe the returned documents; a successful server read does not prove that all participant data has already been uploaded.

Each `updates` call owns an independent subscription and yields the newest complete query snapshot. Cancelling a task while it consumes the stream removes its listener. When leaving a loop early, release both the stream and iterator; cancelling an already-completed task does not dispose a stream retained elsewhere. Errors terminate streams. Start another subscription to retry.

Operations capture their account and backend session. Logout/account changes cancel outstanding reads and subscriptions rather than switching a background computation to another participant. The SwiftUI adapter can subscribe again when the new account becomes available. The app's standard forwards account events before asynchronous cleanup and suspends new reads for an account while explicit logout is underway.

Standalone clients can supply `StatsStore(firestore:accountID:)`. Their owner must call `invalidateSession()` on session changes, including signing out and back into the same account. Explicitly supplied dependencies are also used by the offline integration tests.

## SwiftUI

```swift
@StatsDocumentsQuery(
    metric: .heartRate,
    timeRange: .last(days: 7),
    aggregationKind: .avg,
    sourcePolicy: .automatic
)
private var samples: [QuantitySample]
```

`samples` contains the processed values. `$samples.isLoading` indicates that the query is waiting for its first processed snapshot. `$samples.isUpdating` indicates processing while a previous snapshot remains available, including a time-range change that reuses the same monthly documents. `$samples.error` and `$samples.snapshot` expose errors and diagnostics; `$samples.retry()` restarts a failed query. An empty result is distinguishable from loading, unavailable account/backend, read failure, or rejected documents. Malformed entries are skipped with diagnostic counts so that one bad entry does not discard the entire month's valid data.

Metadata-only Firestore updates refresh `isFromCache` and `hasPendingWrites` without decoding the documents or rebuilding the processed samples. Changes to document data or the request still trigger processing.

`StatsStore.Request.sleepSessions(in:sourcePolicy:)` and `.bloodPressure(in:sourcePolicy:)` have matching wrapper initializers. A preconstructed typed request can also be passed directly to `StatsDocumentsQuery`.

## Source and interval policies

Source selection is performed after filtering entries to the requested range. Default preference is HealthKit followed by the other source IDs in lexical order. Selection operates on individual buckets, so another source can fill missing buckets even when HealthKit has some data in the same month.

Individual quantity and blood-pressure readings at different timestamps can coexist across sources. At the same timestamp, source preference resolves competing readings; `.mergeCompatible` throws instead. Multiple readings within a single source are retained. The reader does not track observation identities or remove copies at different timestamps.

Timestamp equality compares the exact parsed instant, including supplied fractional seconds; the reader does not truncate timestamps to whole seconds. The HealthKit stats writer currently emits whole-second dates, so a copy retaining a nonzero fractional part has a different timestamp and both readings remain in the result. HealthKit stats fetching does not yet exclude samples based on connected integrations; existing metric-specific filters still apply.

- `.automatic` combines compatible contributions and reports preferred-source fallback where merging is unsupported.
- `.only(id)` restricts results to one source.
- `.preferred(ids)` supplies an ordered preference, followed by the default ordering, and fills uncovered data without pooling competing buckets.
- `.mergeCompatible` requires a supported merge for competing data and throws for incompatible contributions. It also rejects coarse averages that would require unavailable weights.

An optional `StatsStore.AggregationInterval(interval:anchor:calendar:alignmentPolicy:)` on quantity requests reduces buckets before converting them into `QuantitySample`, preserving any available average weights for whole-bucket aggregation. Its alignment policy controls stored buckets that straddle the requested calendar boundaries, for example after travel between time zones:

- `.preserveBuckets` (the default) retains the original series and reports `.unalignedInterval` when exact grouping is impossible.
- `.requireExact` throws `StatsStore.Processor.Error.unalignedAggregationInterval` instead of returning a different resolution.
- `.approximate` permits grouping into shifted intervals at the same or coarser resolution and reports `.approximateInterval(timeRange:)`. Sums are allocated in proportion to the overlap duration; minima, maxima, and averages use the overlapping buckets and do not claim exact sub-bucket values or weights. Requests finer than the stored resolution retain the original series with `.unalignedInterval`.

The dashboard and CVH daily step-count query explicitly select `.approximate`, preserving daily chart bars and daily score inputs across shifted bucket boundaries. Missing days are not added as zero-valued samples. The CVH score continues averaging only days with data and rounding that mean; it leaves the step score unavailable if the stored resolution is too coarse to produce daily inputs.

Legacy averages reduced across whole buckets retain the previous unweighted approximation and report `.approximateAverage`; callers requiring exact averages should inspect diagnostics or select `.mergeCompatible`. That strict source policy also rejects interval splitting, even if the interval's alignment policy permits approximation.

The source policies and limitations of current HealthKit documents are detailed in [StatsAggregation.md](StatsAggregation.md).
