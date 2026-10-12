/// Mëngøh Labs Brand Guide, pages 17–20. Printed sRGB hex values, not sampled preview pixels.
public enum MengohPalette {
    public static let forest: UInt32 = 0x082E1F
    public static let labGreen: UInt32 = 0x145A32
    public static let moss: UInt32 = 0x3B8D5D
    public static let signal: UInt32 = 0x72D572
    public static let cream: UInt32 = 0xF3F1E6
    public static let paper: UInt32 = 0xFAF9F3
    public static let research: UInt32 = 0x3880BD
    public static let amber: UInt32 = 0xD99422
    public static let fault: UInt32 = 0xC94B4B
    public static let iris: UInt32 = 0x7967B8
    public static let ion: UInt32 = 0x3AA7A3
    public static let ink800: UInt32 = 0x0F3B2A
    public static let ink600: UInt32 = 0x275E45
    public static let ink500: UInt32 = 0x497965
    public static let ink300: UInt32 = 0x9FB7AC
    public static let ink200: UInt32 = 0xD6DDD7
    public static let success: UInt32 = 0x2E7D4F
    public static let info: UInt32 = 0x2F80ED
    public static let warning: UInt32 = 0xF5C242
    public static let danger: UInt32 = 0xE5484D
    public static func foreground(_ rgb: UInt32) -> String { "38;2;\((rgb >> 16) & 255);\((rgb >> 8) & 255);\(rgb & 255)" }
    public static func background(_ rgb: UInt32) -> String { "48;2;\((rgb >> 16) & 255);\((rgb >> 8) & 255);\(rgb & 255)" }
}
