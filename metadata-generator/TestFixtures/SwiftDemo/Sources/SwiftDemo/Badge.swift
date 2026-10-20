// A SwiftUI view JavaScript hosts in a UIHostingController.

import SwiftUI

public struct Badge: View {
    public var title: String
    public var count: Int

    public init(title: String, count: Int) {
        self.title = title
        self.count = count
    }

    public var body: some View {
        HStack {
            Text(title)
            Text("\(count)").bold()
        }
        .padding()
    }
}
