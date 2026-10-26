import UIKit

extension OwnRegistration {
    /// The registration asked for, then the exit, behind the progress alert
    /// the operation page shows for an update of the app.
    static func finishUpdate(from controller: UIViewController, registering: Bool) {
        let progress = progressAlert(
            title: "Updating App…",
            message: "Preparing the app update. The app will exit when it finishes."
        )
        controller.present(progress, animated: true) {
            Task {
                if registering {
                    _ = await request()
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                UIApplication.prepareForExitAndSuspend()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                exit(0)
            }
        }
    }

    /// At launch, once the daemon has answered: an update that stopped the
    /// app before it asked leaves LaunchServices with the build before this
    /// one, and this build asks once.
    static func finishIfStale(from controller: UIViewController) {
        guard claimStaleRegistration() else { return }
        finishUpdate(from: controller, registering: true)
    }
}
