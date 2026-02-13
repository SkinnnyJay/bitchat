import XCTest
@testable import bitchat

final class CommandProcessorTests: XCTestCase {
    
    var identityManager: MockIdentityManager!
    
    override func setUp() {
        super.setUp()
        // Provide a minimal identity manager for commands that query identity/block lists
        identityManager = MockIdentityManager(MockKeychain())
    }
    
    override func tearDown() {
        identityManager = nil
        super.tearDown()
    }

    @MainActor
    func test_slap_notFoundGrammar() {
        let processor = CommandProcessor(chatViewModel: nil, meshService: nil, identityManager: identityManager)
        let result = processor.process("/slap @system")
        switch result {
        case .error(let message):
            XCTAssertEqual(message, "cannot slap system: not found")
        default:
            XCTFail("Expected error result")
        }
    }

    @MainActor
    func test_hug_notFoundGrammar() {
        let processor = CommandProcessor(chatViewModel: nil, meshService: nil, identityManager: identityManager)
        let result = processor.process("/hug @system")
        switch result {
        case .error(let message):
            XCTAssertEqual(message, "cannot hug system: not found")
        default:
            XCTFail("Expected error result")
        }
    }

    @MainActor
    func test_slap_usageMessage() {
        let processor = CommandProcessor(chatViewModel: nil, meshService: nil, identityManager: identityManager)
        let result = processor.process("/slap")
        switch result {
        case .error(let message):
            XCTAssertEqual(message, "usage: /slap <nickname>")
        default:
            XCTFail("Expected error result for usage message")
        }
    }

    func testResolveFavoriteNoisePublicKeySupportsPrefixedFullNoisePeerID() {
        let fullNoise = String(repeating: "ab", count: 32)

        let resolved = CommandProcessor.resolveFavoriteNoisePublicKey(
            from: "noise:\(fullNoise)",
            fallbackNoiseKey: nil
        )

        XCTAssertEqual(resolved?.hexEncodedString(), fullNoise)
    }

    func testResolveFavoriteNoisePublicKeySupportsMeshPrefixedFullNoisePeerID() {
        let fullNoise = String(repeating: "cd", count: 32)

        let resolved = CommandProcessor.resolveFavoriteNoisePublicKey(
            from: "  mesh:\(fullNoise)  ",
            fallbackNoiseKey: nil
        )

        XCTAssertEqual(resolved?.hexEncodedString(), fullNoise)
    }

    func testResolveFavoriteNoisePublicKeyUsesFallbackForShortPeerID() {
        let fallbackNoise = Data(repeating: 0x11, count: 32)

        let resolved = CommandProcessor.resolveFavoriteNoisePublicKey(
            from: "abcdef0123456789",
            fallbackNoiseKey: fallbackNoise
        )

        XCTAssertEqual(resolved, fallbackNoise)
    }

    func testResolveFavoriteNoisePublicKeyRejectsInvalidFallbackLength() {
        let invalidFallback = Data(repeating: 0x11, count: 8)

        let resolved = CommandProcessor.resolveFavoriteNoisePublicKey(
            from: "abcdef0123456789",
            fallbackNoiseKey: invalidFallback
        )

        XCTAssertNil(resolved)
    }

    func testFavoriteNicknameForPersistenceKeepsValidNickname() {
        XCTAssertEqual(CommandProcessor.favoriteNicknameForPersistence("alice"), "alice")
    }

    func testFavoriteNicknameForPersistenceFallsBackToUserForInvalidInput() {
        XCTAssertEqual(CommandProcessor.favoriteNicknameForPersistence("   "), "user")
    }

    func testSanitizedNicknameForIdentityKeepsValidNickname() {
        XCTAssertEqual(CommandProcessor.sanitizedNicknameForIdentity("alice"), "alice")
    }

    func testSanitizedNicknameForIdentityFallsBackToUserForInvalidInput() {
        XCTAssertEqual(CommandProcessor.sanitizedNicknameForIdentity("   "), "user")
    }

    func testCanonicalNostrBlockKeyAcceptsHexAndLowercases() {
        let uppercaseHex = String(repeating: "AB", count: 32)

        let canonical = CommandProcessor.canonicalNostrBlockKey(uppercaseHex)

        XCTAssertEqual(canonical, String(repeating: "ab", count: 32))
    }

    func testCanonicalNostrBlockKeyRejectsInvalidValues() {
        XCTAssertNil(CommandProcessor.canonicalNostrBlockKey("abc"))
        XCTAssertNil(CommandProcessor.canonicalNostrBlockKey(String(repeating: "zz", count: 32)))
    }
}
