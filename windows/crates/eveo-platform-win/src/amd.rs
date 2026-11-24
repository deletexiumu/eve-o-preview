// SPDX-License-Identifier: GPL-3.0-or-later
//
// AMD 驱动的「帧率目标控制」（Frame Rate Target Control，FRTC）读写，用来在没有 NVIDIA 时给 EVE 限帧
// （规则见 eveo_core::frame_cap::value）。
//
// 注意：FRTC 是整块显卡的全局设置，ADLX 没有按程序设置的接口，打开后所有游戏都会被限帧；设置页上用红字讲明。
// 这和用户在 AMD Software「游戏 > 图形」里打开「帧率目标控制」是一回事。
//
// 做法：从 System32 动态加载 amdadlx64.dll（随 AMD 驱动安装），用 ADLXInitialize 取 IADLXSystem，
// 再按 C 接口的虚表调用：GetGPUs → 选一块显卡（独显优先）→ Get3DSettingsServices → GetFrameRateTargetControl。
// 虚表顺序、函数签名与结构体取自 AMD 公开的 ADLX SDK（github.com/GPUOpen-LibrariesAndSDKs/ADLX 的
// SDK/Include/ADLX.h、ADLXDefines.h、ADLXStructures.h、ICollections.h、ISystem.h、I3DSettings.h）。
// x64 上 ADLX_STD_CALL（__stdcall）与 ADLX_CDECL_CALL 都是同一种调用约定。
//
// 这部分没有在 AMD 显卡上实测过，所以只在独立的子进程里调用（见 eveo-app 的 frame_cap_helper）：
// 万一哪里不对导致崩溃，只是子进程退出，设置页显示错误码，不影响主程序。
//
// 接口的引用计数：除 IADLXSystem 外，取到的接口用完都要 Release；全部释放后调 ADLXTerminate。

//! AMD 驱动的帧率目标控制（全局限帧）。

use std::ffi::c_void;

use eveo_core::frame_cap::SyncError;
use eveo_core::frame_cap::value::{CapValue, GpuKind, ValueBackend};
use windows::core::{s, w};

use crate::driver_dll::{export, load};

/// ADLX_RESULT：成功。ALREADY_ENABLED（1）与 ALREADY_INITIALIZED（2）也算成功（同 ADLX_SUCCEEDED）。
const OK: i32 = 0;
/// ADLX_RESULT：驱动的 ADLX 版本与请求的不兼容。
const BAD_VER: i32 = 5;
/// ADLX_RESULT：ADL 初始化失败（没有 AMD 显卡）。
const ADL_INIT_ERROR: i32 = 8;
/// ADLX_RESULT：没找到。
const NOT_FOUND: i32 = 9;
/// ADLX_RESULT：不支持这项功能。
const NOT_SUPPORTED: i32 = 12;

/// 本模块按 ADLX SDK 2.0.0.125 的头文件写成（ADLX_MAKE_FULL_VER）。驱动里的 ADLX 更旧时按驱动的版本初始化：
/// 用到的接口在 1.0 就有，虚表只在末尾追加。
const SDK_VERSION: u64 = (2 << 48) | 125;

/// ADLX_GPU_TYPE：独立显卡。
const GPU_TYPE_DISCRETE: i32 = 2;

/// 虚表里方法的位置（从 0 数）。IADLXSystem 没有 Acquire/Release，其余接口前三个都是 Acquire、Release、QueryInterface。
mod slot {
    /// IADLXInterface::Release。
    pub const RELEASE: usize = 1;
    /// IADLXSystem::GetGPUs。
    pub const SYSTEM_GET_GPUS: usize = 1;
    /// IADLXSystem::Get3DSettingsServices。
    pub const SYSTEM_GET_3D_SETTINGS: usize = 7;
    /// IADLXList::Begin。
    pub const LIST_BEGIN: usize = 5;
    /// IADLXList::End。
    pub const LIST_END: usize = 6;
    /// IADLXGPUList::At_GPUList。
    pub const GPU_LIST_AT: usize = 11;
    /// IADLXGPU::Type。
    pub const GPU_TYPE: usize = 5;
    /// IADLXGPU::UniqueId。
    pub const GPU_UNIQUE_ID: usize = 18;
    /// IADLX3DSettingsServices::GetFrameRateTargetControl。
    pub const SETTINGS_GET_FRTC: usize = 9;
    /// IADLX3DFrameRateTargetControl::IsSupported。
    pub const FRTC_IS_SUPPORTED: usize = 3;
    /// IADLX3DFrameRateTargetControl::IsEnabled。
    pub const FRTC_IS_ENABLED: usize = 4;
    /// IADLX3DFrameRateTargetControl::GetFPSRange。
    pub const FRTC_GET_RANGE: usize = 5;
    /// IADLX3DFrameRateTargetControl::GetFPS。
    pub const FRTC_GET_FPS: usize = 6;
    /// IADLX3DFrameRateTargetControl::SetEnabled。
    pub const FRTC_SET_ENABLED: usize = 7;
    /// IADLX3DFrameRateTargetControl::SetFPS。
    pub const FRTC_SET_FPS: usize = 8;
}

