# Releasing

## One-time setup

1. Register a CocoaPods trunk session (once, from any machine):
   ```
   pod trunk register you@payghaam.com 'Your Name' --description='local'
   ```
   Click the verification link trunk emails you.
2. Get a token for CI: after registering, your session token is in
   `~/.netrc` under the `trunk.cocoapods.org` entry — copy the `password`
   value from there.
3. Add it as a repo secret: Settings → Secrets and variables → Actions →
   `COCOAPODS_TRUNK_TOKEN`.

SPM needs none of this — tagging the repo is the entire "publish" step for
SPM consumers (see below). Trunk is only required for the CocoaPods path,
which `payghaam-flutter` and `payghaam-react-native` both depend on.

## Every release

1. Bump `s.version` in `Payghaam.podspec`.
2. Commit, push to `main`.
3. `git tag 0.1.1 && git push --tags` — this both makes the release resolvable
   via SPM immediately, and triggers `.github/workflows/publish.yml` to lint
   and push the podspec to CocoaPods trunk.
4. Optional: submit the repo URL to the
   [Swift Package Index](https://swiftpackageindex.com/add-a-package) once —
   after that, every new tag is picked up automatically with no further
   action.

Note the podspec's `s.source` uses `s.version.to_s` for the git tag — trunk
tags are un-prefixed (`0.1.1`), unlike Android/RN's `v0.1.1` convention below.
Keep that consistent or `pod trunk push` will fail to find the tag.
