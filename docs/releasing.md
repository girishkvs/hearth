# Releasing Hearth

## Version is a contract

`VERSION` is the single product-version source. Change it, run
`scripts/sync-version.sh`, and add matching `docs/releases/<version>.md` and
changelog entries. The checked-in Swift version is generated; `Package.swift`
fails before building if it drifts. App metadata and both package versions derive
from `VERSION`. Release asset names and tag gates use it too.

Product **1.2.0** is separate from root IPC 2, user Lock IPC 2,
journal/status schema 4 and authorization
schema numbers. Do not renumber compatibility formats for marketing. The native
bundle build number also remains a separate monotonic value. Older private
`2.0.<timestamp>` labels were not public releases; current source uses explicit
verified maintenance rather than a blind version overwrite.

## Verify and prepare from clean source

```sh
git status --short                       # Must be clean
swift test --disable-automatic-resolution
.build/debug/HearthApp --smoke-test
scripts/test-package.sh --fixture
scripts/prepare-release.sh --output-dir "$PWD/dist/hearth-1.2.0-reviewed-local"
```

The release script builds release binaries, checks the CLI version, makes only
normal setup/removal packages, validates them without installation, creates a
source archive from HEAD, and emits checksums and build information. It never
opens Installer, registers a service, changes power settings, uploads files, or
includes local repair approvals. Output:

```text
dist/hearth-1.2.0-reviewed-local/
  hearth-1.2.0-macos-<architecture>-local-setup.pkg
  hearth-1.2.0-macos-<architecture>-local-remove.pkg
  hearth-1.2.0-source.tar.gz
  BUILD-INFO.txt
  RELEASE-NOTES.md
  SHA256SUMS.txt
```

Inside the chosen directory, `shasum -a 256 -c SHA256SUMS.txt` verifies every intended
asset. `local` explicitly means unsigned/not notarized, not a trusted publisher
signature. Only the recorded native architecture is included.

Retain the accepted commit/package and keep its runtime evidence separate from
later source changes. Verify the final version, local document/image links and
exact diff. Inspect the rendered README and actual primary-menu screenshots;
Advanced-panel images are not substitutes. Capture-tool or workflow changes need
their relevant checks, not a documentation-only pass.

Run the final build and tests from a fresh local clone with pinned dependencies,
not just a warm worktree, before preparing artifacts from the clean commit in a
new directory. Compare packaged app, CLI, helper and maintenance code with the
accepted package. A rebuilt artifact or passing CI run is not another live install.
Prose-only edits may use focused documentation checks; any later installation
still requires approval and the exact `--package` path.

## Repeatability, not an unsupported bit-for-bit claim

Use the same clean commit, `Package.resolved`, Xcode/Swift, OS and architecture.
`SOURCE_DATE_EPOCH` defaults to the Git commit time and controls the package build
identifier. Source archives use `git archive` plus `gzip -n`. Release compilation
maps checkout paths to `/Hearth` rather than embedding personal checkout paths.
`BUILD-INFO.txt` records these inputs.

Apple's packaging/signing tools and different SDKs/architectures may still produce
different binary bytes. We do not claim cross-toolchain bit-for-bit reproduction.
For a source archive without Git, direct package builds default to current time
unless `SOURCE_DATE_EPOCH` is supplied.

## Hosted workflows

CI uses a documented macOS 15 runner image and explicitly selected Xcode 26.3;
pinned dependencies require Swift 6.2+. First-party actions are pinned to verified
commit SHAs. Tests and native/installer fixtures are unprivileged; no production
installer or live write runs in CI.

`Release` supports manual artifact preparation and an explicitly pushed semantic
version tag. Only a tag exactly equal to `v$(head -n 1 VERSION)` at the checked-out
commit can pass. Preparation has read-only repository permission; only the
separate publish job has `contents: write`. It downloads verified artifacts,
checks their checksums/versioned names, then creates the GitHub Release.
Manual dispatch never publishes. No internal/checkpoint tags are release triggers.

Hosted CI/release results must be checked after the repository is actually pushed;
local validation is not a claim that Actions has passed.
CI runs on `main` pushes, pull requests targeting `main`, or manual dispatch. A
feature-branch push alone does not run it; explicitly dispatch CI for that branch
or use a reviewed pull request before approving the release commit.

## Publication is a separate authorized step

Review files/history and ensure images contain sample Hearth-only content, no
tokens, personal desktops, state, credentials or repair fingerprints. Freeze all
writers, commit with the intended author/committer, and record the exact commit.
Verify repository authentication as `girishkvs` before any remote operation.

1.0.0 is already published as the single root commit
`2cf1d03d2b655b18942f649fea2f236a610263e8`. Do not rewrite that root or its
`v1.0.0` tag. The 1.2.0 development work is one feature commit on top. Published
commits and tags must not be amended; an authorized `main` update must fast-forward
to the approved descendant.
No remote write is implied by preparing local artifacts.

After separate explicit permission and approval of the release commit, push only
the approved branch/ref and intended tag. Verify CI for the new commit, not the
existing green 1.0.0 run. Manual Release dispatch can prepare artifacts without
publishing. Example final tag gate:

```sh
# Only after publication is authorized and the approved commit is on main:
git tag -a v1.2.0 -m "Hearth 1.2.0"
RELEASE_TAG=v1.2.0 scripts/prepare-release.sh --output-dir /absolute/new/release-dir
git -c push.followTags=false push origin refs/tags/v1.2.0:refs/tags/v1.2.0
```

Never push `--mirror`, `--all` or all tags from an app-managed repository: local
checkpoint refs and stashes are not publication material. Do not rewrite history
without permission. Pushing the exact release tag intentionally starts publication.

## Platform and installation gates

The 1.2.0 installed-product acceptance used candidate `4ff5f1a`, build
`1.2.0.20260909074248`, on Apple silicon/ARM64 with macOS 26.6.2 and Xcode
26.6/Swift 6.3.3. The approved GUI update matched its inventory/signatures/pins,
preserved pre-client state, and migrated schema 3 to 4. One installed
CLI-to-broker-to-native LockOn/RestoreLock cycle returned exit 0 for both actions
in 3.5848 seconds, restoring exact timer absence, full power and prior ownership
without Automation consent. Separate diagnostic observations established delayed
consumer adoption of zero and return to the engine default after restoration.
See [the release acceptance record](releases/1.2.0.md).

macOS 13 remains a deployment target, not a full validation matrix. This evidence
does not cover Intel, reboot, power-source switching, broad managed-policy cases,
sustained physical idle behavior or a 1.2.0 direct-TTY installation. Historical
1.0.0 GUI/Terminal evidence is recorded in its [release notes](releases/1.0.0.md).
Current installer/progress fixtures exercise the GUI/CLI argument, exit-status and
authentication boundary without performing another installation.

Independent state/privilege review, isolated migration and mixed-protocol tests,
actual unprivileged endpoint-transfer/peer-role coverage, fake CFPreferences/policy
coverage, sample-data screenshots and clean committed-source package proof support
the candidate. New payload entitlements remain empty; only verified installed
legacy app grants are accepted for maintenance. Uncertain and legacy saver intent
retains its recovery limits. Keep **Configured** wording and delayed-adoption
disclosure; no fixture or short cycle proves immediate OS protection.

Any further live update/test must follow the fresh preserve/restore sequence in
[migration](migration.md) under explicit approval. Release preparation does not
restart the installed app/helper/web, alter user state or justify weakening
Gatekeeper, SIP, signing or ownership checks.
