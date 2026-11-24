// SPDX-License-Identifier: GPL-3.0-or-later
//
// NVIDIA 驱动配置库（DRS）的读写，用来给 exefile.exe 设「最大帧速率」（规则见 eveo_core::frame_cap）。
//
// 做法：从 System32 动态加载 nvapi64.dll（随 NVIDIA 驱动安装；没有这个 DLL 就不是 NVIDIA），用它唯一导出的
// nvapi_QueryInterface 按编号取各个函数。编号、结构体布局与状态码取自 NVIDIA 公开的 NVAPI SDK
// （github.com/NVIDIA/nvapi 的 nvapi_interface.h、nvapi.h、nvapi_lite_common.h 与 NvApiDriverSettings.h）。
// 只碰驱动的配置库，不碰 EVE 客户端进程：效果与用户在 NVIDIA 控制面板「管理 3D 设置 > 程序设置」里手动设置相同。
//
// 一次操作在一个 DRS 会话里完成：建会话 → 载入配置库 → 读现状 → 按计划改 → 保存 → 销毁会话。
// 载入配置库要几十到几百毫秒，调用方应放在后台线程里，不要卡住界面。
// DLL 加载一次后一直留在进程里（NVAPI 本身也不建议反复卸载）。

//! NVIDIA 驱动配置库：读写 exefile.exe 的「最大帧速率」。

use std::ffi::c_void;
use std::sync::OnceLock;

use eveo_core::frame_cap::{DriverState, EXE_NAME, OWN_PROFILE_NAME, Plan, Step};
use windows::Win32::System::LibraryLoader::{GetProcAddress, LOAD_LIBRARY_SEARCH_SYSTEM32, LoadLibraryExW};
use windows::core::{s, w};

/// NVAPI 的状态码：成功。
pub const OK: i32 = 0;
/// 找不到 NVAPI 的库（不是 NVIDIA 显卡或驱动没装）。
pub const LIBRARY_NOT_FOUND: i32 = -2;
/// 没有 NVIDIA 显卡驱动着显示器（例如只装了驱动没插卡）。
pub const NVIDIA_DEVICE_NOT_FOUND: i32 = -6;
/// 要管理员权限才能调用。
pub const INVALID_USER_PRIVILEGE: i32 = -137;
/// 设置项不存在（配置文件上没有这项设置）。
const SETTING_NOT_FOUND: i32 = -160;
/// 配置文件不存在。
const PROFILE_NOT_FOUND: i32 = -163;
/// 配置文件名已被占用。
const PROFILE_NAME_IN_USE: i32 = -164;
/// 程序不在任何配置文件里。
const EXECUTABLE_NOT_FOUND: i32 = -166;

/// 「最大帧速率」（Frame Rate Limiter，FRL_FPS_ID）：值是帧数，0 表示不限。
const FRL_FPS_ID: u32 = 0x1083_5002;
/// 设置值的类型：DWORD。
const DWORD_TYPE: u32 = 0;
/// 设置值来自所查询的配置文件本身（而不是全局、基础或默认配置文件）。
const CURRENT_PROFILE_LOCATION: u32 = 0;

/// NVAPI 的定长 Unicode 字符串：2048 个 UTF-16 单元，以 0 结尾。
const UNICODE_MAX: usize = 2048;
/// NVAPI 的定长 Unicode 字符串。
type UnicodeString = [u16; UNICODE_MAX];
/// 会话与配置文件的句柄（驱动内部的指针，只原样传回）。
type Handle = *mut c_void;

/// NVDRS_SETTING_V1。两个联合体各 4100 字节（最大成员是 4 字节长度加 4096 字节数据的二进制值），用 u32 数组占位，
/// 只读写开头的 DWORD。结构按 4 字节对齐，总长 12320 字节。
#[repr(C)]
struct DrsSetting {
    version: u32,
    setting_name: UnicodeString,
    setting_id: u32,
    setting_type: u32,
    setting_location: u32,
    is_current_predefined: u32,
    is_predefined_valid: u32,
    predefined_value: [u32; 1025],
    current_value: [u32; 1025],
}

/// NVDRS_PROFILE_V1，4116 字节。
#[repr(C)]
struct DrsProfile {
    version: u32,
    profile_name: UnicodeString,
    gpu_support: u32,
    is_predefined: u32,
    num_of_apps: u32,
    num_of_settings: u32,
}

