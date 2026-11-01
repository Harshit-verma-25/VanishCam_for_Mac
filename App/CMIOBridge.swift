import Foundation
import CoreMediaIO

/// Minimal CoreMediaIO helpers to read/write the extension's custom stream properties
/// ("mode", "cmnd", "stat"). This is how the app talks to the camera extension.
enum CMIOBridge {
    private static func address(_ selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: selector,
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private static func objectIDs(of object: CMIOObjectID, selector: Int) -> [CMIOObjectID] {
        var addr = address(CMIOObjectPropertySelector(selector))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, &ids) == noErr else { return [] }
        return ids
    }

    static func deviceID(named name: String) -> CMIOObjectID? {
        let devices = objectIDs(of: CMIOObjectID(kCMIOObjectSystemObject), selector: kCMIOHardwarePropertyDevices)
        return devices.first { string($0, selector: CMIOObjectPropertySelector(kCMIOObjectPropertyName)) == name }
    }

    static func streams(of device: CMIOObjectID) -> [CMIOObjectID] {
        objectIDs(of: device, selector: kCMIODevicePropertyStreams)
    }

    static func string(_ object: CMIOObjectID, selector: CMIOObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return nil }
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func string(_ object: CMIOObjectID, _ fourCC: String) -> String? {
        string(object, selector: CMIOObjectPropertySelector(VanishIPC.fourCC(fourCC)))
    }

    @discardableResult
    static func setString(_ object: CMIOObjectID, _ fourCC: String, _ value: String) -> Bool {
        var addr = address(CMIOObjectPropertySelector(VanishIPC.fourCC(fourCC)))
        var cfValue = value as CFString
        let size = UInt32(MemoryLayout<CFString>.size)
        return CMIOObjectSetPropertyData(object, &addr, 0, nil, size, &cfValue) == noErr
    }
}
