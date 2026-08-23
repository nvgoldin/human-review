import Foundation
import Testing

@Suite("config subcommand")
struct ConfigCommandTests {

    let cli = ReviewCLIFixture()

    @Test func testSetThenGetRoundTripsThroughTheGlobalFile() {
        #expect(cli.run(["config", "--global", "global.prompt", "be terse"]).exitCode == 0)

        let result = cli.run(["config", "global.prompt"])

        #expect(result.exitCode == 0, "\(result.standardError)")
        #expect(result.standardOutput == "be terse\n")
    }

    @Test func testWritesDefaultToTheGlobalScope() {
        cli.run(["config", "global.prompt", "be terse"])

        #expect(FileManager.default.fileExists(atPath: cli.globalConfigPath))
        #expect(cli.fileExists(".human-review.config") == false)
    }

    @Test func testALocalWriteCreatesTheConfigFileInTheWorkingDirectory() {
        #expect(cli.run(["config", "--local", "global.prompt", "local text"]).exitCode == 0)

        #expect(cli.fileExists(".human-review.config"))
        #expect(cli.contentsOfFile(".human-review.config").contains("local text"))
    }

    @Test func testALocalValueOverridesTheGlobalValue() {
        cli.run(["config", "--global", "global.prompt", "from global"])
        cli.run(["config", "--local", "global.prompt", "from local"])

        #expect(cli.run(["config", "global.prompt"]).standardOutput == "from local\n")
        #expect(cli.run(["config", "--global", "global.prompt"]).standardOutput == "from global\n")
        #expect(cli.run(["config", "--local", "global.prompt"]).standardOutput == "from local\n")
    }

    @Test func testGettingAnUnsetKeyPrintsNothingAndExitsWithOne() {
        let result = cli.run(["config", "global.prompt"])

        #expect(result.exitCode == 1)
        #expect(result.standardOutput == "")
    }

    @Test func testUnsetRemovesTheKeyAndExitsWithOneWhenItWasAbsent() {
        cli.run(["config", "--global", "global.prompt", "be terse"])

        #expect(cli.run(["config", "--global", "--unset", "global.prompt"]).exitCode == 0)
        #expect(cli.run(["config", "global.prompt"]).exitCode == 1)
        #expect(cli.run(["config", "--global", "--unset", "global.prompt"]).exitCode == 1)
    }

    @Test func testUnsetOnTheLocalScopeLeavesTheGlobalValueInPlace() {
        cli.run(["config", "--global", "global.prompt", "from global"])
        cli.run(["config", "--local", "global.prompt", "from local"])

        #expect(cli.run(["config", "--local", "--unset", "global.prompt"]).exitCode == 0)
        #expect(cli.run(["config", "global.prompt"]).standardOutput == "from global\n")
    }