/// NVDRS_APPLICATION_V3，16396 字节。最后一个字段是位域（isMetro、isCommandLine），这里都填 0。
#[repr(C)]
struct DrsApplication {
    version: u32,
    is_predefined: u32,
    app_name: UnicodeString,
    user_friendly_name: UnicodeString,
    launcher: UnicodeString,
    file_in_folder: UnicodeString,
    flags: u32,
}

// 布局与 SDK 一致：长度不对时驱动会返回 NVAPI_INCOMPATIBLE_STRUCT_VERSION，在编译时先拦住。
const _: () = assert!(size_of::<DrsSetting>() == 12320);
const _: () = assert!(size_of::<DrsProfile>() == 4116);
const _: () = assert!(size_of::<DrsApplication>() == 16396);

/// MAKE_NVAPI_VERSION：结构长度或上版本号左移 16 位。
const fn version<T>(ver: u32) -> u32 {
    size_of::<T>() as u32 | (ver << 16)
}

/// 把 Rust 字符串写成 NVAPI 的定长字符串（超长时截断，保留结尾的 0）。
fn unicode(text: &str) -> Box<UnicodeString> {
    let mut buffer = Box::new([0u16; UNICODE_MAX]);
    for (slot, unit) in buffer.iter_mut().zip(text.encode_utf16().take(UNICODE_MAX - 1)) {
        *slot = unit;
    }
    buffer
}

/// 读出定长字符串，到第一个 0 为止。
fn from_unicode(buffer: &UnicodeString) -> String {
    let len = buffer.iter().position(|&c| c == 0).unwrap_or(UNICODE_MAX);
    String::from_utf16_lossy(&buffer[..len])
}

/// 只带会话句柄的函数（销毁、载入、保存会话）。
type SessionFn = unsafe extern "C" fn(Handle) -> i32;
/// 建会话。
type CreateSessionFn = unsafe extern "C" fn(*mut Handle) -> i32;
/// 按程序名找配置文件。
type FindApplicationFn = unsafe extern "C" fn(Handle, *const u16, *mut Handle, *mut DrsApplication) -> i32;
/// 按名字找配置文件。
type FindProfileFn = unsafe extern "C" fn(Handle, *const u16, *mut Handle) -> i32;
/// 读配置文件的信息。
type ProfileInfoFn = unsafe extern "C" fn(Handle, Handle, *mut DrsProfile) -> i32;
/// 新建配置文件。
type CreateProfileFn = unsafe extern "C" fn(Handle, *mut DrsProfile, *mut Handle) -> i32;
/// 删除配置文件。
type DeleteProfileFn = unsafe extern "C" fn(Handle, Handle) -> i32;
/// 往配置文件里加程序。
type CreateApplicationFn = unsafe extern "C" fn(Handle, Handle, *mut DrsApplication) -> i32;
/// 读一项设置。
type GetSettingFn = unsafe extern "C" fn(Handle, Handle, u32, *mut DrsSetting) -> i32;
/// 写一项设置。
type SetSettingFn = unsafe extern "C" fn(Handle, Handle, *mut DrsSetting) -> i32;
/// 删除配置文件上的一项设置。
type DeleteSettingFn = unsafe extern "C" fn(Handle, Handle, u32) -> i32;

/// 用到的 NVAPI 函数。函数指针可以在线程间共享，整个表放在 OnceLock 里只取一次。
struct Api {
    create_session: CreateSessionFn,
    destroy_session: SessionFn,
    load_settings: SessionFn,
    save_settings: SessionFn,
    find_application_by_name: FindApplicationFn,
    find_profile_by_name: FindProfileFn,
    get_profile_info: ProfileInfoFn,
    create_profile: CreateProfileFn,
    delete_profile: DeleteProfileFn,
    create_application: CreateApplicationFn,
    get_setting: GetSettingFn,
    set_setting: SetSettingFn,
    delete_profile_setting: DeleteSettingFn,
}

/// 加载并初始化 NVAPI，结果缓存起来：失败时是状态码（不是 NVIDIA 时为 LIBRARY_NOT_FOUND 或 NVIDIA_DEVICE_NOT_FOUND）。
fn api() -> Result<&'static Api, i32> {
    static API: OnceLock<Result<Api, i32>> = OnceLock::new();
    API.get_or_init(load).as_ref().map_err(|&code| code)
}

