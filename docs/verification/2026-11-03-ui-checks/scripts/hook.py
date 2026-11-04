# Adds or removes the temporary repro hook in MainView.swift. Usage: hook.py add|remove
import pathlib, sys
p = pathlib.Path("/Users/brianmannakee/dev/maser/Sources/Maser/MainView.swift"); s = p.read_text()
anchor = """        state.open(first)
        focus = nil
        prs.dropFirst().forEach { openWindow(value: $0) }
"""
hook = """        // DEBUG-REPRO (temporary)
        if ProcessInfo.processInfo.environment["MASER_REPRO"] != nil {
            let mainWindow = NSApp.windows.first { $0.className.contains("AppKitWindow") && $0.isVisible }
            func say(_ text: String) { FileHandle.standardError.write(Data((text + "\\n").utf8)) }
            func responder() -> String {
                let r = mainWindow?.firstResponder
                return "\\(r.map { String(describing: type(of: $0)) } ?? "nil") focus=\\(String(describing: focus)) sel=\\(selection.map(\\.lastPathComponent)) vis=\\(state.columnVisibility == .detailOnly ? "hidden" : "shown") queueKeys=\\(state.queueHasKeys) open=\\(state.openPR?.number ?? 0)"
            }
            func run(_ c: CommandID) { _ = perform(c, in: (queue.sections ?? []).isEmpty ? [] : QueueSection.displayed(queue.sections ?? [], filter: filter)) }
            NSApp.activate()
            mainWindow?.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .seconds(6))
            SCRIPT
            say("survived")
            exit(0)
        }
"""
if sys.argv[1] == "add":
    script = pathlib.Path(sys.argv[2]).read_text()
    s = s.replace(anchor, anchor + hook.replace("            SCRIPT\n", script), 1)
else:
    start = s.index("        // DEBUG-REPRO (temporary)")
    end = s.index("            exit(0)\n        }\n", start) + len("            exit(0)\n        }\n")
    s = s[:start] + s[end:]
p.write_text(s)
