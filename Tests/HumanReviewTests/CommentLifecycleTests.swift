import Foundation
import Testing

@Suite("comment lifecycle")
struct CommentLifecycleTests {

    let cli = ReviewCLIFixture(withSourceFile: true)

    @Test func testAddLineAnchorsToTheEnclosingBlock() {
        let result = cli.run(["add", "notes.md", "--line", "4", "--body", "check this"])

        #expect(result.exitCode == 0, "\(result.standardError)")
        let comment = cli.jsonObject(result.standardOutput)
        #expect(comment?["scope"] as? String == "block")
        #expect(comment?["anchorLine"] as? Int == 3)
        #expect(comment?["anchorText"] as? String == "beta block")
        #expect(comment?["body"] as? String == "check this")
        #expect(comment?["author"] as? String == "agent")
        #expect(comment?["replyTo"] as? String == nil)
    }

    @Test func testAddGlobalCreatesGlobalScopedRootWithNoAnchor() {
        let result = cli.run(["add", "notes.md", "--global", "--body", "whole document note"])

        #expect(result.exitCode == 0, "\(result.standardError)")
        let comment = cli.jsonObject(result.standardOutput)
        #expect(comment?["scope"] as? String == "global")
        #expect(comment?["anchorLine"] as? Int == 0)
        #expect(comment?["anchorText"] as? String == "")
    }

    @Test func testAddAuthorOverridesTheDefaultAgentName() {
        let result = cli.run(["add", "notes.md", "--line", "1", "--body", "hi", "--author", "reviewer"])

        #expect(cli.jsonObject(result.standardOutput)?["author"] as? String == "reviewer")
    }

    @Test func testReplyInheritsTheRootScopeAndIgnoresTheGlobalFlag() {
        let rootId = cli.addRootComment()

        let reply = cli.run(["add", "notes.md", "--reply-to", rootId, "--global", "--body", "a reply"])

        #expect(reply.exitCode == 0, "\(reply.standardError)")
        let replyComment = cli.jsonObject(reply.standardOutput)
        #expect(replyComment?["replyTo"] as? String == rootId)
        #expect(replyComment?["scope"] as? String == "block")
        #expect(replyComment?["anchorLine"] as? Int == 3)
        #expect(replyComment?["anchorText"] as? String == "beta block")
    }

    @Test func testReplyToAGlobalRootStaysGlobal() {
        let globalRoot = cli.run(["add", "notes.md", "--global", "--body", "doc chat"])
        let rootId = cli.jsonObject(globalRoot.standardOutput)?["id"] as? String ?? ""

        let reply = cli.run(["add", "notes.md", "--reply-to", rootId, "--body", "answer"])

        #expect(cli.jsonObject(reply.standardOutput)?["scope"] as? String == "global")
    }

    @Test func testListReturnsEveryCommentAsAJSONArray() {
        let rootId = cli.addRootComment()
        cli.run(["add", "notes.md", "--reply-to", rootId, "--body", "a reply"])
        cli.run(["add", "notes.md", "--global", "--body", "doc chat"])

        let result = cli.run(["list", "notes.md"])

        #expect(result.exitCode == 0, "\(result.standardError)")
        #expect(cli.jsonArray(result.standardOutput)?.count == 3)
    }

    @Test func testListScopeFlagFiltersBlockGlobalAndAll() {
        cli.addRootComment()
        cli.run(["add", "notes.md", "--global", "--body", "doc chat"])

        let blockOnly = cli.jsonArray(cli.run(["list", "notes.md", "--scope", "block"]).standardOutput)
        let globalOnly = cli.jsonArray(cli.run(["list", "notes.md", "--scope", "global"]).standardOutput)
        let everything = cli.jsonArray(cli.run(["list", "notes.md", "--scope", "all"]).standardOutput)

        #expect(blockOnly?.count == 1)
        #expect(blockOnly?.first?["scope"] as? String == "block")
        #expect(globalOnly?.count == 1)
        #expect(globalOnly?.first?["scope"] as? String == "global")
        #expect(everything?.count == 2)
    }

    @Test func testThreadsReportsRootsWithTheirReplyCount() {
        let rootId = cli.addRootComment()
        cli.run(["add", "notes.md", "--reply-to", rootId, "--body", "first reply"])
        cli.run(["add", "notes.md", "--reply-to", rootId, "--body", "second reply"])

        let result = cli.run(["threads", "notes.md"])

        #expect(result.exitCode == 0, "\(result.standardError)")
        let threads = cli.jsonArray(result.standardOutput)
        #expect(threads?.count == 1)
        #expect(threads?.first?["id"] as? String == rootId)
        #expect(threads?.first?["replyCount"] as? Int == 2)
    }

