// tests/test_coach_review.py: the halves that are the model choice's (the coach's model is chosen on its own, local by
// default, and the setup assistant's bulk choice leaves it alone). The tests of the best next question's inputs, its
// helper, its button and `model_name` go with the next question (Task 43); they are in the ledger.
import Foundation
import PalaverCore
import Testing
@testable import PalaverDomain

@Suite struct CoachReviewTests {
    /// The choice half: `api.language_model`'s feature list goes with the window's routes.
    @Test func test_the_coach_never_inherits_the_notes_engine() {
        let t = TempFolder("coach-review"); defer { t.remove() }
        let stores = StorePaths(configDir: t.url.appendingPathComponent("config/palaver", isDirectory: true),
                                home: t.url.appendingPathComponent("home", isDirectory: true))
        var cfg = Config()
        cfg.notesEngine = "claude"
        cfg.notesModel = "opus"
        #expect(ModelChoice.choiceFor(feature: "notes", config: cfg, stores: stores) == "claude-cli")
        #expect(ModelChoice.choiceFor(feature: "coach", config: cfg, stores: stores) == "local")
        #expect(ModelChoice.defaultChoice(feature: "coach", config: cfg) == "local")
    }

    /// `api.setup_registry`'s features: those not chosen on their own, by kind.
    @Test func test_the_setup_assistant_leaves_the_coach_alone() {
        let bulk = ModelChoice.features.filter { !$0.own && $0.uses == ModelChoice.LANGUAGE_MODEL }.map(\.id)
        #expect(!bulk.contains("coach"))
        #expect(Set(bulk) == ["notes", "projects"])
    }
}
