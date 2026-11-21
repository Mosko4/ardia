import XCTest

@testable import ArdiaPluginCore

final class OfficialPluginsTests: XCTestCase {
  var root = ""
  var store: OfficialStore!
  var places: ProgramPlaces!

  override func setUpWithError() throws {
    let made = FileManager.default.temporaryDirectory.appendingPathComponent("official-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
    root = PluginSandbox.resolved(made.path)!
    store = OfficialStore(root: "\(root)/OfficialPlugins")
    places = ProgramPlaces(store: "\(root)/Programs", binDir: "\(root)/bin")
    places.shadowable = []
    OfficialVerification.recheckAfter = 0
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(atPath: root)
  }

  func tarHeader(_ name: String, type: UInt8, size: Int = 0, mode: Int = 0o644, link: String = "") -> [UInt8] {
    var header = [UInt8](repeating: 0, count: 512)
    func put(_ text: String, at offset: Int, _ length: Int) {
      for (index, byte) in text.utf8.prefix(length).enumerated() { header[offset + index] = byte }
    }
    put(name, at: 0, 100)
    put(String(format: "%07o", mode), at: 100, 8)
    put("0000000", at: 108, 8)
    put("0000000", at: 116, 8)
    put(String(format: "%011o", size), at: 124, 12)
    put("00000000000", at: 136, 12)
    put("        ", at: 148, 8)
    header[156] = type
    put(link, at: 157, 100)
    put("ustar", at: 257, 6)
    put("00", at: 263, 2)
    let sum = header.reduce(0) { $0 + Int($1) }
    put(String(format: "%06o", sum) + "\0 ", at: 148, 8)
    return header
  }

  func tar(_ entries: [(name: String, type: UInt8, body: Data, mode: Int, link: String)]) -> Data {
    var data = Data()
    for entry in entries {
      data.append(contentsOf: tarHeader(entry.name, type: entry.type, size: entry.body.count, mode: entry.mode, link: entry.link))
      data.append(entry.body)
      let pad = (512 - entry.body.count % 512) % 512
      data.append(Data(count: pad))
    }
    data.append(Data(count: 1024))
    return data
  }

  func gzip(_ data: Data, name: String) throws -> String {
    let raw = "\(root)/\(name).tar"
    try data.write(to: URL(fileURLWithPath: raw))
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    process.arguments = ["-n", "-f", raw]
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    return raw + ".gz"
  }

  func manifest(_ version: String = "1.2.0", claim: Bool = false) -> String {
    #"{"manifest":2,"name":"tool","version":"\#(version)","official":true,"contributes":{"programs":[{"name":"tool","path":"bin/tool"\#(claim ? #","claim":true"# : "")}]}}"#
  }

  func pluginArchive(_ manifestText: String, extra: [(name: String, type: UInt8, body: Data, mode: Int, link: String)] = [], tool: Data = Data("#!/bin/sh\necho hi\n".utf8)) throws -> String {
    let entries: [(name: String, type: UInt8, body: Data, mode: Int, link: String)] = [
      ("tool/", UInt8(ascii: "5"), Data(), 0o755, ""),
      ("tool/bin/", UInt8(ascii: "5"), Data(), 0o755, ""),
      ("tool/plugin.json", UInt8(ascii: "0"), Data(manifestText.utf8), 0o644, ""),
      ("tool/bin/tool", UInt8(ascii: "0"), tool, 0o755, ""),
    ] + extra
    return try gzip(tar(entries), name: "tool-\(UUID().uuidString)")
  }

  func entry(sha: String, reserved: [String] = []) -> OfficialPinEntry {
    OfficialPinEntry(name: "tool", version: "1.2.0", url: URL(string: "https://example.invalid/tool.tar.gz")!, sha256: sha, reservedPrograms: reserved, legacyInstall: nil)
  }

  func publish(_ archive: String, entry: OfficialPinEntry, registry: ProgramRegistry = .empty) -> Result<(copy: OfficialCopy, manifest: String), OfficialInstaller.Failure> {
    let scratch = store.makeScratch("tool", prefix: ".fetch-")!
    defer { PluginPrograms.discard(scratch) }
    let download = "\(scratch)/download.tar.gz"
    try? FileManager.default.copyItem(atPath: archive, toPath: download)
    return OfficialInstaller.verifyAndPublish(entry, archive: download, scratch: scratch, store: store, registry: registry)
  }

  func testThePinIsReadFromOfficialPluginsJsonAsIs() throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../apps/browser/official-plugins.json")
    let doc = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    let pin = try XCTUnwrap(OfficialPin.parse(doc))
    let cli = try XCTUnwrap(pin.entry("cli"))
    XCTAssertTrue(cli.url.absoluteString.hasPrefix("https://github.com/ardia-browser/plugins/releases/download/cli-v"))
    XCTAssertEqual(cli.url.lastPathComponent, cli.file)
    XCTAssertEqual(cli.folderId, "official-\(cli.sha256)")
    XCTAssertEqual((pin.registryDocument["claims"] as? [String: String])?["ardia"], "cli")
    let bare: [String: Any] = ["version": 1, "plugins": [["name": "x", "version": "1.0.0", "release": "https://example.invalid/r", "artifacts": ["macos-arm64": ["file": "x.tar.gz", "sha256": NSNull()]]]]]
    XCTAssertEqual(OfficialPin.parse(bare)?.entries, [], "an artifact not published yet can't be fetched")
    var http = bare
    http["plugins"] = [["name": "x", "version": "1.0.0", "release": "http://example.invalid/r", "artifacts": ["macos-arm64": ["file": "x.tar.gz", "sha256": String(repeating: "a", count: 64)]]]]
    XCTAssertNil(OfficialPin.parse(http), "only https")
    var clash = bare
    clash["plugins"] = ["a", "b"].map { ["name": $0, "version": "1.0.0", "release": "https://example.invalid/r", "reservedPrograms": ["same"], "artifacts": ["macos-arm64": ["file": "\($0).tar.gz", "sha256": String(repeating: "a", count: 64)]]] }
    XCTAssertNil(OfficialPin.parse(clash), "two plugins can't reserve one program")
  }

