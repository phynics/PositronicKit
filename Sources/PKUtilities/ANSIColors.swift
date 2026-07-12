import Foundation

/// ANSI color codes for terminal output
public enum ANSIColors {
    public static let reset = "\u{001B}[0m"
    public static let bold = "\u{001B}[1m"
    public static let dim = "\u{001B}[2m"
    public static let italic = "\u{001B}[3m"
    public static let underline = "\u{001B}[4m"

    public static let black = "\u{001B}[30m"
    public static let red = "\u{001B}[31m"
    public static let green = "\u{001B}[32m"
    public static let yellow = "\u{001B}[33m"
    public static let blue = "\u{001B}[34m"
    public static let magenta = "\u{001B}[35m"
    public static let cyan = "\u{001B}[36m"
    public static let white = "\u{001B}[37m"

    public static let brightBlack = "\u{001B}[90m"
    public static let brightRed = "\u{001B}[91m"
    public static let brightGreen = "\u{001B}[92m"
    public static let brightYellow = "\u{001B}[93m"
    public static let brightBlue = "\u{001B}[94m"
    public static let brightMagenta = "\u{001B}[95m"
    public static let brightCyan = "\u{001B}[96m"
    public static let brightWhite = "\u{001B}[97m"

    public static func colorize(_ text: String, color: String) -> String {
        "\(color)\(text)\(reset)"
    }
}
