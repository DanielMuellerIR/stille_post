import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio

/// Ein aktuell an macOS angemeldetes Audio-Eingabegerät.
///
/// Der sichtbare Name kann sich ändern; die CoreAudio-UID bleibt dagegen stabil
/// und eignet sich deshalb zum Speichern in der Konfiguration.
public struct AudioInputDevice: Identifiable, Equatable, Sendable {
    public var id: String { uid }
    public let uid: String
    public let name: String

    public init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }
}

/// Liest die Eingabegeräte aus CoreAudio und verbindet eine gespeicherte Auswahl
/// mit dem Eingabeknoten von AVAudioEngine.
public enum AudioInputDeviceCatalog {

    /// Alle Geräte, die mindestens einen Eingabe-Stream anbieten.
    public static func availableDevices() -> [AudioInputDevice] {
        allDeviceIDs()
            .filter(hasInputStreams)
            .compactMap(device)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Das momentan in macOS gewählte Standard-Eingabegerät.
    public static func defaultDevice() -> AudioInputDevice? {
        guard let id = defaultDeviceID() else { return nil }
        return device(id)
    }

    /// Wählt das gespeicherte Gerät am AVAudioEngine-Eingang aus. Eine leere UID
    /// bedeutet bewusst „Systemstandard“ und braucht keine CoreAudio-Änderung.
    static func apply(uid: String, to inputNode: AVAudioInputNode) throws {
        guard !uid.isEmpty else { return }
        guard let deviceID = deviceID(forUID: uid) else {
            throw SelectionError.unavailable
        }
        guard let audioUnit = inputNode.audioUnit else {
            throw SelectionError.cannotConfigure(-1)
        }

        var selectedID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &selectedID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw SelectionError.cannotConfigure(status)
        }
    }

    enum SelectionError: Error, Equatable {
        case unavailable
        case cannotConfigure(OSStatus)
    }

    // MARK: - CoreAudio-Abfragen

    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            systemObject, &address, 0, nil, &byteCount
        ) == noErr, byteCount > 0 else { return [] }

        var ids = [AudioDeviceID](
            repeating: kAudioObjectUnknown,
            count: Int(byteCount) / MemoryLayout<AudioDeviceID>.size
        )
        guard AudioObjectGetPropertyData(
            systemObject, &address, 0, nil, &byteCount, &ids
        ) == noErr else { return [] }
        return ids
    }

    private static func defaultDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(kAudioObjectUnknown)
        var byteCount = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            systemObject, &address, 0, nil, &byteCount, &id
        ) == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    private static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &byteCount) == noErr
            && byteCount > 0
    }

    private static func device(_ id: AudioDeviceID) -> AudioInputDevice? {
        guard let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID),
              let name = stringProperty(id, selector: kAudioObjectPropertyName),
              !uid.isEmpty, !name.isEmpty else { return nil }
        return AudioInputDevice(uid: uid, name: name)
    }

    private static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { id in
            hasInputStreams(id)
                && stringProperty(id, selector: kAudioDevicePropertyDeviceUID) == uid
        }
    }

    /// CoreAudio übergibt Namen und UIDs mit Besitzrecht an den Aufrufer. Durch
    /// `takeRetainedValue` übernimmt ARC das spätere Freigeben des CFStrings.
    private static func stringProperty(
        _ id: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var byteCount = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            id, &address, 0, nil, &byteCount, &value
        ) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
