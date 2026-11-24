// SPDX-License-Identifier: GPL-3.0-or-later
//
// Intel 显卡驱动的按程序限帧（IGCL 的 3D 特性 CTL_3D_FEATURE_FRAME_LIMIT），用来在没有 NVIDIA 时给 EVE 限帧
// （规则见 eveo_core::frame_cap::value）。和 NVIDIA 一样只设 exefile.exe，不影响别的游戏。
//
// 做法：从 System32 动态加载 ControlLib.dll（Intel 显卡驱动随附的 IGCL 运行库，Intel 的封装库也是这样加载的），
// ctlInit → ctlEnumerateDevices → 读每块显卡的属性（独显优先）→ ctlGetSupported3DCapabilities 确认这块显卡
// 支持按程序限帧并取帧数范围 → ctlGetSet3DFeature 读写 exefile.exe 的帧数上限 → ctlClose。
// 结构体布局、函数签名与常量取自 Intel 公开的 IGCL（github.com/intel/drivers.gpu.control-library 的
// include/igcl_api.h 与 Samples/3D_Feature_Samples）。结构体长度与关键字段的位置在编译时断言。
//
// 这部分没有在 Intel 显卡上实测过，所以只在独立的子进程里调用（见 eveo-app 的 frame_cap_helper）：
// 万一哪里不对导致崩溃，只是子进程退出，设置页显示错误码，不影响主程序。

//! Intel 显卡驱动的按程序限帧。

use std::ffi::{CString, c_void};
use std::mem::offset_of;

use eveo_core::frame_cap::value::{CapValue, GpuKind, ValueBackend};
use eveo_core::frame_cap::{EXE_NAME, FPS_RANGE, SyncError};
use windows::core::{s, w};

use crate::driver_dll::{export, load};

/// ctl_result_t：成功。
const SUCCESS: u32 = 0;
/// ctl_result_t：权限不够。
const INSUFFICIENT_PERMISSIONS: u32 = 0x4000_0006;
/// ctl_result_t：驱动不支持请求的版本。
const UNSUPPORTED_VERSION: u32 = 0x4000_0009;
/// ctl_result_t：不支持这项功能。
const UNSUPPORTED_FEATURE: u32 = 0x4000_000a;
/// ctl_result_t：没有实现。
const NOT_IMPLEMENTED: u32 = 0x4000_0015;
/// ctl_result_t：库加载失败。
const LOAD_FAILED: u32 = 0x4000_0026;

/// CTL_MAKE_VERSION(1, 1)：本模块按 IGCL 1.1 的头文件写成。
const APP_VERSION: u32 = (1 << 16) | 1;
/// CTL_3D_FEATURE_FRAME_LIMIT。
const FEATURE_FRAME_LIMIT: u32 = 2;
/// CTL_PROPERTY_VALUE_TYPE_INT32。
const VALUE_TYPE_INT32: u32 = 2;
/// CTL_ADAPTER_PROPERTIES_FLAG_INTEGRATED。
const ADAPTER_INTEGRATED: u32 = 1;

/// IGCL 的句柄（驱动内部的指针，只原样传回）。
type Handle = *mut c_void;

/// ctl_application_id_t（GUID 的布局）。
#[repr(C)]
#[derive(Default)]
struct ApplicationId {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [u8; 8],
}

/// ctl_init_args_t，36 字节。
#[repr(C)]
#[derive(Default)]
struct InitArgs {
    size: u32,
    version: u8,
    app_version: u32,
    flags: u32,
    supported_version: u32,
    application_uid: ApplicationId,
}

/// ctl_firmware_version_t。
#[repr(C)]
#[derive(Default)]
struct FirmwareVersion {
    major: u64,
    minor: u64,
    build: u64,
}

/// ctl_device_adapter_properties_t，320 字节。只用 graphics_adapter_properties（是不是核显）与 name。
#[repr(C)]
struct AdapterProperties {
    size: u32,
    version: u8,
    device_id: *mut c_void,
    device_id_size: u32,
    device_type: u32,
    supported_subfunction_flags: u32,
    driver_version: u64,
    firmware_version: FirmwareVersion,
    pci_vendor_id: u32,
    pci_device_id: u32,
    rev_id: u32,
    num_eus_per_sub_slice: u32,
    num_sub_slices_per_slice: u32,
    num_slices: u32,
    name: [u8; 100],
    graphics_adapter_properties: u32,
    frequency: u32,
    pci_subsys_id: u16,
    pci_subsys_vendor_id: u16,
    adapter_bdf: [u8; 3],
    num_xe_cores: u32,
    reserved: [u8; 108],
}

