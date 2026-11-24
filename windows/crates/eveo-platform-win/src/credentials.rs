// SPDX-License-Identifier: GPL-3.0-or-later
//
// Windows 凭据管理器里的翻译 API Key，对应 macOS 的 KeychainSecretStore（设计文档 7.7 节）。
// - 每个服务预设一项「普通凭据」（CRED_TYPE_GENERIC），目标名是 `EVE-O Preview/apikey.<预设>`，
//   在「控制面板 → 凭据管理器 → Windows 凭据」里能看到、也能手动删除。
// - 保存范围是 CRED_PERSIST_LOCAL_MACHINE：只在这台电脑上、只对当前用户可见，不随漫游配置同步到别的电脑。
// - Key 以 UTF-8 字节存放；读出时不是 UTF-8 的内容按「没有 Key」处理（只会是别的程序写了同名凭据）。
// - 读写都是同步调用，很快，不弹窗；与 macOS 钥匙串不同，没有「要用户确认」的情形。
// Key 只在内存里经过这里，不写日志、不进问题报告；错误只带系统错误码。

//! 凭据管理器里的 API Key：读、写、删。

use windows::Win32::Foundation::ERROR_NOT_FOUND;
use windows::Win32::Security::Credentials::{
    CRED_PERSIST_LOCAL_MACHINE, CRED_TYPE_GENERIC, CREDENTIALW, CredDeleteW, CredFree, CredReadW, CredWriteW,
};
use windows::core::{HSTRING, PWSTR};

/// 目标名的前缀，后面接 `apikey.<预设>`（eveo_core::translation::providers::credential_account）。
pub const TARGET_PREFIX: &str = "EVE-O Preview/";
/// Key 的长度上限（字节）。凭据管理器的上限是 2,560 字节；真实的 Key 远小于它。
pub const MAX_SECRET_BYTES: usize = 2_560;

/// 凭据操作失败的原因。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CredentialError {
    /// Key 超过长度上限。
    TooLong,
    /// 系统调用失败，关联值是 HRESULT（不含 Key）。
    System(i32),
}

/// 某个账户名对应的完整目标名。
pub fn target_name(account: &str) -> String {
    format!("{TARGET_PREFIX}{account}")
}

/// 读 Key。没有这项凭据时是 Ok(None)；内容不是 UTF-8 或为空时也是 Ok(None)。
pub fn read(account: &str) -> Result<Option<String>, CredentialError> {
    let target = HSTRING::from(target_name(account));
    let mut credential: *mut CREDENTIALW = std::ptr::null_mut();
    // SAFETY: target 在调用期间有效；credential 是输出指针，成功时由系统分配，下面用 CredFree 释放。
    if let Err(error) = unsafe { CredReadW(&target, CRED_TYPE_GENERIC, None, &mut credential) } {
        if error.code() == ERROR_NOT_FOUND.to_hresult() {
            return Ok(None);
        }
        return Err(CredentialError::System(error.code().0));
    }
    // SAFETY: 读取成功时 credential 指向系统分配的有效结构；blob 指针与长度由系统给出，长度为 0 时指针可能为空。
    let secret = unsafe {
        let value = &*credential;
        let bytes = if value.CredentialBlob.is_null() || value.CredentialBlobSize == 0 {
            Vec::new()
        } else {
            std::slice::from_raw_parts(value.CredentialBlob, value.CredentialBlobSize as usize).to_vec()
        };
        CredFree(credential.cast());
        bytes
    };
    Ok(String::from_utf8(secret).ok().filter(|s| !s.is_empty()))
}

/// 保存 Key（覆盖同名的旧值）。空串等于删除。
pub fn write(account: &str, secret: &str) -> Result<(), CredentialError> {
    if secret.is_empty() {
        return delete(account);
    }
    if secret.len() > MAX_SECRET_BYTES {
        return Err(CredentialError::TooLong);
    }
    let mut target: Vec<u16> = target_name(account).encode_utf16().chain(Some(0)).collect();
    let mut blob = secret.as_bytes().to_vec();
    let credential = CREDENTIALW {
        Type: CRED_TYPE_GENERIC,
        TargetName: PWSTR(target.as_mut_ptr()),
        // 长度已检查过不超过 2,560，放得进 u32。
        CredentialBlobSize: blob.len() as u32,
        CredentialBlob: blob.as_mut_ptr(),
        Persist: CRED_PERSIST_LOCAL_MACHINE,
        ..CREDENTIALW::default()
    };
    // SAFETY: credential 里的指针（目标名、blob）在调用期间有效；系统只读取它们并复制。
    let result = unsafe { CredWriteW(&credential, 0) };
    // 用完立刻把内存里的 Key 抹掉，不等释放。
    blob.fill(0);
    result.map_err(|error| CredentialError::System(error.code().0))
}

/// 删除 Key。本来就没有时也算成功。
pub fn delete(account: &str) -> Result<(), CredentialError> {
    let target = HSTRING::from(target_name(account));
    // SAFETY: target 在调用期间有效。
    match unsafe { CredDeleteW(&target, CRED_TYPE_GENERIC, None) } {
        Ok(()) => Ok(()),
        Err(error) if error.code() == ERROR_NOT_FOUND.to_hresult() => Ok(()),
        Err(error) => Err(CredentialError::System(error.code().0)),
    }
}
