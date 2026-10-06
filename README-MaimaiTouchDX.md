# Maimai TouchDX iOS

这是一个基于 Moonlight iOS 的一体化客户端：

- Moonlight 继续负责视频、音频和原有输入。
- `MaimaiTouchHandler` 接管 iPad 原生多点触控。
- 触控按照 maimai 896 x 898 区域表命中 A1-A8、B1-B8、C1-C2、D1-D8、E1-E8。
- 状态以 TouchDX 的 8 字节 little-endian `uint64_t` 发送到游戏 PC 的 `4321` 端口。
- PC 端继续使用 TouchDX-Mod，不需要改 `MaiRemoteTouchMod.dll`。

## PC 端准备

1. 将 `MaiRemoteTouchMod.dll` 放入游戏目录：

   ```text
   C:\SDEZ160\Package\Mods\
   ```

   不要同时运行另一个占用 `4321` 端口的程序。

2. 确保游戏主机和 iPad 位于同一个局域网。若使用 iPad USB-C 转以太网，建议 PC 与 iPad 使用独立网段或直连以太网，降低 Wi-Fi 抖动。

3. Windows 防火墙允许 TCP `4321` 入站。

## iPad 端

在 macOS 上使用 Xcode 打开：

```text
Moonlight.xcodeproj
```

选择 `Moonlight` scheme，而不是 `Moonlight TV`。然后：

1. 在 Signing & Capabilities 中选择自己的 Team。
2. 将 Bundle Identifier 改成自己的唯一值，例如：

   ```text
   com.example.maimaitouchdx
   ```

3. 连接 iPad，选择设备并 Build/Run。
4. 若要给其他人安装，使用 TestFlight；本机测试也可以使用 AltStore、SideStore 或其他签名方式。

设置页中新增了 `TouchDX Multi-Touch` 开关，默认开启。客户端会自动使用当前 Moonlight 主机 IP，并向其 TCP `4321` 发送触点状态。

首次进入串流后确认：

- iPad 能正常看到 Moonlight 画面。
- 游戏目录的 MelonLoader 日志出现 `MaiRemoteTouchMod` 监听 `4321`。
- 进入游戏后，游戏端识别当前卡并切换到打歌界面。

## 协议验证

PC 端安装好 Mod 后，可先不启动 iPad，用仓库中的 PowerShell 脚本发送一个 A1 状态：

```powershell
.\Tools\Send-TouchDXState.ps1 -HostName 192.168.1.100 -State 256
```

`256` 对应 bit 8，即 A1。游戏不在打歌界面时，它应被 Mod 映射为 `Btn1`；打歌时它应触发 A1 触点。

常用状态：

- A1: `1 << 8`
- A5: `1 << 12`
- B1: `1 << 16`
- C1: `1 << 24`
- D1: `1 << 26`
- E1: `1 << 34`
- Select: `1 << 42`
- Coin: `1 << 45`

## 区域生成

`Limelight/Input/TouchDXRegions.h` 由以下脚本生成：

```powershell
powershell -ExecutionPolicy Bypass -File .\Tools\GenerateTouchDXRegions.ps1
```

生成的数据来自 TouchDX-AndroidClient 的 AGPL-3.0 区域几何。发布本客户端时需要遵守 Moonlight、GPL-3.0 和 TouchDX、AGPL-3.0 的源码提供要求。

## 当前限制

- 这个仓库是在 Windows 上完成的源码改造，iOS 工程需要在 macOS/Xcode 上最终编译和签名。
- 标准 Moonlight 的触摸模式仍然保留；关闭 TouchDX 开关后会回到原来的相对/绝对鼠标模式。
- iPad 无法像 Android 一样使用 `adb reverse`，因此网络质量比 ADB 更重要。建议优先使用 USB-C 以太网或干净的 5GHz/6GHz Wi-Fi。
- 本客户端不包含游戏文件、PC Mod DLL、账号或服务端配置。
