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
            draftSurvivesRelaunch, closedPRLeavesPane, agentConversation, agentOffUntilAllowed, agentFollowsHead,
            canvasShowsDiagram, canvasRejectsScript, canvasFollowsCitation, agentCommentsMarked, ghTimesOut,
            reviewRequestedClear, reviewRequestedFails, reviewRequestedOff, focusNextReview,
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

        /// Adds the built-in Review requested search to the queue, answered by the fake `gh` as given.
        ///
        /// The test config leaves the section out, and it has no recording, so each scenario supplies its answer.
        ///
        /// - Parameters:
        ///   - app: The scenario's app.
        ///   - answer: The fake `gh`'s answer to the Review requested search.
        /// - Throws: `UIScenarioFailure` if the fake `gh` can't be overridden.
        private static func addReviewRequested(_ app: UIScenarioDriver, answer: UIScenarioDriver.GHOverride) throws {
            try app.overrideGH([answer])
            // Changing the searches reloads the queue at once (REQ-QUE-005).
            ConfigStore.shared.overrideQueueSearches { $0.insert(.reviewRequested, at: 0) }
        }

        /// The Review requested section from the fake `gh`, as the queue loaded it.
        ///
        /// - Parameter app: The scenario's app.
        /// - Returns: The section, or `nil` if the queue doesn't have it.
        private static func reviewRequestedSection(_ app: UIScenarioDriver) -> QueueSection? {
            ReviewQueue.shared.sections?.first { $0.search == .reviewRequested }
        }

        /// An empty Review requested search congratulates in the detail column, and says when it was checked.
        static let reviewRequestedClear = UIScenario(
            "review-requested-clear", "REQ-QUE-008: An empty Review requested search congratulates, with when it was checked"
        ) { app in
            try app.expect(app.review == nil, "no review is open at launch", app.summary)
            try addReviewRequested(
                app, answer: .init(match: ["search", "review-requested:@me"], status: 0, stdout: "[]", stderr: nil))
            try await app.waitUntil("the Review requested search finds nothing") {
                reviewRequestedSection(app)?.prs == [] && reviewRequestedSection(app)?.error == nil
            }
            try await app.waitUntil("the congratulations shows") {
                ShownText.values["no-review-open"] == NoReviewOpenView.clearTitle
            }
            let checked = ShownText.values["no-review-checked"] ?? ""
            try app.expect(checked.hasPrefix("Checked at "), "it says when the queue was checked", checked)
            try app.expect(checked.contains("⌘O"), "it keeps the hint about ⌘O", checked)
            try app.expect(!app.queuePRs.isEmpty, "the other sections still list their PRs", app.summary)
            app.snapshot("review-requested-clear")
        }

        /// A failed Review requested search never congratulates, even when its last result was empty.
        static let reviewRequestedFails = UIScenario(
            "review-requested-fails", "REQ-QUE-008: A failed Review requested search doesn't congratulate"
        ) { app in
            try addReviewRequested(
                app, answer: .init(match: ["search", "review-requested:@me"], status: 0, stdout: "[]", stderr: nil))
            try await app.waitUntil("the congratulations shows while the search succeeds") {
                ShownText.values["no-review-open"] == NoReviewOpenView.clearTitle
            }

            try app.overrideGH([
                .init(match: ["search", "review-requested:@me"], status: 1, stdout: nil, stderr: "HTTP 502: Bad Gateway")
            ])
            // The queue's r, not ⌘R: in the test app the Refresh menu item stays disabled (see the README).
            try await app.press("r")
            try await app.waitUntil("the failed search shows its error") {
                reviewRequestedSection(app)?.error?.contains("Bad Gateway") == true
            }
            try app.expect(reviewRequestedSection(app)?.prs == [], "the section keeps its empty last result", app.summary)
            try await app.waitUntil("the usual message replaces the congratulations") {
                ShownText.values["no-review-open"] == NoReviewOpenView.noneOpenTitle
            }
        }

        /// With Review requested left out of the queue's sections, nothing congratulates.
        static let reviewRequestedOff = UIScenario(
            "review-requested-off", "REQ-QUE-008: Review requested turned off doesn't congratulate"
        ) { app in
            try app.expect(ReviewQueue.shared.sections != nil, "the queue has loaded", app.summary)
            try app.expect(reviewRequestedSection(app) == nil, "the test config leaves Review requested out", app.summary)
            try app.expect(app.review == nil, "no review is open", app.summary)
            try app.expect(
                ShownText.values["no-review-open"] == NoReviewOpenView.noneOpenTitle, "the usual message shows",
                ShownText.values["no-review-open"] ?? "nothing")
        }

        /// A `gh` that never answers is stopped, the user is told so, and trying again loads.
        static let ghTimesOut = UIScenario(
            "gh-times-out", "REQ-GH-007: A stalled gh call times out with a message, and trying again loads"
        ) { app in
            ConfigStore.shared.overrideGHTimeout(seconds: 2)
            let failing = app.probe.sections()[0]
            let word = failing.search.query.split(separator: " ").last.map(String.init) ?? ""
            try app.overrideGH([.init(match: ["search", word], status: 0, stdout: "[]", stderr: nil, delaySeconds: 60)])

            try await app.press("r")
            try await app.waitUntil("the stalled search times out") {
                app.probe.sections().first { $0.id == failing.id }?.error?.contains("within 2 seconds") == true
            }
            try app.expect(!ReviewQueue.shared.isLoading, "the queue stops loading", app.summary)
            try app.expect(
                app.probe.sections().first { $0.id == failing.id }?.prs == failing.prs, "it keeps the PRs it found before",
                app.summary)

            try app.overrideGH([])
            try await app.press("r")
            try await app.waitUntil("trying again loads the search") {
                app.probe.sections().first { $0.id == failing.id }?.error == nil && !ReviewQueue.shared.isLoading
            }

            // A diff gets twice the timeout.
            try app.overrideGH([.init(match: ["pr", "diff"], status: 0, stdout: "", stderr: nil, delaySeconds: 60)])
            try await app.openFromQueue(smallPR)
            try await app.press("g f")
            try await app.waitUntil("the stalled diff times out") {
                if case let .failed(message) = app.review?.filesState { return message.contains("within 4 seconds") }
                return false
            }
            try app.expect(
                ShownText.values["files-failed"]?.contains("Check your network, then try again") == true,
                "the Files tab says to try again", ShownText.values["files-failed"] ?? "nothing shown")

            try app.overrideGH([])
            try await app.press("r")
            try await app.waitUntil("trying again loads the diff") {
                if case .loaded = app.review?.filesState { return app.review?.selectedFile != nil }
                return false
            }
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

        /// The queue focuses the first PR waiting for review at launch, on a refresh and after a submit, but not while
        /// the user works in a review or has unsent text.
        static let focusNextReview = UIScenario(
            "focus-next-review",
            "REQ-QUE-009: The first review-requested PR is focused at launch, on a refresh and after a submit, not mid-review"
        ) { app in
            /// Makes the Review requested search find the test PR, updated most recently, and two recorded PRs.
            @MainActor func reviewRequested() throws -> UIScenarioDriver.GHOverride {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let prs = app.queuePRs.filter { [testPR, smallPR, mainPR].contains($0.number) }
                var objects = try JSONSerialization.jsonObject(with: try encoder.encode(prs)) as? [[String: Any]] ?? []
                for index in objects.indices where objects[index]["number"] as? Int == testPR {
                    objects[index]["updatedAt"] = Date.now.ISO8601Format()
                }
                return .init(
                    match: ["search", "prs", "review-requested:@me"], status: 0,
                    stdout: String(decoding: try JSONSerialization.data(withJSONObject: objects), as: UTF8.self),
                    stderr: nil)
            }

            if !app.relaunched {
                // The scenarios' config has no Review requested section, since there's no recording for it. Add one,
                // answered by the fake gh, and launch again so the launch itself is checked.
                try app.overrideGH([try reviewRequested()])
                let url = ConfigStore.shared.fileURL
                let config = try String(contentsOf: url, encoding: .utf8)
                try app.expect(config.contains("sections = []"), "the config lists no built-in sections", config)
                try config.replacing("sections = []", with: #"sections = ["review-requested"]"#)
                    .write(to: url, atomically: true, encoding: .utf8)
                app.crash()
            }

            let waiting = app.probe.sections().first { $0.search == .reviewRequested }?.prs?.map(\.number) ?? []
            try app.expect(
                waiting.count == 3 && waiting[0] == testPR, "Review requested lists the test PR first, then two more",
                "\(waiting)")
            let second = waiting[1]
            try await app.waitUntil("at launch the first PR is selected and shown, and the queue has the keys") {
                app.selectedNumbers == [testPR] && app.state.queueHasKeys && app.review?.pr.number == testPR
            }

            try await app.press("j")
            try await app.press("j")
            try await app.waitUntil("j moves on") { app.review?.pr.number == waiting[2] }
            try await app.press("r")
            try await app.waitUntil("a refresh with the queue holding the keys goes back to the first PR") {
                app.selectedNumbers == [testPR] && app.review?.pr.number == testPR && app.state.queueHasKeys
            }

            /// Refreshes the queue, with `r` or as a window opening or a config change would, and waits for the load.
            @MainActor func refreshQueue(pressingR: Bool) async throws {
                let loads = ReviewQueue.shared.loads
                if pressingR { try await app.press("r") } else { await ReviewQueue.shared.refresh() }
                try await app.waitUntil("the queue reloads") { ReviewQueue.shared.loads > loads }
                await app.pause(.milliseconds(500))
            }

            try await app.press("j")
            try await app.press("enter")
            try await app.waitUntil("Return opens the second PR with the keys") {
                app.review?.pr.number == second && !app.state.queueHasKeys
            }
            try await refreshQueue(pressingR: false)
            try app.expect(
                app.selectedNumbers == [second] && app.review?.pr.number == second && !app.state.queueHasKeys,
                "a refresh leaves a review with the keys alone", app.summary)

            try await app.press("c")
            try await app.waitUntil("the comment box has focus") { app.responder == .editor }
            await app.type("Not posted yet.")
            try await app.press("esc")
            try await app.press("cmd+0")
            try await refreshQueue(pressingR: true)
            try app.expect(
                app.selectedNumbers == [second] && app.review?.pr.number == second && app.state.queueHasKeys,
                "nor, with the queue holding the keys, one with unsent text", app.summary)

            try await app.press("g g")
            try await app.press("enter")
            try await app.waitUntil("Return opens the test PR, and its diff loads") {
                app.review?.pr.number == testPR && app.review?.diffCommitID != nil && !app.state.queueHasKeys
            }
            try app.overrideGH([
                try reviewRequested(),
                .init(match: ["addPullRequestReview("], status: 0, stdout: "PRR_scenario\n", stderr: nil),
                .init(match: ["submitPullRequestReview"], status: 0, stdout: "{}", stderr: nil),
            ])
            let loads = ReviewQueue.shared.loads
            try await app.press("S")
            try await app.waitUntil("Finish Review opens") { app.review?.isFinishingReview == true }
            await app.type("Reviewed.")
            try await app.press("cmd+enter")
            try await app.waitUntil("after submitting, the next PR is focused and shown, with the queue holding the keys") {
                app.selectedNumbers == [second] && app.review?.pr.number == second && app.state.queueHasKeys
            }
            try await app.waitUntil("the queue refreshes, still listing the reviewed PR") {
                ReviewQueue.shared.loads > loads && !ReviewQueue.shared.isLoading
            }
            await app.pause(.milliseconds(500))
            try app.expect(
                app.selectedNumbers == [second] && app.review?.pr.number == second,
                "the refresh doesn't go back to the PR just reviewed", app.summary)
        }

        /// Opens the test PR's Agent tab, once its diff and account have loaded.
        ///
        /// - Parameter app: The driver.
        /// - Returns: The PR's review.
        /// - Throws: `UIScenarioFailure` if the PR or the tab doesn't open.
        private static func openAgent(_ app: UIScenarioDriver) async throws -> ReviewModel {
            try await app.openFromQueue(testPR)
            guard let review = app.review else { throw UIScenarioFailure(description: "no review") }
            try await app.waitUntil("the diff loads") { review.diffCommitID != nil }
            try await app.press("g a")
            try app.expect(review.tab == .agent, "g a shows the Agent tab", app.summary)
            guard review.agent.allowRule != nil else {
                try app.expect(!review.agent.focusRequest, "with the agent off, g a leaves no focus request", app.summary)
                return review
            }
            try await app.waitUntil("g a focuses the message box") { app.responder == .editor }
            await app.type("x")
            try app.expect(review.agent.draft == "x", "typing goes into the box", review.agent.draft)
            review.agent.draft = ""
            // Leave the box, so the scenario's keys reach the tab.
            try await app.press("esc")
            try await app.waitUntil("Esc leaves the box") { app.responder != .editor }
            return review
        }

        /// Sends a message from the Agent tab's box and waits for the turn to end.
        ///
        /// - Parameters:
        ///   - app: The driver.
        ///   - review: The PR's review.
        ///   - message: The message.
        /// - Throws: `UIScenarioFailure` if the box doesn't focus or the turn doesn't end.
        private static func ask(_ app: UIScenarioDriver, _ review: ReviewModel, _ message: String) async throws {
            let ends = review.agent.transcript.entries.count { if case .turnEnded = $0 { true } else { false } }
            try await app.press("c")
            try await app.waitUntil("c focuses the message box") { app.responder == .editor }
            await app.type(message)
            try await app.press("cmd+enter")
            try await app.waitUntil("the agent answers \"\(message)\"", timeout: .seconds(20)) {
                review.agent.status == .idle
                    && review.agent.transcript.entries.count { if case .turnEnded = $0 { true } else { false } } == ends + 1
            }
            try await app.press("esc")
        }

        /// The conversation reaches Maser's tools through the real helper, shows every call and refusal, keeps its cost,
        /// uses the chosen effort, and carries on after a crash.
        static let agentConversation = UIScenario(
            "agent-conversation",
            "REQ-AGT-001, REQ-AGT-002, REQ-AGT-009, REQ-AGT-010, REQ-AGT-011: A conversation with tool calls, refusals, cost, effort, and a relaunch"
        ) { app in
            let review = try await openAgent(app)
            let agent = review.agent
            if app.relaunched {
                try app.expect(agent.transcript.entries.count >= 6, "the conversation is back after the crash", app.summary)
                guard let session = agent.transcript.sessionID else {
                    throw UIScenarioFailure(description: "no session to resume: \(app.summary)")
                }
                try await ask(app, review, "still there?")
                try app.expect(
                    app.claudeStarts.last.map { $0.contains("--resume") && $0.contains(session) } == true,
                    "the next message resumes the same session", "\(app.claudeStarts.last ?? [])")
                return
            }
            let head = review.diffCommitID ?? ""
            try await app.waitUntil("the tab says what the agent reads") {
                ShownText.values["agent-scope"]?.hasPrefix("Reads bmannakee/maser at \(head.prefix(7)), read-only") == true
            }

            try await ask(app, review, "Please call pr_context")
            let tools = agent.transcript.entries.compactMap { if case let .tool(use) = $0 { use } else { nil } }
            try app.expect(
                tools.first?.name == "mcp__maser__pr_context" && tools.first?.isError == false
                    && tools.first?.result?.contains("bmannakee/maser #1") == true,
                "pr_context went through the helper to Maser and back", "\(tools)")
            let answer = agent.transcript.entries.compactMap { if case let .agent(text) = $0 { text } else { nil } }.last
            try app.expect(answer?.hasPrefix("Read the PR: # bmannakee/maser #1") == true, "the answer is shown", answer ?? "")
            try app.expect(ShownText.values["agent-cost"] == "$0.01", "the cost is shown", "\(ShownText.values)")
            let first = app.claudeStarts.first ?? []
            let confining = ["--permission-mode", "dontAsk", "--setting-sources", "user", "--strict-mcp-config"]
            try app.expect(
                confining.allSatisfy(first.contains) && !first.contains("--resume") && !first.contains("--effort"),
                "claude ran with the confining flags, no resume and no effort set", "\(first)")

            try await ask(app, review, "read something outside")
            let refused = agent.transcript.entries.compactMap { if case let .tool(use) = $0 { use } else { nil } }.last
            try app.expect(
                refused?.name == "Read" && refused?.isRefused == true, "the refusal is shown", "\(String(describing: refused))")

            agent.setEffort(.max)
            try await app.waitUntil("the tab shows the effort chosen") { ShownText.values["agent-effort"] == "max" }
            try await ask(app, review, "hello again")
            let restart = app.claudeStarts.last ?? []
            try app.expect(
                app.claudeStarts.count == 2 && restart.contains("--effort") && restart.contains("max")
                    && restart.contains(agent.transcript.sessionID ?? "?"),
                "a new effort restarts claude, resuming the session", "\(app.claudeStarts)")
            try app.expect(
                ShownText.values["agent-cost"] == "$0.03", "the cost carries on across the restart", "\(ShownText.values)")
            app.crash()
        }

        /// The agent stays off for a PR whose owner isn't allowed, and says how to allow it.
        static let agentOffUntilAllowed = UIScenario(
            "agent-off-until-allowed", "REQ-AGT-005: The Agent tab is off until [agent] allow names the owner, and says so"
        ) { app in
            ConfigStore.shared.overrideAgentSettings { $0.allow = [] }
            _ = try await openAgent(app)
            try await app.waitUntil("the tab says the agent is off, and how to allow it") {
                ShownText.values["agent-off"]?.hasPrefix("To let it read this PR, add \"bmannakee\" to [agent] allow") == true
            }
            try await app.press("c")
            try app.expect(app.claudeLog.isEmpty, "claude was never started", "\(app.claudeLog)")

            ConfigStore.shared.overrideAgentSettings { $0.allow = ["bmannakee"].compactMap(AgentSettings.AllowRule.init) }
            try await app.waitUntil("allowing the owner turns it on") { ShownText.values["agent-scope"] != nil }
        }

        /// After a push, the conversation is marked as about the older commit, and the next message moves the agent on.
        static let agentFollowsHead = UIScenario(
            "agent-follows-head",
            "REQ-AGT-006: After a push, the conversation is marked as older, and the next message moves the agent to the new head"
        ) { app in
            let review = try await openAgent(app)
            try await ask(app, review, "first")
            let seen = review.diffCommitID ?? ""
            let pushed = String(repeating: "2", count: 40)
            try app.overrideGH([
                .init(
                    match: ["number=\(testPR)", "headRefOid"], status: 0,
                    stdout:
                        #"{"data":{"viewer":{"login":"\#(review.postingAccount ?? "")"},"repository":{"pullRequest":{"id":"\#(review.reviewContext?.pullRequestID ?? "")","headRefOid":"\#(pushed)","reviews":{"nodes":[]}}}}}"#,
                    stderr: nil)
            ])
            try await app.press("r")
            try await app.waitUntil("the refresh finds the new head") { review.diffCommitID == pushed }
            try await app.waitUntil("the conversation is marked as about the older commit") {
                ShownText.values["agent-stale"]?.hasPrefix("This conversation is about \(seen.prefix(7))") == true
            }
            try await ask(app, review, "and now?")
            try app.expect(
                app.claudeMessages.last?.hasPrefix("[Maser: the PR's head commit changed from \(seen) to \(pushed)") == true,
                "the agent is told the head moved", app.claudeMessages.last ?? "")
            try app.expect(
                app.claudeStarts.count == 2 && app.claudeStarts.last?.contains("--resume") == true,
                "claude restarted on the new commit, resuming the session", "\(app.claudeStarts)")
            try app.expect(
                !review.agent.isStale && review.agent.transcript.commit == pushed, "the conversation is now about the new head",
                app.summary)
        }

        /// A diagram from the agent is rendered, labeled as the agent's with its commit, and checked; the flagged element
        /// is outlined and listed, and the agent is told.
        static let canvasShowsDiagram = UIScenario(
            "canvas-shows-diagram",
            "REQ-CNV-001, REQ-CNV-004, REQ-CNV-005: A diagram is drawn, labeled as the agent's at its commit, and checked"
        ) { app in
            let review = try await openAgent(app)
            let agent = review.agent
            try await ask(app, review, "draw the door")
            guard let drawn = agent.transcript.diagrams.last else {
                throw UIScenarioFailure(description: "no diagram: \(agent.transcript.entries)")
            }
            let head = review.diffCommitID ?? ""
            try await app.waitUntil("the canvas shows it, labeled as the agent's at the commit") {
                ShownText.values["canvas-title"] == "Door (fake)"
                    && ShownText.values["canvas-label"]?.hasPrefix("Drawn by the agent at \(head.prefix(7)).") == true
            }
            try app.expect(
                drawn.svg.contains(#"data-id="closed""#)
                    && drawn.svg.contains(#"[data-id="edge2"] :is(rect,ellipse,circle,polygon,path) { stroke-dasharray"#)
                    && !drawn.svg.contains("<script"),
                "the SVG has the elements, with the flagged one outlined", String(drawn.svg.prefix(300)))
            try app.expect(
                drawn.flagged.map(\.id) == ["edge2"] && ShownText.values["canvas-flags"] == "3 elements; 1 flagged",
                "only the element citing lines the PR doesn't change is flagged", "\(drawn.findings)")
            let reply = agent.transcript.entries.compactMap { if case let .tool(use) = $0 { use } else { nil } }.last
            try app.expect(
                reply?.result?.contains("Maser flagged these elements") == true && reply?.isError == false,
                "the agent is told what was flagged", reply?.result ?? "")
            try app.expect(
                review.tab == .agent && review.overview != nil && review.pendingCommentCount == 0,
                "drawing changed no review state", app.summary)
            app.snapshot("canvas")
        }

        /// A diagram that could act or reach out is refused before it renders, and the agent is told why.
        static let canvasRejectsScript = UIScenario(
            "canvas-rejects-script", "REQ-CNV-002: A diagram with a click handler is refused, and nothing is drawn"
        ) { app in
            let review = try await openAgent(app)
            try await ask(app, review, "draw unsafe")
            let call = review.agent.transcript.entries.compactMap { if case let .tool(use) = $0 { use } else { nil } }.last
            try app.expect(
                call?.name == "mcp__maser__show_diagram" && call?.isError == true
                    && call?.result?.contains("can't use click") == true,
                "the call is refused with the reason", "\(String(describing: call))")
            try app.expect(review.agent.transcript.diagrams.isEmpty, "nothing was drawn", app.summary)
        }

        /// Keys move through diagrams and elements; Return opens an element's lines, in the Files tab when they're in the
        /// diff and read-only from the checkout when they're not.
        static let canvasFollowsCitation = UIScenario(
            "canvas-follows-citation",
            "REQ-CNV-003, REQ-CNV-006: Keys choose a diagram and element, and Return opens its lines in the diff or the checkout"
        ) { app in
            let review = try await openAgent(app)
            let agent = review.agent
            try await ask(app, review, "draw the door")
            try await ask(app, review, "draw it again")
            try app.expect(agent.transcript.diagrams.count == 2, "two diagrams", app.summary)
            try await app.press("[")
            try app.expect(agent.shownDiagram?.id == agent.transcript.diagrams.first?.id, "[ shows the older one", app.summary)
            try await app.press("]")
            try app.expect(agent.shownDiagram?.id == agent.transcript.diagrams.last?.id, "] the newer one", app.summary)

            // The third element cites COMMENT-TEST.md:3, a line PR #1 adds.
            for _ in 0..<3 { try await app.press("j") }
            try app.expect(agent.selectedElement == 2, "j moves through the elements", app.summary)
            try await app.press("enter")
            try await app.waitUntil("Return opens the cited line in the Files tab") {
                review.tab == .files && review.selectedPath == "COMMENT-TEST.md"
                    && review.cursorLineID.flatMap { review.selectedFile?.line(withID: $0)?.newLine } == 3
            }

            // The first cites Sources/Door.swift:2, which isn't in the diff.
            try await app.press("g a")
            try await app.waitUntil("g a focuses the message box") { app.responder == .editor }
            try await app.press("esc")
            try await app.press("k")
            try await app.press("k")
            try app.expect(agent.selectedElement == 0, "k moves back", app.summary)
            try await app.press("enter")
            try await app.waitUntil("Return opens lines outside the diff from the checkout") {
                ShownText.values["citation-title"] == "Sources/Door.swift:2-2" && agent.openedCitation != nil
            }
            try await app.press("esc")
            try await app.waitUntil("Esc closes it") { agent.openedCitation == nil }

            try await app.press("i")
            try app.expect(!agent.showsCanvas, "i hides the canvas", app.summary)
            try await app.press("i")
            try app.expect(agent.showsCanvas, "and shows it again", app.summary)
        }

        /// The agent's comment goes into the pending review, pinned to the commit and saying an agent drafted it; it's
        /// badged, and Finish Review asks before submitting it until the user has opened it.
        static let agentCommentsMarked = UIScenario(
            "agent-comments-marked",
            "REQ-AGT-007: The agent's comment is posted with its attribution, badged, and asked about until it's opened"
        ) { app in
            let review = try await openAgent(app)
            try await app.waitUntil("the account is shown") { review.postingAccount != nil }
            let account = review.postingAccount ?? ""
            let head = review.diffCommitID ?? ""
            let body = AgentComment.body("Is this file meant to stay?", model: "claude-opus-5-5")
            // After posting, GitHub returns the agent's comment as the viewer's pending draft.
            let thread: [String: Any] = [
                "id": "PRRT_agent", "path": "COMMENT-TEST.md", "line": 3, "startLine": NSNull(), "originalLine": 3,
                "diffSide": "RIGHT", "isOutdated": false, "isResolved": false,
                "comments": [
                    "nodes": [
                        [
                            "id": "PRRC_agent", "author": ["login": account], "body": body, "createdAt": "2026-11-12T12:00:00Z",
                            "url": NSNull(), "state": "PENDING",
                        ]
                    ]
                ],
            ]
            let threads = String(decoding: try JSONSerialization.data(withJSONObject: thread), as: UTF8.self)
            try app.overrideGH([
                .init(match: ["addPullRequestReview("], status: 0, stdout: "PRR_scenario\n", stderr: nil),
                .init(match: ["addPullRequestReviewThread("], status: 0, stdout: "PRRT_agent\n", stderr: nil),
                .init(match: ["reviewThreads(first"], status: 0, stdout: threads + "\n", stderr: nil),
                .init(match: ["submitPullRequestReview"], status: 0, stdout: "{}", stderr: nil),
            ])

            try await ask(app, review, "please comment on the new file")
            let call = review.agent.transcript.entries.compactMap { if case let .tool(use) = $0 { use } else { nil } }.last
            try app.expect(
                call?.name == "mcp__maser__add_review_comment" && call?.isError == false
                    && call?.result?.hasPrefix("Added to the user's pending review on COMMENT-TEST.md") == true,
                "the agent's comment is added", "\(String(describing: call))")
            let posted = app.ghCalls.first { $0.args.contains { $0.contains("addPullRequestReviewThread(") } }
            let started = app.ghCalls.first { $0.args.contains { $0.contains("addPullRequestReview(") } }
            try app.expect(
                posted?.args.contains("body=\(body)") == true && started?.args.contains("commit=\(head)") == true,
                "it's posted with the attribution, in a review pinned to the commit", "\(posted?.args ?? [])")
            try await app.waitUntil("the comment is the agent's, and unopened") {
                review.agentComments.map(\.id) == ["PRRC_agent"] && review.unopenedAgentComments.count == 1
            }

            try await app.press("S")
            try await app.waitUntil("Finish Review counts it") {
                ShownText.values["finish-review-pending"] == "1 draft comment, 1 drafted by the agent will be published."
            }
            try await app.press("cmd+enter")
            try await app.waitUntil("submitting asks first") { review.isConfirmingUnopenedAgentComments }
            await app.pause(.milliseconds(500))
            // Either submit mutation carries the verdict: submitPullRequestReview, or addPullRequestReview with an event.
            let submits = { app.ghCalls.filter { $0.args.contains { $0.contains("event: $event") } } }
            try app.expect(submits().isEmpty, "nothing was submitted", "\(submits().map(\.args))")
            // The question is a dialog on the sheet, which the driver's keys don't reach; answer Cancel for it.
            review.isConfirmingUnopenedAgentComments = false
            review.isFinishingReview = false
            try await app.waitUntil("the sheet closes") { !review.isFinishingReview }

            try await app.press("g f")
            try await app.press("n")
            try await app.waitUntil("n opens the agent's comment, which is badged") {
                review.unopenedAgentComments.isEmpty && ShownText.values["agent-badge"] == "PRRC_agent"
            }
            try await app.press("S")
            try await app.waitUntil("Finish Review opens") { review.isFinishingReview }
            try await app.press("cmd+enter")
            try await app.waitUntil("once opened, it submits without asking") { !submits().isEmpty }
            try app.expect(!review.isConfirmingUnopenedAgentComments, "no question was asked", app.summary)
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