/// ctl_property_int_t：联合体 ctl_property_t 里用到的整数成员（联合体最大的成员也是 8 字节、4 字节对齐）。
#[repr(C)]
#[derive(Default, Clone, Copy)]
struct PropertyInt {
    enable: bool,
    value: i32,
}

/// ctl_3d_feature_getset_t，56 字节。
#[repr(C)]
struct FeatureGetSet {
    size: u32,
    version: u8,
    feature_type: u32,
    application_name: *mut u8,
    application_name_length: i8,
    set: bool,
    value_type: u32,
    value: PropertyInt,
    custom_value_size: i32,
    custom_value: *mut c_void,
}

/// ctl_property_info_int_t：联合体 ctl_property_info_t 里用到的整数成员。
#[repr(C)]
#[derive(Clone, Copy)]
struct PropertyInfoInt {
    default_enable: bool,
    min: i32,
    max: i32,
    step: i32,
    default: i32,
}

/// ctl_property_info_t：最大的成员是 ctl_property_info_enum_t（u64 + u32，16 字节、8 字节对齐）与
/// 整数、浮点成员（20 字节），合起来 24 字节、8 字节对齐。
#[repr(C)]
#[derive(Clone, Copy)]
union PropertyInfo {
    int: PropertyInfoInt,
    _align: [u64; 3],
}

/// ctl_3d_feature_details_t，72 字节。
#[repr(C)]
#[derive(Clone, Copy)]
struct FeatureDetails {
    feature_type: u32,
    value_type: u32,
    value: PropertyInfo,
    custom_value_size: i32,
    custom_value: *mut c_void,
    per_app_support: bool,
    conflicting_features: i64,
    feature_misc_support: i16,
    reserved: [i16; 3],
}

/// ctl_3d_feature_caps_t，24 字节。
#[repr(C)]
struct FeatureCaps {
    size: u32,
    version: u8,
    num_supported_features: u32,
    feature_details: *mut FeatureDetails,
}

// 布局与 SDK 一致：长度或位置不对时驱动会读错字段，在编译时先拦住。
const _: () = assert!(size_of::<InitArgs>() == 36);
const _: () = assert!(size_of::<AdapterProperties>() == 320);
const _: () = assert!(offset_of!(AdapterProperties, name) == 88);
const _: () = assert!(offset_of!(AdapterProperties, graphics_adapter_properties) == 188);
const _: () = assert!(offset_of!(AdapterProperties, num_xe_cores) == 204);
const _: () = assert!(size_of::<FeatureGetSet>() == 56);
const _: () = assert!(offset_of!(FeatureGetSet, value) == 32);
const _: () = assert!(size_of::<FeatureDetails>() == 72);
const _: () = assert!(offset_of!(FeatureDetails, per_app_support) == 48);
const _: () = assert!(size_of::<FeatureCaps>() == 24);

/// ctlInit。
type InitFn = unsafe extern "C" fn(*mut InitArgs, *mut Handle) -> u32;
/// ctlClose。
type CloseFn = unsafe extern "C" fn(Handle) -> u32;
/// ctlEnumerateDevices。
type EnumerateFn = unsafe extern "C" fn(Handle, *mut u32, *mut Handle) -> u32;
/// ctlGetDeviceProperties。
type PropertiesFn = unsafe extern "C" fn(Handle, *mut AdapterProperties) -> u32;
/// ctlGetSupported3DCapabilities。
type CapsFn = unsafe extern "C" fn(Handle, *mut FeatureCaps) -> u32;
/// ctlGetSet3DFeature。
type GetSetFn = unsafe extern "C" fn(Handle, *mut FeatureGetSet) -> u32;

/// ctl_result_t 转成结果：不支持、没实现、版本不对算「不支持」，权限不够算「要管理员权限」。
fn check(code: u32) -> Result<(), SyncError> {
    match code {
        SUCCESS => Ok(()),
        UNSUPPORTED_VERSION | UNSUPPORTED_FEATURE | NOT_IMPLEMENTED | LOAD_FAILED => {
            Err(SyncError::Unsupported)
        }
        INSUFFICIENT_PERMISSIONS => Err(SyncError::NeedsAdmin),
        // 错误码都小于 0x8000_0000，转成 i32 不变号；万一变号也只是显示的数字不同。
        _ => Err(SyncError::Failed(code as i32)),
    }
}

/// 一块 Intel 显卡上已经确认支持按程序限帧的会话，析构时 ctlClose。
pub struct Intel {
    api_handle: Handle,
    close: CloseFn,
    get_set: GetSetFn,
    device: Handle,
    /// exefile.exe，带结尾的 0（IGCL 的参数是可写的 char*，所以自己持有一份）。
    app_name: CString,
    /// 显卡的标识，写进还原记录。
    target: String,
    /// 显卡种类，用来在 AMD 与 Intel 之间选。
    kind: GpuKind,
    /// 驱动接受的帧数范围。
    range: (u32, u32),
}

