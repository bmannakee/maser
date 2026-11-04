import AppKit
import SwiftUI

let mode = CommandLine.arguments.dropFirst().first ?? "nested"

@MainActor @Observable final class Model { var files = false; var comments = true }

struct Inner: View {
    @Bindable var model: Model
    var body: some View {
        if mode == "nested" {
            NavigationSplitView {
                List(0..<20, id: \.self) { Text("file \($0)") }
                    .navigationSplitViewColumnWidth(min: 180, ideal: 260, max: 500)
            } detail: {
                ScrollView { LazyVStack { ForEach(0..<300, id: \.self) { Text("line \($0)") } } }
            }
            .inspector(isPresented: $model.comments) { Text("comments").inspectorColumnWidth(min: 240, ideal: 340, max: 600) }
        } else {
            HSplitView {
                List(0..<20, id: \.self) { Text("file \($0)") }
                    .frame(minWidth: 180, idealWidth: 260, maxWidth: 500)
                ScrollView { LazyVStack { ForEach(0..<300, id: \.self) { Text("line \($0)") } } }
                    .frame(minWidth: 300, maxWidth: .infinity)
            }
            .inspector(isPresented: $model.comments) { Text("comments").inspectorColumnWidth(min: 240, ideal: 340, max: 600) }
        }
    }
}

struct Root: View {
    let model: Model
    var body: some View {
        NavigationSplitView {
            List(0..<10, id: \.self) { Text("PR \($0)") }
        } detail: {
            Group {
                if model.files { Inner(model: model) } else { Text("overview") }
            }
            .toolbar {
                ToolbarItem(placement: .principal) { Text(model.files ? "Files" : "Overview") }
                if model.files { ToolbarItem { Button("Comments", systemImage: "sidebar.right") { model.comments.toggle() } } }
            }
        }
        .frame(width: 1600, height: 950)
    }
}

@MainActor final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let model = Model()
    func applicationDidFinishLaunching(_ n: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 950), styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Root(model: model))
        window.orderFrontRegardless()
        var flips = 0
        Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            MainActor.assumeIsolated {
                self.model.files.toggle()
                flips += 1
                if flips == 12 { print("survived \(mode)"); NSApp.terminate(nil) }
            }
        }
    }
}
MainActor.assumeIsolated {
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = Delegate()
app.delegate = delegate
app.run()
}
