import StillePostCore

func transcriptOriginLabelKey(_ result: DictationResult, cleanupEnabled: Bool, partial: Bool = false) -> String {
    if partial { return "audio_import.partial" }
    if let entry = result.entry, entry.originalOrigin != nil || entry.resultMetadata != nil {
        return "editor.origin.\(entry.resultOrigin.rawValue)"
    }
    if result.entry?.cleanupFellBack == true { return "test_dictation.raw" }
    return cleanupEnabled ? "test_dictation.cleaned" : "test_dictation.cleanup_off"
}
