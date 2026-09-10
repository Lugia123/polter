import SwiftUI

struct ErrorView: View {
    var body: some View {
        HStack {
            Image("AppIconImage")
                .resizable()
                .scaledToFit()
                .frame(width: 128, height: 128)

            VStack(alignment: .leading) {
                Text(String(localized: "Oh, no. 😭", comment: "终端崩溃后的错误页")).font(.title)
                Text(String(localized: "Something went fatally wrong.\nCheck the logs and restart Polter.", comment: "终端崩溃后的错误页"))
            }
        }
        .padding()
    }
}

struct ErrorView_Previews: PreviewProvider {
    static var previews: some View {
        ErrorView()
    }
}