/// 取函数指针：`id` 是 nvapi_interface.h 里的编号。
macro_rules! entry {
    ($query:expr, $id:expr, $ty:ty) => {{
        // SAFETY: nvapi_QueryInterface 按编号返回函数地址，取不到时返回空指针。
        let address = unsafe { $query($id) };
        if address.is_null() {
            return Err(LIBRARY_NOT_FOUND);
        }
        // SAFETY: 编号与函数签名都取自 NVAPI SDK 的头文件，地址指向签名相符的函数。
        unsafe { std::mem::transmute::<*mut c_void, $ty>(address) }
    }};
}

/// 加载 nvapi64.dll、调 NvAPI_Initialize 并取全部用到的函数。
fn load() -> Result<Api, i32> {
    // 只在 System32 里找，避免加载到当前目录里同名的 DLL。
    // SAFETY: 参数是常量字符串；失败时返回错误。
    let module = unsafe { LoadLibraryExW(w!("nvapi64.dll"), None, LOAD_LIBRARY_SEARCH_SYSTEM32) }
        .map_err(|_| LIBRARY_NOT_FOUND)?;
    // SAFETY: module 是刚加载的模块，名字是常量字符串。
    let query = unsafe { GetProcAddress(module, s!("nvapi_QueryInterface")) }.ok_or(LIBRARY_NOT_FOUND)?;
    // SAFETY: nvapi_QueryInterface 的签名是 `void* (unsigned int)`，x64 上 C 约定就是系统约定。
    let query = unsafe {
        std::mem::transmute::<unsafe extern "system" fn() -> isize, unsafe extern "C" fn(u32) -> *mut c_void>(
            query,
        )
    };
    let initialize = entry!(query, 0x0150_E828, unsafe extern "C" fn() -> i32);
    // SAFETY: 无参数；没有 NVIDIA 显卡时返回 NVIDIA_DEVICE_NOT_FOUND。
    let status = unsafe { initialize() };
    if status != OK {
        return Err(status);
    }
    Ok(Api {
        create_session: entry!(query, 0x0694_D52E, CreateSessionFn),
        destroy_session: entry!(query, 0xDAD9_CFF8, SessionFn),
        load_settings: entry!(query, 0x375D_BD6B, SessionFn),
        save_settings: entry!(query, 0xFCBC_7E14, SessionFn),
        find_application_by_name: entry!(query, 0xEEE5_66B2, FindApplicationFn),
        find_profile_by_name: entry!(query, 0x7E4A_9A0B, FindProfileFn),
        get_profile_info: entry!(query, 0x61CD_6FD6, ProfileInfoFn),
        create_profile: entry!(query, 0xCC17_6068, CreateProfileFn),
        delete_profile: entry!(query, 0x1709_3206, DeleteProfileFn),
        create_application: entry!(query, 0x4347_A9DE, CreateApplicationFn),
        get_setting: entry!(query, 0x73BF_8338, GetSettingFn),
        set_setting: entry!(query, 0x577D_D202, SetSettingFn),
        delete_profile_setting: entry!(query, 0xE4A2_6362, DeleteSettingFn),
    })
}

/// 状态码转成结果。
fn check(status: i32) -> Result<(), i32> {
    if status == OK { Ok(()) } else { Err(status) }
}

/// 一个已载入配置库的 DRS 会话，析构时销毁。
struct Session {
    api: &'static Api,
    handle: Handle,
}

impl Drop for Session {
    fn drop(&mut self) {
        // SAFETY: 句柄由 create_session 得到，只在这里销毁一次。
        unsafe {
            (self.api.destroy_session)(self.handle);
        }
    }
}

impl Session {
    /// 建会话并载入配置库。
    fn open() -> Result<Self, i32> {
        let api = api()?;
        let mut handle: Handle = std::ptr::null_mut();
        // SAFETY: handle 是有效的输出位置。
        check(unsafe { (api.create_session)(&mut handle) })?;
        let session = Self { api, handle };
        // SAFETY: 会话句柄有效。
        check(unsafe { (api.load_settings)(session.handle) })?;
        Ok(session)
    }

