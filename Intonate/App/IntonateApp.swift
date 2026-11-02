import SwiftUI

@main
struct IntonateApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.brass)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.path) {
            ProgrammeView()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .stage(let exercise):
                        StageView(exercise: exercise)
                    case .review(let exercise, let report):
                        ReviewView(exercise: exercise, report: report)
                    }
                }
        }
    }
}
