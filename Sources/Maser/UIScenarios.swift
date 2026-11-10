// The UI scenarios that `scripts/check-ui` runs, each against a fresh launch of a debug build.
//
// Each scenario is named with the requirements it verifies, like a unit test, and requirements cite it as
// `UI:<name>`; `maser-trace` checks both directions. The scenarios run against the recordings in
// `Tests/UIScenarios/recordings` and the queue searches in `Tests/UIScenarios/config.toml`, so the PR numbers below
// are the ones recorded there. See `Tests/UIScenarios/README.md` for running and re-recording them.

#if DEBUG
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

        /// Every scenario, in the order `scripts/check-ui` runs them.
        static let all: [UIScenario] = [
            queueKeys, keyRouting, tabAndPaneStress, commentBoxKeepsFocus, typingPausesKeys, postComment,
            queueSearchFails, switchPRsKeepsState,
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
            try await app.press("c")
            try await app.waitUntil("the comment box has focus") { app.responder == .editor }
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

            try await app.press("cmd+r")
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
