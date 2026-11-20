// SPDX-License-Identifier: GPL-3.0-or-later
//
// 安装更新（v1.1 设计 9.3 节、19 节的修订）。12 步按顺序执行，第 9 步（替换）之前的任何失败都不碰已安装的应用：
//  1. 重新算能否安装；已安装的包所在的卷应支持 `RENAME_SWAP`（APFS）；重新算 dmg 的 SHA-256 并与记录比较。
//  2. 挂载 dmg（`DiskImage`）。从这一步起，不论成败都在结束前卸载。
//  3. 找卷顶层的 `EVE-O Preview.app`，`lstat` 确认是目录而不是符号链接。
//  4. 在已安装的包所在的卷上建暂存目录（`itemReplacementDirectory`），权限 0700。
//  5. 把应用复制进暂存目录，然后卸载 dmg。
//  6. 核对暂存副本的签名，要求满足正在运行的应用的指定要求（`CodeSignatureVerifier`）。
//  7. 核对副本的 Info.plist 与架构（`UpdatePolicy.validate`）。
//  8. 删掉副本上的 `com.apple.quarantine`（递归，不存在不算错）。
//  9. 先 `lstat` 已安装的路径：应是目录而不是符号链接，bundle id 与版本号等于正在运行的应用，否则返回
//     `bundleMismatch("installedBundle")`。然后 `renamex_np(副本, 已安装的包, RENAME_SWAP)`。只用这一种办法：
//     任何失败（HFS+ 与 exFAT 返回 ENOTSUP，FAT 返回 ENOTEMPTY）都返回 `swapFailed`，已安装的应用不变。
//     不再有「两次改名」的后备：两次改名之间被打断时，已安装的路径下什么都没有（审查 M1）。
// 10. 对已安装的路径再核对一次签名；失败时换回旧版本，返回 `signatureInvalid`。换回也失败时，已安装的路径下是
//     没通过复核的新版本，旧版本在暂存目录里：保留暂存目录，在 fault 日志里写明它的位置，返回 `swapFailed`（审查 B1）。
// 11. 把已安装的包的修改时间设为现在，并 `LSRegisterURL`；失败只记日志。
// 12. 返回 `InstallOutcome`。
//
// 失败的处理按 9.4 节：挂载与复制失败时卸载并删暂存目录；验证失败时另删 dmg，并写一条 fault 日志。
// 暂存目录只在两种情况下删：旧版本仍在（或已换回）已安装的路径，暂存目录里只有新副本；或安装成功，
// 暂存目录里是换下来的旧版本（交给下次启动的 `removeLeftovers`）。dmg 只在它位于缓存目录下时才删
// （`isInsideCache`）：路径来自 state.json，不能让它删到别处的文件。
// 契约里没有对应错误的两种失败按以下办法报告：暂存目录建不出来报 `swapFailed(code:)`（替换没能开始），
// 从卷里复制失败报 `imageMountFailed`（与挂载同属 9.4 节「挂载与复制」一行）；
// 正在运行的应用没有指定要求时报 `requirementNotSatisfied`（无从核对，按不满足处理）。
//
// `removeLeftovers` 也在这里：卸载残留的挂载点、删缓存里除待装 dmg 以外的文件、删上次换下来的旧包。

import CoreServices
import Foundation
import EVEOPreviewCore

/// 应用包的替换与残留清理。
struct BundleInstaller: Sendable {
    /// 缓存目录 `…/Updates`。
    let cacheRoot: URL
    /// 成功后是否向 LaunchServices 登记新包。探针对临时副本传 false，免得登记一个临时路径。
    let registersWithLaunchServices: Bool
    /// 挂载点所在的子目录名。
    static let mountDirectoryName = "mnt"
    /// 隔离属性的名字。
    static let quarantineAttribute = "com.apple.quarantine"
    private var log: LogChannel { PlatformLog.logger("Updates") }