impl Drop for Intel {
    fn drop(&mut self) {
        // SAFETY: 句柄由成功的 ctlInit 得到，只在这里关闭一次。
        unsafe {
            (self.close)(self.api_handle);
        }
    }
}

/// 一块显卡：句柄、种类与名字。
struct Adapter {
    handle: Handle,
    kind: GpuKind,
    name: String,
}

impl Intel {
    /// 加载 IGCL、选一块支持按程序限帧的 Intel 显卡（独显优先）。没有 Intel 驱动、没有 Intel 显卡或驱动
    /// 不支持时为 [`SyncError::Unsupported`]。
    pub fn open() -> Result<Self, SyncError> {
        let module = load(w!("ControlLib.dll")).ok_or(SyncError::Unsupported)?;
        // SAFETY: 名字与签名取自 igcl_api.h。
        let (init, close, enumerate, properties, caps, get_set) = unsafe {
            (
                export::<InitFn>(module, s!("ctlInit")),
                export::<CloseFn>(module, s!("ctlClose")),
                export::<EnumerateFn>(module, s!("ctlEnumerateDevices")),
                export::<PropertiesFn>(module, s!("ctlGetDeviceProperties")),
                export::<CapsFn>(module, s!("ctlGetSupported3DCapabilities")),
                export::<GetSetFn>(module, s!("ctlGetSet3DFeature")),
            )
        };
        let (Some(init), Some(close), Some(enumerate), Some(properties), Some(caps), Some(get_set)) =
            (init, close, enumerate, properties, caps, get_set)
        else {
            return Err(SyncError::Unsupported);
        };
        let mut args = InitArgs {
            size: size_of::<InitArgs>() as u32,
            app_version: APP_VERSION,
            ..InitArgs::default()
        };
        let mut api_handle: Handle = std::ptr::null_mut();
        // SAFETY: 参数与输出位置有效。
        check(unsafe { init(&mut args, &mut api_handle) })?;
        let mut session = Self {
            api_handle,
            close,
            get_set,
            device: std::ptr::null_mut(),
            app_name: CString::new(EXE_NAME).unwrap_or_default(),
            target: String::new(),
            kind: GpuKind::Integrated,
            range: (0, 0),
        };
        // SAFETY: api_handle 有效，函数指针来自同一个模块。
        let mut adapters = unsafe { adapters(api_handle, enumerate, properties) }?;
        adapters.sort_by_key(|adapter| adapter.kind != GpuKind::Discrete);
        for adapter in adapters {
            // SAFETY: 句柄来自 ctlEnumerateDevices。
            if let Some(range) = unsafe { frame_limit_range(adapter.handle, caps) } {
                session.device = adapter.handle;
                session.kind = adapter.kind;
                session.target = format!("intel-{}", adapter.name);
                session.range = range;
                // 能读出 exefile.exe 的设置才算能用。
                if session.read().is_ok() {
                    return Ok(session);
                }
            }
        }
        Err(SyncError::Unsupported)
    }

    /// 显卡种类。
    pub fn kind(&self) -> GpuKind {
        self.kind
    }

    /// 读或写 exefile.exe 的帧数上限：`set` 为 `None` 时读。
    fn get_set_frame_limit(&mut self, set: Option<PropertyInt>) -> Result<PropertyInt, SyncError> {
        let mut feature = FeatureGetSet {
            size: size_of::<FeatureGetSet>() as u32,
            version: 0,
            feature_type: FEATURE_FRAME_LIMIT,
            application_name: self.app_name.as_ptr().cast_mut().cast(),
            // "exefile.exe" 只有 11 个字符，转换不会失败。
            application_name_length: i8::try_from(self.app_name.as_bytes().len()).unwrap_or(i8::MAX),
            set: set.is_some(),
            value_type: VALUE_TYPE_INT32,
            value: set.unwrap_or_default(),
            custom_value_size: 0,
            custom_value: std::ptr::null_mut(),
        };
        // SAFETY: device 是选中的显卡；feature 有效，名字的缓冲区在调用期间一直存在，驱动只读不写。
        check(unsafe { (self.get_set)(self.device, &mut feature) })?;
        Ok(feature.value)
    }
}