    /// exefile.exe 所在的配置文件：句柄与名字；不在任何配置文件里时为 `None`。
    fn exe_profile(&self) -> Result<Option<(Handle, String)>, i32> {
        let name = unicode(EXE_NAME);
        let mut profile: Handle = std::ptr::null_mut();
        let mut application = new_application();
        // SAFETY: 名字是以 0 结尾的定长缓冲区，两个输出位置都有效，application 的版本号已填。
        let status = unsafe {
            (self.api.find_application_by_name)(self.handle, name.as_ptr(), &mut profile, &mut *application)
        };
        match status {
            OK => Ok(Some((profile, self.profile_name(profile)?))),
            EXECUTABLE_NOT_FOUND => Ok(None),
            code => Err(code),
        }
    }

    /// 配置文件的名字。
    fn profile_name(&self, profile: Handle) -> Result<String, i32> {
        let mut info = Box::new(DrsProfile {
            version: version::<DrsProfile>(1),
            profile_name: [0; UNICODE_MAX],
            gpu_support: 0,
            is_predefined: 0,
            num_of_apps: 0,
            num_of_settings: 0,
        });
        // SAFETY: 句柄来自本会话，info 的版本号已填。
        check(unsafe { (self.api.get_profile_info)(self.handle, profile, &mut *info) })?;
        Ok(from_unicode(&info.profile_name))
    }

    /// 配置文件上用户设的帧数：值来自这个配置文件本身且不是预置值时才算；没有时为 `None`。
    fn user_fps(&self, profile: Handle) -> Result<Option<u32>, i32> {
        let mut setting = new_setting(0);
        // SAFETY: 句柄来自本会话，setting 的版本号已填。
        let status = unsafe { (self.api.get_setting)(self.handle, profile, FRL_FPS_ID, &mut *setting) };
        match status {
            OK if setting.setting_location == CURRENT_PROFILE_LOCATION
                && setting.is_current_predefined == 0 =>
            {
                Ok(Some(setting.current_value[0]))
            }
            OK | SETTING_NOT_FOUND => Ok(None),
            code => Err(code),
        }
    }

    /// 读出 exefile.exe 的现状。
    fn state(&self) -> Result<(DriverState, Option<Handle>), i32> {
        let Some((handle, name)) = self.exe_profile()? else {
            return Ok((DriverState::default(), None));
        };
        let user_fps = self.user_fps(handle)?;
        Ok((
            DriverState {
                profile: Some(name),
                user_fps,
            },
            Some(handle),
        ))
    }

    /// 新建（或找到同名的）自己的配置文件，并把 exefile.exe 加进去。
    fn create_own_profile(&self) -> Result<Handle, i32> {
        let mut info = Box::new(DrsProfile {
            version: version::<DrsProfile>(1),
            profile_name: *unicode(OWN_PROFILE_NAME),
            gpu_support: 0,
            is_predefined: 0,
            num_of_apps: 0,
            num_of_settings: 0,
        });
        let mut profile: Handle = std::ptr::null_mut();
        // SAFETY: info 的版本号与名字已填，profile 是有效的输出位置。
        match unsafe { (self.api.create_profile)(self.handle, &mut *info, &mut profile) } {
            OK => {}
            // 同名的配置文件还在（上次没删干净）：接着用它。
            PROFILE_NAME_IN_USE => profile = self.find_own_profile()?.ok_or(PROFILE_NOT_FOUND)?,
            code => return Err(code),
        }
        let mut application = new_application();
        application.app_name = *unicode(EXE_NAME);
        application.user_friendly_name = *unicode("EVE Online");
        // SAFETY: 句柄来自本会话，application 的版本号与名字已填。
        check(unsafe { (self.api.create_application)(self.handle, profile, &mut *application) })?;
        Ok(profile)
    }

    /// 按名字找自己的配置文件。
    fn find_own_profile(&self) -> Result<Option<Handle>, i32> {
        let name = unicode(OWN_PROFILE_NAME);
        let mut profile: Handle = std::ptr::null_mut();
        // SAFETY: 名字是以 0 结尾的定长缓冲区，profile 是有效的输出位置。
        match unsafe { (self.api.find_profile_by_name)(self.handle, name.as_ptr(), &mut profile) } {
            OK => Ok(Some(profile)),
            PROFILE_NOT_FOUND => Ok(None),
            code => Err(code),
        }
    }

