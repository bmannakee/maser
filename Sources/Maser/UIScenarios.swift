// The UI scenarios that `scripts/check-ui` runs, each against a fresh launch of a debug build.
//
// Each scenario is named with the requirements it verifies, like a unit test, and requirements cite it as
// `UI:<name>`; `maser-trace` checks both directions. The scenarios run against the recordings in
// `Tests/UIScenarios/recordings` and the queue searches in `Tests/UIScenarios/config.toml`, so the PR numbers below
// are the ones recorded there. See `Tests/UIScenarios/README.md` for running and re-recording them.

#if DEBUG
    import Foundation
    import MaserCore

    /// The scenarios, and the recorded PRs they use.
    @MainActor
    enum UIScenarios {
        /// A merged PR with several files and review threads.
        static let mainPR = 16
        /// A small merged PR.
        static let smallPR = 13
        /// The closed test PR, the only one live write tests may touch, so comments posted to it are harmless.
        static let testPR = 1
        /// A merged PR that adds the design docs: Markdown with lines long enough to wrap.
        static let designDocsPR = 22

        /// Every scenario, in the order `scripts/check-ui` runs them.
        static let all: [UIScenario] = [
            queueKeys, keyRouting, tabAndPaneStress, commentBoxKeepsFocus, typingPausesKeys, postComment,
            queueSearchFails, switchPRsKeepsState, longLinesWrap, headMovedBlocksPosting, namesPRAndAccount,
            draftSurvivesRelaunch, closedPRLeavesPane,
        ]

        /// The queue's keys move the selection and open PRs.
        static let queueKeys = UIScenario(
            "queue-keys", "REQ-QUE-007: j/k, ]/[, g g/G and Return in the queue (not o, which opens a browser)"
        ) { app in
            let prs = app.queuePRs
            let sections = app.probe.sections().map { $0.prs ?? [] }.filter { !$0.isEmpty }
            try app.expect(prs.count >= 3 && sections.count >= 2, "a queue of 3+ PRs in 2+ sections", app.summary)
            try app.expect(app.state.queueHasKeys && app.review == nil, "the queue has the keys at launch", app.summary)

            try await app.press("j")
            try app.expect(app.selectedNumbers == [prs[0].number], "j with nothing selected selects the first PR", app.summary)
            try await app.press("j")
            try app.expect(app.selectedNumbers == [prs[1].number], "j selects the next PR", app.summary)
            try await app.press("k")
            try app.expect(app.selectedNumbers == [prs[0].number], "k selects the previous PR", app.summary)
            try await app.press("G")
            try app.expect(app.selectedNumbers == [prs[prs.count - 1].number], "G selects the last PR", app.summary)
            try await app.press("j")
            try app.expect(app.selectedNumbers == [prs[prs.count - 1].number], "j on the last PR stays put", app.summary)
            try await app.press("g g")
            try app.expect(app.selectedNumbers == [prs[0].number], "g g selects the first PR", app.summary)
            try await app.press("]")
            try app.expect(
                app.selectedNumbers == [sections[1][0].number], "] jumps to the next section's first PR", app.summary)
            try await app.press("[")
            try app.expect(
                app.selectedNumbers == [sections[0][0].number], "[ jumps back to the previous section's first PR", app.summary)
            try await app.press("enter")
            try await app.waitUntil("Return opens the selected PR and gives it the keys") {
                app.review?.pr.number == prs[0].number && !app.state.queueHasKeys
            }
        }

        /// Keys go to the queue or the review as REQ-WIN-003 and REQ-KEY-003 say; the V10 check from 2026-11-03.
        static let keyRouting = UIScenario(
            "key-routing", "REQ-WIN-003, REQ-KEY-003: Who gets the keys after Return, ⌘0, g p, e and /"
        ) { app in
            let prs = app.queuePRs
            try await app.openFromQueue(prs[1].number)
            try app.expect(!app.state.queueHasKeys, "Return gives the review the keys", app.summary)

            try await app.press("/")
            try app.expect(
                !app.state.queueHasKeys && app.responder != .textField, "/ does nothing while the review has the keys",
                app.summary)

            try await app.press("cmd+0")
            try await app.waitUntil("⌘0 gives the queue the keys, with the open PR selected and the list focused") {
                app.state.queueHasKeys && app.selectedNumbers == [prs[1].number] && app.responder == .list
            }
            try await app.press("k")
            try app.expect(app.selectedNumbers == [prs[0].number], "k moves the selection", app.summary)
            try await app.waitUntil("the selected PR shows while the queue keeps the keys") {
                app.review?.pr.number == prs[0].number && app.state.queueHasKeys
            }
            try await app.press("g f")
            try app.expect(
                app.review?.tab == .files && app.state.queueHasKeys, "g f, which the queue doesn't use, reaches the review",
                app.summary)

            try await app.press("j")
            try await app.press("enter")
            try await app.waitUntil("Return opens the PR and gives it the keys") {
                app.review?.pr.number == prs[1].number && !app.state.queueHasKeys
            }
            try await app.press("e")
            try app.expect(
                app.state.columnVisibility == .detailOnly && !app.state.queueHasKeys, "e hides the queue", app.summary)
            try await app.press("e")
            try app.expect(
                app.state.columnVisibility != .detailOnly && app.state.queueHasKeys, "e shows it with the keys", app.summary)
            try await app.press("e")
            try app.expect(
                app.state.columnVisibility == .detailOnly && !app.state.queueHasKeys, "e hides it again", app.summary)
            try await app.press("/")
            try app.expect(
                app.state.columnVisibility == .detailOnly && app.responder != .textField,
                "/ does nothing with the queue hidden", app.summary)

            try await app.press("g p")
            try app.expect(
                app.state.columnVisibility != .detailOnly && app.state.queueHasKeys, "g p shows the queue with the keys",
                app.summary)
            try await app.press("/")
            try await app.waitUntil("/ focuses the filter while the queue has the keys") { app.responder == .textField }
        }

        /// Flipping tabs and panes repeatedly neither crashes nor stalls; the V7 check from 2026-11-03.
        static let tabAndPaneStress = UIScenario(
            "tab-and-pane-stress", "REQ-WIN-007: 10 rounds of switching tabs and hiding and showing both panes"
        ) { app in
            try await app.openFromQueue(mainPR)
            for round in 1...10 {
                try await app.press("g f")
                try await app.waitUntil("round \(round): the Files tab shows a file") {
                    app.review?.tab == .files && app.review?.selectedFile != nil
                }
                try await app.press("i")
                try await app.press("e")
                try await app.press("j")
                try await app.press("g o")
                try await app.press("e")
                try await app.press("g f")
                try await app.press("i")
                try await app.press("g o")
                try app.expect(
                    app.review?.tab == .overview && app.review?.showComments == true
                        && app.state.columnVisibility != .detailOnly,
                    "round \(round): back to the Overview with both panes showing", app.summary)
            }
            try await app.press("g f")
            // The last `e` gave the queue the keys; hide it so j moves the diff's cursor.
            try await app.press("e")
            let start = app.review?.cursorLineID
            try await app.press("j")
            try await app.press("j")
            try app.expect(app.review?.cursorLineID != start, "the diff still responds to keys", app.summary)
        }

        /// A comment box opened with `c` keeps the keyboard; the V8 check from 2026-11-03.
        static let commentBoxKeepsFocus = UIScenario(
            "comment-box-keeps-focus", "REQ-KEY-004: c on the Overview and on a diff line keeps focus in the comment box"
        ) { app in
            try await app.openFromQueue(smallPR)
            try await app.press("c")
            try await app.waitUntil("c on the Overview focuses the comment box") { app.responder == .editor }
            await app.pause(.seconds(2))
            try app.expect(app.responder == .editor, "the comment box still has focus 2 s later", app.summary)
            try await app.press("esc")
            try app.expect(app.responder != .editor, "Esc leaves the comment box", app.summary)

            try await app.press("g f")
            try await app.waitUntil("the Files tab shows a file") { app.review?.selectedFile != nil }
            for _ in 0..<3 { try await app.press("j") }
            try await app.press("c")
            try await app.waitUntil("c on a diff line opens a focused comment box") {
                app.review?.inlineDraft != nil && app.responder == .editor
            }
            await app.pause(.seconds(2))
            try app.expect(app.responder == .editor, "the line comment box still has focus 2 s later", app.summary)
        }

        /// Keys typed into a comment box are text, not commands, until Esc.
        static let typingPausesKeys = UIScenario(
            "typing-pauses-keys", "REQ-KEY-002: Keys typed in a comment box are text; Esc leaves it and cancels a sequence"
        ) { app in
            try await app.openFromQueue(smallPR)
            try await app.press("c")
            try await app.waitUntil("the comment box has focus") { app.responder == .editor }
            await app.type("jk g f] e")
            try app.expect(app.review?.commentDraft == "jk g f] e", "typed keys land in the draft", app.summary)
            try app.expect(
                app.review?.tab == .overview && app.state.columnVisibility != .detailOnly, "and run no commands",
                app.summary)
            try await app.press("esc")
            try app.expect(app.responder != .editor, "Esc leaves the comment box", app.summary)
            try await app.press("g f")
            try app.expect(app.review?.tab == .files, "keys are commands again", app.summary)
            try await app.press("g o")
            try await app.press("g")
            try await app.press("esc")
            try await app.press("f")
            try app.expect(app.review?.tab == .overview, "Esc cancels a half-typed g f", app.summary)
        }

        /// Posting to the conversation sends the comment through `gh`, and a failed post keeps the draft.
        static let postComment = UIScenario(
            "post-comment", "REQ-OVR-004, REQ-GH-004: Posts a comment with ⌘Return; a failed post shows why and keeps it"
        ) { app in
            try await app.openFromQueue(testPR)
            // Maser won't post until it has shown which account it posts as.
            try await app.waitUntil("the account is shown") { app.review?.postingAccount != nil }
            try app.overrideGH([
                .init(match: ["--method", "POST", "issues/\(testPR)/comments"], status: 0, stdout: "{}", stderr: nil)
            ])
            try await app.press("c")
            try await app.waitUntil("the comment box has focus") { app.responder == .editor }
            await app.type("Posted by a UI scenario.")
            try await app.press("cmd+enter")
            try await app.waitUntil("gh is asked to post the comment") {
                app.ghCalls.contains { $0.args.contains("body=Posted by a UI scenario.") && $0.args.contains("POST") }
            }
            try await app.waitUntil("the draft clears with no error") {
                app.review?.commentDraft == "" && app.review?.commentError == nil && app.review?.isPostingComment == false
            }

            try app.overrideGH([
                .init(
                    match: ["--method", "POST"], status: 1, stdout: nil,
                    stderr: "gh: Unable to create comment because issue is locked (HTTP 403)")
            ])
            try app.expect(app.responder == .editor, "the comment box keeps focus after posting", app.summary)
            await app.type("This one fails.")
            try await app.press("cmd+enter")
            try await app.waitUntil("the failure shows gh's message") {
                app.review?.commentError?.contains("issue is locked") == true
            }
            try app.expect(app.review?.commentDraft == "This one fails.", "the draft is kept", app.summary)
        }

        /// A failing search shows its error and keeps its PRs; the other sections still update.
        static let queueSearchFails = UIScenario(
            "queue-search-fails", "REQ-QUE-004: A failed search keeps its last results and shows the error"
        ) { app in
            let before = app.probe.sections()
            try app.expect(before.count >= 2 && before.allSatisfy { $0.error == nil }, "every search loads", app.summary)
            let failing = before[before.count - 1]
            let searchesBefore = app.ghCalls.filter { $0.args.starts(with: ["search", "prs"]) }.count
            // Fail only the last section's search, by its last word.
            let word = failing.search.query.split(separator: " ").last.map(String.init) ?? ""
            try app.overrideGH([.init(match: ["search", word], status: 1, stdout: nil, stderr: "HTTP 502: Bad Gateway")])

            // The queue's r, not ⌘R: in the test app the Refresh menu item stays disabled (see the README).
            try await app.press("r")
            try await app.waitUntil("the failed search shows its error") {
                app.probe.sections().first { $0.id == failing.id }?.error?.contains("Bad Gateway") == true
            }
            let after = app.probe.sections()
            try app.expect(
                after.first { $0.id == failing.id }?.prs == failing.prs, "it keeps the PRs it found before", app.summary)
            try app.expect(
                after.filter { $0.id != failing.id }.allSatisfy { $0.error == nil && $0.prs?.isEmpty == false },
                "the other sections still show their PRs", app.summary)
            let searchesAfter = app.ghCalls.filter { $0.args.starts(with: ["search", "prs"]) }.count
            try app.expect(
                searchesAfter - searchesBefore == before.count, "every section searched again",
                "\(searchesAfter - searchesBefore)")
        }

        /// Long lines wrap inside their own row, so every line's text is drawn in full and none is hidden under another.
        static let longLinesWrap = UIScenario(
            "long-lines-wrap", "REQ-DIF-009: Wrapped diff lines stay in their rows; no line's text overlaps another's"
        ) { app in
            try await app.openFromQueue(designDocsPR)
            try await app.press("g f")
            try await app.waitUntil("the Files tab shows a file") { app.review?.selectedFile != nil }
            // The design docs are Markdown with long lines; check the first few files.
            for index in 1...3 {
                await app.pause(.milliseconds(500))
                let path = app.review?.selectedPath ?? ""
                let rows = LayoutProbe.rowFrames.filter { $0.key.hasPrefix("\(path)#") }
                var wrapped = 0
                var outside: [String] = []
                for (key, row) in rows {
                    guard let text = LayoutProbe.textFrames[key] else { continue }
                    // One line of 12 pt monospaced text is about 15 pt tall.
                    if text.height > 24 { wrapped += 1 }
                    if text.minY < row.minY - 0.5 || text.maxY > row.maxY + 0.5 {
                        outside.append("\(key): text \(text.minY)–\(text.maxY), row \(row.minY)–\(row.maxY)")
                    }
                }
                app.step("\(path): \(rows.count) rows, \(wrapped) wrapped")
                try app.expect(rows.count > 10 && wrapped > 0, "file \(index) has wrapped lines to check", path)
                try app.expect(
                    outside.isEmpty, "every line's text is inside its row in \(path)", outside.prefix(3).joined(separator: "; "))
                try await app.press("]")
            }
        }

        /// A push after the diff loaded stops line comments and reviews from posting, until the diff is refreshed.
        static let headMovedBlocksPosting = UIScenario(
            "head-moved-blocks-posting",
            "REQ-CMT-007: After a push, a line comment or review isn't posted; after a refresh it's placed on the new diff"
        ) { app in
            try await app.openFromQueue(testPR)
            try await app.waitUntil("the diff loads with its commit") { app.review?.diffCommitID != nil }
            let seen = app.review?.diffCommitID ?? ""
            // Someone pushes: from now on GitHub reports a different head.
            let pushed = String(repeating: "1", count: 40)
            let movedHead = UIScenarioDriver.GHOverride(
                match: ["number=\(testPR)", "headRefOid"], status: 0,
                stdout:
                    #"{"data":{"viewer":{"login":"\#(app.review?.postingAccount ?? "")"},"repository":{"pullRequest":{"id":"PR_kwDOVeiRMs8AAAABMJbuaw","headRefOid":"\#(pushed)","reviews":{"nodes":[]}}}}}"#,
                stderr: nil)
            try app.overrideGH([movedHead])
            let mutations = { app.ghCalls.filter { $0.args.contains { $0.contains("mutation") } } }

            try await app.press("g f")
            try await app.waitUntil("the Files tab shows a file") { app.review?.selectedFile != nil }
            for _ in 0..<3 { try await app.press("j") }
            try await app.press("c")
            try await app.waitUntil("the line comment box has focus") { app.responder == .editor }
            await app.type("Pinned.")
            try await app.press("cmd+enter")
            try await app.waitUntil("the comment is refused because the head moved") {
                app.review?.inlineDraft?.error?.contains("New commits were pushed") == true
            }
            try app.expect(app.review?.inlineDraft?.body == "Pinned.", "the comment's text is kept", app.summary)
            try app.expect(mutations().isEmpty, "nothing was sent to GitHub", "\(mutations().map(\.args))")

            try await app.press("esc")
            try await app.press("S")
            try await app.waitUntil("Finish Review opens") { app.review?.isFinishingReview == true }
            await app.type("Summary.")
            try await app.press("cmd+enter")
            try await app.waitUntil("the review is refused because the head moved, with a refresh offered") {
                app.review?.reviewError?.contains("New commits were pushed") == true && app.review?.reviewHeadMoved == true
            }
            try app.expect(mutations().isEmpty, "nothing was sent to GitHub", "\(mutations().map(\.args))")
            try await app.press("esc")
            try await app.waitUntil("the sheet closes") { app.review?.isFinishingReview == false }

            try await app.press("r")
            try await app.waitUntil("the refresh loads the new head") { app.review?.diffCommitID == pushed }
            try app.expect(
                app.review?.inlineDraft?.error == ReviewModel.placeAgainMessage, "the comment asks to be placed again",
                app.summary)
            try app.overrideGH([
                movedHead,
                UIScenarioDriver.GHOverride(
                    match: ["addPullRequestReviewThread("], status: 0, stdout: "PRRT_scenario\n", stderr: nil),
                UIScenarioDriver.GHOverride(match: ["addPullRequestReview("], status: 0, stdout: "PRR_scenario\n", stderr: nil),
            ])
            try await app.press("c")
            try app.expect(app.review?.inlineDraft?.error == nil, "c places it on the new diff", app.summary)
            try await app.waitUntil("the line comment box has focus") { app.responder == .editor }
            try await app.press("cmd+enter")
            try await app.waitUntil("the comment posts") { app.review?.inlineDraft == nil }
            let started = mutations().first { $0.args.contains { $0.contains("addPullRequestReview(") } }
            try app.expect(
                started?.args.contains("commit=\(pushed)") == true && seen != pushed,
                "the review starts pinned to the new head", "\(started?.args ?? [])")
        }

        /// Everything that posts names the account, Finish Review names the PR, and a switched account isn't posted as
        /// until it has been shown.
        static let namesPRAndAccount = UIScenario(
            "names-pr-and-account",
            "REQ-CMT-009: Comment boxes and Finish Review name the account and PR; a switched account is shown before posting"
        ) { app in
            try await app.openFromQueue(testPR)
            try await app.waitUntil("the account and diff are loaded") {
                app.review?.postingAccount != nil && app.review?.diffCommitID != nil
            }
            guard let review = app.review, let account = review.postingAccount, let head = review.diffCommitID else {
                throw UIScenarioFailure(description: "no review")
            }
            try await app.press("c")
            try await app.waitUntil("the comment box has focus") { app.responder == .editor }
            await app.type("Hello.")
            try app.expect(
                ShownText.values["comment-button"] == "Comment as @\(account)", "the Comment button names the account",
                "\(ShownText.values)")

            // `gh auth switch` to another account while Maser is open.
            let other = "someone-else"
            let switched = UIScenarioDriver.GHOverride(
                match: ["number=\(testPR)", "headRefOid"], status: 0,
                stdout:
                    #"{"data":{"viewer":{"login":"\#(other)"},"repository":{"pullRequest":{"id":"\#(review.reviewContext?.pullRequestID ?? "")","headRefOid":"\#(head)","reviews":{"nodes":[]}}}}}"#,
                stderr: nil)
            try app.overrideGH([switched])
            let posts = { app.ghCalls.filter { $0.args.contains("POST") } }
            try await app.press("cmd+enter")
            try await app.waitUntil("the post is refused, naming both accounts") {
                review.commentError?.contains("@\(other), not @\(account)") == true
            }
            try app.expect(posts().isEmpty, "nothing was posted", "\(posts().map(\.args))")
            try app.expect(review.commentDraft == "Hello.", "the text is kept", app.summary)
            try app.expect(
                ShownText.values["comment-button"] == "Comment as @\(other)", "the Comment button now names the new account",
                "\(ShownText.values)")

            try app.overrideGH([
                switched,
                .init(match: ["--method", "POST", "issues/\(testPR)/comments"], status: 0, stdout: "{}", stderr: nil),
            ])
            try await app.press("cmd+enter")
            try await app.waitUntil("posting again posts as the account shown") {
                review.commentDraft == "" && review.commentError == nil && posts().count == 1
            }

            try await app.press("esc")
            try await app.press("g f")
            try await app.waitUntil("the Files tab shows a file") { review.selectedFile != nil }
            for _ in 0..<3 { try await app.press("j") }
            try await app.press("c")
            try await app.waitUntil("the line comment's button names the account") {
                ShownText.values["inline-post-button"] == "Start a review as @\(other)"
            }
            try await app.press("esc")
            try await app.press("S")
            try await app.waitUntil("Finish Review opens") { review.isFinishingReview }
            let names = "\(review.pr.repository.nameWithOwner) #\(review.pr.number): \(review.pr.title)"
            try await app.waitUntil("Finish Review names the PR and the account") {
                ShownText.values["finish-review-pr"] == names
                    && ShownText.values["finish-review-account"] == "Posting as @\(other)"
            }
            try await app.press("esc")
        }

        /// Text typed but not posted comes back after a crash, and posting it clears what was kept.
        static let draftSurvivesRelaunch = UIScenario(
            "draft-survives-relaunch",
            "REQ-CMT-008: An unsent comment, line comment and review summary survive a crash, and posting clears them"
        ) { app in
            let comment = "Unsent comment."
            let lineComment = "Unsent line comment."
            let summary = "Unsent summary."
            if !app.relaunched {
                try await app.openFromQueue(testPR)
                try await app.waitUntil("the diff loads") { app.review?.diffCommitID != nil }
                try await app.press("c")
                try await app.waitUntil("the comment box has focus") { app.responder == .editor }
                await app.type(comment)
                try await app.press("esc")
                try await app.press("g f")
                try await app.waitUntil("the Files tab shows a file") { app.review?.selectedFile != nil }
                for _ in 0..<3 { try await app.press("j") }
                try await app.press("c")
                try await app.waitUntil("the line comment box has focus") { app.responder == .editor }
                await app.type(lineComment)
                try await app.press("esc")
                try await app.press("S")
                try await app.waitUntil("Finish Review opens") { app.review?.isFinishingReview == true }
                await app.type(summary)
                try await app.press("esc")
                try await app.waitUntil("the sheet closes") { app.review?.isFinishingReview == false }
                app.crash()
            }

            try await app.openFromQueue(testPR)
            guard let review = app.review else { throw UIScenarioFailure(description: "no review") }
            try app.expect(review.commentDraft == comment, "the conversation comment is back", app.summary)
            try app.expect(review.reviewSummary == summary, "the review summary is back", app.summary)
            guard let draft = review.inlineDraft, case .newThread = draft.target else {
                throw UIScenarioFailure(description: "the line comment didn't come back: \(app.summary)")
            }
            try app.expect(draft.body == lineComment, "the line comment's text is back", draft.body)
            try await app.waitUntil("the diff loads") { review.diffCommitID != nil && review.postingAccount != nil }
            try app.expect(
                review.inlineDraft?.error == nil, "the line comment is still placed, since nothing was pushed",
                review.inlineDraft?.error ?? "")

            try app.overrideGH([
                .init(match: ["--method", "POST", "issues/\(testPR)/comments"], status: 0, stdout: "{}", stderr: nil)
            ])
            try await app.press("c")
            try await app.waitUntil("the comment box has focus") { app.responder == .editor }
            try await app.press("cmd+enter")
            try await app.waitUntil("the comment posts") { review.commentDraft == "" && review.commentError == nil }
            let kept = try ReviewModel.unsentStore.load(for: review.pr)
            try app.expect(
                kept == UnsentText(lineComment: draft.unsent, reviewSummary: summary),
                "only the posted comment is cleared from what's kept", "\(kept)")
        }

        /// A PR that drops out of the queue on a refresh, as a merged one does, closes, unless it has unsent text.
        static let closedPRLeavesPane = UIScenario(
            "closed-pr-leaves-pane",
            "REQ-WIN-008: A PR that leaves the queue closes and the queue gets the keys; with unsent text it stays, with a note"
        ) { app in
            let all = app.queuePRs
            /// Makes every queue search find just these PRs.
            func searchesFind(_ numbers: Set<Int>) throws -> UIScenarioDriver.GHOverride {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let prs = all.filter { !numbers.contains($0.number) }
                return .init(
                    match: ["search", "prs"], status: 0, stdout: String(decoding: try encoder.encode(prs), as: UTF8.self),
                    stderr: nil)
            }

            try await app.openFromQueue(smallPR)
            try app.overrideGH([try searchesFind([smallPR])])
            try await app.press("cmd+0")
            try await app.press("r")
            try await app.waitUntil("the PR's review closes and the queue has the keys") {
                app.review == nil && app.state.queueHasKeys && !app.queuePRs.contains { $0.number == smallPR }
            }

            try await app.openFromQueue(mainPR)
            try await app.press("c")
            try await app.waitUntil("the comment box has focus") { app.responder == .editor }
            await app.type("Not posted yet.")
            try await app.press("esc")
            try app.overrideGH([try searchesFind([smallPR, mainPR])])
            try await app.press("cmd+0")
            try await app.press("r")
            try await app.waitUntil("the review stays, saying it left the queue") {
                ShownText.values["left-queue"] == ReviewView.leftQueueNote
            }
            try app.expect(
                app.review?.pr.number == mainPR && app.review?.commentDraft == "Not posted yet."
                    && !app.queuePRs.contains { $0.number == mainPR },
                "with its text, though the queue dropped it", app.summary)
        }

        /// Going back to a PR finds it as it was left, without reloading it.
        static let switchPRsKeepsState = UIScenario(
            "switch-prs-keeps-state", "REQ-WIN-001: Going back to a PR keeps its tab, file, cursor and draft"
        ) { app in
            try await app.openFromQueue(mainPR)
            try await app.press("c")
            try await app.waitUntil("the comment box has focus") { app.responder == .editor }
            await app.type("Unsent draft")
            try await app.press("esc")
            try await app.press("g f")
            try await app.waitUntil("the Files tab shows a file") { app.review?.selectedFile != nil }
            try await app.press("]")
            for _ in 0..<4 { try await app.press("j") }
            let path = app.review?.selectedPath
            let cursor = app.review?.cursorLineID
            try app.expect(path != nil && cursor != nil, "a file and line are selected", app.summary)
            let loads = app.ghCalls.filter { $0.args.contains("number=\(mainPR)") }.count

            try await app.openFromQueue(smallPR)
            try await app.openFromQueue(mainPR)
            try app.expect(app.review?.tab == .files, "the Files tab is still showing", app.summary)
            try app.expect(app.review?.selectedPath == path, "the same file is selected", app.summary)
            try app.expect(app.review?.cursorLineID == cursor, "the cursor is on the same line", app.summary)
            try app.expect(app.review?.commentDraft == "Unsent draft", "the draft is still there", app.summary)
            try app.expect(
                app.ghCalls.filter { $0.args.contains("number=\(mainPR)") }.count == loads,
                "it wasn't reloaded, since its data is under 60 s old", app.summary)
        }
    }
#endif
