# Liberty iOS diagnostic — Actions kit

Builds a standalone Metal display/audio/storage diagnostic, NOT GTA IV.
No game files, licence files, Apple accounts, certificates or secrets belong in this repository.

## Download and install

Open this repository's Actions tab and select **Build unsigned iOS diagnostic**. The workflow builds on pushes to main or via Run workflow.

Once the device job succeeds, download **NativeDiagnostics-unsigned-IPA** from the run's Artifacts section. Extract the ZIP and upload `NativeDiagnostics-unsigned.ipa` to Signulous on your registered device. Do not upload the outer artifact ZIP.

Open the app, check the changing panel and storage result, play the tone and confirm if audible, then share the diagnostic log.

If a build fails, download its build-logs artifact or send the Actions run URL. No IPA is produced when the device compile fails. The simulator job only checks compilation; it does not boot a simulator or test hardware.

## Build locally on a Mac

Run `bash scripts/build-unsigned.sh iphoneos`. Xcode and its iOS SDK must be installed. Output: `output/NativeDiagnostics-unsigned.ipa`.

## Scope and validation

The unsigned IPA cannot be installed directly; signing and provisioning are supplied separately by your signing service. Service compatibility has not been tested. This kit does not change your Apple developer account status or establish permission under your terminated agreements.

The diagnostic requires iOS/iPadOS 16 or newer. It requests no special entitlements. It is not the LibertyRecomp runtime and passing its checks does not establish GTA IV compatibility.

The included source patch is the initial iOS declaration fix from the earlier kit. Further game renderer, dependency and data import work remains.

Shell syntax, workflow structure and ZIP contents were checked locally. This environment cannot run Xcode; compilation and device execution remain unverified until the first Actions/device run.