    @Test func testThreadsActiveAndSettledSplitOnTheResolvedState() {
        let settledId = cli.addRootComment(line: 1, body: "settled thread")
        let activeId = cli.addRootComment(line: 4, body: "active thread")
        cli.run(["resolve", "notes.md", "--id", settledId])

        let active = cli.jsonArray(cli.run(["threads", "notes.md", "--active"]).standardOutput)
        let settled = cli.jsonArray(cli.run(["threads", "notes.md", "--settled"]).standardOutput)

        #expect(active?.compactMap { $0["id"] as? String } == [activeId])
        #expect(settled?.compactMap { $0["id"] as? String } == [settledId])
    }

    @Test func testGetAcksByDefaultAndNoAckLeavesReadByUntouched() {
        let rootId = cli.addRootComment()

        let silent = cli.run(["get", "notes.md", "--id", rootId, "--no-ack", "--author", "human"])
        #expect(silent.exitCode == 0, "\(silent.standardError)")
        #expect(cli.jsonObject(silent.standardOutput)?["readBy"] as? [String] == [])

        let acking = cli.run(["get", "notes.md", "--id", rootId, "--author", "human"])
        #expect(acking.exitCode == 0, "\(acking.standardError)")
        #expect(cli.jsonObject(acking.standardOutput)?["readBy"] as? [String] == ["human"])
    }

    @Test func testAckRecordsTheReaderOnTheComment() {
        let rootId = cli.addRootComment()

        let result = cli.run(["ack", "notes.md", "--id", rootId, "--author", "human"])

        #expect(result.exitCode == 0, "\(result.standardError)")
        #expect(cli.jsonObject(result.standardOutput)?["readBy"] as? [String] == ["human"])
    }

    @Test func testResolveThenReopenFlipsTheRootResolvedFlag() {
        let rootId = cli.addRootComment()

        let resolved = cli.run(["resolve", "notes.md", "--id", rootId])
        #expect(resolved.exitCode == 0, "\(resolved.standardError)")
        #expect(cli.jsonObject(resolved.standardOutput)?["resolved"] as? Bool == true)

        let reopened = cli.run(["reopen", "notes.md", "--id", rootId])
        #expect(reopened.exitCode == 0, "\(reopened.standardError)")
        #expect(cli.jsonObject(reopened.standardOutput)?["resolved"] as? Bool == false)
    }

    @Test func testReplyingToASettledThreadAutoReopensIt() {
        let rootId = cli.addRootComment()
        cli.run(["resolve", "notes.md", "--id", rootId])

        cli.run(["add", "notes.md", "--reply-to", rootId, "--body", "one more thing"])

        let threads = cli.jsonArray(cli.run(["threads", "notes.md"]).standardOutput)
        #expect(threads?.first?["resolved"] as? Bool == false)
        #expect(cli.eventLogLines().contains { $0.contains("\"event\":\"reopened\"") })
    }

    @Test func testDeletingARootRemovesTheWholeThread() {
        let rootId = cli.addRootComment()
        cli.run(["add", "notes.md", "--reply-to", rootId, "--body", "a reply"])

        let result = cli.run(["delete", "notes.md", "--id", rootId])

        #expect(result.exitCode == 0, "\(result.standardError)")
        #expect(cli.jsonObject(result.standardOutput)?["id"] as? String == rootId)
        #expect(cli.jsonArray(cli.run(["list", "notes.md"]).standardOutput)?.count == 0)
    }

    @Test func testDeletingAReplyKeepsTheRoot() {
        let rootId = cli.addRootComment()
        let reply = cli.run(["add", "notes.md", "--reply-to", rootId, "--body", "a reply"])
        let replyId = cli.jsonObject(reply.standardOutput)?["id"] as? String ?? ""

        cli.run(["delete", "notes.md", "--id", replyId])

        let remaining = cli.jsonArray(cli.run(["list", "notes.md"]).standardOutput)
        #expect(remaining?.compactMap { $0["id"] as? String } == [rootId])
    }

    @Test func testExportReplacesTheSourceExtensionInsteadOfAppendingIt() {
        cli.addRootComment()

        let result = cli.run(["export", "notes.md"])

        #expect(result.exitCode == 0, "\(result.standardError)")
        #expect(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == cli.path("notes.review.md"))
        #expect(cli.fileExists("notes.review.md"))
        #expect(cli.fileExists("notes.md.review.md") == false)
        #expect(cli.contentsOfFile("notes.review.md").contains("> [!review]"))
    }

