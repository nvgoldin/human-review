import Foundation
import Testing

@Suite("markdown image resolution")
struct MarkdownImageResolutionTests {

    let cli = ReviewCLIFixture()

    @Test func testARelativePathIntoASubdirectoryLoads() {
        cli.writePNGFile(named: "assets/shot.png")
        cli.writeTextFile(named: "doc.md", contents: "# images\n\n![diagram](assets/shot.png)\n")

        let page = renderPage(cli, "doc.md")

        expectOneLoadedImage(in: page, endingIn: "/assets/shot.png")
    }

    @Test func testARelativeSiblingPathLoads() {
        cli.writePNGFile(named: "shot.png")
        cli.writeTextFile(named: "doc.md", contents: "# images\n\n![diagram](shot.png)\n")

        let page = renderPage(cli, "doc.md")

        expectOneLoadedImage(in: page, endingIn: "/shot.png")
    }

    @Test func testAnExplicitDotSlashPathLoads() {
        cli.writePNGFile(named: "shot.png")
        cli.writeTextFile(named: "doc.md", contents: "# images\n\n![diagram](./shot.png)\n")

        let page = renderPage(cli, "doc.md")

        expectOneLoadedImage(in: page, endingIn: "/shot.png")
        #expect(page.images.first?.source.contains("/./") == false, "\(page.images)")
    }

    @Test func testAPathEscapingIntoTheParentDirectoryLoads() {
        cli.writePNGFile(named: "assets/shot.png")
        cli.makeDirectory(named: "assets/pages")
        cli.writeTextFile(named: "assets/pages/doc.md", contents: "# images\n\n![diagram](../shot.png)\n")

        let page = renderPage(cli, "assets/pages/doc.md")

        expectOneLoadedImage(in: page, endingIn: "/assets/shot.png")
        #expect(page.images.first?.source.contains("..") == false, "\(page.images)")
    }

    @Test func testAnAbsolutePathLoads() {
        cli.writePNGFile(named: "shot.png")
        cli.writeTextFile(named: "doc.md", contents: "# images\n\n![diagram](\(cli.path("shot.png")))\n")

        let page = renderPage(cli, "doc.md")

        expectOneLoadedImage(in: page, endingIn: "/shot.png")
    }

    @Test func testAReferenceStyleImageResolvesADefinitionInASeparateBlock() {
        cli.writePNGFile(named: "shot.png")
        cli.writeTextFile(named: "doc.md", contents: """
        # images

        ![diagram][shot]

        some prose between the use and the definition

        [shot]: shot.png

        """)

        let page = renderPage(cli, "doc.md")

        expectOneLoadedImage(in: page, endingIn: "/shot.png")
    }

    @Test func testAnImageWithATitleLoads() {
        cli.writePNGFile(named: "shot.png")
        cli.writeTextFile(named: "doc.md", contents: "# images\n\n![diagram](shot.png \"the title\")\n")

        let page = renderPage(cli, "doc.md")

        expectOneLoadedImage(in: page, endingIn: "/shot.png")
    }

    @Test func testARawHTMLImageTagLoads() {
        cli.writePNGFile(named: "shot.png")
        cli.writeTextFile(named: "doc.md", contents: "# images\n\n<img src=\"shot.png\" width=\"80\">\n")

        let page = renderPage(cli, "doc.md")

        expectOneLoadedImage(in: page, endingIn: "/shot.png")
    }

    @Test func testAPercentEncodedFilenameWithASpaceLoads() {
        cli.writePNGFile(named: "my shot.png")
        cli.writeTextFile(named: "doc.md", contents: "# images\n\n![diagram](my%20shot.png)\n")

        let page = renderPage(cli, "doc.md")

        expectOneLoadedImage(in: page, endingIn: "/my%20shot.png")
    }

    @Test func testAFilenameWithASpaceInAngleBracketsLoads() {
        cli.writePNGFile(named: "my shot.png")
        cli.writeTextFile(named: "doc.md", contents: "# images\n\n![diagram](<my shot.png>)\n")

        let page = renderPage(cli, "doc.md")

        expectOneLoadedImage(in: page, endingIn: "/my%20shot.png")
    }

