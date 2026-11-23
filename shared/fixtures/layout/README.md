# 布局用例

`cases.json` 按函数分组，每组是一个用例数组。矩形写成 `[x, y, 宽, 高]`，尺寸 `[宽, 高]`，点 `[x, y]`，
坐标都是全局屏幕坐标（原点在主屏左上角，y 轴向下）。

| 组 | 输入 | 期望 |
| --- | --- | --- |
| `snapMove` | `proposed`、`targets`（`neighbors` 与 `screens` 两组矩形）、`threshold` | `rect`、`snappedX`、`snappedY`（没有对齐时为 `null`） |
| `snapResize` | 上面这些，加 `movingEdges`（`left`、`right`、`top`、`bottom`）、`minimum`、`maximum`、`aspectRatio`（宽 ÷ 高，可为 `null`） | 同上 |
| `resizeEdges` | `point`、`rect`、`margin` | 边的名字列表 |
| `edgeGrip` | `point`、`rect`（边缘带 6、角区 14） | 边的名字列表 |
| `clampSize` | `size`、`aspectRatio`，缩略图设置取默认值（最小 192×108，最大 960×540） | 尺寸 |
| `clampToScreens` | `rect`、`screens`、`minimumVisible` | 矩形 |
| `resolveFrame` | `identity`（`kind` 是 `character`、`login` 或 `unknown`）、`loginIndex`、`layouts`（同配置文件里的写法）、`screens`、`occupied`，其余设置取默认值 | `frame`、`isAutoPlaced` |
| `zoom` | `base`、`factor`、`anchor`（同配置里的 zoomAnchor） | 矩形 |
| `crop` | `sourceSize`、`cropHeight` | 归一化矩形 `[x, y, 宽, 高]` |

`screens` 里每块屏幕是 `{"frame": 矩形, "visibleFrame": 矩形, "scale": 数字, "isMain": 布尔}`。