    /// 执行一步。`profile` 是 exefile.exe 所在的配置文件，新建自己的配置文件后换成新的句柄。
    fn run(&self, step: &Step, profile: &mut Option<Handle>) -> Result<(), i32> {
        match step {
            Step::CreateOwnProfile => *profile = Some(self.create_own_profile()?),
            Step::SetFps(fps) => {
                let target = profile.ok_or(EXECUTABLE_NOT_FOUND)?;
                let mut setting = new_setting(*fps);
                // SAFETY: 句柄来自本会话，setting 的版本号、编号、类型与值已填。
                check(unsafe { (self.api.set_setting)(self.handle, target, &mut *setting) })?;
            }
            Step::DeleteFps => {
                let target = profile.ok_or(EXECUTABLE_NOT_FOUND)?;
                // SAFETY: 句柄来自本会话。
                match unsafe { (self.api.delete_profile_setting)(self.handle, target, FRL_FPS_ID) } {
                    // 已经没有这项设置：目的已达到。
                    OK | SETTING_NOT_FOUND => {}
                    code => return Err(code),
                }
            }
            Step::DeleteOwnProfile => {
                if let Some(own) = self.find_own_profile()? {
                    // SAFETY: 句柄来自本会话。
                    check(unsafe { (self.api.delete_profile)(self.handle, own) })?;
                }
            }
        }
        Ok(())
    }

    /// 把改动写回驱动。非管理员不允许写时返回 INVALID_USER_PRIVILEGE。
    fn save(&self) -> Result<(), i32> {
        // SAFETY: 会话句柄有效。
        check(unsafe { (self.api.save_settings)(self.handle) })
    }
}

/// 新的设置结构：「最大帧速率」，DWORD 值为 `fps`。
fn new_setting(fps: u32) -> Box<DrsSetting> {
    let mut setting = Box::new(DrsSetting {
        version: version::<DrsSetting>(1),
        setting_name: [0; UNICODE_MAX],
        setting_id: FRL_FPS_ID,
        setting_type: DWORD_TYPE,
        setting_location: CURRENT_PROFILE_LOCATION,
        is_current_predefined: 0,
        is_predefined_valid: 0,
        predefined_value: [0; 1025],
        current_value: [0; 1025],
    });
    setting.current_value[0] = fps;
    setting
}

/// 新的程序结构（V3），只填了版本号。
fn new_application() -> Box<DrsApplication> {
    Box::new(DrsApplication {
        version: version::<DrsApplication>(3),
        is_predefined: 0,
        app_name: [0; UNICODE_MAX],
        user_friendly_name: [0; UNICODE_MAX],
        launcher: [0; UNICODE_MAX],
        file_in_folder: [0; UNICODE_MAX],
        flags: 0,
    })
}

/// 状态码是不是表示「不是 NVIDIA」（没有库或没有 NVIDIA 显卡）。
pub fn is_not_nvidia(code: i32) -> bool {
    code == LIBRARY_NOT_FOUND || code == NVIDIA_DEVICE_NOT_FOUND
}

/// 读出驱动里 exefile.exe 的现状（检测时用）。失败时返回 NVAPI 的状态码，用 [`is_not_nvidia`] 区分。
pub fn read_state() -> Result<DriverState, i32> {
    Session::open()?.state().map(|(state, _)| state)
}

/// 在一个会话里读现状、按 `planner` 求出计划、执行并保存。返回执行过的计划（调用方据此写记录）与操作后的现状。
/// 计划没有步骤时不保存。任何一步失败都不保存，驱动保持原样。
pub fn apply(planner: impl FnOnce(&DriverState) -> Plan) -> Result<(Plan, DriverState), i32> {
    let session = Session::open()?;
    let (state, mut profile) = session.state()?;
    let plan = planner(&state);
    if plan.steps.is_empty() {
        return Ok((plan, state));
    }
    for step in &plan.steps {
        session.run(step, &mut profile)?;
    }
    session.save()?;
    // 再读一次，让调用方显示的是驱动里真实的值。
    let (after, _) = session.state()?;
    Ok((plan, after))
}
