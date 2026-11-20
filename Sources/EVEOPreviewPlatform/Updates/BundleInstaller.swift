// SPDX-License-Identifier: GPL-3.0-or-later
//
// 安装更新（v1.1 设计 9.3 节）。12 步按顺序执行，第 9 步（替换）之前的任何失败都不碰已安装的应用：
//  1. 重新算能否安装；重新算 dmg 的 SHA-256 并与记录比较。
//  2. 挂载 dmg（`DiskImage`）。从这一步起，不论成败都在结束前卸载。
//  3. 找卷顶层的 `EVE-O Preview.app`，`lstat` 确认是目录而不是符号链接。
//  4. 在已安装的包所在的卷上建暂存目录（`itemReplacementDirectory`），权限 0700。
//  5. 把应用复制进暂存目录，然后卸载 dmg。
//  6. 核对暂存副本的签名，要求满足正在运行的应用的指定要求（`CodeSignatureVerifier`）。
//  7. 核对副本的 Info.plist 与架构（`UpdatePolicy.validate`）。
//  8. 删掉副本上的 `com.apple.quarantine`（递归，不存在不算错）。
//  9. `renamex_np(副本, 已安装的包, RENAME_SWAP)`；ENOTSUP 或 EINVAL 时改为两次改名。
// 10. 对已安装的路径再核对一次签名；失败时换回旧版本，返回 `signatureInvalid`。
// 11. 把已安装的包的修改时间设为现在，并 `LSRegisterURL`；失败只记日志。
// 12. 返回 `InstallOutcome`。
//
// 失败的处理按 9.4 节：挂载与复制失败时卸载并删暂存目录；验证失败时另删 dmg，并写一条 fault 日志。
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
    /// 回退替换时旧包在暂存目录里的名字。
    static let previousBundleName = "previous.app"
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
        guard let actual = UpdateDownloader.sha256(of: image), actual == prepared.sha256.lowercased() else {
            log.error("待装的 dmg 与下载时的 SHA-256 不同，删掉它")
            try? FileManager.default.removeItem(at: image)
            return .failure(.checksumMismatch)
        }
        let installed = URL(fileURLWithPath: installedPath, isDirectory: true)

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
            try? FileManager.default.removeItem(at: image)
            return .failure(error)
        }

        // 第 8 步：去掉隔离属性。
        removeQuarantine(under: staged)

        // 第 9 步：替换。
        let swap: SwapMode
        switch replace(installed: installed, with: staged, staging: staging) {
        case .success(let mode): swap = mode
        case .failure(let error):
            try? FileManager.default.removeItem(at: staging)
            return .failure(error)
        }

        // 第 10 步：替换后复核已安装的路径。
        let recheck = CodeSignatureVerifier.check(bundleAt: installed,
                                                  requirement: environment.signature.designatedRequirement ?? "")
        if recheck != errSecSuccess {
            log.fault("替换后复核签名失败，返回值 \(recheck)，换回旧版本")
            revert(installed: installed, staging: staging, mode: swap)
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

    /// 第 9 步用的是哪种办法，第 10 步换回时按同样的办法反过来做。
    enum SwapMode: Sendable {
        /// `RENAME_SWAP` 一次交换。
        case exchange
        /// 两次改名：旧包在暂存目录的 `previous.app`。
        case twoRenames
    }

    /// 第 9 步。成功后已安装的路径下是新版本，旧版本在暂存目录里。
    private func replace(installed: URL, with staged: URL, staging: URL) -> Result<SwapMode, UpdateError> {
        if renamex_np(staged.path, installed.path, UInt32(RENAME_SWAP)) == 0 { return .success(.exchange) }
        let code = errno
        guard code == ENOTSUP || code == EINVAL else {
            log.error("RENAME_SWAP 失败，errno \(code)")
            return .failure(.swapFailed(code: code))
        }
        log.notice("文件系统不支持 RENAME_SWAP（errno \(code)），改为两次改名")
        let previous = staging.appendingPathComponent(BundleInstaller.previousBundleName, isDirectory: true)
        guard rename(installed.path, previous.path) == 0 else {
            let first = errno
            log.error("把旧包移到暂存目录失败，errno \(first)")
            return .failure(.swapFailed(code: first))
        }
        guard rename(staged.path, installed.path) != 0 else { return .success(.twoRenames) }
        let second = errno
        if rename(previous.path, installed.path) != 0 {
            log.fault("新包改名失败（errno \(second)），旧包也没能改回原处，旧包在 \(previous.path, privacy: .public)")
        } else {
            log.error("新包改名失败，errno \(second)，已把旧包改回原处")
        }
        return .failure(.swapFailed(code: second))
    }

    /// 第 10 步失败后换回旧版本。
    private func revert(installed: URL, staging: URL, mode: SwapMode) {
        let stagedName = staging.appendingPathComponent(UpdateAssetContract.appBundleName, isDirectory: true)
        switch mode {
        case .exchange:
            // 暂存目录里的同名包现在是旧版本，再交换一次。
            if renamex_np(stagedName.path, installed.path, UInt32(RENAME_SWAP)) != 0 {
                log.fault("换回旧版本失败，errno \(errno)，旧包在 \(stagedName.path, privacy: .public)")
            }
        case .twoRenames:
            let previous = staging.appendingPathComponent(BundleInstaller.previousBundleName, isDirectory: true)
            guard rename(installed.path, stagedName.path) == 0, rename(previous.path, installed.path) == 0 else {
                log.fault("换回旧版本失败，errno \(errno)，旧包在 \(previous.path, privacy: .public)")
                return
            }
        }
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
    /// 里面只有一个条目，名字是 `EVE-O Preview.app` 或 `previous.app`。不满足时不删，只记日志。
    private func removeStaleStaging(_ path: String) {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        guard exists else { return }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        let allowed: Set<String> = [UpdateAssetContract.appBundleName, BundleInstaller.previousBundleName]
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
