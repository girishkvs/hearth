import Foundation

extension InstallerTests {
    func testScriptOnlyReceipts() throws {
        let (target, host) = try fixture("optional-apple-receipts")
        try payload(target)
        let ownReceipt = try Data(contentsOf: URL(fileURLWithPath: target.path(target.receipt)))
        try assert(target.preflight() != nil, "verified Hearth manifest permits absent scripts-only Apple receipts")
        try files.removeItem(atPath: target.path(target.receipt))
        try refused("absent Apple receipts never authorize an unowned installation") { _ = try target.preflight() }
        try write(Data("damaged".utf8), target.path(target.receipt))
        try refused("absent Apple receipts never bypass a damaged Hearth manifest") { _ = try target.preflight() }
        try write(ownReceipt, target.path(target.receipt))
        host.badSignature = true
        try refused("absent Apple receipts never bypass code signature checks") { _ = try target.preflight() }
        host.badSignature = false

        try appleReceipt(target)
        let apple = "/private/var/db/receipts/\(target.packageID)"
        let applePlist = try Data(contentsOf: URL(fileURLWithPath: target.path(apple + ".plist")))
        try assert(target.preflight() != nil, "matching optional Apple receipts remain accepted")
        try files.removeItem(atPath: target.path(apple + ".plist"))
        try refused("orphaned Apple BOM is not treated as absent receipts") { _ = try target.preflight() }
        try write(applePlist, target.path(apple + ".plist"))
        try files.removeItem(atPath: target.path(apple + ".bom"))
        try assert(target.preflight() != nil, "optional Apple plist does not require a filesystem BOM")
        let foreign = try PropertyListSerialization.data(
            fromPropertyList: ["PackageIdentifier": "unrelated.product"], format: .xml, options: 0)
        try write(foreign, target.path(apple + ".plist"))
        try refused("present Apple receipt must match Hearth identifier") { _ = try target.preflight() }
        try write(applePlist, target.path(apple + ".plist"))
        host.wrongOwners.insert(target.path(apple + ".plist"))
        try refused("present Apple receipt must retain trusted ownership") { _ = try target.preflight() }
        host.wrongOwners.removeAll()
        try files.moveItem(atPath: target.path(apple + ".plist"), toPath: target.path(apple + ".saved"))
        try files.createSymbolicLink(atPath: target.path(apple + ".plist"), withDestinationPath: target.path(apple + ".saved"))
        try refused("present Apple receipt cannot be a symlink") { _ = try target.preflight() }

        let (source, _) = try fixture("receiptless-source")
        try payload(source)
        let extraction = try extractionFor(source, name: "receiptless-package")
        let (fresh, freshHost) = try fixture("receiptless-lifecycle")
        let maintenance = Maintenance(validator: fresh, extraction: extraction)
        try maintenance.run("setup-preflight")
        try maintenance.run("setup-postflight")
        try assert(fresh.preflight() != nil, "initial scripts-only setup remains owned without Apple receipts")
        try maintenance.run("setup-preflight")
        try maintenance.run("setup-postflight")
        try assert(freshHost.registered, "explicit update succeeds using full Hearth manifest and signatures")
        try maintenance.run("remove-preflight")
        try maintenance.run("remove-postflight")
        try assert(try fresh.metadata(fresh.app) == nil && !freshHost.registered,
                   "explicit receiptless removal deletes only verified Hearth artifacts")
        try assert(!freshHost.commands.contains { $0.0 == "/usr/sbin/pkgutil" && $0.1.first == "--forget" },
                   "removal never calls pkgutil forget for an absent Apple receipt")
        try assert(try fresh.metadata(maintenance.lock) != nil, "receiptless removal preserves the permanent operation lock")
    }
}