/// ADLX 的 C 接口：第一个字段指向虚表（函数指针数组）。
#[repr(C)]
struct Interface {
    vtbl: *const *const c_void,
}

/// ADLX_IntRange。
#[repr(C)]
#[derive(Default)]
struct IntRange {
    min_value: i32,
    max_value: i32,
    step: i32,
}

/// ADLXQueryFullVersion。
type QueryFullVersionFn = unsafe extern "C" fn(*mut u64) -> i32;
/// ADLXInitialize。
type InitializeFn = unsafe extern "C" fn(u64, *mut *mut Interface) -> i32;
/// ADLXTerminate。
type TerminateFn = unsafe extern "C" fn() -> i32;
/// Release。
type ReleaseFn = unsafe extern "system" fn(*mut Interface) -> i32;
/// 无参数、取出一个接口的方法（GetGPUs、Get3DSettingsServices）。
type GetInterfaceFn = unsafe extern "system" fn(*mut Interface, *mut *mut Interface) -> i32;
/// 无参数、返回无符号数的方法（Begin、End）。
type GetUintFn = unsafe extern "system" fn(*mut Interface) -> u32;
/// At_GPUList。
type AtFn = unsafe extern "system" fn(*mut Interface, u32, *mut *mut Interface) -> i32;
/// 取出一个整数的方法（Type、UniqueId、GetFPS）。
type GetIntFn = unsafe extern "system" fn(*mut Interface, *mut i32) -> i32;
/// 取出一个布尔的方法（IsSupported、IsEnabled）。adlx_bool 在 C 接口里是 uint8。
type GetBoolFn = unsafe extern "system" fn(*mut Interface, *mut u8) -> i32;
/// GetFrameRateTargetControl。
type GetFrtcFn = unsafe extern "system" fn(*mut Interface, *mut Interface, *mut *mut Interface) -> i32;
/// GetFPSRange。
type GetRangeFn = unsafe extern "system" fn(*mut Interface, *mut IntRange) -> i32;
/// SetEnabled。
type SetBoolFn = unsafe extern "system" fn(*mut Interface, u8) -> i32;
/// SetFPS。
type SetIntFn = unsafe extern "system" fn(*mut Interface, i32) -> i32;

/// 取接口虚表里第 `index` 个方法。
///
/// # Safety
/// `object` 必须是有效的 ADLX 接口，`F` 必须是该位置方法的函数指针类型。
unsafe fn method<F: Copy>(object: *mut Interface, index: usize) -> F {
    const { assert!(size_of::<F>() == size_of::<*const c_void>()) };
    // SAFETY: 调用方保证 object 有效；虚表至少有 index + 1 项（取自 SDK 头文件）。
    let entry = unsafe { *(*object).vtbl.add(index) };
    // SAFETY: F 与函数指针同大小（上面的断言），调用方保证签名相符。
    unsafe { std::mem::transmute_copy::<*const c_void, F>(&entry) }
}

/// ADLX_RESULT 转成结果；ALREADY_ENABLED 与 ALREADY_INITIALIZED 也算成功。
fn check(code: i32) -> Result<(), SyncError> {
    if (OK..=2).contains(&code) {
        Ok(())
    } else if code == NOT_SUPPORTED {
        Err(SyncError::Unsupported)
    } else {
        Err(SyncError::Failed(code))
    }
}

/// 一个带引用计数的接口，析构时 Release。
struct Owned(*mut Interface);

impl Owned {
    /// 包一个刚取到的接口；空指针时按失败处理。
    fn new(object: *mut Interface) -> Result<Self, SyncError> {
        if object.is_null() {
            Err(SyncError::Failed(-1))
        } else {
            Ok(Self(object))
        }
    }
}

