<!--
This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project

SPDX-FileCopyrightText: 2026 Stanford University

SPDX-License-Identifier: MIT
-->

# MHC Data - Sources, Storage & Formats (DRAFT; iOS pov)


## High-level data persistence locations
- The app uses a firebase backend to store server-persisted data
  - Within that, it uses both firestore as well as firebase storage
- This document mainly covers the iOS app's data flow/structure, but does also go a bit into server-relevant things
- Data that does not need to persist across multiple installs of the app is stored as `UserDefaults` and local sqlite databases.


## What data does the app produce/collect?
- demographics
- user / account flags/settings/preferences
- consent pdf
- device environment data (time zone, last-active date, etc)
- automated data donation (healthkit, sensorkit)
- user-provided data entered into the app (questionnaires, active tasks, custom quantity samples, etc)
- scheduler state (*todo*)
- (outside of iOS app) data coming from third-party wearable devices


### Demographics Data
- Demographics data is collected from the user as part of the onboarding
- The list of questions collected in the demographics (and their conditions) is defined in the google sheet and implemented in the `demographicsLayout()` function
- Responses to the demographcis fields are stored in the user document in firebase (see DemographicsAccountKeys.swift)


### User/Account Flags/Preferences
- Stored in the user document (`/users/{uid}`) in firestore

#### User-Visible Account Keys
| Account Key | Type | Description |
| :---------- | :--: | :---------- |
| `hasWithdrawnFromStudy` | `Bool` | Tracks whether the user has explicitly requested to withdraw from the study, via the in-app button in the account sheet. If the value is `false` or absent, the user has not withdrawn. Not written directly by the app; managed by the `markAccountForStudyWithdrawal` and `markAccountForStudyReenrollment` functions |
| `dateOfEnrollment` | `Date` | Timestamp of when the user first enrolled into the study |
| `lastSignedConsentVersion` | `String` | SemVer version string of the user's last-signed consent document version |
| `lastSignedConsentDate` | `Date` | Timestamp of when the user last signed the consent document |
| `didOptInToTrial` | `Bool` | Tracks whether the user opted in to the trial during onboarding |
| `preferredWorkoutTypes` | `String` | Comma-separated list of workout preference identifiers (e.g. `"walk,bicycle"`) |
| `preferredNotificationTime` | `String` | The user's preferred time to receive nudge notifications. Format: `"HH:mm"` |
| `extendedActivityNudgesOptIn` | `Bool` | Whether the user decided to opt in to receive post-trial nudged. Missing value means the user is opted in. |

#### Internal Account Keys
| Account Key | Type | Description |
| :---------- | :--: | :---------- |
| `lastActiveDate` | `Date` | Timestamp when the user last opened the app. Does not get updated when the app is launched in the background |
| `fcmToken` | `String` | The app's FCM token |
| `enableAppDebugMode` | `Bool` | Whether the app's debug mode should be enabled for the user |
| `timeZone` | `String` | Last-seen device time zone |
| `language` | `String` | Last-seen device/app language |
| `preferredMeasurementSystem` | `String` | Last-seen preferred measurement system (e.g., `metric`, `ussystem`, or `uksystem`) |
| `mostRecentOnboardingStep` | `String` | Identifier of the most recent onboarding step reached by the user |



### Consent
- At the end of the onboarding, the user signs the study consent document; the app exports the signed document as a PDF and uploads it to firebase storage
- The upload goes directly to firebase storage (this is the only upload in the app that does not go through the `ManagedFileUpload` module), to `/users/{uid}/consent/{timestamp}.pdf`
  - `{timestamp}` is the whole-second unix timestamp of the signing; the folder thereby acts as an append-only history of all consent documents the user has signed
  - contentType is `application/pdf`