    @Test func testListWithoutAScopeMergesBothFilesSorted() {
        cli.run(["config", "--global", "global.prompt", "from global"])
        cli.run(["config", "--global", "global.promptquiet", "false"])
        cli.run(["config", "--local", "review.tone", "blunt"])

        let result = cli.run(["config", "--list"])

        #expect(result.exitCode == 0, "\(result.standardError)")
        #expect(result.standardOutput ==
                "global.prompt=from global\nglobal.promptquiet=false\nreview.tone=blunt\n")
    }

    @Test func testListWithAScopeShowsOnlyThatFile() {
        cli.run(["config", "--global", "global.prompt", "from global"])
        cli.run(["config", "--local", "review.tone", "blunt"])

        #expect(cli.run(["config", "--global", "--list"]).standardOutput == "global.prompt=from global\n")
        #expect(cli.run(["config", "--local", "--list"]).standardOutput == "review.tone=blunt\n")
    }

    @Test func testPathPrintsTheFileEachScopeResolvesTo() {
        #expect(cli.run(["config", "--global", "--path"]).standardOutput == cli.globalConfigPath + "\n")
        #expect(cli.run(["config", "--local", "--path"]).standardOutput == cli.resolvedPath(".human-review.config") + "\n")
        #expect(cli.run(["config", "--path"]).standardOutput == cli.globalConfigPath + "\n")
    }

    @Test func testAMultiLineValueRoundTripsAndListsEscaped() {
        let multiLine = "first line\nsecond line"
        #expect(cli.run(["config", "--global", "global.prompt", multiLine]).exitCode == 0)

        #expect(cli.contentsOfFile("global.human-reviewconfig")
            .contains("prompt = \"first line\\nsecond line\""))
        #expect(cli.run(["config", "global.prompt"]).standardOutput == multiLine + "\n")
        #expect(cli.run(["config", "--list"]).standardOutput == "global.prompt=first line\\nsecond line\n")
    }

    @Test func testAMalformedConfigLineExitsWithTwoAndNamesTheFileAndLineNumber() {
        cli.writeGlobalConfig("[global]\n\tprompt = fine\nthis line has no equals sign\n")

        let result = cli.run(["config", "--list"])

        #expect(result.exitCode == 2)
        #expect(result.standardError ==
                "human-review: bad config line \(cli.globalConfigPath):3: this line has no equals sign\n")
    }

    @Test func testAKeyOutsideAnySectionIsAMalformedLine() {
        cli.writeGlobalConfig("prompt = orphaned\n")

        let result = cli.run(["config", "--list"])

        #expect(result.exitCode == 2)
        #expect(result.standardError.contains("bad config line \(cli.globalConfigPath):1:"),
                "\(result.standardError)")
    }

    @Test func testCommentsAndBlankLinesAreIgnored() {
        cli.writeGlobalConfig("# a comment\n; another comment\n\n[global]\n\tprompt = kept\n")

        #expect(cli.run(["config", "global.prompt"]).standardOutput == "kept\n")
    }

    @Test func testSettingAKeyPreservesTheOtherSectionsAndKeys() {
        cli.writeGlobalConfig("[other]\n\tkeep = me\n\n[global]\n\tpromptQuiet = false\n")

        cli.run(["config", "--global", "global.prompt", "added"])

        let stored = cli.contentsOfFile("global.human-reviewconfig")
        #expect(stored.contains("keep = me"), "\(stored)")
        #expect(stored.contains("promptQuiet = false"), "\(stored)")
        #expect(stored.contains("prompt = added"), "\(stored)")
    }

    @Test func testBothScopeFlagsTogetherExitWithTwo() {
        let result = cli.run(["config", "--global", "--local", "global.prompt"])

        #expect(result.exitCode == 2)
        #expect(result.standardError.contains("mutually exclusive"), "\(result.standardError)")
    }

    @Test func testConfigWithoutAKeyPrintsUsageAndExitsWithTwo() {
        let result = cli.run(["config"])

        #expect(result.exitCode == 2)
        #expect(result.standardError.contains("usage: human-review config"), "\(result.standardError)")
    }
}

@Suite("preferences banner")
struct PreferencesBannerTests {

    let cli = ReviewCLIFixture(withSourceFile: true)

    @Test func testPromptPrintsTheConfiguredTextOnStandardOutput() {
        cli.run(["config", "--global", "global.prompt", "reply in threads"])

        let result = cli.run(["prompt"])

        #expect(result.exitCode == 0, "\(result.standardError)")
        #expect(result.standardOutput == "reply in threads\n")
        #expect(result.standardError == "")
    }

    @Test func testPromptExitsWithOneWhenNothingIsConfigured() {
        let result = cli.run(["prompt"])

        #expect(result.exitCode == 1)
        #expect(result.standardOutput == "")
        #expect(result.standardError.contains("no review prompt configured"), "\(result.standardError)")
    }

    @Test func testPromptFileWinsOverTheInlinePrompt() {
        cli.writeTextFile(named: "rules.md", contents: "rules from the file\n")
        cli.run(["config", "--global", "global.prompt", "inline text"])
        cli.run(["config", "--global", "global.promptFile", cli.path("rules.md")])

        #expect(cli.run(["prompt"]).standardOutput == "rules from the file\n")
    }