    /// 挂载点的根目录 `Updates/mnt`。
    var mountRoot: URL { cacheRoot.appendingPathComponent(BundleInstaller.mountDirectoryName, isDirectory: true) }

    // MARK: - 安装

    /// 9.3 节的 12 步。systemVersion 是当前系统的版本，如 `27.0.0`。
    func install(_ prepared: PreparedUpdate, environment: AppEnvironment, isTestFeed: Bool,
                 systemVersion: String) async -> Result<InstallOutcome, UpdateError> {
        let image = URL(fileURLWithPath: prepared.imagePath)
        // 第 1 步：能否安装、dmg 是否还是核对过的那一份。
        let capability = UpdatePolicy.capability(for: environment, isTestFeed: isTestFeed)
        guard capability == .canInstall, let installedPath = environment.bundlePath else {
            if case .notifyOnly(let blocker) = capability { return .failure(.blocked(blocker)) }
            return .failure(.blocked(.unsigned))
        }
        let installed = URL(fileURLWithPath: installedPath, isDirectory: true)
        // 卷不支持交换时第 9 步一定失败，在挂载与复制之前就停下。查不到时照常往下走，由第 9 步报错。
        if (try? installed.resourceValues(forKeys: [.volumeSupportsSwapRenamingKey]))?
            .volumeSupportsSwapRenaming == false {
            log.error("已安装的应用所在的卷不支持 RENAME_SWAP（不是 APFS），不能自动安装")
            return .failure(.swapFailed(code: ENOTSUP))
        }
        guard let actual = UpdateDownloader.sha256(of: image), actual == prepared.sha256.lowercased() else {
            log.error("待装的 dmg 与下载时的 SHA-256 不同，删掉它")
            removeImage(image)
            return .failure(.checksumMismatch)
        }

        // 第 2～5 步：挂载、找应用、建暂存目录、复制，然后卸载。
        let staging: URL
        let staged: URL
        switch await stageCopy(from: image, installed: installed) {
        case .success(let result): (staging, staged) = result
        case .failure(let error): return .failure(error)
        }

        // 第 6、7 步：核对暂存副本。失败时删暂存目录与 dmg。
        if let error = verifyStaged(staged, prepared: prepared, environment: environment,
                                    systemVersion: systemVersion) {
            try? FileManager.default.removeItem(at: staging)
            removeImage(image)
            return .failure(error)
        }

        // 第 8 步：去掉隔离属性。
        removeQuarantine(under: staged)

        // 第 9 步：核对已安装的路径，然后交换。失败时什么都没有动，暂存目录里只有新副本。
        if let error = checkInstalled(installed, environment: environment)
            ?? replace(installed: installed, with: staged) {
            try? FileManager.default.removeItem(at: staging)
            return .failure(error)
        }

        // 第 10 步：替换后复核已安装的路径。
        let recheck = CodeSignatureVerifier.check(bundleAt: installed,
                                                  requirement: environment.signature.designatedRequirement ?? "")
        if recheck != errSecSuccess {
            log.fault("替换后复核签名失败，返回值 \(recheck)，换回旧版本")
            if let code = revert(installed: installed, staged: staged) {
                // 旧版本不在已安装的路径上：暂存目录是它唯一的副本，不删。
                log.fault("换回旧版本失败，errno \(code)，旧版本保留在 \(staged.path, privacy: .public)")
                log.fault("已安装的路径下是没通过复核的新版本，暂存目录不删")
                return .failure(.swapFailed(code: code))
            }
            try? FileManager.default.removeItem(at: staging)
            return .failure(.signatureInvalid(status: recheck))
        }

        // 第 11 步：修改时间与 LaunchServices 登记，失败只记日志。
        touchAndRegister(installed)

        // 第 12 步。
        log.info("已安装 \(prepared.version, privacy: .public)，旧包在 \(staging.path, privacy: .public)")
        return .success(InstallOutcome(installedVersion: prepared.version, stagingPath: staging.path))
    }