    @Test func testADataURIImageKeepsItsSourceAndLoads() {
        cli.writeTextFile(named: "doc.md",
                          contents: "# images\n\n![inline](\(ReviewCLIFixture.samplePNGDataURI))\n")

        let page = renderPage(cli, "doc.md")

        #expect(page.exitCode == 0, "\(page.standardError)")
        #expect(page.images.count == 1)
        #expect(page.images.first?.source == ReviewCLIFixture.samplePNGDataURI)
        #expect(page.images.first?.loaded == true)
        #expect(page.images.first?.width == ReviewCLIFixture.samplePNGWidth)
        #expect(page.notes.isEmpty, "\(page.notes)")
    }

    @Test func testAnImageInACommentBodyResolvesAgainstTheDocumentDirectory() {
        cli.writePNGFile(named: "shot.png")
        cli.writeTextFile(named: "doc.md", contents: "# images\n\nfirst paragraph\n")
        cli.addRootComment(to: "doc.md", line: 3, body: "see ![diagram](shot.png)")

        let page = renderPage(cli, "doc.md")

        expectOneLoadedImage(in: page, endingIn: "/shot.png")
    }
}

@Suite("blocked and missing images")
struct BlockedAndMissingImageTests {

    let cli = ReviewCLIFixture()

    @Test func testHTTPAndHTTPSSourcesBecomeBlockedNotesWithNoImageLeft() {
        cli.writeTextFile(named: "doc.md", contents: """
        # images

        ![secure](https://example.com/nope.png)

        ![plain](http://example.com/nope.png)

        """)

        let page = renderPage(cli, "doc.md")

        #expect(page.exitCode == 0, "\(page.standardError)")
        #expect(page.images.isEmpty, "\(page.images)")
        #expect(page.notes.map(\.kind) == ["blocked", "blocked"])
        #expect(page.notes.first?.text == "https images are not fetched: https://example.com/nope.png")
        #expect(page.notes.last?.text == "http images are not fetched: http://example.com/nope.png")
    }

    @Test func testAJavascriptSourceIsBlockedLikeAnyOtherScheme() {
        cli.writeTextFile(named: "doc.md", contents: "# images\n\n![script](javascript:alert(1))\n")

        let page = renderPage(cli, "doc.md")

        #expect(page.exitCode == 0, "\(page.standardError)")
        #expect(page.images.isEmpty, "\(page.images)")
        #expect(page.notes.map(\.kind) == ["blocked"])
        #expect(page.notes.first?.text.hasPrefix("javascript images are not fetched:") == true,
                "\(page.notes)")
    }

    @Test func testAPathThatDoesNotExistBecomesAMissingNoteWithNoImageLeft() {
        cli.writeTextFile(named: "doc.md", contents: "# images\n\n![gone](nosuch.png)\n")

        let page = renderPage(cli, "doc.md")

        #expect(page.exitCode == 0, "\(page.standardError)")
        #expect(page.images.isEmpty, "\(page.images)")
        #expect(page.notes.map(\.kind) == ["missing"])
        #expect(page.notes.first?.text.hasPrefix("image not found:") == true, "\(page.notes)")
        #expect(page.notes.first?.text.hasSuffix("/nosuch.png") == true, "\(page.notes)")
    }
}

@Suite("cross-link overlay")
struct CrossLinkOverlayTests {

    let cli = ReviewCLIFixture()

    @Test func testAnImageInALinkedDocumentResolvesAgainstTheLinkedDirectory() {
        cli.writePNGFile(named: "linked/pic.png")
        cli.writePNGFile(named: "pic.png")
        cli.writeTextFile(named: "main.md", contents: "# main\n\nsee [the other doc](linked/other.md)\n")
        cli.writeTextFile(named: "linked/other.md", contents: "# other\n\n![pic](pic.png)\n")

        let page = renderPage(cli, "main.md", extraArguments: ["--overlay", "linked/other.md"])

        #expect(page.overlayVisible)
        expectOneLoadedImage(in: page, endingIn: "/linked/pic.png")
    }

