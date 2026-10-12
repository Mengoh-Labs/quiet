import Foundation
import IOKit

public struct CPUTemperature: Codable, Sendable {
    public var hottestCelsius: Double
    public var averageCelsius: Double
    public var sensorCount: Int
}

/// Read-only AppleSMC transport. Sensor mappings are hardware-specific and unofficial.
/// Only known M3 CPU keys are queried; unknown hardware reports unavailable.
/// Protocol/key reference: https://github.com/exelban/stats (SMC/smc.swift, Modules/Sensors/values.swift).
public enum TemperatureReader {
    static let m3Keys = ["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"]
    private static let supported: Bool = {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return false }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 else { return false }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).hasPrefix("Apple M3")
    }()

    public static func read() -> CPUTemperature? {
        guard supported else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
        defer { IOServiceClose(connection) }
        let values = m3Keys.compactMap { readKey($0, connection: connection) }
        guard let maximum = values.max() else { return nil }
        return CPUTemperature(hottestCelsius: maximum, averageCelsius: values.reduce(0, +) / Double(values.count), sensorCount: values.count)
    }

    private static func fourCC(_ text: String) -> UInt32 { text.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
    private static func put(_ value: UInt32, at offset: Int, into bytes: inout [UInt8]) {
        for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }
    private static func word(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | (UInt32(bytes[offset + $1]) << ($1 * 8)) }
    }
    private static func call(_ input: [UInt8], connection: io_connect_t) -> [UInt8]? {
        // AppleSMC's 80-byte key message ABI: info 28, result 40, command 42, payload 48.
        var output = [UInt8](repeating: 0, count: 80)
        var count = 80
        let status = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                IOConnectCallStructMethod(connection, 2, source.baseAddress, 80, destination.baseAddress, &count)
            }
        }
        guard status == KERN_SUCCESS, count == 80, output[40] == 0 else { return nil }
        return output
    }
    private static func readKey(_ key: String, connection: io_connect_t) -> Double? {
        var request = [UInt8](repeating: 0, count: 80)
        put(fourCC(key), at: 0, into: &request)
        request[42] = 9 // read metadata; never issue a write command
        guard let metadata = call(request, connection: connection) else { return nil }
        let size = word(metadata, at: 28), type = word(metadata, at: 32)
        guard (type == fourCC("flt ") && size == 4) || (type == fourCC("sp78") && size == 2) else { return nil }
        put(size, at: 28, into: &request)
        request[42] = 5 // read value
        guard let response = call(request, connection: connection) else { return nil }
        return decode(Array(response[48..<(48 + Int(size))]), type: type == fourCC("flt ") ? "flt " : "sp78")
    }
    static func decode(_ bytes: [UInt8], type: String) -> Double? {
        let value: Double
        if type == "flt ", bytes.count == 4 { value = Double(Float(bitPattern: word(bytes, at: 0))) }
        else if type == "sp78", bytes.count == 2 { value = Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256 }
        else { return nil }
        // Reject absent, corrupted and non-temperature values; never display a fabricated zero.
        return value.isFinite && (1...130).contains(value) ? value : nil
    }
}
