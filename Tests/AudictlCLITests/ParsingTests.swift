import ArgumentParser
import Testing
@testable import audictl

/// Parse-only tests: commands are constructed from argv but never run().
@Suite struct ParsingTests {
    private func parses(_ args: [String]) -> Bool {
        (try? Audictl.parseAsRoot(args)) != nil
    }

    @Test func coreCommandsParse() {
        #expect(parses(["list"]))
        #expect(parses(["list", "--input", "--json"]))
        #expect(parses(["info", "Scarlett 2i2", "--by-name"]))
        #expect(parses(["default", "get", "output"]))
        #expect(parses(["default", "set", "input", "Scarlett", "--json"]))
        #expect(parses(["volume", "get", "speakers"]))
        #expect(parses(["volume", "set", "speakers", "50", "--scope", "output", "--channel", "1"]))
        #expect(parses(["mute", "toggle", "speakers", "--quiet"]))
        #expect(parses(["rate", "set", "Scarlett", "44.1k", "--timeout", "10"]))
    }

    @Test func aggregateCommandsParse() {
        #expect(parses(["aggregate"]))  // defaults to show-all
        #expect(parses(["aggregate", "show"]))
        #expect(parses(["aggregate", "show", "Rig", "--by-name"]))
        #expect(parses(["aggregate", "create", "--name", "Rig", "--devices", "a,b",
                        "--clock", "a", "--drift", "all", "--private", "--uid", "custom"]))
        #expect(parses(["aggregate", "destroy", "Rig", "--if-exists"]))
        #expect(parses(["aggregate", "add", "Rig", "mic", "--drift"]))
        #expect(parses(["aggregate", "remove", "Rig", "mic", "--if-absent-ok"]))
        #expect(parses(["aggregate", "set-clock", "Rig", "mic"]))
        #expect(parses(["aggregate", "drift", "Rig", "mic", "on"]))
        #expect(parses(["multi", "create", "--name", "Everywhere", "--devices", "a,b", "--primary", "a"]))
        #expect(parses(["multi", "destroy", "Everywhere", "--if-exists"]))
    }

    @Test func invalidInvocationsRejected() {
        #expect(!parses(["default", "get", "sideways"]))
        #expect(!parses(["aggregate", "drift", "Rig", "mic", "maybe"]))
        #expect(!parses(["aggregate", "create", "--devices", "a,b"]))  // missing --name
        #expect(!parses(["info"]))  // missing device
        #expect(!parses(["info", "x", "--by-uid", "--by-id"]))  // exclusive flags
    }

    @Test func valueParsers() throws {
        #expect(try parseVolumeValue("50") == 0.5)
        #expect(try parseVolumeValue("0.5") == 0.5)
        #expect(try parseVolumeValue("100") == 1.0)
        #expect(try parseVolumeValue("1.0") == 1.0)
        #expect(throws: (any Error).self) { try parseVolumeValue("101") }
        #expect(throws: (any Error).self) { try parseVolumeValue("1.5") }
        #expect(throws: (any Error).self) { try parseVolumeValue("loud") }

        #expect(try parseRateValue("48000") == 48000)
        #expect(try parseRateValue("44.1k") == 44100)
        #expect(try parseRateValue("96kHz") == 96000)
        #expect(try parseRateValue("48000hz") == 48000)
        #expect(throws: (any Error).self) { try parseRateValue("fast") }
        #expect(throws: (any Error).self) { try parseRateValue("-1") }
    }
}