  func testAVerifiedDownloadIsPublishedByDigestAndStaysOutOfTheActiveCopyUntilPromoted() throws {
    let archive = try pluginArchive(manifest())
    let sha = try XCTUnwrap(OfficialArchive.sha256(file: archive))
    let made = try publish(archive, entry: entry(sha: sha)).get()
    XCTAssertEqual(made.copy.path, "\(root)/OfficialPlugins/tool/\(sha)")
    XCTAssertEqual(made.copy.payloadDigest, PluginPrograms.payloadDigest(made.copy.path))
    XCTAssertNil(store.active("tool"), "a candidate isn't active until the user confirms")
    XCTAssertFalse(OfficialStore.hasQuarantine("\(made.copy.path)/bin/tool"), "the copy isn't quarantined, so Gatekeeper never asks to notarize it")
    let approved = PluginFiles.approvalHash(text: made.manifest, folderId: made.copy.folderId)
    let pin = OfficialPin(entries: [entry(sha: sha)])
    XCTAssertEqual(OfficialInstaller.promote("tool", folderId: made.copy.folderId, approved: "0" + approved.dropFirst(), store: store, pin: pin), "It changed since you approved it. Try again.")
    XCTAssertNil(store.active("tool"))
    XCTAssertNil(OfficialInstaller.promote("tool", folderId: made.copy.folderId, approved: approved, store: store, pin: pin))
    XCTAssertEqual(store.active("tool"), made.copy)
    let again = try publish(archive, entry: entry(sha: sha)).get()
    XCTAssertEqual(again.copy, made.copy, "the same download is reused, not replaced")
  }