    @Test func testReloadReportsUnchangedWhenTheSourceIsUntouched() {
        cli.addRootComment()

        let result = cli.run(["reload", "notes.md"])

        #expect(result.exitCode == 0, "\(result.standardError)")
        let stats = cli.jsonObject(result.standardOutput)
        #expect(stats?["unchanged"] as? Int == 1)
        #expect(stats?["relocated"] as? Int == 0)
        #expect(stats?["orphaned"] as? Int == 0)
    }

    @Test func testReloadRelocatesAnAnchorThatMovedDownTheFile() {
        cli.addRootComment()
        cli.writeSourceFile(contents: "new heading\n\nalpha block\nstill alpha\n\nbeta block\n\ngamma block\n")

        let stats = cli.jsonObject(cli.run(["reload", "notes.md"]).standardOutput)

        #expect(stats?["relocated"] as? Int == 1)
        #expect(stats?["orphaned"] as? Int == 0)
    }

    @Test func testReloadOrphansAnAnchorWhoseBlockWasDeletedFromTheSource() {
        cli.addRootComment()
        cli.writeSourceFile(contents: "alpha block\nstill alpha\n\ngamma block\n")

        let stats = cli.jsonObject(cli.run(["reload", "notes.md"]).standardOutput)

        #expect(stats?["orphaned"] as? Int == 1)
        #expect(cli.jsonArray(cli.run(["list", "notes.md"]).standardOutput)?.first?["orphaned"] as? Bool == true)
    }

    @Test func testPruneTruncatesTheEventLog() {
        cli.addRootComment()
        #expect(cli.eventLogLines().isEmpty == false)

        let result = cli.run(["prune", "notes.md"])

        #expect(result.exitCode == 0, "\(result.standardError)")
        #expect(cli.fileExists("notes.md.events.jsonl"))
        #expect(cli.eventLogLines() == [])
    }

    @Test func testAttentionMarksTheCommentTheGUIShouldFocus() {
        let rootId = cli.addRootComment()

        let result = cli.run(["attention", "notes.md", "--id", rootId])

        #expect(result.exitCode == 0, "\(result.standardError)")
        let record = cli.jsonObject(result.standardOutput)
        #expect(record != nil, "stdout must be exactly one JSON document: \(result.standardOutput)")
        #expect(record?["attention"] as? String == rootId)
        #expect(cli.jsonObject(cli.contentsOfFile("notes.md.comments.json"))?["pendingAttention"] as? String == rootId)
    }

    @Test func testAttentionAppendsExactlyOneEventToTheLog() {
        let rootId = cli.addRootComment()
        let before = cli.eventLogLines().count

        _ = cli.run(["attention", "notes.md", "--id", rootId])

        let added = cli.eventLogLines().dropFirst(before)
        #expect(added.count == 1, "\(added)")
        #expect(cli.jsonObject(added.first ?? "")?["event"] as? String == "attention")
    }
}

@Suite("sidecars and event log")
struct SidecarAndEventLogTests {

    let cli = ReviewCLIFixture(withSourceFile: true)

    @Test func testThreeSidecarsAreCreatedNextToTheSourceFile() {
        cli.addRootComment()

        #expect(cli.fileExists("notes.md.comments.json"))
        #expect(cli.fileExists("notes.md.events.jsonl"))
        #expect(cli.fileExists("notes.review.md"))
    }

    @Test func testTheSourceFileIsNeverRewritten() {
        let before = cli.contentsOfFile("notes.md")
        let rootId = cli.addRootComment()
        cli.run(["resolve", "notes.md", "--id", rootId])

        #expect(cli.contentsOfFile("notes.md") == before)
    }

    @Test func testEachMutationAppendsExactlyOneEventLine() {
        var expectedCount = 1
        let rootId = cli.addRootComment()
        #expect(cli.eventLogLines().count == expectedCount, "add")

        for command in [["resolve", "notes.md", "--id", rootId],
                        ["reopen", "notes.md", "--id", rootId],
                        ["ack", "notes.md", "--id", rootId, "--author", "human"],
                        ["reload", "notes.md"],
                        ["delete", "notes.md", "--id", rootId]] {
            cli.run(command)
            expectedCount += 1
            #expect(cli.eventLogLines().count == expectedCount, "\(command[0])")
        }
    }

