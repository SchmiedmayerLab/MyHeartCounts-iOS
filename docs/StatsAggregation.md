<!--

This source file is part of the My Heart Counts iOS open-source project

SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)

SPDX-License-Identifier: MIT

-->

# Stats aggregation metadata

Monthly stats entries may carry the optional `average` field below. This field is additive: existing entries remain readable, and writers should omit metadata they cannot establish accurately.

The Swift metadata type is `StatsDocument.Average`; source keys use `StatsDocument.SourceID`. Nesting these types does not change the JSON field names or encoding.

```json
{
  "start": "2026-09-07T08:00:00+02:00",
  "end": "2026-09-07T09:00:00+02:00",
  "unit": "count/min",
  "min": 60,
  "max": 100,
  "avg": 75,
  "average": {
    "numerator": 2250,
    "denominator": 30,
    "weighting": "example-observation-mean-v1"
  }
}
```

`average.numerator / average.denominator` must reproduce `avg` in the entry's unit. Both numbers must be finite; the denominator must be positive. `weighting` identifies the averaging algorithm and weight units. Writers must agree on its complete semantics before using the same identifier. In this illustrative example, the numerator is the sum of 30 individual observations and the denominator is their count. It does **not** describe HealthKit heart-rate averaging.

Compatible averages merge by summing their numerators and denominators. Weights must remain attached through subsequent interval aggregation; an average of already averaged buckets generally loses the original weighting. Cross-source heart-rate averages require matching weight labels and identical whole buckets within the requested range. These checks establish arithmetic compatibility; the reader does not detect observations copied between sources. Partial overlap cannot be resolved exactly by prorating aggregate values; consumers may explicitly opt into diagnosed interval approximations as described in [StatsQueries.md](StatsQueries.md).

HealthKit currently fetches all eligible samples, including samples written by connected providers. Provider exclusion during stats fetching is planned separately. Until then, copied readings can appear in multiple source contributions, and pooling compatible averages can count them more than once. Callers can use `.only` or `.preferred` to avoid pooling competing buckets.

Under `.automatic`, current HealthKit documents support the following behavior:

- Cumulative values (steps and exercise time) prefer HealthKit for overlapping buckets and fill gaps from other sources; competing totals are not added.
- Heart-rate minima and maxima can merge across matching whole buckets.
- Heart-rate averages prefer HealthKit for competing buckets because its writer does not supply compatible average weights.
- Overlapping sleep sessions prefer HealthKit; uncovered sessions from other sources can still be included.
- Individual quantity readings and blood-pressure pairs at different timestamps can coexist. At a shared timestamp, competing sources cause preferred-source fallback. The reader does not remove copies at different timestamps.

Pooling competing averages requires compatible weights on **both** contributions. Writers must omit unsupported weights rather than infer them from sample counts or bucket durations.

## HealthKit heart-rate limitation

HealthKit heart rate uses a temporally weighted integration function, and a quantity sample may represent an entire series of underlying measurements. Counting `HKQuantitySample` objects therefore cannot provide its averaging denominator. Apple's public `HKStatistics.duration()` contract describes covered sample duration; it does not establish that this duration is the denominator used by `averageQuantity()`.

The HealthKit writer consequently keeps its existing `min`, `max`, and `avg` values without adding inferred weights. Source selection remains conservative for these averages and exposes fallback diagnostics. Independent providers with trustworthy weights can use the optional `average` schema. Supporting exact pooling of HealthKit averages requires a documented mergeable representation or a separately specified averaging algorithm; it must not silently substitute a different meaning for the existing HealthKit average.

Sources: [HealthKit temporal aggregation](https://developer.apple.com/documentation/healthkit/hkquantityaggregationstyle/discretetemporallyweighted), [HKStatistics duration](https://developer.apple.com/documentation/healthkit/hkstatistics/duration()), [WWDC19: Exploring New Data Representations in HealthKit](https://developer.apple.com/videos/play/wwdc2019/218/).