- The uploaded object carries the following custom metadata fields:
  - `consentFormMetadata`: JSON-encoded metadata of the consent document (i.e., the markdown file's frontmatter)
  - `responses`: JSON-encoded responses the user entered into the consent form (toggles, selects, etc)
  - `date`: ISO8601 timestamp of the signing
  - `version`: the consent document's version (only present if the document declares one)
- Signing also updates account keys in the user document: `lastSignedConsentVersion` and `lastSignedConsentDate`, as well as the consent-form-derived flags (`didOptInToTrial`, `futureStudies`)
- Consent renewal: if the study's current consent document has a newer version than the user's `lastSignedConsentVersion`, the app prompts the user to re-sign; re-signing runs through the same flow as above (i.e., uploads an additional PDF and updates the account keys)
- The account sheet lists the user's previously-signed consent documents, by fetching the contents of the storage folder


### Device Environment Data
- The app mirrors a small set of device-environment values into the user document, so that the backend knows the user's current context:
  - `timeZone`, `language`, and `preferredMeasurementSystem` are updated when iOS notifies the app of a change (and when an account is associated)
  - `lastActiveDate` is updated whenever the app is brought into the foreground (but not for background launches)
- See the Internal Account Keys table above for the individual fields


### Active Tasks
- MHC currently has the following kinds of active tasks:
  - Questionnaires we prompt the user to fill out and answer
  - Timed Walk/Run Test results
  - ECGs
- These data are collected as FHIR resources:
  - [QuestionnaireResponse][R4QuestionnaireResponse] for the questionnaires
  - [Observation][R4Observation] for the timed walk/run tests and the ECGs
- Storage:
  - Questionnaire responses are written directly into firestore, as individual documents at `/users/{uid}/questionnaireResponses/{id}`
    - The document id is the response's FHIR `identifier`, if present; otherwise (in practice: always) a freshly-generated UUID
    - The response's `questionnaire` field is set to the canonical url of the questionnaire it belongs to
    - Note: these are direct firestore writes; there is no staging/retry (a failed write is logged and dropped)
    - Since the migration from Spezi to Grove (Grove 0.3.0), a question the participant skipped or left unselected is omitted from `item` entirely. Documents written by earlier builds instead carry an `item` entry for it, with `"answer": [{}]` for a single-value question and `"answer": []` for a choice question. Consumers must treat a missing `linkId` as "not answered", rather than assuming every question appears exactly once per response.
  - Timed Walk/Run Test results are written directly into firestore, as individual documents at `/users/{uid}/HealthObservations_MHCHealthObservationTimedWalkingTestResultIdentifier/{uuid}`, with the document id being the observation's id
  - ECGs are not stored separately: they exist as `HKElectrocardiogram` samples in the Health database, and get collected and uploaded via the regular HealthKit ingestion pipeline (see below)
- For questionnaires: in addition to creating a FHIR resource representing the questionnaire response as a whole, the app also extracts supported quantity values from questionnaire responses and writes them to HealthKit, triggering the regular HealthKit ingestion pipeline (see below)
  - This is currently the case for the "Heart Risk" questionnaire, which contains questions collecting values for blood pressure and blood glucose
  - The system is extensible and should be updated to cover additional questionnaires as well, where possible


### Custom Quantity Samples
- MHC supports data entry (via the dashboard) for quantity sample types not supported by HealthKit
  - (It also supports data entry for HealthKit-supported quantity sample types; in these cases the entered data simply gets saved into HealthKit and ptocessed via the pipeline described below)
- Custom quantity values (i.e., blood lipids / LDL cholesterol, and A1c blood glusose) are encoded as FHIR [Observation][R4Observation]s and written directly into firestore, as individual documents at `/users/{uid}/HealthObservations_{sampleTypeId}/{uuid}` (with the document id being the observation's id)uploaded using the same pipeline as regular HealthKit samples


### HealthKit

- MHC collects HealthKit data
- The set of `HKSampleType`s we collect is defined in the study definition
- During the onboarding, the user is asked to grant us access, and the app registers automatic background observers for all sample types listed in the study definition
- iOS will periodically wake the app in the background to inform it of new samples that were added to the Health database
  - The app then ingests these samples using the processing pipeline outlined below
- HealthKit data is represented as FHIR [Observation][R4Observation]s (except `HKClinicalRecord` values; see below)
- MHC perfoms two kinds of data ingestion from HealthKit:
  1. Collection of live Health data (i.e., `HKSample`s added to HealthKit after the user's enrollment in the study)
  2. Collection of historical Health data (i.e., `HKSample`s that already exist in HealthKit at the time of the user's enrollment)
- Live health data collection is handled via the above-mentioned background observer queries
- Historical health data collection is handled by the `HistoricalHealthSamplesExportManager`, which uses SpeziHealthKit's Bulk Upload API to collect and batch-upload past health data
  - The underlying `BulkHealthExporter` manages the historical data collection
  - The collection and upload of historical data is not expected to complete in a single launch, and is specifically implemented in a way that allows it to run (slowly) in the background and process and upload the historical data batch-by-batch over the course of multiple app sessions
  - The API explicitly supports the app being killed while the data ingestion is running; the next launch will simply continue where the previous one left off



#### (Live) HealthKit Data Ingestion Pipeline

- The app does not upload live HealthKit samples immediately to the server
- Instead, it has a local buffer database, into which any new samples HealthKit delivers to the app are placed
- The app then keeps the samples in the buffer for around 3 days, and only then will upload them to the server
- The purpose of the buffer is to:
  1. Allow for on-device reconciliation of HealthKit deletions: if HealthKit informs us of a new sample at timestamp `T1`, and then informs us of a deletion at timestamp `T2 > T1`, if the deletion matches the sample added at `T1` and the sample is still in the local staging buffer, we can simply remove it from the buffer and never upload it, instead of having to upload the sample to the server and then also, separately inform the server of the deletion.
  2. Allow the app to (ideally) batch multiple samples belonging to the same sample type into a single upload, instead of having to run a bunch of individual single-sample uploads
- Any deletions HealthKit informs us about that don't match any existing samples in the upload buffer are written into a dedicated deletions buffer
- The app periodically runs an upload operation, which:
  1. takes all samples whose time in the buffer has exceeded the on-device retention period,
  2. batches them by sample type,
  3. uploads them to the server,
  4. removes them from the buffer.
- It also does the same for the deletion records
- When adding samples to the local buffer, the samples are converted into FHIR resources, which are then placed in the buffer (as JSON strings)
  - As part of the `HKSample` → FHIR conversion, MHC adjusts the resource as follows:
    - The `issued` date is set to the timestemp when the app ingested the `HKSample` (i.e., it represents the date the FHIR resource was issued, rather than the date the underlying `HKSample` was created)
    - FHIR extensions are added to the resource, storing:
      - The device's current time zone when the sample is collected
      - The currently-enrolled study revision
      - The current version and build number of the MHC app
- Each batch of samples being uploaded to the server is a single zstd-compressed JSON file.
  - The uploading is done using the `ManagedFileUpload` module; see below
- It is guaranteed that each batch is homogeneous, i.e., that all samples contained within a batch have the same sample type.
- HealthKit sample batches are uploaded to the following locations within firebase storage:
  - `/users/{uid}/liveHealthSamples/{sampleTypeId}_{uuid}.json.zstd` for all new samples being added to HealthKit after the user enrolled into the study;
  - `/users/{uid}/historicalHealthSamples/{sampleTypeId}_{uuid}.json.zstd` for the one-time upload of past historical HealthKit data
- Deletion records that have been in the buffer longer than the on-device retention period are also batched (into CSV files) and uploaded to the firebase storage backend
  - `/users/{uid}/healthDeletions/{sampleTypeId}_{uuid}.csv.zstd`
- All HealthKit-related files uploaded to storage (both for ingestion of new samples as well as for deletion records) have the following metadata fields set:
  - `batchStartDate`: the start date of the earliest sample in the batch (ISO8601 string)
  - `batchEndDate`: the end date of the latest sample in the batch (ISO8601 string)
  - `numSamples`: the number of samples in the batch (integer)


#### HealthKit Data Format

- All `HKSample`s are represnted as FHIR [Observation][R4Observation]s
- `HKClinicalRecord` samples are represented using their underlying FHIR resource provided to us by HealthKit
  - This can be either a R4 resource or a DSTU2
  - It can be any of the following resource types: AllergyIntolerance, Condition, Coverage, Immunization, MedicationOrder, MedicationRequest, MedicationStatement, MedicationDispense, Observation, Procedure, DiagnosticReport, or DocumentReference
  - In contrast to all other `HKSample`s, `HKClinicalRecord` samples are wrapped in a `{"version": "R4"|"DSTU2", "resource": {...}}` envelope
- Time zone handling:
  - `HKSample` start/end dates are absolute points in time; HealthKit does not inherently associate samples with a time zone
    - the app that created a sample *may* have stored the then-current time zone in the sample's metadata (`HKMetadataKeyTimeZone`), but this is optional and many sources don't
  - when converting a sample into a FHIR Observation, the `effectiveDateTime` / `effectivePeriod` values are serialized using the sample's `HKMetadataKeyTimeZone` metadata entry, if present; otherwise using the device's current time zone at the time of the conversion
    - i.e.: the UTC offset in these values tells us the user's local time at which the sample was recorded *only* for samples that carry a time zone in their metadata (in which case the time zone also shows up in the `metadata` FHIR extension); for all other samples, the offset is merely an artifact of the conversion and carries no information about the sample itself
  - additionally, the `sampleUploadTimeZone` extension stores the device's time zone identifier as of when the sample was ingested/converted by MHC
    - for live samples this happens when the sample is placed into the upload buffer (i.e., typically shortly after the sample was recorded, and up to several days before the actual upload; the name is slightly misleading)
    - for historical samples this happens at export time, which can be years after the sample was recorded
  - all `effective[x]` dates in FHIR resources created from HealthKit samples should be converted into UTC before downstream processing
    - for samples where HealthKit explicitly records time zone information, a `HKMetadataKeyTimeZone` entry will be recorded as an extension


<details>
<summary>Example HKQuantitySample FHIR JSON</summary>

```json
{
  "code" : {
    "coding" : [
      {
        "code" : "8867-4",
        "display" : "Heart rate",
        "system" : "http://loinc.org"
      },
      {
        "code" : "364075005",
        "display" : "Heart rate",
        "system" : "http://snomed.info/sct"
      },
      {
        "code" : "HKQuantityTypeIdentifierHeartRate",
        "display" : "Heart Rate",
        "system" : "http://developer.apple.com/documentation/healthkit"
      }
    ]
  },
  "effectiveDateTime" : "2026-08-07T16:03:37.797878384-07:00",
  "extension" : [
    {
      "extension" : [
        {
          "url" : "https://bdh.stanford.edu/fhir/defs/sourceDevice/name",
          "valueString" : "Apple Watch"
        },
        {
          "url" : "https://bdh.stanford.edu/fhir/defs/sourceDevice/manufacturer",
          "valueString" : "Apple Inc."
        },
        {
          "url" : "https://bdh.stanford.edu/fhir/defs/sourceDevice/model",
          "valueString" : "Watch"
        },
        {
          "url" : "https://bdh.stanford.edu/fhir/defs/sourceDevice/hardwareVersion",
          "valueString" : "Watch7,12"
        },
        {
          "url" : "https://bdh.stanford.edu/fhir/defs/sourceDevice/softwareVersion",
          "valueString" : "26.5"
        }
      ],
      "url" : "https://bdh.stanford.edu/fhir/defs/sourceDevice"
    },
    {
      "extension" : [
        {
          "extension" : [
            {
              "url" : "https://bdh.stanford.edu/fhir/defs/sourceRevision/source/name",
              "valueString" : "Lukas' Apple Watch"
            },
            {
              "url" : "https://bdh.stanford.edu/fhir/defs/sourceRevision/source/bundleIdentifier",
              "valueString" : "com.apple.health.B83FE7C9-B62D-44D9-92A8-5CB2AE037A06"
            }
          ],
          "url" : "https://bdh.stanford.edu/fhir/defs/sourceRevision/source"
        },
        {
          "url" : "https://bdh.stanford.edu/fhir/defs/sourceRevision/version",
          "valueString" : "31.2"
        },
        {
          "url" : "https://bdh.stanford.edu/fhir/defs/sourceRevision/productType",
          "valueString" : "Watch7,12"
        },
        {
          "url" : "https://bdh.stanford.edu/fhir/defs/sourceRevision/OSVersion",
          "valueString" : "26.5.0"
        }
      ],
      "url" : "https://bdh.stanford.edu/fhir/defs/sourceRevision"
    },
    {
      "extension" : [
        {
          "url" : "https://bdh.stanford.edu/fhir/defs/metadata/HKMetadataKeyHeartRateMotionContext",
          "valueCoding" : {
            "code" : "1",
            "display" : "sedentary",
            "system" : "https://developer.apple.com/documentation/healthkit/hkheartratemotioncontext"
          }
        }
      ],
      "url" : "https://bdh.stanford.edu/fhir/defs/metadata"
    },
    {
      "url" : "https://bdh.stanford.edu/fhir/defs/sampleUploadTimeZone",
      "valueString" : "America/Los_Angeles"
    },
    {
      "extension" : [
        {
          "url" : "https://myheartcounts.stanford.edu/fhir/StructureDefinition/study-enrollment/study-id",
          "valueString" : "5D464372-C9A3-4018-A789-47149D934BFC"
        },
        {
          "url" : "https://myheartcounts.stanford.edu/fhir/StructureDefinition/study-enrollment/study-revision",
          "valueInteger" : 42
        }
      ],
      "url" : "https://myheartcounts.stanford.edu/fhir/StructureDefinition/study-enrollment"
    }
  ],
  "id" : "BDAC71F6-3398-4BDD-A56C-7BD50988D87A",
  "identifier" : [
    {
      "id" : "BDAC71F6-3398-4BDD-A56C-7BD50988D87A",
      "value" : "BDAC71F6-3398-4BDD-A56C-7BD50988D87A"
    }
  ],
  "issued" : "2026-08-07T16:04:59.340883016-07:00",
  "resourceType" : "Observation",
  "status" : "final",
  "valueQuantity" : {
    "code" : "/min",
    "system" : "http://unitsofmeasure.org",
    "unit" : "beats/minute",
    "value" : 84
  }
}
```
</details>


##### HKSample -> FHIR Observation mapping history
- Prior to MHC build *todo*



### SensorKit

- MHC collects SensorKit data, if the user has opted in by granting us access
- SensorKit data is collected when the app is launched, as well as via a background `BGHealthResearchTask`
- In contrast to HealthKit, SensorKit does not offer a background "new data" observation API, and the app needs to handle this on its own
- Since the amount of data produced by SensorKit is significantly larger than what HealthKit produces, the app is not able to unconditionally store these data as FHIR resources, and instead employes a per-sensor encoding strategy (see the table below)
  - Low-density sensor streams are collected and uploaded as JSON-encoded FHIR [Observation][R4Observation]s
  - High-density sensor streams are instead collected and uploaded as CSV files containing the raw readings
- In contrast to HealthKit, the SensorKit data collection does not have an on-device buffer, and instead always uploads all data directly to the server
- The uploading happens using the `ManagedFileUpload` module, to the following locations in firebase storage:
  - `/users/{uid}/SensorKit/{sensorId}/{uuid}.{fileExt}`
- Each file uploaded by MHC's SensorKit data collection system sets the following metadata fields:
  - `batchStartDate`: the start date of the earliest sample in the batch (ISO8601 string)
  - `batchEndDate`: the end date of the latest sample in the batch (ISO8601 string)
  - `numSamples`: the number of samples in the batch (integer)


| Sensor           | Upload |
| :--------------- | :----- |
| visits           | JSON file with FHIR observations (`.json.zstd`) |
| onWrist          | JSON file with FHIR observations (`.json.zstd`) |
| deviceUsage      | JSON file with FHIR observations (`.json.zstd`) |
| ecg              | JSON file with FHIR observations (`.json.zstd`) |
| wristTemperature | CSV file per sample (`.csv.zstd`) |
| heartRate        | CSV file per batch (`.csv.zstd`) |
| pedometer        | CSV file per batch (`.csv.zstd`) |
| ambientLight     | CSV file per batch (`.csv.zstd`) |
| accelerometer    | CSV file per batch (`.csv.zstd`) |
| ambientPressure  | CSV file per batch (`.csv.zstd`) |
| ppg              | custom binary format (`.mhcPPG`) |

- The `.mhcPPG` files used for the PPG data are a custom binary format
  - The reference implementation in the `MyHeartCountsShared` package serves as the format's definition (see also the `SensorKitCLI` target, which implements offline decoding of these files)
  - Note: in contrast to the other SensorKit upload formats, `.mhcPPG` files are not zstd-compressed



### Third-party wearable devices
- MHC allows the user to connect third-party wearable fitness/activity trackers, such as Fitbit, Withings, etc.
- This works by the user establishing a connection between their MHC account and their account with the third-party server, via the MHC account page in the iOS app
- The MHC backend then periodically ingests data from the third-party service (be it via push or pull), and stores it into the firebase storage, as FHIR-encoded samples, in line with how the HealthKit data is represented and stored


## File Uploading

- The `ManagedFileUpload` module is responsible for uploading files from the app to the server
- Other parts of the app (e.g., the HealthKit or SensorKit ingestion pipelines) hand files to `ManagedFileUpload`, which then schedules them for upload
- Every upload belongs to a `Category`, which defines the destination folder within the user's firebase storage prefix (e.g.: `liveHealthSamples`, `historicalHealthSamples`, `healthDeletions`, `SensorKit/{sensorId}`)
- Scheduling is durable: each pending upload is tracked as an entry in a dedicated database (SwiftData; stored in the app's Application Support directory), and the to-be-uploaded file is moved into a staging directory within the app's Documents folder, where it is stored under the upload entry's UUID
  - Scheduling a file for upload returns once the upload is durably registered (database entry created + file moved into the module's custody), i.e. before/independent of the actual upload happening
- The module works its way through the pending entries (oldest first; several concurrently), uploading each file into firebase storage and deleting the entry + staged file upon success
- Uploads are written to `users/{uid}/{category}/{filename}`, with contentType `application/octet-stream`
- Failure/retry behavior:
  - A failed upload remains scheduled and is retried on subsequent launches (at most one attempt per entry per launch; no retry cap)
  - If the database cannot be accessed because the device hasn't yet been unlocked since boot (e.g., background launch before first unlock), the module is inert for that launch; pending uploads resume on the next launch
  - If the database is corrupted, it is moved aside (not deleted) and recreated; uploads pending at that point are no longer tracked (their staged files are retained on disk, but won't be re-scheduled)



## Data Lifecycle

### Logout / Unenrollment
- Logging out unenrolls the user from the study, and deletes the local study/scheduler state, the HealthKit upload buffer, and any pending (not-yet-uploaded) file uploads
  - Note: this means that locally buffered health samples (and deletion records) that have not yet been uploaded at that point are discarded, not uploaded
- The SensorKit query anchors are also reset; a subsequent re-login will therefore re-fetch (and re-upload) SensorKit data the server already has

### Study Withdrawal
- The user can withdraw from the study via the in-app button in the account sheet; this invokes the `markAccountForStudyWithdrawal` function (which sets `hasWithdrawnFromStudy` and appends to the user document's `studyEnrollmentHistory`), and then logs the user out
- Withdrawal does not delete any data; all previously collected data remains on the server
  - Its effects are: the user stops receiving nudge notifications, and the user's samples can no longer be marked as entered-in-error
- Re-enrollment (via `markAccountForStudyReenrollment`) clears the flag again

### Account Deletion
- Account deletion is handled server-side: a `toBeDeleted` flag on the user document gets picked up by a periodic deletion sweep (running every 30 minutes), which recursively deletes the user's firestore document tree, the user's firebase storage prefix, and the auth user
- There is currently no in-app UI for requesting account deletion
- Note: data living outside the `/users/{uid}` trees survives deletion (e.g., submitted feedback documents, which live in a root-level `feedback` collection)

### Individual Sample Deletion
- HealthKit deletions are propagated via the deletions buffer and uploaded as CSV files (see the ingestion pipeline above)
  - deletions that still find their matching sample in the local upload buffer are reconciled locally; neither the sample nor the deletion record reaches the server in that case
- Server-side, samples are never physically deleted; the `deleteHealthSamples` function instead marks the affected FHIR resources as entered-in-error

### Server-Side Retention
- Every change to the user document is versioned server-side into `/users/{uid}/documentSnapshots` (excluding a handful of volatile fields, e.g. `fcmToken` and `lastActiveDate`); this history is retained indefinitely and is not client-accessible
- Delivered (and failed) nudge notifications are retained in `/users/{uid}/notificationHistory`


## Server-Written Data

Not all data in the user's firestore tree is written by the app; the backend also produces data:

- Questionnaire scoring: a cloud function triggers on every write to `/users/{uid}/questionnaireResponses/` and computes score observations for the supported questionnaires, writing them as FHIR [Observation][R4Observation]s into the corresponding collections:
  - Diet (MEPA) score → `HealthObservations_MHCCustomSampleTypeDietMEPAScore`
  - Mental Well-Being (WHO-5) score → `HealthObservations_MHCCustomSampleTypeWHO5Score`
  - Nicotine Exposure score → `HealthObservations_MHCCustomSampleTypeNicotineExposure`
  - LDL values parsed from the Heart Risk questionnaire → `HealthObservations_MHCCustomSampleTypeBloodLipidMeasurement`
  - I.e.: the score collections the dashboard reads (see below) are populated by the server, not by the app
  - Note: since the trigger runs on every write, re-writing a questionnaire response produces an additional score observation
- Nudge notifications: the backend plans nudges into `/users/{uid}/notificationBacklog`, delivers them via FCM, and archives each result (incl. delivery status) into `/users/{uid}/notificationHistory`
- User document fields: some fields on `/users/{uid}` are exclusively server-managed and not backed by any account key in the app (e.g., `disabled`, `participantGroup`, `toBeDeleted`, `studyEnrollmentHistory`, `lastUploadDate`)
- `/users/{uid}/documentSnapshots`: server-maintained version history of the user document (see Data Lifecycle above)
- Note: the server-side ingestion of the uploaded health-sample batch files (unpacking `liveHealthSamples` uploads into firestore observations) is currently disabled; uploaded batches accumulate in firebase storage until it is re-enabled




## Client data needs

- in addition to querying on-device HealthKit data for upload to the backend, MHC also needs to query data for displaying it in the app, to the user
- we cannot rely only on querying local HealthKit data here, as this would miss any data that exists on the server but is not present in the client's HealthKit database:
  - data imported from third-party wearable services that don't already push their samples into the user's Health app
  - data manually entered by the user into the app, when we were not granted HealthKit write permissions


| Data | Needed By | Fetched From |
| :--- | :--- | :--- |
| Exercise Minutes          | HHD | Stats doc |
| Step Count                | HHD | Stats doc |
| Sleep Stats               | HHD | Stats doc |
| Diet                      | HHD | `/users/{uid}/HealthObservations_MHCCustomSampleTypeDietMEPAScore/` |
| Nicotine Exposure         | HHD | `/users/{uid}/HealthObservations_MHCCustomSampleTypeNicotineExposure/` |
| Mental Well Being         | HHD | `/users/{uid}/HealthObservations_MHCCustomSampleTypeWHO5Score/` |
| Heart Rate                | HHD | Stats doc |
| Blood Pressure            | HHD | Stats doc |
| LDL cholesterol           | HHD | Individual samples (`/users/{uid}/HealthObservations_MHCCustomSampleTypeBloodLipidMeasurement/`) |
| Blood Glucose (Fasting)   | HHD | Individual samples (`/users/{uid}/HealthObservations_MHCCustomSampleTypeBloodGlucoseFasting/`) |
| Blood Glucose (A1c)       | HHD | Individual samples (`/users/{uid}/HealthObservations_MHCCustomSampleTypeBloodGlucoseA1c/`) |
| BMI                       | HHD | Stats doc |
| Height                    | HHD | Stats doc |
| Weight                    | HHD | Stats doc |
| Past Timed Walk/Run tests | App | Individual samples (`/users/{uid}/HealthObservations_MHCHealthObservationTimedWalkingTestResultIdentifier/`) |




## User Data Statistics

- In order to drive certain in-app functionality (e.g., the health dashboard), the app needs statistics computed/derived from the user's data
- E.g.: the Heart Health Dashboard needs to know a bunch of data to compute its individual cardiovascular health scores
- Since we have data sources beyond the on-device HealthKit data, we cannot implement this the easy/trivial way (by simply running a local on-device HKStatisticsQuery)
- Solution: we maintain a series of well-known statistics documents, which store precomputed statistical values, that can be used by the client (eg the app) to compute whatever final statistics it needs
- The purpose of these documents is to enable the app to be able to fetch *all* of the data it displays to the user from the cloud backend, instead of performing local fetches from e.g. HalthKit.
- As such, we only need these stats documents for data that is being added into the app by multiple sources, and/or is not written directly into the firestore.
- Conventions:
  - each metric has a well-known, stable, kebab-case identifier (e.g. `steps`, `heart-rate`; see the metrics table below), which is used both in the stats document paths and in the documents' `metric` field
    - note: these are deliberately *not* the HealthKit identifiers; the stats layer is source-agnostic
  - all timestamps within stats documents are encoded as ISO8601 strings (incl. the UTC offset of the device's local time zone, since the bucket boundaries are computed in local time)
  - all numeric values are stored as plain (double) numbers
  - all values are stored in fixed, locale-independent units (SI, resp. the metric's canonical unit; e.g. `count`, `count/min`, `kg`, `mmHg`), denoted by the entries' `unit` field; the client converts into locale-appropriate units for display


### What data do we need?

| Data | Need | Format |
| :--- | :--- | :--- |
| Exercise Minutes | HHD | Daily "number of active minutes" count |
| Step Count | HHD | Daily step count |
| Sleep Stats | HHD | Time asleep, per sleep session |
| Diet | HHD | Score computed from survey responses |
| Mental Well Being | HHD | Score computed from survey responses |
| Heart Rate | HHD | Hourly min/max/avg |
| Blood Pressure | HHD | Individual samples for sys/dia |
| LDL cholesterol | HHD | Individual samples |
| Blood Glucose (Fasting + A1c) | HHD | Individual samples |
| BMI | HHD | Individual samples |
| Height | HHD | Individual samples |
| Weight | HHD | Individual samples |
| Noicotine Exposure | HHD | Score computed from survey responses |
| Past Timed Walk/Run tests | App | Individual samples |

Constraints:
- all data needs to go back at least 12 months
- since we have multiple potential data sources (HealthKit, Android Health Connect, Fitbit, Withings, etc), we need the data handling/processing/storage and stats computation to somehow work in a way that supports these multiple, competing data sources


### High-level structure
- we have special stats documents, at `/users/{uid}/stats/{metric}/months/{year}-{month}`, which contain hourly stats for a sample type for a month
  - e.g. `/users/{uid}/stats/steps/months/2026-08`
  - note: the path schema is intentionally `stats/{metric}/months/{year}-{month}` instead of e.g. `stats/{metric}/{year}/{month}`, since the iOS client SDK allows us to query all documents within a collection, but not to query all collections within a document. in the second schema, we would be unable to easily obtain a full list of all stats docs available for a metric, and would need to programmatically enumerate all possible years, to check within each year's collection. the first schema allows us to simply ask firestore for a list of all `year-month` documents within a metric.
- each statistics document contains the following:
  - a `version` so we can easily evolve the structure down the road
  - the `metric` of the values in the document
  - the entries themselves, grouped by data source (under `hourly`/`daily` for bucketed metrics, `sessions` for sleep, resp. `samples` for individual-samples metrics; see below)
- different metrics' stats documents have different shapes, based on the specific metric's shape and needs:
  - cumulative metrics (e.g., step count) are stored as per-interval sums
  - high-frequency non-cumulative metrics (e.g., heart rate) are stored as per-interval min/max/avg buckets
  - sparse/discrete measurements (e.g., blood pressure, weight) are stored as individual samples
  - sleep is stored per sleep session, using the same shape as the interval sums, but with the entries' start/end being the session's bounds instead of a fixed interval
    - the reason for this is that sleep sessions don't align with clock intervals (a night's sleep typically spans midnight); storing the individual sessions allows a consumer to derive whatever view it needs (incl. a per-day one), which wouldn't be possible if we split each session across the calendar days it overlaps
    - the sessions are formed by grouping consecutive sleep analysis samples (the same way the app does it for the dashboard), and a session's value is the actual time spent asleep, which takes overlapping samples (e.g. from a phone and a watch tracking the same night) into account


#### Non-cumulative metric stats document

In the case of a non-cumulative sample type, each month's stats document contains a list of hourly min/max/avg readings.

Example: heart rate, at `/users/{uid}/stats/heart-rate/months/2026-08`

```jsonc
{
  "version": 0,
  "metric": "heart-rate",
  "hourly": {
    "com.apple.HealthKit": [
      // ...
      {
        "start": "2026-08-10T04:00:00-07:00",
        "end": "2026-08-10T05:00:00-07:00",
        "unit": "count/min",
        "min": 49,
        "max": 56,
        "avg": 52.423825347707634
      },
      {
        "start": "2026-08-10T05:00:00-07:00",
        "end": "2026-08-10T06:00:00-07:00",
        "unit": "count/min",
        "min": 47.83707809448242,
        "max": 65,
        "avg": 55.85580520629883
      },
      {
        "start": "2026-08-10T06:00:00-07:00",
        "end": "2026-08-10T07:00:00-07:00",
        "unit": "count/min",
        "min": 50,
        "max": 63,
        "avg": 54.875
      },
      // ...
    ],
    "fitbit": [
      // ...
    ]
  }
}
```


#### Cumulative metric stats document

In the case of cumulative metrics (e.g., step count, exercise minutes, etc), each month's document simply contains a list of hourly sums.

Example: step count stats document, at `/users/{uid}/stats/steps/months/2026-08`
```jsonc
{
  "version": 0,
  "metric": "steps",
  "hourly": {
    "com.apple.HealthKit": [
      // ...
      {
        "start": "2026-08-10T07:00:00-07:00",
        "end": "2026-08-10T08:00:00-07:00",
        "unit": "count",
        "sum": 2288
      },
      {
        "start": "2026-08-10T08:00:00-07:00",
        "end": "2026-08-10T09:00:00-07:00",
        "unit": "count",
        "sum": 350
      },
      {
        "start": "2026-08-10T09:00:00-07:00",
        "end": "2026-08-10T10:00:00-07:00",
        "unit": "count",
        "sum": 34
      },
      // ...
    ],
    "fitbit": [
      // ...
    ]
  }
}
```


#### Individual-samples metric stats document

In the case of sparse/discrete metrics (e.g., blood pressure, weight), each month's document simply contains the individual readings.

Example: blood pressure, at `/users/{uid}/stats/blood-pressure/months/2026-08`
```jsonc
{
  "version": 0,
  "metric": "blood-pressure",
  "samples": {
    "com.apple.HealthKit": [
      // ...
      {
        "date": "2026-08-10T08:41:00-07:00",
        "unit": "mmHg",
        "systolic": 121,
        "diastolic": 79
      },
      // ...
    ]
  }
}
```


### Metrics

| Metric           | Id               | Shape              | Time Range |
| :--------------- | :--------------- | :----------------- | :--------- |
| Step Count       | `steps`          | sum                | hourly     |
| Exercise Minutes | `exercise-time`  | sum                | hourly     |
| Heart Rate       | `heart-rate`     | min/max/avg        | hourly     |
| Sleep Stats      | `sleep`          | sum                | per sleep session |
| Blood Pressure   | `blood-pressure` | individual samples | —          |
| Weight           | `weight`         | individual samples | —          |
| Height           | `height`         | individual samples | —          |
| BMI              | `bmi`            | individual samples | —          |

- Note: the survey-derived scores (Diet, Mental Well Being, Nicotine Exposure) and the custom quantity samples (LDL cholesterol, blood glucose) deliberately do *not* get stats documents: they are single-source data that is already stored directly in firestore, in queryable per-sample collections, so the app can simply fetch them from there (in line with the rule above)



[R4QuestionnaireResponse]: https://hl7.org/fhir/R4/questionnaireresponse.html
[R4Observation]: https://hl7.org/fhir/R4/observation.html
