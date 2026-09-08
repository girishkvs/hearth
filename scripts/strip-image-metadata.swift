import Foundation

for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path)
    let png = try Data(contentsOf: url)
    guard png.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]) else {
        throw NSError(domain: "HearthDocs", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected PNG: \(path)"])
    }
    var output = Data(png.prefix(8))
    var offset = 8
    while offset + 12 <= png.count {
        let count = png[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
        let end = offset + 12 + count
        guard end <= png.count else { throw NSError(domain: "HearthDocs", code: 2) }
        let name = String(decoding: png[(offset + 4)..<(offset + 8)], as: UTF8.self)
        if ["IHDR", "PLTE", "IDAT", "IEND", "tRNS"].contains(name) {
            output.append(png[offset..<end])
        }
        offset = end
    }
    guard offset == png.count else { throw NSError(domain: "HearthDocs", code: 3) }
    try output.write(to: url, options: .atomic)
}
