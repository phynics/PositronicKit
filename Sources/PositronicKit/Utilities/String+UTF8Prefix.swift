extension String {
    /// The longest prefix of whole characters whose UTF-8 encoding fits in `byteCount` bytes.
    /// A character is never split, so the result is always valid text.
    func utf8Prefix(maxBytes byteCount: Int) -> String {
        guard byteCount > 0 else { return "" }
        var output = ""
        var used = 0
        for character in self {
            guard used + character.utf8.count <= byteCount else { break }
            output.append(character)
            used += character.utf8.count
        }
        return output
    }
}