  func testTheOldReceiptPromotesOnlyTheSameManifest() throws {
    let archive = try pluginArchive(manifest())
    let sha = try XCTUnwrap(OfficialArchive.sha256(file: archive))
    let made = try publish(archive, entry: entry(sha: sha)).get()
    let old = PluginFiles.approvalHash(text: made.manifest, folderId: OfficialPin.legacyFolderId)
    let pin = OfficialPin(entries: [entry(sha: sha)])
    XCTAssertNotNil(OfficialInstaller.promote("tool", folderId: made.copy.folderId, approved: PluginFiles.approvalHash(text: manifest("1.1.0"), folderId: OfficialPin.legacyFolderId), store: store, pin: pin))
    XCTAssertNil(OfficialInstaller.promote("tool", folderId: made.copy.folderId, approved: old, store: store, pin: pin))
  }

  func testASha256MismatchIsRefusedAndLeavesNothing() throws {
    let archive = try pluginArchive(manifest())
    let result = publish(archive, entry: entry(sha: String(repeating: "0", count: 64)))
    guard case .failure(let failure) = result else { return XCTFail("a mismatch was published") }
    XCTAssertEqual(failure.code, "verify")
    XCTAssertTrue(failure.reason.contains("doesn't match"))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: "\(root)/OfficialPlugins/tool").filter { !$0.hasPrefix(".fetch-") && !$0.hasPrefix(".trash-") }, [])
  }

  func testLinksEscapesAndStrayTopsAreRefused() throws {
    let link = ("tool/bin/evil", UInt8(ascii: "2"), Data(), 0o755, "/etc/passwd")
    let hard = ("tool/bin/hard", UInt8(ascii: "1"), Data(), 0o755, "tool/bin/tool")
    let escape = ("tool/../escaped", UInt8(ascii: "0"), Data("x".utf8), 0o644, "")
    let stray = ("other/file", UInt8(ascii: "0"), Data("x".utf8), 0o644, "")
    let device = ("tool/dev", UInt8(ascii: "3"), Data(), 0o644, "")
    for bad in [link, hard, escape, stray, device] {
      let archive = try pluginArchive(manifest(), extra: [bad])
      let sha = try XCTUnwrap(OfficialArchive.sha256(file: archive))
      guard case .failure(let failure) = publish(archive, entry: entry(sha: sha)) else { return XCTFail("\(bad.0) was accepted") }
      XCTAssertEqual(failure.code, "verify", bad.0)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: "\(root)/OfficialPlugins/escaped"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: "\(root)/escaped"))
  }

  func testAManifestThatIsntThePinnedVersionOrClaimsAnotherNameIsRefused() throws {
    for (text, why) in [(manifest("9.9.9"), "version"), (manifest(claim: true), "claims")] {
      let archive = try pluginArchive(text)
      let sha = try XCTUnwrap(OfficialArchive.sha256(file: archive))
      guard case .failure(let failure) = publish(archive, entry: entry(sha: sha)) else { return XCTFail(why) }
      XCTAssertEqual(failure.code, "verify", why)
    }
    let archive = try pluginArchive(manifest(claim: true))
    let sha = try XCTUnwrap(OfficialArchive.sha256(file: archive))
    let registry = ProgramRegistry(claims: ["tool": "tool"], legacy: [], failClosed: false)
    XCTAssertNoThrow(try publish(archive, entry: entry(sha: sha, reserved: ["tool"]), registry: registry).get(), "a claim the pin and registry both give it is fine")
  }

  func adHocTrue() throws -> Data {
    let path = "\(root)/adhoc-true"
    try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: path)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    process.arguments = ["--force", "--sign", "-", path]
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    return try Data(contentsOf: URL(fileURLWithPath: path))
  }

  func testAnAdHocProgramFromThePinnedDownloadLinksAndRuns() throws {
    let archive = try pluginArchive(manifest(), tool: adHocTrue())
    let sha = try XCTUnwrap(OfficialArchive.sha256(file: archive))
    let made = try publish(archive, entry: entry(sha: sha)).get()
    let folder = try XCTUnwrap(PluginFiles.openFolder(made.copy.path))
    defer { folder.close() }
    let approved = PluginFiles.approvalHash(text: made.manifest, folderId: folder.id)
    let linked = try PluginPrograms.install(
      plugin: "tool", from: folder, approved: approved, version: "1.2.0", programs: [PluginProgram(name: "tool", path: "bin/tool")], places: places, expectedDigest: made.copy.payloadDigest
    ).get()
    XCTAssertEqual(linked.linked, ["tool"])
    let run = Process()
    run.executableURL = URL(fileURLWithPath: "\(places.binDir)/tool")
    try run.run()
    run.waitUntilExit()
    XCTAssertEqual(run.terminationStatus, 0, "trust comes from the pinned SHA-256, not a team signature")
    XCTAssertFalse(OfficialStore.hasQuarantine("\(places.store)/tool/current/bin/tool"))
  }

  func testAQuarantinedDownloadIsClearedOnlyAfterItsDigestMatches() throws {
    let archive = try pluginArchive(manifest())
    XCTAssertEqual(setxattr(archive, OfficialStore.quarantineName, "0081;0;Test;", 12, 0, XATTR_NOFOLLOW), 0)
    let sha = try XCTUnwrap(OfficialArchive.sha256(file: archive))
    guard case .failure = publish(archive, entry: entry(sha: String(repeating: "1", count: 64))) else { return XCTFail("a mismatch was published") }
    let made = try publish(archive, entry: entry(sha: sha)).get()
    XCTAssertFalse(OfficialStore.hasQuarantine("\(made.copy.path)/bin/tool"))
    XCTAssertFalse(OfficialStore.hasQuarantine("\(made.copy.path)/plugin.json"))
  }

  func testLinkingRefusesAProgramCopyThatIsntTheVerifiedDownload() throws {
    let archive = try pluginArchive(manifest())
    let sha = try XCTUnwrap(OfficialArchive.sha256(file: archive))
    let made = try publish(archive, entry: entry(sha: sha)).get()
    let folder = try XCTUnwrap(PluginFiles.openFolder(made.copy.path))
    defer { folder.close() }
    let approved = PluginFiles.approvalHash(text: made.manifest, folderId: folder.id)
    try "#!/bin/sh\necho swapped\n".write(toFile: "\(made.copy.path)/bin/tool", atomically: false, encoding: .utf8)
    guard case .failure(let refusal) = PluginPrograms.install(
      plugin: "tool", from: folder, approved: approved, version: "1.2.0", programs: [PluginProgram(name: "tool", path: "bin/tool")], places: places, expectedDigest: made.copy.payloadDigest)
    else { return XCTFail("linked a copy that isn't the verified download") }
    XCTAssertTrue(refusal.reason.contains("don't match"))
    XCTAssertNil(PluginPrograms.linkTarget("\(places.binDir)/tool"))
  }

  func makeFolder(_ version: String, say: String) throws -> OpenedFolder {
    let folder = "\(root)/src-\(version)"
    try FileManager.default.createDirectory(atPath: "\(folder)/bin", withIntermediateDirectories: true)
    try manifest(version).write(toFile: "\(folder)/plugin.json", atomically: true, encoding: .utf8)
    try "#!/bin/sh\necho \(say)\n".write(toFile: "\(folder)/bin/tool", atomically: true, encoding: .utf8)
    XCTAssertEqual(chmod("\(folder)/bin/tool", 0o755), 0)
    return try XCTUnwrap(PluginFiles.openFolder(folder))
  }

  func install(_ given: OpenedFolder, version: String, identity: String? = nil) throws -> ProgramsLinked {
    let folder = identity.map { OpenedFolder(fd: given.fd, path: given.path, id: $0) } ?? given
    guard case .text(let text) = PluginFiles.readManifest(in: folder) else { throw XCTSkip("no manifest") }
    return try PluginPrograms.install(
      plugin: "tool", from: folder, approved: PluginFiles.approvalHash(text: text, folderId: folder.id), version: version, programs: [PluginProgram(name: "tool", path: "bin/tool")],
      places: places
    ).get()
  }

  func testAReplacementThatCantTakeOverPATHLeavesTheOldTargetInPlaceAndARetryFinishesIt() throws {
    let old = try makeFolder("1.0.0", say: "old")
    defer { old.close() }
    let first = try install(old, version: "1.0.0")
    XCTAssertEqual(first.linked, ["tool"])
    let before = PluginPrograms.linkTarget("\(places.store)/tool/current")
    unlink("\(places.binDir)/tool")
    try "someone else's".write(toFile: "\(places.binDir)/tool", atomically: true, encoding: .utf8)
    let new = try makeFolder("2.0.0", say: "new")
    defer { new.close() }
    let held = try install(new, version: "2.0.0")
    XCTAssertEqual(held.linked, [])
    XCTAssertNotNil(held.refused["tool"])
    XCTAssertEqual(held.kept, before)
    XCTAssertEqual(PluginPrograms.linkTarget("\(places.store)/tool/current"), before, "current isn't switched while PATH refuses the new one")
    try FileManager.default.removeItem(atPath: "\(places.binDir)/tool")
    let retried = try install(new, version: "2.0.0")
    XCTAssertEqual(retried.linked, ["tool"])
    XCTAssertNotEqual(PluginPrograms.linkTarget("\(places.store)/tool/current"), before)
  }

  func testOnlyACopyMadeUnderTheOldIdentityCountsAsTheEarlierInstall() throws {
    let fetched = try makeFolder("0.5.0", say: "fetched")
    defer { fetched.close() }
    _ = try install(fetched, version: "0.5.0", identity: "official-\(String(repeating: "a", count: 64))")
    XCTAssertNil(PluginPrograms.legacyCopy(plugin: "tool", places: places), "a fetched program copy whose download failed verification isn't an earlier install")
  }

  func testTheOldCopyIsKeptLinkedInPlaceWithoutRestaging() throws {
    let old = try makeFolder("0.4.0", say: "old")
    defer { old.close() }
    _ = try install(old, version: "0.4.0", identity: OfficialPin.legacyFolderId)
    let version = try XCTUnwrap(PluginPrograms.linkTarget("\(places.store)/tool/current"))
    XCTAssertEqual(PluginPrograms.legacyCopy(plugin: "tool", places: places), "\(places.store)/tool/\(version)")
    unlink("\(places.binDir)/tool")
    let kept = try PluginPrograms.keepLegacy(plugin: "tool", programs: [PluginProgram(name: "tool", path: "bin/tool")], places: places).get()
    XCTAssertEqual(kept.linked, ["tool"])
    XCTAssertEqual(kept.kept, version)
    XCTAssertEqual(PluginPrograms.linkTarget("\(places.store)/tool/current"), version, "nothing restaged or switched")
    XCTAssertEqual(PluginPrograms.linkTarget("\(places.binDir)/tool"), "\(places.store)/tool/current/bin/tool")
    PluginPrograms.withdrawAllBut(["tool"], places: places)
    XCTAssertNotNil(PluginPrograms.linkTarget("\(places.binDir)/tool"), "the launch sweep keeps an owner it's told to keep")
  }

  func testRemovingWhileAnAfterUpdateCommandRunsTakesItOffPATHAndLeavesTheLeasedCopyUntilItEnds() throws {
    let old = try makeFolder("1.0.0", say: "old")
    defer { old.close() }
    let linked = try install(old, version: "1.0.0")
    let lease = try XCTUnwrap(PluginPrograms.lease(plugin: "tool", version: linked.version, places: places))
    XCTAssertFalse(PluginPrograms.remove(plugin: "tool", programs: ["tool"], places: places), "a running command keeps its copy")
    XCTAssertNil(PluginPrograms.linkTarget("\(places.binDir)/tool"))
    XCTAssertNil(PluginPrograms.linkTarget("\(places.store)/tool/current"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: "\(places.store)/tool/\(linked.version)"))
    unlink(lease)
    XCTAssertTrue(PluginPrograms.remove(plugin: "tool", programs: ["tool"], places: places))
    XCTAssertFalse(FileManager.default.fileExists(atPath: "\(places.store)/tool"))
  }

  func testAnInterruptedPublishLeavesNoHalfCopyAndTheNextOneFinishes() throws {
    let archive = try pluginArchive(manifest())
    let sha = try XCTUnwrap(OfficialArchive.sha256(file: archive))
    try FileManager.default.createDirectory(atPath: "\(root)/OfficialPlugins/tool/\(sha)", withIntermediateDirectories: true)
    XCTAssertNil(store.copy("tool", sha: sha), "a folder without its download is a crash between files, not a copy")
    let orphan = String(repeating: "c", count: 64)
    try Data("x".utf8).write(to: URL(fileURLWithPath: "\(root)/OfficialPlugins/tool/\(orphan).tar.gz"))
    store.sweep("tool", keeping: [sha])
    XCTAssertFalse(FileManager.default.fileExists(atPath: "\(root)/OfficialPlugins/tool/\(orphan).tar.gz"), "a download whose folder never arrived is dropped")
    XCTAssertFalse(FileManager.default.fileExists(atPath: "\(root)/OfficialPlugins/tool/\(sha)"), "a folder with no download is dropped")
    let made = try publish(archive, entry: entry(sha: sha)).get()
    XCTAssertEqual(store.copy("tool", sha: sha), made.copy)
    XCTAssertTrue(FileManager.default.fileExists(atPath: "\(made.copy.path)/plugin.json"))
    XCTAssertTrue(store.activate("tool", sha: sha))
    XCTAssertTrue(store.remove("tool"))
    XCTAssertNil(store.active("tool"))
  }

  func testACopyThatNoLongerMatchesItsPinnedDownloadIsNotOfficial() throws {
    let archive = try pluginArchive(manifest())
    let sha = try XCTUnwrap(OfficialArchive.sha256(file: archive))
    let made = try publish(archive, entry: entry(sha: sha)).get()
    try "#!/bin/sh\necho swapped\n".write(toFile: "\(made.copy.path)/bin/tool", atomically: false, encoding: .utf8)
    let approved = PluginFiles.approvalHash(text: made.manifest, folderId: made.copy.folderId)
    XCTAssertNil(store.copy("tool", sha: sha), "an edit inside a copy already checked this launch is still noticed")
    XCTAssertNotNil(OfficialInstaller.promote("tool", folderId: made.copy.folderId, approved: approved, store: store, pin: OfficialPin(entries: [entry(sha: sha)])), "promotion re-verifies against the download")
    let other = try pluginArchive(manifest("1.2.0"), tool: Data("#!/bin/sh\necho other\n".utf8))
    try FileManager.default.removeItem(atPath: "\(root)/OfficialPlugins/tool/\(sha).tar.gz")
    try FileManager.default.copyItem(atPath: other, toPath: "\(root)/OfficialPlugins/tool/\(sha).tar.gz")
    OfficialVerification.shared.forget()
    XCTAssertNil(store.copy("tool", sha: sha), "a download that isn't the pinned SHA-256 vouches for nothing")
  }

  func testAnEarlierCopyIsntTakenForADamagedNewOne() throws {
    let old = try makeFolder("0.4.0", say: "old")
    defer { old.close() }
    _ = try install(old, version: "0.4.0", identity: OfficialPin.legacyFolderId)
    XCTAssertFalse(PluginPrograms.currentIsDamaged(plugin: "tool", places: places, version: "0.5.0", approved: String(repeating: "b", count: 64), digest: String(repeating: "c", count: 64)), "a failed update leaves the earlier copy's ardia on PATH")
    let version = try XCTUnwrap(PluginPrograms.linkTarget("\(places.store)/tool/current"))
    try "#!/bin/sh\necho swapped\n".write(toFile: "\(places.store)/tool/\(version)/bin/tool", atomically: false, encoding: .utf8)
    guard case .text(let text) = PluginFiles.readManifest(in: OpenedFolder(fd: old.fd, path: old.path, id: OfficialPin.legacyFolderId)) else { return XCTFail("no manifest") }
    XCTAssertTrue(PluginPrograms.currentIsDamaged(plugin: "tool", places: places, version: "0.4.0", approved: PluginFiles.approvalHash(text: text, folderId: OfficialPin.legacyFolderId), digest: String(repeating: "c", count: 64)))
  }

  func testTurningAnOfficialPluginOffKeepsItsCopySoItCanTurnBackOn() throws {
    let old = try makeFolder("0.4.0", say: "old")
    defer { old.close() }
    _ = try install(old, version: "0.4.0", identity: OfficialPin.legacyFolderId)
    let version = try XCTUnwrap(PluginPrograms.linkTarget("\(places.store)/tool/current"))
    PluginPrograms.withdraw(plugin: "tool", programs: ["tool"], places: places, keepCopy: true)
    XCTAssertNil(PluginPrograms.linkTarget("\(places.binDir)/tool"), "off takes it off PATH")
    XCTAssertEqual(PluginPrograms.linkTarget("\(places.store)/tool/current"), version, "but keeps the copy an earlier Ardia made")
    PluginPrograms.withdrawAllBut([], places: places, keepingCopies: ["tool"])
    XCTAssertEqual(PluginPrograms.legacyCopy(plugin: "tool", places: places), "\(places.store)/tool/\(version)", "the launch sweep keeps it too")
    let back = try PluginPrograms.keepLegacy(plugin: "tool", programs: [PluginProgram(name: "tool", path: "bin/tool")], places: places).get()
    XCTAssertEqual(back.linked, ["tool"])
  }

  func testNamesOutsideTheDigestAreRefusedAndPlantedOnesBreakTheMatch() throws {
    for bad in [("tool/__pycache__/x.pyc", UInt8(ascii: "0"), Data("x".utf8), 0o644, ""), ("tool/.leases/1", UInt8(ascii: "0"), Data(), 0o644, "")] {
      let archive = try pluginArchive(manifest(), extra: [bad])
      let sha = try XCTUnwrap(OfficialArchive.sha256(file: archive))
      guard case .failure(let failure) = publish(archive, entry: entry(sha: sha)) else { return XCTFail("\(bad.0) was accepted") }
      XCTAssertEqual(failure.code, "verify")
    }
    let archive = try pluginArchive(manifest())
    let sha = try XCTUnwrap(OfficialArchive.sha256(file: archive))
    let made = try publish(archive, entry: entry(sha: sha)).get()
    try FileManager.default.createDirectory(atPath: "\(made.copy.path)/bin/__pycache__", withIntermediateDirectories: true)
    try "x".write(toFile: "\(made.copy.path)/bin/__pycache__/planted.pyc", atomically: true, encoding: .utf8)
    XCTAssertNil(store.copy("tool", sha: sha), "a planted cache file isn't skipped by an official copy's digest")
  }

  func testAnUnpinnedActiveCopyIsntApprovedByTheOldReceiptAndADamagedOneCanBeRepaired() throws {
    let archive = try pluginArchive(manifest())
    let sha = try XCTUnwrap(OfficialArchive.sha256(file: archive))
    let made = try publish(archive, entry: entry(sha: sha)).get()
    XCTAssertTrue(store.activate("tool", sha: sha))
    let newer = OfficialPin(entries: [entry(sha: String(repeating: "e", count: 64))])
    let oldReceipt = PluginFiles.approvalHash(text: made.manifest, folderId: OfficialPin.legacyFolderId)
    XCTAssertNotNil(OfficialInstaller.promote("tool", folderId: made.copy.folderId, approved: oldReceipt, store: store, pin: newer), "the old receipt vouches only for the pinned bytes")
    XCTAssertNil(OfficialInstaller.promote("tool", folderId: made.copy.folderId, approved: PluginFiles.approvalHash(text: made.manifest, folderId: made.copy.folderId), store: store, pin: newer), "its own exact approval still holds")
    try "#!/bin/sh\necho damaged\n".write(toFile: "\(made.copy.path)/bin/tool", atomically: false, encoding: .utf8)
    XCTAssertNil(store.active("tool"))
    let repaired = try publish(archive, entry: entry(sha: sha)).get()
    XCTAssertEqual(store.active("tool"), repaired.copy, "a clean download of the same pinned file replaces a damaged active copy")
  }

  func testAFailedFreshCheckClearsTheRecentCheck() throws {
    OfficialVerification.recheckAfter = 30
    defer { OfficialVerification.recheckAfter = 0 }
    let archive = try pluginArchive(manifest())
    let sha = try XCTUnwrap(OfficialArchive.sha256(file: archive))
    let made = try publish(archive, entry: entry(sha: sha)).get()
    XCTAssertNotNil(store.copy("tool", sha: sha))
    try "#!/bin/sh\necho swapped\n".write(toFile: "\(made.copy.path)/bin/tool", atomically: false, encoding: .utf8)
    XCTAssertNil(store.copy("tool", sha: sha, fresh: true))
    XCTAssertNil(store.copy("tool", sha: sha), "a mismatch found by a fresh check isn't hidden by the recent good one")
  }

  func testAQuarantinedArchiveIsClearedToo() throws {
    let archive = try pluginArchive(manifest())
    XCTAssertEqual(setxattr(archive, OfficialStore.quarantineName, "0081;0;Test;", 12, 0, XATTR_NOFOLLOW), 0)
    let sha = try XCTUnwrap(OfficialArchive.sha256(file: archive))
    _ = try publish(archive, entry: entry(sha: sha)).get()
    XCTAssertFalse(OfficialStore.hasQuarantine(store.archivePath("tool", sha)))
  }

  func testAnArchivePackedLikeBuildShUnpacks() throws {
    let work = "\(root)/pack"
    let deep = "tool/" + Array(repeating: "a-rather-long-folder-name", count: 6).joined(separator: "/")
    try FileManager.default.createDirectory(atPath: "\(work)/\(deep)", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: "\(work)/tool/bin", withIntermediateDirectories: true)
    try manifest().write(toFile: "\(work)/tool/plugin.json", atomically: true, encoding: .utf8)
    try "#!/bin/sh\n".write(toFile: "\(work)/tool/bin/tool", atomically: true, encoding: .utf8)
    try "deep".write(toFile: "\(work)/\(deep)/file-with-a-long-name-too.txt", atomically: true, encoding: .utf8)
    XCTAssertEqual(chmod("\(work)/tool/bin/tool", 0o755), 0)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    process.currentDirectoryURL = URL(fileURLWithPath: work)
    process.environment = ["COPYFILE_DISABLE": "1"]
    process.arguments = ["--no-mac-metadata", "-czf", "\(root)/packed.tar.gz", "tool"]
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    let sha = try XCTUnwrap(OfficialArchive.sha256(file: "\(root)/packed.tar.gz"))
    let made = try publish("\(root)/packed.tar.gz", entry: entry(sha: sha)).get()
    XCTAssertEqual(try String(contentsOfFile: "\(made.copy.path)/\(String(deep.dropFirst(5)))/file-with-a-long-name-too.txt", encoding: .utf8), "deep")
    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: "\(made.copy.path)/bin/tool"))
  }

  func testGzipAndTarReadersRefuseDamage() throws {
    let archive = try pluginArchive(manifest())
    var bytes = try Data(contentsOf: URL(fileURLWithPath: archive))
    bytes[bytes.count / 2] ^= 0xff
    let damaged = "\(root)/damaged.tar.gz"
    try bytes.write(to: URL(fileURLWithPath: damaged))
    let stage = "\(root)/stage-damaged"
    XCTAssertEqual(mkdir(stage, 0o700), 0)
    XCTAssertNotNil(OfficialArchive.unpack(damaged, top: "tool", into: stage, scratch: root))
    try Data("not gzip".utf8).write(to: URL(fileURLWithPath: "\(root)/plain.tar.gz"))
    let other = "\(root)/stage-plain"
    XCTAssertEqual(mkdir(other, 0o700), 0)
    XCTAssertEqual(OfficialArchive.unpack("\(root)/plain.tar.gz", top: "tool", into: other, scratch: root), "the download isn't a gzip file")
  }
}