    @Test func testOverlayVisibleIsFalseWhenNoOverlayIsRequested() {
        cli.writePNGFile(named: "linked/pic.png")
        cli.writeTextFile(named: "main.md", contents: "# main\n\nsee [the other doc](linked/other.md)\n")
        cli.writeTextFile(named: "linked/other.md", contents: "# other\n\n![pic](pic.png)\n")

        let page = renderPage(cli, "main.md")

        #expect(page.exitCode == 0, "\(page.standardError)")
        #expect(page.overlayVisible == false)
        #expect(page.images.isEmpty, "\(page.images)")
    }

    @Test func testAnOverlayOnAMissingFileExitsWithOne() {
        cli.writeTextFile(named: "main.md", contents: "# main\n\nprose\n")

        let result = cli.run(["render", "main.md", "--overlay", "gone.md", "--wait", renderWaitSeconds])

        #expect(result.exitCode == 1)
        #expect(result.standardError.contains("overlay file not found"), "\(result.standardError)")
        #expect(result.standardOutput == "")
    }
}

@Suite("unsafe image attributes")
struct UnsafeImageAttributeTests {

    let cli = ReviewCLIFixture()

    @Test func testAnEventHandlerInjectedThroughTheImageDescriptionIsRemoved() {
        cli.writePNGFile(named: "shot.png")
        cli.writeTextFile(named: "doc.md",
                          contents: "# images\n\n![\" onerror=\"window.__pwned=1](shot.png)\n")

        let page = renderPage(cli, "doc.md")

        expectOneLoadedImage(in: page, endingIn: "/shot.png")
        #expect(page.images.first?.attributes == ["alt", "data-hr-resolved", "src"])
    }

    @Test func testAnEventHandlerAndSrcsetOnARawHTMLImageAreRemoved() {
        cli.writePNGFile(named: "shot.png")
        cli.writeTextFile(named: "doc.md", contents: """
        # images

        <img src="shot.png" onerror="window.__pwned=2" srcset="https://example.com/t.png">

        """)

        let page = renderPage(cli, "doc.md")

        expectOneLoadedImage(in: page, endingIn: "/shot.png")
        #expect(page.images.first?.attributes == ["data-hr-resolved", "src"])
    }

    @Test func testWidthAndHeightOnARawHTMLImageSurvive() {
        cli.writePNGFile(named: "shot.png")
        cli.writeTextFile(named: "doc.md", contents: """
        # images

        <img src="shot.png" width="80" height="60" alt="sized">

        """)

        let page = renderPage(cli, "doc.md")

        expectOneLoadedImage(in: page, endingIn: "/shot.png")
        #expect(page.images.first?.attributes == ["alt", "data-hr-resolved", "height", "src", "width"])
    }
}

@Suite("render subcommand")
struct RenderSubcommandTests {

    let cli = ReviewCLIFixture()

    @Test func testRenderOnAMissingFileExitsWithOne() {
        let result = cli.run(["render", "gone.md", "--wait", renderWaitSeconds])

        #expect(result.exitCode == 1)
        #expect(result.standardError.contains("file not found"), "\(result.standardError)")
        #expect(result.standardOutput == "")
    }

    @Test func testRenderWithoutAFileArgumentExitsWithTwo() {
        let result = cli.run(["render"])

        #expect(result.exitCode == 2)
        #expect(result.standardError.contains("usage: human-review render"), "\(result.standardError)")
        #expect(result.standardOutput == "")
    }

