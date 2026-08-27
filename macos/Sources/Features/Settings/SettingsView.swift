import SwiftUI

struct SettingsView: View {
    // We need access to our app delegate to know if we're quitting or not.
    @EnvironmentObject private var appDelegate: AppDelegate

    var body: some View {
        HStack {
            // The running application's icon, not the `AppIconImage` asset.
            // That asset is still upstream's ghost -- it came in with
            // "New Ghostty icon" and was never replaced -- so this window
            // was showing Ghostty's icon inside Polter. Asking the running
            // app means there is one source of truth and nothing to keep in
            // step by hand.
            ghosttyIconImage()
                .resizable()
                .scaledToFit()
                .frame(width: 128, height: 128)

            VStack(alignment: .leading) {
                Text("Coming Soon. 🚧").font(.title)
                Text("You can't configure settings in the GUI yet. To modify settings, " +
                     "edit the file at $HOME/.config/polter/config.polter and restart Polter.")
                .multilineTextAlignment(.leading)
                .lineLimit(nil)
            }
        }
        .padding()
        .frame(minWidth: 500, maxWidth: 500, minHeight: 156, maxHeight: 156)
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
