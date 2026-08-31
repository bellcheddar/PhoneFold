import Testing
import Foundation

/// The privacy manifest, and whether it still describes the code.
///
/// **The failure mode is staleness, not absence.** A manifest is written once and then quietly
/// stops being true the first time somebody reads a file's modification date - and nothing
/// fails, because Apple checks it at submission and not at build. This scans the source for
/// the required-reason APIs and asserts that every category actually used is declared.
@Suite("Privacy manifest")
struct PrivacyManifestTests {

    static var root: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url
    }

    static var manifestURL: URL {
        root.appending(path: "Apps/PhoneFold/Resources/PrivacyInfo.xcprivacy")
    }

    /// Every required-reason API category, and the symbols that give it away.
    ///
    /// From Apple's list. `Date()` and `CACurrentMediaTime` are deliberately not here: neither
    /// is a required-reason API, and treating them as one would make the test cry wolf on the
    /// most ordinary line in the codebase.
    static let categories: [(category: String, symbols: [String])] = [
        ("NSPrivacyAccessedAPICategoryUserDefaults", ["UserDefaults"]),
        ("NSPrivacyAccessedAPICategoryFileTimestamp",
         ["attributesOfItem", "contentModificationDateKey", "creationDateKey",
          ".modificationDate", "getattrlist", "NSFileCreationDate"]),
        ("NSPrivacyAccessedAPICategorySystemBootTime",
         ["systemUptime", "mach_absolute_time", "mach_continuous_time"]),
        ("NSPrivacyAccessedAPICategoryDiskSpace",
         ["volumeAvailableCapacity", "systemFreeSize", "volumeTotalCapacity"]),
        ("NSPrivacyAccessedAPICategoryActiveKeyboards", ["activeInputModes"]),
    ]

    /// Every Swift file that actually ships in the app.
    ///
    /// Tests and the command-line tools are excluded: a manifest describes the binary Apple
    /// receives, and `preview-style` is not in it.
    static func shippingSources() -> [String] {
        var contents: [String] = []
        for directory in ["Apps/PhoneFold/Sources", "PhoneFoldKit/Sources"] {
            let base = root.appending(path: directory)
            guard let walker = FileManager.default.enumerator(
                at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                // The command-line tools ship nothing to Apple.
                guard !url.path.contains("/preview-style/"),
                      !url.path.contains("/foldaudio-probe/") else { continue }
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    contents.append(text)
                }
            }
        }
        return contents
    }

    @Test("the manifest exists, parses, and claims nothing untrue")
    func manifestIsWellFormed() throws {
        let data = try Data(contentsOf: Self.manifestURL)
        let plist = try #require(try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any])

        // PhoneFold collects nothing and tracks nobody. If that ever stops being true, this
        // test is the place it has to be changed deliberately.
        #expect(plist["NSPrivacyTracking"] as? Bool == false)
        #expect((plist["NSPrivacyTrackingDomains"] as? [Any])?.isEmpty ?? true)
        #expect((plist["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty ?? true)
    }

    @Test("every required-reason API the shipping code uses is declared")
    func declaredCategoriesCoverTheCode() throws {
        let data = try Data(contentsOf: Self.manifestURL)
        let plist = try #require(try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any])
        let declared = Set(((plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]]) ?? [])
            .compactMap { $0["NSPrivacyAccessedAPIType"] as? String })

        let sources = Self.shippingSources()
        #expect(!sources.isEmpty, "no shipping sources were found to scan")

        for (category, symbols) in Self.categories {
            let used = symbols.contains { symbol in
                sources.contains { $0.contains(symbol) }
            }
            if used {
                #expect(declared.contains(category),
                        "the code uses \(category) and the manifest does not declare it")
            }
        }

        // UserDefaults is used, for the onboarding flag - so this is a check that the scan
        // itself works rather than passing because it found nothing.
        #expect(declared.contains("NSPrivacyAccessedAPICategoryUserDefaults"))
    }

    @Test("every declared reason is one Apple recognises")
    func reasonsAreValid() throws {
        // A plausible-looking reason string that Apple does not publish is rejected at
        // submission, which is a long way from here.
        let valid: Set<String> = [
            "CA92.1", "1C8F.1", "C56D.1", "AC6B.1",           // UserDefaults
            "DDA9.1", "C617.1", "3B52.1", "0A2A.1",           // File timestamp
            "35F9.1", "8FFB.1", "3D61.1",                     // System boot time
            "85F4.1", "E174.1", "7D9E.1", "B728.1",           // Disk space
            "3EC4.1", "54BD.1",                               // Active keyboards
        ]
        let data = try Data(contentsOf: Self.manifestURL)
        let plist = try #require(try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any])
        for entry in (plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]]) ?? [] {
            let reasons = (entry["NSPrivacyAccessedAPITypeReasons"] as? [String]) ?? []
            #expect(!reasons.isEmpty, "a declared API type with no reason is rejected")
            for reason in reasons {
                #expect(valid.contains(reason), "\(reason) is not a published reason code")
            }
        }
    }
}