    @Test func testEveryEventLineIsJSONWithAlphabeticallySortedKeys() {
        let rootId = cli.addRootComment()
        cli.run(["add", "notes.md", "--reply-to", rootId, "--body", "a reply"])
        cli.run(["resolve", "notes.md", "--id", rootId])
        cli.run(["ack", "notes.md", "--id", rootId, "--author", "human"])
        cli.run(["reload", "notes.md"])

        let lines = cli.eventLogLines()
        #expect(lines.isEmpty == false)
        for line in lines {
            #expect(cli.jsonObject(line) != nil, "not valid JSON: \(line)")
            for keys in cli.objectKeyOrders(inJSONText: line) {
                #expect(keys == keys.sorted(), "unsorted keys in: \(line)")
            }
        }
    }

    @Test func testAnEventLineCarriesItsNameAndTheAbsoluteSourcePath() {
        cli.addRootComment()

        let event = cli.jsonObject(cli.eventLogLines()[0])

        #expect(event?["event"] as? String == "added")
        #expect(event?["file"] as? String == cli.path("notes.md"))
        #expect(event?["timestamp"] as? String != nil)
    }

    @Test func testTheCommentsSidecarHoldsTheCanonicalCommentList() {
        let rootId = cli.addRootComment()

        let sidecar = cli.jsonObject(cli.contentsOfFile("notes.md.comments.json"))

        #expect(sidecar?["file"] as? String == "notes.md")
        let comments = sidecar?["comments"] as? [[String: Any]]
        #expect(comments?.compactMap { $0["id"] as? String } == [rootId])
    }
}

@Suite("streaming and blocking", .serialized)
struct StreamingTests {

    let cli = ReviewCLIFixture(withSourceFile: true)

    @Test func testWaitForAReplyTimesOutWith124AndNoStandardOutput() {
        let rootId = cli.addRootComment()

        let result = cli.run(["wait", "notes.md", "--reply-to", rootId, "--timeout", "2"])

        #expect(result.exitCode == 124)
        #expect(result.standardOutput == "")
    }

    @Test func testWaitForAReplyReturnsTheMatchingEventWhenAnotherProcessReplies() {
        let rootId = cli.addRootComment()
        let (waiter, waiterOutput) = cli.startInBackground(
            ["wait", "notes.md", "--reply-to", rootId, "--timeout", "30", "--no-ack"])

        Thread.sleep(forTimeInterval: 2)
        let reply = cli.run(["add", "notes.md", "--reply-to", rootId,
                             "--body", "the human answers", "--author", "human"])
        #expect(reply.exitCode == 0, "\(reply.standardError)")
        let replyId = cli.jsonObject(reply.standardOutput)?["id"] as? String ?? ""

        let seen = cli.collectOutput(of: waiterOutput, until: { $0.contains(replyId) }, timeout: 30)
        waiter.waitUntilExit()

        #expect(waiter.terminationStatus == 0)
        let event = cli.jsonObject(seen.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(event?["event"] as? String == "added")
        #expect((event?["comment"] as? [String: Any])?["id"] as? String == replyId)
    }

    @Test func testWaitForExitTimesOutWith124WhenNoGUIRuns() {
        cli.addRootComment()

        let result = cli.run(["wait", "notes.md", "--exit", "--timeout", "2"])

        #expect(result.exitCode == 124)
        #expect(result.standardOutput == "")
    }

    @Test func testWaitRejectsMoreThanOneMode() {
        let rootId = cli.addRootComment()

        let result = cli.run(["wait", "notes.md", "--reply-to", rootId, "--exit"])

        #expect(result.exitCode == 2)
        #expect(result.standardError.contains("exactly one of"), "\(result.standardError)")
    }

    @Test func testWatchFromStartReplaysOnlyTheRequestedEventTypes() {
        let rootId = cli.addRootComment()
        cli.run(["add", "notes.md", "--reply-to", rootId, "--body", "a reply"])
        cli.run(["resolve", "notes.md", "--id", rootId])

        let (watcher, watcherOutput) = cli.startInBackground(
            ["watch", "notes.md", "--from-start", "--types", "added", "--no-ack"])
        let seen = cli.collectOutput(of: watcherOutput, until: { countLines($0) >= 2 })
        cli.terminate(watcher)

        let lines = seen.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 2)
        #expect(lines.compactMap { cli.jsonObject($0)?["event"] as? String } == ["added", "added"])
    }