    @Test func testThePromptFilePathExpandsTilde() {
        let missingInHome = "~/human-review-absent-\(UUID().uuidString).md"
        cli.run(["config", "--global", "global.promptFile", missingInHome])

        let warning = cli.run(["prompt"]).standardError

        let expanded = (missingInHome as NSString).expandingTildeInPath
        #expect(warning == "human-review: config global.promptFile unreadable: \(expanded)\n")
        #expect(warning.contains("~/") == false, "\(warning)")
    }

    @Test func testAnUnreadablePromptFileWarnsButLetsTheCommandRun() {
        cli.run(["config", "--global", "global.promptFile", cli.path("no-such-rules.md")])

        let listing = cli.run(["list", "notes.md"])

        #expect(listing.exitCode == 0)
        #expect(listing.standardError ==
                "human-review: config global.promptFile unreadable: \(cli.path("no-such-rules.md"))\n")
        #expect(cli.jsonArray(listing.standardOutput) != nil)
    }

    @Test func testAnUnreadablePromptFileMakesPromptExitWithOne() {
        cli.run(["config", "--global", "global.promptFile", cli.path("no-such-rules.md")])

        let result = cli.run(["prompt"])

        #expect(result.exitCode == 1)
        #expect(result.standardOutput == "")
    }

    @Test func testTheBannerGoesToStandardErrorExactlyOnce() {
        cli.run(["config", "--global", "global.prompt", "line one\nline two"])

        let result = cli.run(["list", "notes.md"])

        #expect(cli.bannerCount(in: result.standardError) == 1)
        #expect(result.standardError == """
        ── human-review · your review preferences (config global.prompt) ──
        line one
        line two
        ── follow these when you reply to comments ──

        """)
        #expect(result.standardOutput.contains("your review preferences") == false)
    }

    @Test func testStdoutStaysPureJSONWhileTheBannerIsOnStderr() {
        cli.run(["config", "--global", "global.prompt", "reply in threads"])

        let result = cli.run(["add", "notes.md", "--line", "1", "--body", "x"])

        #expect(result.exitCode == 0, "\(result.standardError)")
        #expect(cli.bannerCount(in: result.standardError) == 1)
        #expect(cli.jsonObject(result.standardOutput)?["body"] as? String == "x")
        let trimmed = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(trimmed.first == "{")
        #expect(trimmed.last == "}")
    }

    @Test func testPromptQuietSuppressesTheBannerButNotThePromptSubcommand() {
        cli.run(["config", "--global", "global.prompt", "reply in threads"])
        cli.run(["config", "--global", "global.promptQuiet", "true"])

        #expect(cli.bannerCount(in: cli.run(["list", "notes.md"]).standardError) == 0)
        #expect(cli.run(["prompt"]).standardOutput == "reply in threads\n")
    }

    @Test func testPromptQuietAcceptsEveryDocumentedBooleanSpelling() {
        cli.run(["config", "--global", "global.prompt", "reply in threads"])

        for trueSpelling in ["true", "yes", "on", "1", "TRUE", "On"] {
            cli.run(["config", "--global", "global.promptQuiet", trueSpelling])
            #expect(cli.bannerCount(in: cli.run(["list", "notes.md"]).standardError) == 0, "\(trueSpelling)")
        }
        for falseSpelling in ["false", "no", "off", "0", "FALSE"] {
            cli.run(["config", "--global", "global.promptQuiet", falseSpelling])
            #expect(cli.bannerCount(in: cli.run(["list", "notes.md"]).standardError) == 1, "\(falseSpelling)")
        }
    }

    @Test func testANonBooleanPromptQuietWarnsAndStillShowsTheBanner() {
        cli.run(["config", "--global", "global.prompt", "reply in threads"])
        cli.run(["config", "--global", "global.promptQuiet", "maybe"])

        let result = cli.run(["list", "notes.md"])

        #expect(result.exitCode == 0)
        #expect(result.standardError.contains(
            "human-review: config global.promptQuiet is not a boolean: \"maybe\" — showing the banner"),
                "\(result.standardError)")
        #expect(cli.bannerCount(in: result.standardError) == 1)
        #expect(cli.jsonArray(result.standardOutput) != nil)
    }

    @Test func testTheEnvironmentVariableSuppressesTheBannerUnlessItIsZero() {
        cli.run(["config", "--global", "global.prompt", "reply in threads"])

        let suppressed = cli.run(["list", "notes.md"], environment: ["HUMAN_REVIEW_NO_PROMPT": "1"])
        let zero = cli.run(["list", "notes.md"], environment: ["HUMAN_REVIEW_NO_PROMPT": "0"])
        let empty = cli.run(["list", "notes.md"], environment: ["HUMAN_REVIEW_NO_PROMPT": ""])

        #expect(cli.bannerCount(in: suppressed.standardError) == 0)
        #expect(cli.bannerCount(in: zero.standardError) == 1)
        #expect(cli.bannerCount(in: empty.standardError) == 1)
    }

    @Test func testTheNoPromptFlagSuppressesTheBanner() {
        cli.run(["config", "--global", "global.prompt", "reply in threads"])

        #expect(cli.bannerCount(in: cli.run(["list", "notes.md", "--no-prompt"]).standardError) == 0)
    }

    @Test func testConfigAndPromptNeverPrintTheBanner() {
        cli.run(["config", "--global", "global.prompt", "reply in threads"])

        for arguments in [["config", "--list"], ["prompt"]] {
            #expect(cli.bannerCount(in: cli.run(arguments).standardError) == 0,
                    "\(arguments.joined(separator: " "))")
        }
    }

    @Test func testHelpNeverPrintsTheConfiguredPreferences() {
        cli.run(["config", "--global", "global.prompt", "reply in threads"])

        for flag in ["help", "-h", "--help"] {
            let result = cli.run([flag])
            #expect(result.standardError.contains("reply in threads") == false, "\(flag)")
            #expect(result.standardOutput == "", "\(flag)")
        }
    }

    @Test func testEverySubcommandAcceptsNoPromptWithoutChangingItsExitCode() {
        cli.run(["config", "--global", "global.prompt", "reply in threads"])
        let unknownId = UUID().uuidString

        for arguments in [["list", "notes.md"],
                          ["threads", "notes.md"],
                          ["export", "notes.md"],
                          ["reload", "notes.md"],
                          ["prune", "notes.md"],
                          ["get", "notes.md", "--id", unknownId],
                          ["ack", "notes.md", "--id", unknownId],
                          ["attention", "notes.md", "--id", unknownId],
                          ["resolve", "notes.md", "--id", unknownId],
                          ["reopen", "notes.md", "--id", unknownId],
                          ["delete", "notes.md", "--id", unknownId],
                          ["config", "global.prompt"],
                          ["prompt"],
                          ["watch"],
                          ["wait", "notes.md", "--exit", "--timeout", "1"]] {
            let label = arguments.joined(separator: " ")
            let plain = cli.run(arguments)
            let quiet = cli.run(arguments + ["--no-prompt"])
            #expect(quiet.exitCode == plain.exitCode, "\(label)")
            #expect(quiet.standardError.contains("unknown flag") == false, "\(label)")
            #expect(cli.bannerCount(in: quiet.standardError) == 0, "\(label)")
        }
    }

    @Test func testAddAcceptsNoPromptAndStillReturnsItsRecord() {
        cli.run(["config", "--global", "global.prompt", "reply in threads"])

        let result = cli.run(["add", "notes.md", "--line", "1", "--body", "quiet add", "--no-prompt"])

        #expect(result.exitCode == 0, "\(result.standardError)")
        #expect(result.standardError == "")
        #expect(cli.jsonObject(result.standardOutput)?["body"] as? String == "quiet add")
    }

    @Test func testGUIArgumentParsingAcceptsNoPrompt() {
        cli.run(["config", "--global", "global.prompt", "reply in threads"])

        let result = cli.run(["--no-prompt", "absent.md"])

        #expect(result.exitCode == 1)
        #expect(result.standardError == "human-review: file not found: absent.md\n")
    }
}
