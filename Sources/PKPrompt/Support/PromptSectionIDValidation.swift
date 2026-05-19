import Foundation

public extension Collection where Element == PromptSection {
    func duplicatePromptSectionIDs() -> [String] {
        duplicateIDs(idKeyPath: \.id)
    }
}

public extension Collection where Element == RenderedPrompt.Section {
    func duplicateRenderedPromptSectionIDs() -> [String] {
        duplicateIDs(idKeyPath: \.id)
    }
}