    /// 第 2～5 步。成功时返回（暂存目录，暂存目录里的副本）；dmg 在返回前已卸载。
    private func stageCopy(from image: URL, installed: URL) async -> Result<(URL, URL), UpdateError> {
        let mountPoint: URL
        do {
            mountPoint = try await DiskImage.attach(image, mountRoot: mountRoot)
        } catch {
            log.error("挂载 dmg 失败：\(String(describing: error), privacy: .public)")
            return .failure(error)
        }
        let result = copyApp(from: mountPoint, installed: installed)
        await DiskImage.detach(mountPoint)
        // hdiutil 卸载后通常自己删掉随机目录；卸载失败时目录仍是挂载点，不去删卷里的内容。
        if !isMountPoint(mountPoint) { try? FileManager.default.removeItem(at: mountPoint) }
        return result
    }

    /// 第 3～5 步（卸载由调用方做）：找卷里的应用、建暂存目录、复制。
    private func copyApp(from mountPoint: URL, installed: URL) -> Result<(URL, URL), UpdateError> {
        // 第 3 步：lstat 不跟随符号链接，符号链接与普通文件都按「卷里没有应用」处理。
        let source = mountPoint.appendingPathComponent(UpdateAssetContract.appBundleName, isDirectory: true)
        var info = stat()
        guard lstat(source.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            log.error("dmg 里没有 \(UpdateAssetContract.appBundleName, privacy: .public) 目录")
            return .failure(.appMissingInImage)
        }
        // 第 4 步：暂存目录与已安装的包在同一个卷上，第 9 步的改名才是原子的。
        let staging: URL
        do {
            staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                  appropriateFor: installed, create: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
        } catch {
            log.error("建暂存目录失败：\(String(describing: error), privacy: .public)")
            return .failure(.swapFailed(code: Int32((error as NSError).code)))
        }
        // 第 5 步：复制。
        let staged = staging.appendingPathComponent(UpdateAssetContract.appBundleName, isDirectory: true)
        do {
            try FileManager.default.copyItem(at: source, to: staged)
        } catch {
            log.error("从 dmg 复制应用失败：\(String(describing: error), privacy: .public)")
            try? FileManager.default.removeItem(at: staging)
            return .failure(.imageMountFailed("copy failed"))
        }
        return .success((staging, staged))
    }

    /// 第 6、7 步。通过时返回 nil。
    private func verifyStaged(_ staged: URL, prepared: PreparedUpdate, environment: AppEnvironment,
                              systemVersion: String) -> UpdateError? {
        guard let requirement = environment.signature.designatedRequirement, !requirement.isEmpty else {
            log.fault("正在运行的应用没有指定要求，无法核对新版本")
            return .requirementNotSatisfied
        }
        let status = CodeSignatureVerifier.check(bundleAt: staged, requirement: requirement)
        if let error = CodeSignatureVerifier.error(for: status) {
            log.fault("新版本的签名核对失败：SecStaticCodeCheckValidityWithErrors 返回 \(status)")
            return error
        }
        do {
            try UpdatePolicy.validate(staged: stagedInfo(staged), releaseVersion: prepared.version,
                                      running: environment, systemVersion: systemVersion)
        } catch {
            log.fault("新版本的 Info.plist 核对失败：\(String(describing: error), privacy: .public)")
            return error
        }
        return nil
    }