    @Test func testOutWritesAFileStartingWithThePNGMagicBytes() {
        cli.writePNGFile(named: "shot.png")
        cli.writeTextFile(named: "doc.md", contents: "# images\n\n![diagram](shot.png)\n")

        let page = renderPage(cli, "doc.md",
                              extraArguments: ["--out", cli.path("snapshot.png"),
                                               "--width", "500", "--height", "400"])

        #expect(page.exitCode == 0, "\(page.standardError)")
        #expect(cli.fileExists("snapshot.png"))
        let bytes = (try? Data(contentsOf: URL(fileURLWithPath: cli.path("snapshot.png")))) ?? Data()
        #expect(Array(bytes.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
                "not a PNG: \(Array(bytes.prefix(8)))")
    }

    @Test func testRenderingACodeFileReportsItsLineBlocksAndNoImages() {
        cli.writeTextFile(named: "module.py", contents: """
        def add(first, second):
            return first + second


        def subtract(first, second):
            return first - second

        """)

        let page = renderPage(cli, "module.py")

        #expect(page.exitCode == 0, "\(page.standardError)")
        #expect(page.blocks == 6)
        #expect(page.images.isEmpty, "\(page.images)")
        #expect(page.notes.isEmpty, "\(page.notes)")
    }

    @Test func testRenderingLeavesTheSourceByteIdenticalAndWritesNoSidecars() {
        cli.writePNGFile(named: "shot.png")
        let markdown = "# images\n\n![diagram](shot.png)\n\n![gone](nosuch.png)\n"
        cli.writeTextFile(named: "doc.md", contents: markdown)

        let page = renderPage(cli, "doc.md")

        #expect(page.exitCode == 0, "\(page.standardError)")
        #expect(cli.contentsOfFile("doc.md") == markdown)
        #expect(cli.fileExists("doc.md.comments.json") == false)
        #expect(cli.fileExists("doc.md.events.jsonl") == false)
        #expect(cli.fileExists("doc.review.md") == false)
    }
}

private let renderWaitSeconds = "1"

private struct RenderedImage {
    let source: String
    let width: Int
    let loaded: Bool
    let attributes: [String]
}

private struct RenderedNote {
    let kind: String
    let text: String
}

private struct RenderedPage {
    let exitCode: Int32
    let standardError: String
    let blocks: Int
    let overlayVisible: Bool
    let images: [RenderedImage]
    let notes: [RenderedNote]
}

private func renderPage(_ cli: ReviewCLIFixture, _ name: String,
                        extraArguments: [String] = []) -> RenderedPage {
    let result = cli.run(["render", name, "--wait", renderWaitSeconds] + extraArguments)
    let report = cli.jsonObject(result.standardOutput)
    let images = (report?["images"] as? [[String: Any]] ?? []).map {
        RenderedImage(source: $0["src"] as? String ?? "",
                      width: $0["width"] as? Int ?? -1,
                      loaded: $0["loaded"] as? Bool ?? false,
                      attributes: $0["attributes"] as? [String] ?? [])
    }
    let notes = (report?["notes"] as? [[String: Any]] ?? []).map {
        RenderedNote(kind: $0["kind"] as? String ?? "",
                     text: $0["text"] as? String ?? "")
    }
    return RenderedPage(exitCode: result.exitCode,
                        standardError: "\(result.standardError)\nstdout: \(result.standardOutput)",
                        blocks: report?["blocks"] as? Int ?? -1,
                        overlayVisible: report?["overlayVisible"] as? Bool ?? false,
                        images: images,
                        notes: notes)
}

private func expectOneLoadedImage(in page: RenderedPage, endingIn suffix: String,
                                  sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(page.exitCode == 0, "\(page.standardError)", sourceLocation: sourceLocation)
    #expect(page.notes.isEmpty, "\(page.notes)", sourceLocation: sourceLocation)
    #expect(page.images.count == 1, "\(page.images)", sourceLocation: sourceLocation)
    guard let image = page.images.first else { return }
    #expect(image.loaded, "\(image)", sourceLocation: sourceLocation)
    #expect(image.width == ReviewCLIFixture.samplePNGWidth, "\(image)", sourceLocation: sourceLocation)
    #expect(image.source.hasPrefix("hrimg://local/"), "\(image)", sourceLocation: sourceLocation)
    #expect(image.source.hasSuffix(suffix), "\(image)", sourceLocation: sourceLocation)
    #expect(image.attributes.contains { $0.hasPrefix("on") } == false, "\(image)",
            sourceLocation: sourceLocation)
}
