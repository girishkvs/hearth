# Third-party notices

Hearth is MIT licensed; see [LICENSE](../LICENSE).

The only direct Swift package dependency is [SwiftNIO](https://github.com/apple/swift-nio).
`Package.resolved` pins it and its Swift Atomics, Swift Collections, and Swift System
dependencies. Their own licenses and notices apply independently.

The packaging scripts copy dependency `LICENSE.txt` and available `NOTICE.txt`
files from the resolved checkouts into
`Hearth.app/Contents/Resources/ThirdPartyLicenses/`, and include SwiftNIO's privacy
resource. The project's exact MIT license is separate in the bundle and Installer's
native License step. No dependency license is presented as Hearth's license.
