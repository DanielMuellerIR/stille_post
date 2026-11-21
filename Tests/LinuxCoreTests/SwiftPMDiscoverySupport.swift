// SwiftPM 6.2 bindet MainActor-Testmethoden an einen nicht isolierten
// XCTest-Discovery-Thunk. Diese Testklassen besitzen keinen veränderlichen
// Instanzzustand. Veränderliche Fixtures leben innerhalb der Testmethoden.
extension AudioFailureLifecycleTests: @unchecked Sendable {}
extension HistoryManagementTests: @unchecked Sendable {}
extension HistoryPrivacyTests: @unchecked Sendable {}
extension HoldEngineTests: @unchecked Sendable {}
extension PauseResumeTests: @unchecked Sendable {}
extension ProfileTests: @unchecked Sendable {}
extension SelectionCleanupTests: @unchecked Sendable {}
extension VocabularyRecleanupTests: @unchecked Sendable {}