    @Test func testWatchOverTwoFilesEmitsOnlyJSONAndCoversBothFiles() {
        cli.writeSourceFile(named: "other.md")
        cli.addRootComment(to: "notes.md", body: "note on the first file")
        cli.addRootComment(to: "other.md", body: "note on the second file")

        let (watcher, watcherOutput) = cli.startInBackground(
            ["watch", "notes.md", "other.md", "--from-start", "--no-ack"])
        let seen = cli.collectOutput(of: watcherOutput, until: { countLines($0) >= 2 })
        cli.terminate(watcher)

        let lines = seen.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 2)
        for line in lines {
            #expect(cli.jsonObject(line) != nil, "not valid JSON: \(line)")
            #expect(line.hasPrefix("==> ") == false, "tail header leaked: \(line)")
        }
        let watchedFiles = Set(lines.compactMap { cli.jsonObject($0)?["file"] as? String })
        #expect(watchedFiles == Set([cli.path("notes.md"), cli.path("other.md")]))
    }

    @Test func testTerminatingAWatchKillsItsTailChild() {
        cli.addRootComment()

        let (watcher, watcherOutput) = cli.startInBackground(["watch", "notes.md", "--from-start", "--no-ack"])
        _ = cli.collectOutput(of: watcherOutput, until: { countLines($0) >= 1 })
        #expect(cli.runningProcesses(matching: "tail -F .*\(cli.workingDirectory.lastPathComponent)").count == 1)

        cli.terminate(watcher)
        Thread.sleep(forTimeInterval: 0.5)

        let orphans = cli.runningProcesses(matching: "tail -F .*\(cli.workingDirectory.lastPathComponent)")
        #expect(orphans.isEmpty, "orphaned tail after the watch was terminated: \(orphans)")
    }
}

private func countLines(_ text: String) -> Int {
    text.components(separatedBy: "\n").filter { !$0.isEmpty }.count
}

@Suite("exit codes and argument errors")
struct ExitCodeTests {

    let cli = ReviewCLIFixture(withSourceFile: true)

    @Test func testAMissingSourceFileExitsWithOne() {
        for arguments in [["add", "gone.md", "--line", "1", "--body", "x"],
                          ["list", "gone.md"],
                          ["threads", "gone.md"],
                          ["export", "gone.md"],
                          ["reload", "gone.md"],
                          ["resolve", "gone.md", "--id", UUID().uuidString]] {
            #expect(cli.run(arguments).exitCode == 1, "\(arguments.joined(separator: " "))")
        }
    }

    @Test func testNoSubcommandPrintsUsageAndExitsWithTwo() {
        let result = cli.run([])

        #expect(result.exitCode == 2)
        #expect(result.standardError.contains("human-review · GitHub-style review"), "\(result.standardError)")
        #expect(result.standardOutput == "")
    }

    @Test func testAddWithoutABodyExitsWithTwo() {
        let result = cli.run(["add", "notes.md", "--line", "1"])

        #expect(result.exitCode == 2)
        #expect(result.standardError.contains("--body is required"), "\(result.standardError)")
    }

    @Test func testAddWithoutAnyAnchorExitsWithTwo() {
        let result = cli.run(["add", "notes.md", "--body", "x"])

        #expect(result.exitCode == 2)
        #expect(result.standardError.contains("--line is required"), "\(result.standardError)")
    }

    @Test func testAMissingIdExitsWithTwo() {
        for subcommand in ["resolve", "reopen", "delete", "get", "ack", "attention"] {
            #expect(cli.run([subcommand, "notes.md"]).exitCode == 2, "\(subcommand)")
        }
    }

    @Test func testAMalformedUUIDExitsWithTwo() {
        for subcommand in ["resolve", "reopen", "delete", "get", "ack", "attention"] {
            #expect(cli.run([subcommand, "notes.md", "--id", "not-a-uuid"]).exitCode == 2, "\(subcommand)")
        }
    }

    @Test func testAMissingFileArgumentExitsWithTwo() {
        for subcommand in ["add", "list", "threads", "export", "reload", "prune", "watch", "wait"] {
            #expect(cli.run([subcommand]).exitCode == 2, "\(subcommand)")
        }
    }

    @Test func testAnUnknownIdOnAnExistingFileExitsWithOne() {
        #expect(cli.run(["get", "notes.md", "--id", UUID().uuidString]).exitCode == 1)
    }

    @Test func testHelpExitsWithZeroAndWritesUsageToStandardError() {
        for flag in ["help", "-h", "--help"] {
            let result = cli.run([flag])
            #expect(result.exitCode == 0, "\(flag)")
            #expect(result.standardError.contains("Agent CLI"), "\(flag)")
        }
    }

    @Test func testAnUnknownFlagInGUIModeExitsWithTwo() {
        let result = cli.run(["--not-a-real-flag", "notes.md"])

        #expect(result.exitCode == 2)
        #expect(result.standardError.contains("unknown flag"), "\(result.standardError)")
    }
}
