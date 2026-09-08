# Releasing Hearth

## Version is a contract

`VERSION` is the single product-version source. Change it, run
`scripts/sync-version.sh`, and add matching `docs/releases/<version>.md` and
changelog entries. The checked-in Swift version is generated; `Package.swift`
fails before building if it drifts. App metadata and both package versions derive
from `VERSION`. Release asset names and tag gates use it too.

Product **1.0.0** is separate from the existing IPC, journal and authorization
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
scripts/prepare-release.sh
```

The release script builds release binaries, checks the CLI version, makes only
normal setup/removal packages, validates them without installation, creates a
source archive from HEAD, and emits checksums and build information. It never
opens Installer, registers a service, changes power settings, uploads files, or
includes local repair approvals. Output:

```text
dist/hearth-1.0.0-macos-<architecture>-local/
  hearth-1.0.0-macos-<architecture>-local-setup.pkg
  hearth-1.0.0-macos-<architecture>-local-remove.pkg
  hearth-1.0.0-source.tar.gz
  BUILD-INFO.txt
  RELEASE-NOTES.md
  SHA256SUMS.txt
```

Inside that directory, `shasum -a 256 -c SHA256SUMS.txt` verifies every intended
asset. `local` explicitly means unsigned/not notarized, not a trusted publisher
signature. Only the recorded native architecture is included.

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

## Publication is a separate authorized step

Review files/history and ensure images contain sample Hearth-only content, no
tokens, personal desktops, state, credentials or repair fingerprints. Freeze all
writers, commit with the intended author/committer, and record the exact commit.
Verify repository authentication as `girishkvs` before any remote operation.

After explicit permission, create the intended repository and push only the
approved branch and tag:

```sh
git -c push.followTags=false push origin HEAD:refs/heads/main
# After main CI succeeds and the release commit is approved:
git tag -a v1.0.0 -m "Hearth 1.0.0"
RELEASE_TAG=v1.0.0 scripts/prepare-release.sh --output-dir /absolute/new/release-dir
git -c push.followTags=false push origin refs/tags/v1.0.0:refs/tags/v1.0.0
```

Never push `--mirror`, `--all` or all tags from an app-managed repository: local
checkpoint refs and stashes are not publication material. Do not rewrite history
without permission. Pushing the exact release tag intentionally starts publication.

## Platform and installation gates

Local baseline evidence is Apple silicon/macOS 26.5.1 with Xcode 26.6/Swift 6.3.3.
macOS 13 is a deployment target, not a full live validation matrix. Intel, reboot,
physical idle behavior and root Terminal-install coverage must not be implied from
fake tests or a single machine.

Real GUI setup/helper activation and one reversible installed battery cycle were
tested with permission. One authorized Terminal update also reached native
`/usr/sbin/installer`; PackageKit completed it and the installed 1.0.0 inventory,
signatures, helper readiness, full power settings and active restore state were
verified. The test launcher piped output and its Terminal was closed before the
final report, so its process exit status was not captured.

That attempt exposed missing native architecture metadata and poor Terminal
feedback. After those fixes, the same corrected package completed both a GUI
update and one direct-TTY update. The latter's exit 0 was captured after the
command returned, and the user confirmed success and return to the shell prompt.
Each route preserved its own fresh full settings/raw restore state and passed the
complete installed inventory/signature/helper comparison.

The later compact progress formatter and first-launch conclusion resource have
unprivileged replay/resource coverage, not another live installation. Replays
exercise repeated phases, real fractional percentages, missing progress, errors,
interruption, EOF and the direct sudo input/authentication boundary without sudo.
Do not describe rebuilt artifacts as separately installed merely because the
application/helper code is unchanged. Installer refusal is a stop condition, not
permission to weaken Gatekeeper, SIP, signatures or ownership checks.