/// 列出 Intel 显卡及其种类；读不出属性的显卡当作核显（独显优先只是排序，不影响能不能用）。
///
/// # Safety
/// `api_handle` 必须来自成功的 ctlInit，两个函数指针来自同一个模块。
unsafe fn adapters(
    api_handle: Handle,
    enumerate: EnumerateFn,
    properties: PropertiesFn,
) -> Result<Vec<Adapter>, SyncError> {
    let mut count = 0u32;
    // SAFETY: 先只取个数。
    check(unsafe { enumerate(api_handle, &mut count, std::ptr::null_mut()) })?;
    if count == 0 {
        return Err(SyncError::Unsupported);
    }
    let mut handles: Vec<Handle> = vec![std::ptr::null_mut(); count as usize];
    // SAFETY: 缓冲区有 count 个位置。
    check(unsafe { enumerate(api_handle, &mut count, handles.as_mut_ptr()) })?;
    handles.truncate(count as usize);
    let adapters = handles
        .into_iter()
        .filter(|handle| !handle.is_null())
        .map(|handle| {
            // 设备编号（Windows 上是 LUID，8 字节）由调用方提供缓冲区。
            let mut luid = [0u8; 8];
            // SAFETY: 全零是这个结构的合法初值（指针为空、数字为 0）。
            let mut props: AdapterProperties = unsafe { std::mem::zeroed() };
            props.size = size_of::<AdapterProperties>() as u32;
            props.device_id = luid.as_mut_ptr().cast();
            props.device_id_size = luid.len() as u32;
            // SAFETY: handle 来自 ctlEnumerateDevices，props 与 luid 在调用期间有效。
            let ok = check(unsafe { properties(handle, &mut props) }).is_ok();
            let integrated = !ok || props.graphics_adapter_properties & ADAPTER_INTEGRATED != 0;
            let len = props
                .name
                .iter()
                .position(|&b| b == 0)
                .unwrap_or(props.name.len());
            Adapter {
                handle,
                kind: if integrated {
                    GpuKind::Integrated
                } else {
                    GpuKind::Discrete
                },
                name: String::from_utf8_lossy(&props.name[..len]).trim().to_owned(),
            }
        })
        .collect();
    Ok(adapters)
}

/// 确认显卡支持按程序限帧并取帧数范围；不支持时为 `None`。读不出能力表（旧驱动）时按支持处理，
/// 范围取配置的 10～1000，之后能不能读写 exefile.exe 的设置再决定。
///
/// # Safety
/// `device` 必须来自 ctlEnumerateDevices，`caps` 来自同一个模块。
unsafe fn frame_limit_range(device: Handle, caps: CapsFn) -> Option<(u32, u32)> {
    let fallback = (FPS_RANGE.0 as u32, FPS_RANGE.1 as u32);
    let mut table = FeatureCaps {
        size: size_of::<FeatureCaps>() as u32,
        version: 0,
        num_supported_features: 0,
        feature_details: std::ptr::null_mut(),
    };
    // SAFETY: 第一次只取个数。
    if check(unsafe { caps(device, &mut table) }).is_err() || table.num_supported_features == 0 {
        return Some(fallback);
    }
    // SAFETY: 全零是这个结构的合法初值（与 SDK 示例的 memset 相同）。
    let empty: FeatureDetails = unsafe { std::mem::zeroed() };
    let mut details = vec![empty; table.num_supported_features as usize];
    table.feature_details = details.as_mut_ptr();
    // SAFETY: 缓冲区有 num_supported_features 个位置。
    if check(unsafe { caps(device, &mut table) }).is_err() {
        return Some(fallback);
    }
    let count = (table.num_supported_features as usize).min(details.len());
    let frame_limit = details[..count]
        .iter()
        .find(|d| d.feature_type == FEATURE_FRAME_LIMIT)?;
    if !frame_limit.per_app_support {
        // 只能全局限帧：不用（Intel 的全局设置会影响所有游戏，又没有用户的明确要求）。
        return None;
    }
    if frame_limit.value_type != VALUE_TYPE_INT32 {
        return Some(fallback);
    }
    // SAFETY: value_type 是 INT32 时联合体里是整数成员。
    let info = unsafe { frame_limit.value.int };
    match (u32::try_from(info.min), u32::try_from(info.max)) {
        (Ok(min), Ok(max)) if min <= max && max > 0 => Some((min, max)),
        _ => Some(fallback),
    }
}

impl ValueBackend for Intel {
    fn target(&self) -> &str {
        &self.target
    }

    fn range(&self) -> (u32, u32) {
        self.range
    }

    fn read(&mut self) -> Result<CapValue, SyncError> {
        let value = self.get_set_frame_limit(None)?;
        Ok(CapValue {
            enabled: value.enable,
            fps: u32::try_from(value.value).unwrap_or(0),
        })
    }

    fn write(&mut self, value: CapValue) -> Result<(), SyncError> {
        let property = PropertyInt {
            enable: value.enabled,
            value: i32::try_from(value.fps).unwrap_or(i32::MAX),
        };
        self.get_set_frame_limit(Some(property)).map(|_| ())
    }
}
