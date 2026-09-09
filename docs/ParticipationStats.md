<!--

This source file is part of the My Heart Counts iOS open-source project

SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)

SPDX-License-Identifier: MIT

-->

# Participation statistics

Participation statistics and health achievements read the shared `StatsStore` layer described in [StatsQueries.md](StatsQueries.md). The HealthKit calculator maintains these additional version-zero metrics at `users/{uid}/stats/{metricId}/months/{yyyy-MM}`:

| Metric ID | HealthKit type | Entries | Unit and value |
| --- | --- | --- | --- |
| `active-energy` | Active energy burned | `hourly` | `kcal`, `sum` |
| `walking-running-distance` | Walking/running distance | `hourly` | `m`, `sum` |
| `flights-climbed` | Flights climbed | `hourly` | `count`, `sum` |
| `resting-heart-rate` | Resting heart rate | `samples` | `count/min`, individual `value` |
| `workouts` | Workout | `samples` | `s`, `value` and `duration` contain active duration in seconds |
| `electrocardiograms` | Electrocardiogram | `samples` | `count`, `value` is `1` |

All quantities use their HealthKit type's canonical unit. Resting heart rate stores individual measurements so its average can be computed from measurements without averaging previously averaged buckets. Existing steps, exercise time, heart rate, and sleep documents supply the remaining health statistics.

Workout and ECG entries preserve event identity and timing:

```json
{
  "version": 0,
  "metric": "workouts",
  "samples": {
    "com.apple.HealthKit": [
      {
        "id": "healthkit:efc55c58-041a-4baa-a3af-c1a32a47ce09",
        "date": "2026-09-09T10:00:00+02:00",
        "endDate": "2026-09-09T10:45:00+02:00",
        "unit": "s",
        "value": 2400,
        "duration": 2400,
        "activityType": 37
      }
    ]
  }
}
```

`date` is the event start; `endDate` is its end. The event belongs to the month containing `date`, including events spanning midnight or a month boundary. Event timing does not use the `start`/`end` fields reserved for aggregate buckets. Workout `duration` preserves `HKWorkout.duration`, excluding pauses, rather than assuming it equals the elapsed wall-clock span. `activityType` is the unsigned raw value of `HKWorkoutActivityType`.

ECG entries omit `duration` and `activityType`. Their summary does not contain waveform data or classification. Both event types carry `healthkit:<lowercase UUID>` in `id`, preserving output identity across monthly recomputations. The decoder also accepts the previous `provenance.observationID` field when `id` is absent; new writes do not emit provenance. IDs do not deduplicate entries or establish independence between sources. Simultaneous events from different sources compete under the source policies in [StatsAggregation.md](StatsAggregation.md); same-source events and events at different instants remain distinct. [MHCDataSpec.md](MHCDataSpec.md#entry-shapes) defines the canonical wire-format contract.

All additional metrics retain the calculator's enrollment-aware history, with at least twelve months of chart coverage. Event updates reread and replace the full HealthKit contribution for the event's month. Empty reads clear previous entries only when the anchored update includes deletion evidence, and query anchors advance only after successful uncancelled persistence.

Participation queries use automatic source selection and subscribe while the statistics view is visible. Each incoming metric snapshot replaces the previous one, so backfills, corrections, and deletions update the displayed totals without accumulating duplicates. Foreground, calendar-day, and significant-time changes refresh the query bounds. Missing, failed, or malformed health reads remain unavailable rather than displaying zero. Daily quantity requests include today's complete bucket bounds because a current-hour bucket already contains only the activity recorded so far. Shifted calendar boundaries may be proportionally approximated; heartbeat estimates integrate only recorded hours, and sleep sessions crossing the enrollment boundary are proportionally clipped. Event queries require both endpoints inside the requested range.

Achievement listeners consume exact daily step totals and chronological ECG recordings. Each threshold retains its earliest qualifying date, including when older data arrives after a newer personal best. Earned achievements remain unlocked after corrections or deletions. Listener results and participation refreshes are scoped to their account, backend, study enrollment, and session; obsolete results cannot populate a new account.
