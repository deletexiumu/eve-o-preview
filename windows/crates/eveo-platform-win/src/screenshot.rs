// SPDX-License-Identifier: GPL-3.0-or-later
//
// 截取整个虚拟屏幕（全部显示器拼起来的范围）的画面，供探针核对缩略图里出现了正确的颜色，
// 并存成 BMP 作为 CI 的制品。用 GDI 的 BitBlt（带 CAPTUREBLT，包含分层窗口），DWM 缩略图会如实出现在画面里。

//! 屏幕截图。

use std::fs::File;
use std::io::{self, BufWriter, Write};
use std::path::Path;

use windows::Win32::Graphics::Gdi::{
    BI_RGB, BITMAPINFO, BITMAPINFOHEADER, BitBlt, CAPTUREBLT, CreateCompatibleBitmap, CreateCompatibleDC,
    DIB_RGB_COLORS, DeleteDC, DeleteObject, GetDC, GetDIBits, ReleaseDC, SRCCOPY, SelectObject,
};
use windows::Win32::UI::WindowsAndMessaging::{
    GetSystemMetrics, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN, SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN,
};
use windows::core::{Error, Result};

/// 一张截图：BGRA 像素，从上到下逐行。
pub struct Screenshot {
    /// 左上角的全局 x 坐标。
    pub left: i32,
    /// 左上角的全局 y 坐标。
    pub top: i32,
    /// 宽，像素。
    pub width: i32,
    /// 高，像素。
    pub height: i32,
    pixels: Vec<u8>,
}

impl Screenshot {
    /// 截取整个虚拟屏幕。
    pub fn capture() -> Result<Self> {
        // SAFETY: 只读系统度量。
        let (left, top, width, height) = unsafe {
            (
                GetSystemMetrics(SM_XVIRTUALSCREEN),
                GetSystemMetrics(SM_YVIRTUALSCREEN),
                GetSystemMetrics(SM_CXVIRTUALSCREEN),
                GetSystemMetrics(SM_CYVIRTUALSCREEN),
            )
        };
        if width <= 0 || height <= 0 {
            return Err(Error::from_thread());
        }
        let mut pixels = vec![0u8; width as usize * height as usize * 4];
        // SAFETY: 设备上下文与位图在本块内创建并按相反顺序释放；pixels 的大小正好是宽 × 高 × 4。
        unsafe {
            let screen = GetDC(None);
            let memory = CreateCompatibleDC(Some(screen));
            let bitmap = CreateCompatibleBitmap(screen, width, height);
            let previous = SelectObject(memory, bitmap.into());
            let copied = BitBlt(
                memory,
                0,
                0,
                width,
                height,
                Some(screen),
                left,
                top,
                SRCCOPY | CAPTUREBLT,
            );
            let mut info = BITMAPINFO {
                bmiHeader: BITMAPINFOHEADER {
                    biSize: size_of::<BITMAPINFOHEADER>() as u32,
                    biWidth: width,
                    biHeight: -height,
                    biPlanes: 1,
                    biBitCount: 32,
                    biCompression: BI_RGB.0,
                    ..Default::default()
                },
                ..Default::default()
            };
            SelectObject(memory, previous);
            let lines = GetDIBits(
                memory,
                bitmap,
                0,
                height as u32,
                Some(pixels.as_mut_ptr().cast()),
                &mut info,
                DIB_RGB_COLORS,
            );
            let _ = DeleteObject(bitmap.into());
            let _ = DeleteDC(memory);
            ReleaseDC(None, screen);
            copied?;
            if lines == 0 {
                return Err(Error::from_thread());
            }
        }
        Ok(Self {
            left,
            top,
            width,
            height,
            pixels,
        })
    }

    /// 全局坐标处的颜色 (红, 绿, 蓝)；不在截图范围内时返回 `None`。
    pub fn pixel(&self, x: i32, y: i32) -> Option<(u8, u8, u8)> {
        let (cx, cy) = (x - self.left, y - self.top);
        if cx < 0 || cy < 0 || cx >= self.width || cy >= self.height {
            return None;
        }
        let at = (cy as usize * self.width as usize + cx as usize) * 4;
        Some((self.pixels[at + 2], self.pixels[at + 1], self.pixels[at]))
    }

    /// 存成 32 位 BMP（从上到下）。
    pub fn write_bmp(&self, path: &Path) -> io::Result<()> {
        let data_len = self.pixels.len() as u32;
        let mut out = BufWriter::new(File::create(path)?);
        // 文件头 14 字节 + 信息头 40 字节。
        out.write_all(b"BM")?;
        out.write_all(&(54 + data_len).to_le_bytes())?;
        out.write_all(&0u32.to_le_bytes())?;
        out.write_all(&54u32.to_le_bytes())?;
        out.write_all(&40u32.to_le_bytes())?;
        out.write_all(&self.width.to_le_bytes())?;
        out.write_all(&(-self.height).to_le_bytes())?;
        out.write_all(&1u16.to_le_bytes())?;
        out.write_all(&32u16.to_le_bytes())?;
        for value in [0u32, data_len, 2835, 2835, 0, 0] {
            out.write_all(&value.to_le_bytes())?;
        }
        out.write_all(&self.pixels)?;
        out.flush()
    }
}