    /// 读副本的 Info.plist 与可执行文件的架构。
    func stagedInfo(_ bundle: URL) -> StagedAppInfo {
        let plistURL = bundle.appendingPathComponent("Contents/Info.plist")
        let plist = (try? Data(contentsOf: plistURL))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) } as? [String: Any] ?? [:]
        let architectures = Bundle(url: bundle)?.executableArchitectures?.map(\.intValue) ?? []
        return StagedAppInfo(bundleIdentifier: plist["CFBundleIdentifier"] as? String,
                             version: plist["CFBundleShortVersionString"] as? String,
                             buildLabel: plist["EVEOBuildLabel"] as? String,
                             executableName: plist["CFBundleExecutable"] as? String,
                             minimumSystemVersion: plist["LSMinimumSystemVersion"] as? String,
                             hasCurrentArchitecture: architectures.contains(BundleInstaller.currentArchitecture))
    }

    /// 本进程的架构，取 `NSBundleExecutableArchitecture*` 的值。
    static var currentArchitecture: Int {
        #if arch(arm64)
        return NSBundleExecutableArchitectureARM64
        #else
        return NSBundleExecutableArchitectureX86_64
        #endif
    }

    /// 第 8 步：递归删掉隔离属性。属性不存在不算错，别的失败只记日志。
    private func removeQuarantine(under root: URL) {
        var paths = [root.path]
        if let enumerator = FileManager.default.enumerator(atPath: root.path) {
            for case let relative as String in enumerator { paths.append(root.path + "/" + relative) }
        }
        for path in paths where removexattr(path, BundleInstaller.quarantineAttribute, XATTR_NOFOLLOW) != 0 {
            if errno != ENOATTR { log.error("删隔离属性失败，errno \(errno)") }
        }
    }

    // MARK: - 替换

    /// 第 9 步之前核对已安装的路径：`lstat` 是目录而不是符号链接；Info.plist 的 bundle id 与版本号等于正在运行的应用。
    /// 不满足时返回 `bundleMismatch("installedBundle")`：路径被换成了别的东西，或用户已手动换了版本，不去覆盖它。
    func checkInstalled(_ installed: URL, environment: AppEnvironment) -> UpdateError? {
        var info = stat()
        guard lstat(installed.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            log.error("已安装的路径不是目录（或是符号链接），不替换")
            return .bundleMismatch("installedBundle")
        }
        let current = stagedInfo(installed)
        guard current.bundleIdentifier == environment.bundleIdentifier, current.version == environment.version else {
            let found = "\(current.bundleIdentifier ?? "nil") \(current.version ?? "nil")"
            log.error("已安装的包与正在运行的应用不同（\(found, privacy: .public)），不替换")
            return .bundleMismatch("installedBundle")
        }
        return nil
    }

    /// 第 9 步：`RENAME_SWAP` 一次交换。成功时返回 nil，已安装的路径下是新版本，旧版本在 staged 的位置。
    /// 失败时返回 `swapFailed`；交换是原子的，失败时两边都没有动，旧版本仍在已安装的路径上。
    private func replace(installed: URL, with staged: URL) -> UpdateError? {
        guard renamex_np(staged.path, installed.path, UInt32(RENAME_SWAP)) != 0 else { return nil }
        let code = errno
        log.error("RENAME_SWAP 失败，errno \(code)；已安装的应用没有改动。只有 APFS 卷支持自动安装")
        return .swapFailed(code: code)
    }

    /// 第 10 步失败后再交换一次，换回旧版本（交换后 staged 的位置上是旧版本）。
    /// 返回 nil 表示旧版本已回到已安装的路径；否则返回 errno，旧版本仍在 staged 的位置。
    private func revert(installed: URL, staged: URL) -> Int32? {
        guard renamex_np(staged.path, installed.path, UInt32(RENAME_SWAP)) != 0 else { return nil }
        return errno
    }

    /// 删除 dmg，只在它位于缓存目录下时删。
    private func removeImage(_ image: URL) {
        guard BundleInstaller.isInsideCache(image.path, cacheRoot: cacheRoot) else {
            log.error("待装的 dmg 不在更新缓存目录下，不删：\(image.path, privacy: .public)")
            return
        }
        try? FileManager.default.removeItem(at: image)
    }

    /// path 解析符号链接并规范化后是否位于 cacheRoot（同样解析）之下。任何一个解析不了（不存在）时返回 false。
    static func isInsideCache(_ path: String, cacheRoot: URL) -> Bool {
        guard let resolvedPath = realPath(path), let resolvedRoot = realPath(cacheRoot.path) else { return false }
        let root = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        return resolvedPath.hasPrefix(root)
    }

    /// `realpath(3)`：解析全部符号链接与 `.`、`..`。路径不存在时返回 nil。
    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// 第 11 步：修改时间设为现在，并让 LaunchServices 重新登记。失败只记日志。
    private func touchAndRegister(_ installed: URL) {
        do {
            try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: installed.path)
        } catch {
            log.error("设修改时间失败：\(String(describing: error), privacy: .public)")
        }
        guard registersWithLaunchServices else { return }
        let status = LSRegisterURL(installed as CFURL, true)
        if status != noErr { log.error("LSRegisterURL 返回 \(status)") }
    }

    // MARK: - 残留清理

    /// 卸载 `Updates/mnt/` 下残留的挂载点；删 `Updates/` 下除 prepared 的 dmg 以外的文件；按规则删上次换下来的旧包。
    func removeLeftovers(keeping prepared: PreparedUpdate?, staleStagingPath: String?) async {
        let manager = FileManager.default
        // 挂载点：目录与它的上一级不在同一个设备上。
        if let entries = try? manager.contentsOfDirectory(atPath: mountRoot.path) {
            for entry in entries {
                let point = mountRoot.appendingPathComponent(entry, isDirectory: true)
                if isMountPoint(point) { await DiskImage.detach(point) }
                // 卸载失败时它仍是挂载点，不去删卷里的内容，留到下次再试。
                if !isMountPoint(point) { try? manager.removeItem(at: point) }
            }
        }
        let keep = prepared.map { URL(fileURLWithPath: $0.imagePath).standardizedFileURL.path }
        removeFiles(in: cacheRoot, keeping: keep)
        if let staleStagingPath { removeStaleStaging(staleStagingPath) }
    }

    /// 递归删 directory 下的文件，keep 指向的文件与通往它的目录保留。`mnt` 目录本身保留。
    private func removeFiles(in directory: URL, keeping keep: String?) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(atPath: directory.path) else { return }
        for entry in entries {
            let url = directory.appendingPathComponent(entry)
            let path = url.standardizedFileURL.path
            if path == keep { continue }
            if let keep, keep.hasPrefix(path + "/") {
                removeFiles(in: url, keeping: keep)
            } else if directory == cacheRoot && entry == BundleInstaller.mountDirectoryName {
                continue
            } else {
                try? manager.removeItem(at: url)
            }
        }
    }

    /// 上次换下来的旧包只在同时满足以下条件时删：路径里有 `/TemporaryItems/`；是目录；
    /// 里面只有一个条目，名字是 `EVE-O Preview.app`。不满足时不删，只记日志。
    private func removeStaleStaging(_ path: String) {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        guard exists else { return }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        let allowed: Set<String> = [UpdateAssetContract.appBundleName]
        guard path.contains("/TemporaryItems/"), isDirectory.boolValue, entries.count == 1,
              allowed.contains(entries[0]) else {
            log.error("旧包目录不符合删除条件，不删：\(path, privacy: .public)")
            return
        }
        do {
            try FileManager.default.removeItem(atPath: path)
            log.info("已删除上次安装换下来的旧包")
        } catch {
            log.error("删旧包失败：\(String(describing: error), privacy: .public)")
        }
    }

    /// 目录是不是挂载点：它与上一级目录的设备号不同。
    private func isMountPoint(_ url: URL) -> Bool {
        var own = stat()
        var parent = stat()
        guard stat(url.path, &own) == 0, stat(url.deletingLastPathComponent().path, &parent) == 0 else { return false }
        return own.st_dev != parent.st_dev
    }
}