impl Drop for Owned {
    fn drop(&mut self) {
        // SAFETY: 指针由 ADLX 返回且只在这里释放一次；Release 在虚表第 1 项。
        unsafe {
            let release: ReleaseFn = method(self.0, slot::RELEASE);
            release(self.0);
        }
    }
}

/// 已经初始化的 ADLX，析构时调 ADLXTerminate。必须在所有接口释放之后析构（见 [`Amd`] 的字段顺序）。
struct Adlx {
    system: *mut Interface,
    terminate: TerminateFn,
}

impl Drop for Adlx {
    fn drop(&mut self) {
        // SAFETY: 与成功的 ADLXInitialize 配对，只调一次。
        unsafe {
            (self.terminate)();
        }
    }
}

/// 一块 AMD 显卡上已经打开的帧率目标控制。字段按析构顺序排列：先释放接口，最后结束 ADLX。
pub struct Amd {
    frtc: Owned,
    _gpu: Owned,
    _adlx: Adlx,
    /// 显卡的标识，写进还原记录。
    target: String,
    /// 显卡种类，用来在 AMD 与 Intel 之间选。
    kind: GpuKind,
    /// 驱动接受的帧数范围。
    range: (u32, u32),
}

impl Amd {
    /// 加载 ADLX、选一块支持帧率目标控制的显卡（独显优先）。没有 AMD 驱动、没有 AMD 显卡、驱动太旧或
    /// 显卡不支持时为 [`SyncError::Unsupported`]。
    pub fn open() -> Result<Self, SyncError> {
        let module = load(w!("amdadlx64.dll")).ok_or(SyncError::Unsupported)?;
        // SAFETY: 名字与签名取自 ADLX.h。
        let (query, initialize, terminate) = unsafe {
            (
                export::<QueryFullVersionFn>(module, s!("ADLXQueryFullVersion")),
                export::<InitializeFn>(module, s!("ADLXInitialize")),
                export::<TerminateFn>(module, s!("ADLXTerminate")),
            )
        };
        let (Some(query), Some(initialize), Some(terminate)) = (query, initialize, terminate) else {
            return Err(SyncError::Unsupported);
        };
        let mut driver_version = 0u64;
        // SAFETY: 输出位置有效。
        let version = if check(unsafe { query(&mut driver_version) }).is_ok() && driver_version != 0 {
            driver_version.min(SDK_VERSION)
        } else {
            SDK_VERSION
        };
        let mut system: *mut Interface = std::ptr::null_mut();
        // SAFETY: 输出位置有效；失败时 system 不变。
        let code = unsafe { initialize(version, &mut system) };
        if matches!(code, BAD_VER | ADL_INIT_ERROR | NOT_FOUND | NOT_SUPPORTED) {
            return Err(SyncError::Unsupported);
        }
        check(code)?;
        if system.is_null() {
            return Err(SyncError::Failed(-1));
        }
        let adlx = Adlx { system, terminate };
        Self::choose_gpu(adlx)
    }

    /// 在显卡列表里按独显优先的顺序找第一块支持帧率目标控制的显卡。
    fn choose_gpu(adlx: Adlx) -> Result<Self, SyncError> {
        let mut list: *mut Interface = std::ptr::null_mut();
        // SAFETY: system 有效，GetGPUs 在虚表第 1 项。
        check(unsafe {
            method::<GetInterfaceFn>(adlx.system, slot::SYSTEM_GET_GPUS)(adlx.system, &mut list)
        })?;
        let list = Owned::new(list)?;
        // SAFETY: list 有效，Begin、End 的位置取自 ICollections.h。
        let (begin, end) = unsafe {
            (
                method::<GetUintFn>(list.0, slot::LIST_BEGIN)(list.0),
                method::<GetUintFn>(list.0, slot::LIST_END)(list.0),
            )
        };
        let mut gpus = Vec::new();
        for index in begin..end {
            let mut gpu: *mut Interface = std::ptr::null_mut();
            // SAFETY: list 有效，index 在 Begin..End 内。
            if check(unsafe { method::<AtFn>(list.0, slot::GPU_LIST_AT)(list.0, index, &mut gpu) }).is_ok()
                && let Ok(gpu) = Owned::new(gpu)
            {
                let mut gpu_type = 0;
                // SAFETY: gpu 有效；取不到类型时当作核显。
                let _ = unsafe { method::<GetIntFn>(gpu.0, slot::GPU_TYPE)(gpu.0, &mut gpu_type) };
                let kind = if gpu_type == GPU_TYPE_DISCRETE {
                    GpuKind::Discrete
                } else {
                    GpuKind::Integrated
                };
                gpus.push((kind, gpu));
            }
        }
        drop(list);
        // 独显排前面；sort_by_key 是稳定排序，同类的保持驱动给的顺序。
        gpus.sort_by_key(|(kind, _)| *kind != GpuKind::Discrete);
        let mut services: *mut Interface = std::ptr::null_mut();
        // SAFETY: system 有效，Get3DSettingsServices 在虚表第 7 项。
        check(unsafe {
            method::<GetInterfaceFn>(adlx.system, slot::SYSTEM_GET_3D_SETTINGS)(adlx.system, &mut services)
        })?;
        let services = Owned::new(services)?;
        for (kind, gpu) in gpus {
            if let Some((frtc, range)) = frame_rate_target_control(&services, &gpu) {
                let mut id = 0;
                // SAFETY: gpu 有效；取不到编号时用 0（只用来区分显卡）。
                let _ = unsafe { method::<GetIntFn>(gpu.0, slot::GPU_UNIQUE_ID)(gpu.0, &mut id) };
                drop(services);
                return Ok(Self {
                    frtc,
                    _gpu: gpu,
                    _adlx: adlx,
                    target: format!("amd-{id}"),
                    kind,
                    range,
                });
            }
        }
        Err(SyncError::Unsupported)
    }

