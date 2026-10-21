import Foundation
import Testing

@testable import WorkbenchCore

private let tools = "\n[tools]\navailable = [\"Read\"]\n"

@Suite struct ConfigEditorTests {
    @Test func theProjectKeyTakesAKnownNameOrOnePlainCommand() throws {
        #expect(try Config.parse(tools).editor == nil)
        #expect(try Config.parse("editor = \"cursor\"" + tools).editor == "cursor")
        #expect(try Config.parse("editor = \"/opt/bin/ed --wait\"" + tools).editor == "/opt/bin/ed --wait")
    }

    @Test func aBadProjectValueIsAConfigErrorNamingTheKey() {
        for bad in ["code && rm -rf x", "ed $(id)", "", "bin/ed", "-n"] {
            #expect {
                try Config.parse("editor = \"\(bad)\"" + tools)
            } throws: { error in
                let problems = (error as? ConfigError)?.problems ?? []
                return problems.count == 1 && problems[0].code == .invalidValue && problems[0].line == 1
                    && problems[0].message.hasPrefix("'editor' ")
            }
        }
        #expect(throws: ConfigError.self) { try Config.parse("editor = 3" + tools) }
    }

    @Test func theEditorNeverReachesWhatARunGets() throws {
        let config = try Config.parse("editor = \"zed\"" + tools)
        #expect(!config.effectiveAllowedTools.contains { $0.contains("zed") })
    }

    @Test func theGlobalKeyIsAllowedAndValidated() throws {
        #expect(GlobalConfig.allowedKeys.contains("editor"))
        #expect(try GlobalConfig.parse("editor = \"zed\"\n").editor == "zed")
        #expect(try GlobalConfig.parse("editor = \"subl -n\"\nmodel = \"haiku\"\n").editor == "subl -n")
        #expect {
            try GlobalConfig.parse("editor = \"code; evil\"\n")
        } throws: { error in
            let problems = (error as? ConfigError)?.problems ?? []
            return problems.count == 1 && problems[0].message.hasPrefix("'editor' ")
        }
    }

    @Test func anUnknownGlobalKeyListsEditorAmongTheAllowed() {
        #expect {
            try GlobalConfig.parse("check_command = \"x\"\n")
        } throws: { error in
            "\(error)".contains("allowed: claude_path, editor, model, projects_dir")
        }
    }
}
