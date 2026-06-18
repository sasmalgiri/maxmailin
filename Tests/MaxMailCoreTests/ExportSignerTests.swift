import XCTest
import CryptoKit
@testable import MaxMailCore

final class ExportSignerTests: XCTestCase {

    private func freshSecret() -> Data {
        Data(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    private func makeBundle(with files: [(String, Data)]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("exp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, data) in files {
            try data.write(to: dir.appendingPathComponent(name))
        }
        return dir
    }

    func testSealedManifestVerifies() async throws {
        let dir = try makeBundle(with: [
            ("a.eml", Data("alpha email".utf8)),
            ("b.eml", Data("beta email body".utf8))
        ])
        let signer = ExportSigner(secret: freshSecret())
        let result = try await signer.seal(
            actor: "examiner",
            bundleName: "test-bundle",
            files: [
                .init(relativePath: "a.eml", url: dir.appendingPathComponent("a.eml")),
                .init(relativePath: "b.eml", url: dir.appendingPathComponent("b.eml"))
            ]
        )
        let ok = await signer.verifySignature(
            manifestJSON: result.manifestJSON,
            signatureHex: result.signatureHex
        )
        XCTAssertTrue(ok)
    }

    func testTamperedFileShowsUpInContentVerification() async throws {
        let dir = try makeBundle(with: [
            ("a.eml", Data("original".utf8)),
            ("b.eml", Data("also original".utf8))
        ])
        let signer = ExportSigner(secret: freshSecret())
        let result = try await signer.seal(
            actor: "examiner", bundleName: "b",
            files: [
                .init(relativePath: "a.eml", url: dir.appendingPathComponent("a.eml")),
                .init(relativePath: "b.eml", url: dir.appendingPathComponent("b.eml"))
            ]
        )
        // Tamper with one of the files.
        try Data("modified".utf8).write(to: dir.appendingPathComponent("a.eml"))

        let manifest = try JSONDecoder.iso8601().decode(
            ExportManifest.self, from: result.manifestJSON
        )
        let drifted = try await signer.verifyContents(
            manifest: manifest, bundleRoot: dir
        )
        XCTAssertEqual(drifted, ["a.eml"])
    }

    func testWrongSecretFailsSignatureVerification() async throws {
        let dir = try makeBundle(with: [("x.eml", Data("x".utf8))])
        let signer1 = ExportSigner(secret: freshSecret())
        let r = try await signer1.seal(
            actor: "a", bundleName: "b",
            files: [.init(relativePath: "x.eml", url: dir.appendingPathComponent("x.eml"))]
        )
        let attacker = ExportSigner(secret: freshSecret())
        let ok = await attacker.verifySignature(
            manifestJSON: r.manifestJSON,
            signatureHex: r.signatureHex
        )
        XCTAssertFalse(ok)
    }

    func testHashFileMatchesOpenSSLForKnownInput() throws {
        // SHA-256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
        let dir = try makeBundle(with: [("abc.bin", Data("abc".utf8))])
        let (size, hex) = try ExportSigner.hashFile(dir.appendingPathComponent("abc.bin"))
        XCTAssertEqual(size, 3)
        XCTAssertEqual(hex, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

private extension JSONDecoder {
    static func iso8601() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