    /// 显卡种类。
    pub fn kind(&self) -> GpuKind {
        self.kind
    }
}

/// 取一块显卡的帧率目标控制与范围；不支持或出错时为 `None`。
fn frame_rate_target_control(services: &Owned, gpu: &Owned) -> Option<(Owned, (u32, u32))> {
    let mut frtc: *mut Interface = std::ptr::null_mut();
    // SAFETY: services、gpu 有效，GetFrameRateTargetControl 在虚表第 9 项。
    check(unsafe { method::<GetFrtcFn>(services.0, slot::SETTINGS_GET_FRTC)(services.0, gpu.0, &mut frtc) })
        .ok()?;
    let frtc = Owned::new(frtc).ok()?;
    let mut supported = 0u8;
    // SAFETY: frtc 有效。
    check(unsafe { method::<GetBoolFn>(frtc.0, slot::FRTC_IS_SUPPORTED)(frtc.0, &mut supported) }).ok()?;
    if supported == 0 {
        return None;
    }
    let mut range = IntRange::default();
    // SAFETY: frtc 有效，range 是有效的输出位置。
    check(unsafe { method::<GetRangeFn>(frtc.0, slot::FRTC_GET_RANGE)(frtc.0, &mut range) }).ok()?;
    let min = u32::try_from(range.min_value).unwrap_or(0);
    let max = u32::try_from(range.max_value).unwrap_or(u32::MAX);
    Some((frtc, (min, max)))
}

impl ValueBackend for Amd {
    fn target(&self) -> &str {
        &self.target
    }

    fn range(&self) -> (u32, u32) {
        self.range
    }

    fn read(&mut self) -> Result<CapValue, SyncError> {
        let frtc = self.frtc.0;
        let (mut enabled, mut fps) = (0u8, 0i32);
        // SAFETY: frtc 有效，输出位置有效。
        unsafe {
            check(method::<GetBoolFn>(frtc, slot::FRTC_IS_ENABLED)(
                frtc,
                &mut enabled,
            ))?;
            check(method::<GetIntFn>(frtc, slot::FRTC_GET_FPS)(frtc, &mut fps))?;
        }
        Ok(CapValue {
            enabled: enabled != 0,
            fps: u32::try_from(fps).unwrap_or(0),
        })
    }

    fn write(&mut self, value: CapValue) -> Result<(), SyncError> {
        let frtc = self.frtc.0;
        let fps = i32::try_from(value.fps).unwrap_or(i32::MAX);
        // 先设帧数再开关：打开的瞬间就是想要的帧数。还原成「关」时帧数照样写回原值，
        // 但原值不在范围内（例如从没设过时读出 0）就不写，免得驱动拒绝导致开关也还原不了。
        let in_range = (self.range.0..=self.range.1).contains(&value.fps);
        // SAFETY: frtc 有效。
        unsafe {
            if value.enabled || in_range {
                check(method::<SetIntFn>(frtc, slot::FRTC_SET_FPS)(frtc, fps))?;
            }
            check(method::<SetBoolFn>(frtc, slot::FRTC_SET_ENABLED)(
                frtc,
                u8::from(value.enabled),
            ))
        }
    }
}
