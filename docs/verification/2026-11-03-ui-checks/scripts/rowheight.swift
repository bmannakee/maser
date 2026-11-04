import AppKit
import SwiftUI

struct Row<G: View>: View {
    let gutter: G
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("12").frame(width: 44, alignment: .trailing)
            gutter.frame(width: 20)
            Text("+").frame(width: 14, alignment: .leading)
            Text("let x = 1").frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
        .font(.system(size: 12, design: .monospaced))
    }
}

@MainActor func height(_ v: some View) -> CGFloat {
    let host = NSHostingView(rootView: v.frame(width: 600))
    return host.fittingSize.height
}

MainActor.assumeIsolated {
    print("clear      ", height(Row(gutter: Color.clear)))
    print("plus.bubble", height(Row(gutter: Button {} label: { Image(systemName: "plus.bubble") }.buttonStyle(.plain))))
    print("text.bubble", height(Row(gutter: Image(systemName: "text.bubble.fill"))))
    print("expected   ", NSLayoutManager().defaultLineHeight(for: .monospacedSystemFont(ofSize: 12, weight: .regular)) + 2)
}
