<!--

This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project

SPDX-FileCopyrightText: 2025 Stanford University

SPDX-License-Identifier: MIT

-->

# My Heart Counts

[My Heart Counts (MHC) application](https://myheartcounts.stanford.edu) is a [Spezi](https://github.com/StanfordSpezi)-based large-scale cardiovascular study application, developed at Stanford University.

Key features include:
- Schedule-based, user-actionable tasks and content, such as surveys, active tasks, or informative articles
- Active tasks, for example a Six Minute Walk Test and a Twelve Minute Run Test
- Automatic data collection through Apple’s SensorKit and HealthKit frameworks
- MHC Heart Health Dashboard, which provides an overview of the participant’s overall health, computed from eight metrics read from HealthKit and survey responses
- Physical Activity Trial with personalized coaching messages
- Large Language Model (LLM) generated personalized physical activity nudges

<table style="width: 80%">
  <tr>
    <td align="center" width="33.33333%">
      <img src="assets/screenshots/nudge.png#gh-light-mode-only" width="80%"/>
      <img src="assets/screenshots/nudge~dark.png#gh-dark-mode-only" width="80%"/>
    </td>
    <td align="center" width="33.33333%">
      <img src="assets/screenshots/questionnaire.png#gh-light-mode-only" width="80%"/>
      <img src="assets/screenshots/questionnaire~dark.png#gh-dark-mode-only" width="80%"/>
    </td>
    <td align="center" width="33.33333%">
      <img src="assets/screenshots/dashboard.png#gh-light-mode-only" width="80%"/>
      <img src="assets/screenshots/dashboard~dark.png#gh-dark-mode-only" width="80%"/>
    </td>
  </tr>
  <tr>
    <td align="center">Home</td>
    <td align="center">Heart Health Surveys</td>
    <td align="center">Heart Health Dashboard</td>
  </tr>
  <tr>
    <td align="center" width="33.33333%">
      <img src="assets/screenshots/6mwt.png#gh-light-mode-only" width="80%"/>
      <img src="assets/screenshots/6mwt~dark.png#gh-dark-mode-only" width="80%"/>
    </td>
    <td align="center" width="33.33333%">
      <img src="assets/screenshots/sleep.png#gh-light-mode-only" width="80%"/>
      <img src="assets/screenshots/sleep~dark.png#gh-dark-mode-only" width="80%"/>
    </td>
    <td align="center" width="33.33333%">
      <img src="assets/screenshots/home_es.png#gh-light-mode-only" width="80%"/>
      <img src="assets/screenshots/home_es~dark.png#gh-dark-mode-only" width="80%"/>
    </td>
  </tr>
  <tr>
    <td align="center">Active Tasks (6 Minute Walk Test and 12 Minute Run Test)</td>
    <td align="center">Detailed Health Stats</td>
    <td align="center">Spanish Language Support</td>
  </tr>
</table>


## Stanford Spezi

This repository contains the My Heart Counts (MHC) iOS application, which is implemented using the [Spezi](https://github.com/StanfordSpezi/Spezi) ecosystem and builds on top of the [Stanford Spezi Template Application](https://github.com/StanfordSpezi/SpeziTemplateApplication).

> [!NOTE]  
> Do you want to learn more about the Stanford Spezi Template Application and how to use, extend, and modify this application? Check out the [Stanford Spezi Template Application documentation](https://stanfordspezi.github.io/SpeziTemplateApplication).


## Setting Up a Local Development Environment
In order to run and develop the My Heart Counts app locally, you'll need the following:
1. Clone this repository
2. A firebase environment
3. A study bundle
4. The app itself (either in the simulator or on a real device)

### The Study Definition
1. Go to the definitions submodule: `cd MyHeartCounts-StudyDefinitions`
2. Run `swift run MHCStudyDefinitionExporterCLI export ..` to generate a study bundle
    - This will place a `mhcStudyDefinition.spezistudybundle.aar` file in the root of the MyHeartCounts-iOS repo
    - you can have it saved elsewhere by replacing the `..` with the path of the folder where you want the study definition to be placed

### The Firebase Environment
1. Go to the firebase submodule: `cd MyHeartCounts-Firebase`
2. Run `npm run prepare`
3. Run `npm run serve:seeded`

### The App Itself
1. Disable SensorKit and adjust the Codesign options
    - (You can skip this step if you have access to a Stanford-generated provisioning profile and have Stanford's codesign certificate installed locally.)
    - Open `MyHeartCounts.entitlements` and remove the `com.apple.developer.sensorkit.reader.allow` entry
    - Change the bundle identifiers in all targets (e.g., by adding a custom prefix)
        - Note: you'll also need to edit the watch app's Info.plist and adjust the `WKCompanionAppBundleIdentifier` entry
    - Select your own development team in the MyHeartCounts and MyHeartCountsWatchApp targets, and enable the automatic code signing option
2. Adjust the app's run configuration (open via `cmd+shift+,`) and enable the following options:
    - `--useFirebaseEmulator`
        - If you wish to use a custom firebase deployment instead of a local emulator, you'll need to use the `--overrideFirebaseConfig plist=name` flag instead, where `name` is either an absolute path of a GoogleService-Info.plist file (this will only work in the simulator), or the filename (without extension) of a GoogleService-Info.plist file bundled with the app.
    - `--studyBundle`
        - Specify the absolute path of the `.aar` file generated above
        - Note: if you're running the app on a physical device, specifying the file location on the Mac won't work, since the iPhone can't access that. Instead, you can do one of the following:
            - Bundle the study definition into the app:
                - Drag the `.aar` file into the app's Resources folder in Xcode
                - Adjust the code in the `StudyBundleLoader` type to simply always load from that in-bundle URL
            - Host the study definition using the Firebase storage emulator:
                - Open the Storage emulator (likely at http://localhost:4000/storage)
                - Upload the `mhcStudyBundle.spezistudybundle.aar` file to the `/public` folder
                - Configure the `--studyBundle` argument to point to `http://HOSTNAME.local:9199/v0/b/myheart-counts-development.appspot.com/o/public%2FmhcStudyBundle.spezistudybundle.aar?alt=media`
                    - Note that you'll need to replace `HOSTNAME` with your Mac's local-network name (you can find this in Settings.app → General → Sharing → Local hostname)
    - `--disableAutomaticBulkHealthExport`
        - (this option will disable the historical health data collection, improving performance when running the app on a real device)
3. Run the application in Xcode.

> [!NOTE]  
> Please make sure not to commit and push any of the SensorKit, Code Signing, and run argument changes listed above; these changes are only required for local development.


## Contributing

Contributions to this project are welcome. Please make sure to read the [contribution guidelines](https://github.com/SchmiedmayerLab/.github/blob/main/CONTRIBUTING.md) and the [contributor covenant code of conduct](https://github.com/SchmiedmayerLab/.github/blob/main/CODE_OF_CONDUCT.md) first.


## License

This project is licensed under the MIT License. See [Licenses](https://github.com/SchmiedmayerLab/MyHeartCounts-iOS/tree/main/LICENSES) for more information.

![Stanford and Stanford Medicine logos](https://raw.githubusercontent.com/SchmiedmayerLab/.github/main/assets/stanford-footer-light.png#gh-light-mode-only)
![Stanford and Stanford Medicine logos](https://raw.githubusercontent.com/SchmiedmayerLab/.github/main/assets/stanford-footer-dark.png#gh-dark-mode-only)
