<!--

This source file is part of the My Heart Counts iOS open-source project

SPDX-FileCopyrightText: 2025 Stanford University and the project authors (see CONTRIBUTORS.md)

SPDX-License-Identifier: MIT

-->

# Changelog

Notable changes to the My Heart Counts iOS app, with one section per App Store release (newest first, dated by App Store release).
Changes that haven't been released yet go into the `Next` section.
Versions before 4.0.0 belong to the previous My Heart Counts app and aren't listed here.


## Next

- Heart Health score: the overall score now appears once 3 of its 9 components have data, and shows "More data needed" below 5. Tapping the score opens a sheet that explains the calculation and suggests the easiest missing components to fill in. Mental wellbeing now counts toward the score.
- Blood glucose: the Blood Glucose tile now takes either a blood glucose reading, with the meal time, or an HbA1c value. In the UK, values are shown and entered in mmol/L and mmol/mol. Scoring always uses the units its bands are defined in.
- Data entry: all data entry sheets share one form, with a "Save to the Health App" toggle. Entries are always shared with the study, also when they aren't saved to the Health app or the app may not write to it.
- New participation statistics, personal bests and achievements in the account sheet and the Heart Health dashboard.
- UK study: the region picked during onboarding now selects the US (Stanford) or the UK (Imperial) study. The UK study has its own study definition, consent, Participant Information Sheet and privacy notice, UK demographics questions (counties, education levels, ethnic groups, postcode, and the CHI number in Scotland), NHS guidance links, and LDL in mmol/L.
- The Stanford study now shows the Stage of Change option titles instead of letters.
- Questionnaire responses submitted while offline are now kept and uploaded later.
- If the app's configuration fails to load at launch, a full-screen error now says what went wrong.
- Lower battery, memory and disk use while processing Health and SensorKit data.
- HealthKit and SensorKit data are now uploaded as FHIR Bundles that follow the My Heart Counts implementation guide, including each sample's source details. Each SensorKit batch uploads as one archive.
- All FHIR resources now record the app version and build number.
- Uploads now go through a persistent on-device queue that retries failed uploads and keeps going in the background.
- Health statistics are now computed on the device from the participant's HealthKit data and uploaded.
- More robust HealthKit upload staging: deletions that overlap a pending upload are kept, and oversized or unreadable records no longer stall an upload.
- A single failing SensorKit record no longer keeps the rest of its batch from uploading.
- Manually entered samples are now marked as user-entered.
- The account now records when the upload of historical health data completed.
- Health and SensorKit data can now go to a separate storage bucket, set per backend.
- The study definition now downloads as a zstd archive.
- Background task events can now be exported from the debug view.
- The app is now built on Grove (formerly Spezi), Firebase 13.2, and the iOS 27 SDK.
- Kitten Mode now also has giant pandas, golden retrievers and black panthers.
- The app takes about 48 MB less space on iPhone and about 55 MB less on Apple Watch.
- UK study: participants who withdrew and log back in to re-enroll now sign the consent again.
- Health records now upload as one archive per batch, including the files the Health app stores with them.


## 4.0.7 (2026-08-08)

- Onboarding no longer requires write access to height and weight in the Health app.


## 4.0.6 (2026-08-05)

- Suggested Actions: the Home tab shows a summary of open app actions (enabling SensorKit, completing the demographics, verifying the email address, connecting health records), and tapping it lists them. The account sheet always shows the full list, including completed and hidden actions.
- Demographics: some fields are now optional, or depend on whether the participant opted in to the trial. Optional fields are suggested later through Suggested Actions.
- Connecting health records moved from the onboarding into Suggested Actions.
- New "Update Health Conditions" button in the account sheet.
- The onboarding now skips the consent if the participant already signed the current version.
- The 12-minute run test (Cooper test) now shows a VO2 max estimate.
- Fixed the LDL cholesterol scoring bands, and several content issues in the Heart Health dashboard.
- Fixed on iOS 26.5: the "Complete Demographics" sheet closed as soon as it was touched, and the "Suggested Actions" sheet reloaded unexpectedly.
- Fixed: the demographics weren't always filled in when logging back in to an existing account.
- The license information now links to the project website.


## 4.0.5 (2026-06-26)

- Fixed: "Today's Tasks" showed completed tasks from past days.
- New privacy policy links in the account sheet and on the sign-up and login screens.
- Much less on-device storage: the local Firestore cache is now limited, and the existing cache is cleared.
- Loading the study definition is more resilient: an app version that can't read the server's newer study definition falls back to the one shipped with the app, and a failed update no longer discards the one already loaded.
- New HealthKit samples are now buffered on the device before upload, so samples deleted shortly after being added are never uploaded.
- Health data is now uploaded to Cloud Storage for the backend to process, instead of being written to Firestore directly.
- Updated SpeziFirebase to 2.0.10, and all other dependencies.


## 4.0.4 (2026-04-23)

- Fixed: the app sometimes crashed on launch or in the background (Firebase update).


## 4.0.3 (2026-04-17)

- New option in the account sheet to keep receiving activity nudges after the trial.
- Fixed a SensorKit deadlock.
- Fixed: the account sheet reset when switching to another app and back.
- The app now records when the participant last used it, and their preferred measurement system.


## 4.0.2 (2026-04-05)

- The participant's app language is now saved to their account.
- FHIR observations now record the study and study revision that were active when they were collected.


## 4.0.1 (2026-03-19)

- Participants outside the US now see a "coming soon" screen, where they can join a waitlist. Signing in to the UK study is disabled for now.
- Fixed: withdrawing from the study failed.
- Logging out now shows a full-screen "Logging Out…" view, instead of briefly returning to the Home tab.
- Fixed the consent's language fallback.
- The extended debug info now opens after 5 taps instead of 3, as a sheet, and also shows the account ID.


## 4.0.0 (2026-03-09)

First release of the rebuilt My Heart Counts app.

- Onboarding: eligibility screening, account creation, an interactive consent loaded from the server, demographics, workout preferences, and the Health, SensorKit, health records and notification permissions.
- The study definition is loaded from the server and refreshed in the background. It defines the participant's scheduled tasks.
- Tasks: questionnaires, informative articles, timed walk and run tests (also on Apple Watch, and resumed if the app was closed during a test), an ECG task, and daily activity nudges with notifications.
- Heart Health dashboard: a score for each heart health metric and an overall score, charts with selectable time ranges, manual data entry, and explainers with links to learn more. BMI scoring takes ethnicity into account.
- Blood pressure and blood glucose answers in questionnaires are saved to the Health app, so they show up in the dashboard.
- HealthKit data is collected in the background, including a one-time upload of historical data, and uploaded as compressed FHIR observations.
- Optional access to health records.
- Optional SensorKit data collection (accelerometer, ambient light, ambient pressure, device usage, ECG, heart rate, on-wrist state, pedometer, PPG and wrist temperature), uploaded in the background.
- Account sheet: feedback, SensorKit status, and study withdrawal.
- English and Spanish.
- Data processing adapts to the device (fewer parallel uploads on non-Pro iPhones). On iPad, the app runs without SensorKit.
