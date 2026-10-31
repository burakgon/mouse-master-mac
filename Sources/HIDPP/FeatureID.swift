import Foundation

/// Well known HID++ 2.0 feature ids.
public enum FeatureID {
    public static let root: UInt16 = 0x0000
    public static let featureSet: UInt16 = 0x0001
    public static let deviceFirmwareVersion: UInt16 = 0x0003
    public static let deviceName: UInt16 = 0x0005
    public static let deviceFriendlyName: UInt16 = 0x0007
    public static let batteryStatus: UInt16 = 0x1000
    public static let batteryVoltage: UInt16 = 0x1001
    public static let unifiedBattery: UInt16 = 0x1004
    public static let changeHost: UInt16 = 0x1814
    public static let hostsInfo: UInt16 = 0x1815
    public static let haptic: UInt16 = 0x19B0
    public static let reprogControlsV4: UInt16 = 0x1B04
    public static let wirelessDeviceStatus: UInt16 = 0x1D4B
    public static let smartShift: UInt16 = 0x2110
    public static let smartShiftEnhanced: UInt16 = 0x2111
    public static let hiresWheel: UInt16 = 0x2121
    public static let thumbWheel: UInt16 = 0x2150
    public static let adjustableDPI: UInt16 = 0x2201
    public static let extendedAdjustableDPI: UInt16 = 0x2202
    public static let pointerSpeed: UInt16 = 0x2205
}

/// Human readable name of a feature, for diagnostics.
public func featureName(_ feature: UInt16) -> String {
    switch feature {
    case 0x0000: return "Root"
    case 0x0001: return "Feature set"
    case 0x0002: return "Feature info"
    case 0x0003: return "Device firmware version"
    case 0x0004: return "Device unit id"
    case 0x0005: return "Device name"
    case 0x0006: return "Device groups"
    case 0x0007: return "Device friendly name"
    case 0x0008: return "Keep alive"
    case 0x0020: return "Configuration change"
    case 0x0021: return "Crypto id"
    case 0x0030: return "Target software"
    case 0x0080: return "Wireless signal strength"
    case 0x00C0, 0x00C1, 0x00C2, 0x00C3: return "Firmware update control"
    case 0x00D0: return "Firmware update"
    case 0x1000: return "Battery status"
    case 0x1001: return "Battery voltage"
    case 0x1004: return "Unified battery"
    case 0x1010: return "Charging control"
    case 0x1300: return "LED control"
    case 0x1500: return "Force pairing"
    case 0x1602: return "Password authentication"
    case 0x1802: return "Device reset"
    case 0x1803: return "GPIO access"
    case 0x1805: return "OOB state"
    case 0x1806: return "Configurable device properties"
    case 0x1814: return "Change host"
    case 0x1815: return "Hosts info"
    case 0x1816: return "BLE Pro pre-pairing"
    case 0x1830: return "Power modes"
    case 0x1861: return "Battery levels calibration"
    case 0x1891: return "Test mode"
    case 0x18A1: return "LED test"
    case 0x1981: return "Backlight"
    case 0x1982: return "Backlight 2"
    case 0x1983: return "Backlight 3"
    case 0x1990: return "Illumination"
    case 0x19B0: return "Haptic feedback"
    case 0x19C0: return "Force sensing button"
    case 0x1A00: return "Presenter control"
    case 0x1B00: return "Reprogrammable controls"
    case 0x1B04: return "Reprogrammable controls v4"
    case 0x1B05: return "Full key customization"
    case 0x1C00: return "Persistent remappable action"
    case 0x1D4B: return "Wireless device status"
    case 0x1DF0: return "Remaining pairing"
    case 0x1E00: return "Enable hidden features"
    case 0x1E02: return "Manage deactivatable features"
    case 0x1E22: return "SPI direct access"
    case 0x1EB0: return "TDE access"
    case 0x1F20: return "ADC measurement"
    case 0x2001: return "Left/right swap"
    case 0x2006: return "Pointer axis orientation"
    case 0x2100: return "Vertical scrolling"
    case 0x2110: return "SmartShift"
    case 0x2111: return "SmartShift enhanced"
    case 0x2120: return "Hi-res scrolling"
    case 0x2121: return "Hi-res wheel"
    case 0x2130: return "Low-res wheel"
    case 0x2150: return "Thumb wheel"
    case 0x2200: return "Mouse pointer"
    case 0x2201: return "Adjustable DPI"
    case 0x2202: return "Extended adjustable DPI"
    case 0x2205: return "Pointer speed"
    case 0x2230: return "Angle snapping"
    case 0x2240: return "Surface tuning"
    case 0x2250: return "XY statistics"
    case 0x2251: return "Wheel statistics"
    case 0x2400: return "Hybrid tracking"
    case 0x40A0, 0x40A2, 0x40A3: return "Fn inversion"
    case 0x4100: return "Encryption"
    case 0x4220: return "Lock key state"
    case 0x4521: return "Disable keys"
    case 0x4530: return "Dual platform"
    case 0x4531: return "Multi platform"
    case 0x4540: return "Keyboard layout"
    case 0x6100: return "Touchpad raw XY"
    case 0x6501: return "Gestures"
    case 0x8060: return "Report rate"
    case 0x8061: return "Extended report rate"
    case 0x8070: return "Color LED effects"
    case 0x8071: return "RGB effects"
    case 0x8100: return "Onboard profiles"
    case 0x9001: return "Production test"
    case 0x9205: return "Sensor test"
    case 0x9300: return "Production data"
    default: return "Unknown"
    }
}
