//
//  AppFinder.swift
//  Retroactive
//

import Cocoa

class AppFinder: NSObject {
    var query: NSMetadataQuery?
    var comingFromChoiceVC: Bool = false

    static let shared = AppFinder()
    
    private override init() {
    }

    func queryAllInstalledApps() {
        print("query all installed apps")
        queryAllInstalledApps(shouldPresentAlert: false, claimsToHaveInstalled: false)
    }
    
    func queryAllInstalledApps(shouldPresentAlert: Bool, claimsToHaveInstalled: Bool) {
        query?.stop()
        query = NSMetadataQuery()
        query?.searchScopes = ["/Applications"]
        print("query = \(String(describing: query))")
        let pred = NSPredicate.init(format: "\(searchContentTypeTree) == '\(bundleContentType)' AND \(searchBundleIdentifier) CONTAINS[c] %@", AppManager.shared.existingBundleIDOfChosenApp)
        print("pred = \(String(describing: pred))")
        query?.predicate = pred
        query?.start()
        NotificationCenter.default.removeObserver(self)
        NotificationCenter.default.addObserver(self, selector: #selector(gatheringProgressChanged), name: NSNotification.Name.NSMetadataQueryGatheringProgress, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(gatheringDataUpdated), name: NSNotification.Name.NSMetadataQueryDidUpdate, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(finishedQueryInstalledApps), name: NSNotification.Name.NSMetadataQueryDidFinishGathering, object: nil)
    }
    
    @objc func gatheringProgressChanged(_ notif: NSNotification) {
        print("gatheringProgressChanged")
    }
    
    @objc func gatheringDataUpdated(_ notif: NSNotification) {
        print("gatheringDataUpdated")
    }
    
    @objc func finishedQueryInstalledApps(_ notif: NSNotification) {
        guard let actualQuery = notif.object as? NSMetadataQuery else {
            return
        }
        
        print("finishedQueryInstalledApps, results = \(String(describing: query?.results))")

        if actualQuery != query {
            return
        }

        guard let queriedApps = query?.results as? [NSMetadataItem] else {
            self.pushGuidanceVC()
            return
        }
        
        var incompatibleVersion: String?
        var installedFullVersionString: String?
        var installedShortVersionString: String?

        for result in queriedApps {
            if let bundleID = result.value(forAttribute: searchBundleIdentifier) as? String, let path = result.value(forAttribute: searchPath) as? String {
                var appBundle = Bundle(path: path)
                STPrivilegedTask.flushBundleCache(appBundle)
                appBundle = Bundle(path: path)

                let versionNumberString: String = appBundle?.object(forInfoDictionaryKey: kCFBundleShortVersionString) as? String ?? ""
                let fullVersionNumberString: String = appBundle?.object(forInfoDictionaryKey: kCFBundleVersion) as? String ?? ""
                if bundleID.elementsEqual(AppManager.shared.patchedBundleIDOfChosenApp) || fullVersionNumberString == AppManager.shared.patchedVersionStringOfChosenApp {
                    print("Found compatible patched app: \(bundleID), \(path)")
                    AppManager.shared.locationOfChosenApp = path
                    
                    if AppManager.shared.chosenApp == .aperture || AppManager.shared.chosenApp == .iphoto {
                        let existingFixerPath = "\(path)/\(AppManager.shared.fixerFrameworkSubPath)"
                        if let existingFixerBundle = Bundle.init(path: existingFixerPath),
                            let existingFixerVersion = existingFixerBundle.cfBundleVersionInt,
                            let resourcePath = Bundle.main.resourcePath {
                            let fixerResourcePath = "\(resourcePath)/ApertureFixer/Resources/Info.plist"
                            if let loadedFixerInfoPlist = NSDictionary(contentsOfFile: fixerResourcePath) as? Dictionary<String, Any>,
                                let bundledFixerVersionString = loadedFixerInfoPlist[kCFBundleVersion] as? String, let bundledFixerVersion = Int(bundledFixerVersionString) {
                                if (existingFixerVersion < bundledFixerVersion) {
                                    print("existing fixer is \(existingFixerVersion), bundled fixer is \(bundledFixerVersion), upgrade is available")
                                    AppManager.shared.fixerUpdateAvailable = true
                                } else {
                                    self.pushCompletionVC()
                                    return
                                }
                            }
                        }
                    } else if AppManager.shared.chosenApp == .finalCutPro7 {
                        do {
                            let exists = FileManager.default.fileExists(atPath: kCustomSettingsPath)
                            if (!exists) {
                                self.pushCompletionVC()
                                return
                            }
                            let contents = try FileManager.default.contentsOfDirectory(atPath: kCustomSettingsPath)
                            let presets = contents.filter { $0.lowercased().hasSuffix(".fcpre") }
                            if (presets.count == 0) {
                                self.pushCompletionVC()
                                return
                            }
                        } catch {
                            print("Can't determine if custom settings exist \(error)")
                        }
                    } else {
                        self.pushCompletionVC()
                        return
                    }

                } else {
                    let contains = AppManager.shared.compatibleVersionOfChosenApp.contains { (compatibleID) -> Bool in
                        return (compatibleID == versionNumberString)
                    }
                    if contains {
                        AppManager.shared.locationOfChosenApp = path
                        installedFullVersionString = fullVersionNumberString
                        installedShortVersionString = versionNumberString
                        if AppManager.shared.chosenApp == .xcode {
                            if let minSysVersionString = appBundle?.object(forInfoDictionaryKey: kLSMinimumSystemVersion) as? String {
                                print("Xcode min OS version: \(minSysVersionString), current OS version: \(ProcessInfo.osVersionNumberString)")
                                if (ProcessInfo.osVersionNumberString.osIsAtLeast(otherOS: minSysVersionString)) {
                                    print("Current OS is at least Xcode min OS")
                                    self.pushCompletionVC()
                                    return
                                }
                            }
                        }
                        print("Found compatible unpatched app: \(bundleID), \(path), \(versionNumberString)")
                    } else {
                        incompatibleVersion = versionNumberString
                        print("Found incompatible unpatched app: \(bundleID), \(path), \(versionNumberString)")
                    }
                }
            }
        }
        
        let lastCompatible = AppManager.shared.compatibleVersionOfChosenApp.first
        if AppManager.shared.locationOfChosenApp == nil {
            if let lastCompatibleVersion = lastCompatible, let knownIncompatible = incompatibleVersion {
                let compareResult = knownIncompatible.compare(lastCompatibleVersion, options: .numeric, range: nil, locale: nil)
                if compareResult == .orderedDescending {
                    incompatibleVersion = nil
                }
            }
            self.pushGuidanceVC(incompatibleVersion)
        } else {
            if let lastCompatibleVersion = lastCompatible, let installed = installedFullVersionString, let shortVersion = installedShortVersionString {
                let compareResult = installed.compare(lastCompatibleVersion, options: .numeric, range: nil, locale: nil)
                if compareResult == .orderedAscending {
                    self.pushGuidanceVC(nil, shortOldVersionString: shortVersion, shouldOfferUpdate: true)
                    return
                }
            }
            self.pushAuthenticateVC()
        }
    }

    private func pushGuidanceVC(_ incompatibleVersionString: String? = nil, shortOldVersionString: String? = nil, shouldOfferUpdate: Bool = false) {
        if AppDelegate.rootVC?.navigationController.topViewController is GuidanceViewController {
            let name = AppManager.shared.spaceConstrainedNameOfChosenApp
            var title: String = ""
            var explaination: String = ""
            
            var compat = AppManager.shared.compatibleVersionOfChosenApp.first ?? ""
            let userFacingCompat = AppManager.shared.userFacingLatestShortVersionOfChosenApp
            if (userFacingCompat != compat) {
                compat = "\(userFacingCompat), \(compat)"
            }
            
            if let incompat = incompatibleVersionString {
                title = String.init(format: "You need to update %@ from %@ to %@.".localized(), name, incompat, compat)
                var middlePartial = String(format: "Download the latest version of %@ (%@) from the Purchased list in the Mac App Store, then run Retroactive again.".localized(), name, compat)
                if AppManager.shared.chosenApp == .xcode {
                    middlePartial = String(format: "Directly download %@ from the Apple Developer website, then run Retroactive again.".localized(), name)
                }
                explaination = String.init(format: "The copy of %@ you have installed is %@ (%@), and is too old to be modified. \n\n%@\n\nIf you have installed %@ (%@) at a custom location, locate it manually.".localized(), name, name, incompat, middlePartial, name, compat)
            } else {
                if (shouldOfferUpdate) {
                    let short = shortOldVersionString ?? ""
                    title = String.init(format: "We recommend updating %@ to version %@.".localized(), name, userFacingCompat)
                    explaination = String.init(format: "Retroactive can unlock your installed version of %@ (%@), but works best with %@ (%@). To avoid stability issues, we recommend updating to %@ (%@) before proceeding.".localized(), name, short, name, compat, name, compat)
                } else {
                    title = String(format: "%@ is not installed on your Mac.".localized(), name)
                    explaination = String(format: "Retroactive is unable to locate %@ on your Mac. %@\n\nIf you have installed %@ at a custom location, locate it manually.".localized(), name, AppManager.shared.notInstalledText, name)
                }
            }
            if (shouldOfferUpdate) {
                AppDelegate.showOptionSheet(title: title, text: explaination, firstButtonText: "Update (Recommended)".localized(), secondButtonText: "Don't Update (Not Recommended)".localized(), thirdButtonText: "Cancel".localized()) { (result) in
                    if (result == .alertFirstButtonReturn) {
                        AppManager.shared.updateSelectedApp()
                    }
                    if (result == .alertSecondButtonReturn) {
                        self.pushAuthenticateVC()
                    }
                }
                return
            }
            AppDelegate.showOptionSheet(title: title, text: explaination, firstButtonText: "Locate Manually...".localized(), secondButtonText: AppManager.shared.notInstalledActionText, thirdButtonText: "Cancel".localized()) { (result) in
                if (result == .alertFirstButtonReturn) {
                    AppDelegate.manuallyLocateApp { (result, url, path) in
                        if (result) {
                            if let bundlePath = path {
                                let appBundle = Bundle(path: bundlePath)
                                let versionNumberString: String = appBundle?.object(forInfoDictionaryKey: kCFBundleVersion) as? String ?? ""
                                let displayShortVersionNumberString: String = appBundle?.object(forInfoDictionaryKey: kCFBundleShortVersionString) as? String ?? ""
                                let identifier: String = appBundle?.object(forInfoDictionaryKey: kCFBundleIdentifier) as? String ?? ""
                                let matchesCompatible = AppManager.shared.compatibleVersionOfChosenApp.contains { (compatible) -> Bool in
                                    return compatible == versionNumberString || compatible == displayShortVersionNumberString
                                }
                                if matchesCompatible && AppManager.shared.existingBundleIDOfChosenApp.contains(identifier) {
                                    AppManager.shared.locationOfChosenApp = bundlePath
                                    self.pushAuthenticateVC()
                                } else {
                                    let text = String(format: "%@ (%@) is not %@ (%@). To proceed, you need to locate a valid copy of %@ (%@).".localized(), url?.deletingPathExtension().lastPathComponent ?? "", displayShortVersionNumberString, name, compat, name, compat)
                                    AppDelegate.showTextSheet(title: "Selected app is incompatible".localized(), text: text)
                                }
                            }
                        }
                    }
                }
                if (result == .alertSecondButtonReturn && AppManager.shared.notInstalledActionText.count > 0) {
                    AppManager.shared.acquireSelectedApp()
                }
            }
            return
        }
        if AppManager.shared.chosenApp == .itunes {
            let itunesPath = "/Applications/iTunes.app"
// iTunes won't launch if the path isn't exactly "/Applications/iTunes.app".
//            let alreadyHasiTunes = FileManager.default.fileExists(atPath: itunesPath)
//            if (alreadyHasiTunes) {
//                let fallbackPath = "/Applications/iTunes \(AppManager.shared.compatibleVersionOfChosenApp.first!).app"
//                itunesPath = fallbackPath
//            }
            AppManager.shared.locationOfChosenApp = itunesPath
            self.pushAuthenticateVC()
            return
        }
        AppDelegate.rootVC?.navigationController.pushViewController(GuidanceViewController.instantiate(), animated: true)
    }
    
    private func pushCompletionVC() {
        AppManager.shared.allowPatchingAgain = self.comingFromChoiceVC
        if (AppManager.shared.needsBashAccess) {
            AppDelegate.pushSyncingVC()
            return
        }
        AppDelegate.pushCompletionVC()
    }
    
    private func pushAuthenticateVC() {
        AppDelegate.rootVC?.navigationController.pushViewController(AuthenticateViewController.instantiate(), animated: true)
    }
    
}
