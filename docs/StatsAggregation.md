<!--

This source file is part of the My Heart Counts iOS open-source project

SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)

SPDX-License-Identifier: MIT

-->

# Stats aggregation and source selection

This guide explains how stats queries combine stored contributions and why some merges require source preference. The [User Data Statistics section of the MHC data spec](MHCDataSpec.md#user-data-statistics) is authoritative for storage locations, document structure, source identifiers, and entry fields. The [query guide](StatsQueries.md) documents the Swift APIs and their policies.

## Combining averages

Entries with the [optional average metadata](MHCDataSpec.md#optional-average-metadata) can be combined by summing their numerators and denominators. For example, means of 60 and 90 with compatible weights of 1 and 3 combine to `(60 × 1 + 90 × 3) / (1 + 3) = 82.5`. Taking the unweighted mean of those means would instead produce 75.

Weights must remain attached through subsequent interval aggregation. Cross-source heart-rate averages require matching weight labels and identical whole buckets within the requested range. These checks establish arithmetic compatibility; the reader does not detect observations copied between sources. Partial overlap cannot be resolved exactly by prorating aggregate values; consumers may explicitly opt into diagnosed interval approximations as described in [StatsQueries.md](StatsQueries.md#source-and-interval-policies).

## Source selection

HealthKit stats fetching does not yet exclude samples based on connected integrations; existing metric-specific filters still apply. Copies can therefore appear in multiple source contributions, and pooling compatible averages can count them more than once. Callers can use `.only` or `.preferred` to avoid pooling competing buckets. These policies do not identify copies stored at different timestamps.

Under `.automatic`, current HealthKit documents support the following behavior:

- Cumulative values (steps and exercise time) prefer HealthKit for overlapping buckets and fill gaps from other sources; competing totals are not added.
- Heart-rate minima and maxima can merge across matching whole buckets.
- Heart-rate averages prefer HealthKit for competing buckets because its writer does not supply compatible average weights.
- Overlapping sleep sessions prefer HealthKit; uncovered sessions from other sources can still be included.
- Individual quantity readings and blood-pressure pairs at different timestamps can coexist. At a shared timestamp, competing sources cause preferred-source fallback. The reader does not remove copies at different timestamps.

Pooling competing averages requires compatible weights on **both** contributions. Writers must omit unsupported weights rather than infer them from sample counts or bucket durations.

## HealthKit heart-rate limitation

HealthKit heart rate uses a temporally weighted integration function, and a quantity sample may represent an entire series of underlying measurements. Counting `HKQuantitySample` objects therefore cannot provide its averaging denominator. Apple's public `HKStatistics.duration()` contract describes covered sample duration; it does not establish that this duration is the denominator used by `averageQuantity()`.

The HealthKit writer consequently keeps its existing `min`, `max`, and `avg` values without adding inferred weights. Source selection remains conservative for these averages and exposes fallback diagnostics. Providers with trustworthy weights can use the [optional average metadata](MHCDataSpec.md#optional-average-metadata). Supporting exact pooling of HealthKit averages requires a documented mergeable representation or a separately specified averaging algorithm; it must not silently substitute a different meaning for the existing HealthKit average.

Sources: [HealthKit temporal aggregation](https://developer.apple.com/documentation/healthkit/hkquantityaggregationstyle/discretetemporallyweighted), [HKStatistics duration](https://developer.apple.com/documentation/healthkit/hkstatistics/duration()), [WWDC19: Exploring New Data Representations in HealthKit](https://developer.apple.com/videos/play/wwdc2019/218/).
