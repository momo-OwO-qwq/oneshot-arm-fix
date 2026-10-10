# oneshot-arm-fix

让 **Steam 版 OneShot**（AppID `420530`）在 **aarch64（ARM Linux）+ FEX-Emu + Steam Linux Runtime** 环境下正常启动的一键修复脚本。

> 2026-10-11 在 Orange Pi 5 Plus（RK3588，Armbian Ubuntu，Mesa kisak PPA）上实测通过。
> 修复后主菜单正常显示，渲染器为 `llvmpipe (LLVM 20.1.8)`。

---

## 症状

从 Steam 点「启动」后，依次遇到过下面三种表现（取决于你修到了哪一步）：

| 阶段 | 表现 |
|---|---|
| 1 | 进程启动约 10 秒后静默退出，没有任何窗口 |
| 2 | 弹出对话框 **`Error creating window: Couldn't find matching GLX visual`**，点 OK 后退出 |
| 3 | （改用 Wayland 后端时）报 **`Could not get EGL display`** |

journal 里能看到的典型报错：

```
./oneshot: /usr/lib/pressure-vessel/overrides/lib/x86_64-linux-gnu/libpthread.so.0: \
  version `GLIBC_PRIVATE' not found (required by .../OneShot/librt.so.1)
```

---

## 根因（三层，缺一不可）

1. **游戏自带的旧 glibc 库和运行时冲突**
   `librt.so.1`、`libcrypt.so.1` 来自 Ubuntu 16.04 时代的 glibc，放进新容器后
   `GLIBC_PRIVATE` 符号对不上 → 动态链接器直接失败，进程秒退。

2. **游戏自带的旧 `libstdc++.so.6` 压死了整条 GL 栈**（最隐蔽的一层）
   游戏目录的 RPATH 优先级最高，mesa 的 `libgallium` 需要 `GLIBCXX_3.4.26`，
   而自带的 libstdc++ 没有这个版本 → gallium 加载失败 → 拿不到任何 GL visual →
   SDL 报 `Couldn't find matching GLX visual`。
   **症状是 GLX，真正缺的是 C++ 标准库版本。**

3. **ARM 主机没有 x86_64 可用的硬件 GL 驱动**
   容器里注入的 x86 mesa 无法使用主机的 panfrost（ARM 驱动），
   即使库都在也初始化不了硬件设备 → 必须强制 mesa 软件渲染（llvmpipe）。

---

## 使用

```sh
git clone https://github.com/<you>/oneshot-arm-fix.git
cd oneshot-arm-fix
chmod +x oneshot-arm-fix.sh

./oneshot-arm-fix.sh          # 应用修复（等价于 apply）
./oneshot-arm-fix.sh status   # 查看当前状态
./oneshot-arm-fix.sh doctor   # 状态 + 环境/日志诊断
./oneshot-arm-fix.sh revert   # 一键回滚
```

游戏目录不在默认路径时：

```sh
./oneshot-arm-fix.sh apply -d /path/to/steamapps/common/OneShot
```

> 本脚本**只改名、不删除**，`revert` 可完整还原。

### 它做了什么

```sh
# 1) 禁用三个自带旧库（改名，可回滚）
librt.so.1      -> librt.so.1.disabled
libcrypt.so.1   -> libcrypt.so.1.disabled
libstdc++.so.6  -> libstdc++.so.6.disabled

# 2) 原主程序改名，同名位置放一个包装脚本
oneshot         -> oneshot.bin        # 原始 ELF
oneshot         -> 包装脚本（见下）
```

生成的包装脚本：

```sh
#!/bin/sh
export LIBGL_ALWAYS_SOFTWARE=1
export MESA_LOADER_DRIVER_OVERRIDE=swrast
exec "$(dirname "$0")/oneshot.bin" "$@"
```

之后**正常从 Steam 启动**即可。

---

## 手动修复（不用脚本也行）

进入游戏目录（默认 `~/.local/share/Steam/steamapps/common/OneShot`）：

```sh
cd ~/.local/share/Steam/steamapps/common/OneShot
mv -n librt.so.1      librt.so.1.disabled
mv -n libcrypt.so.1   libcrypt.so.1.disabled
mv -n libstdc++.so.6  libstdc++.so.6.disabled
mv    oneshot         oneshot.bin
cat > oneshot <<'EOF'
#!/bin/sh
export LIBGL_ALWAYS_SOFTWARE=1
export MESA_LOADER_DRIVER_OVERRIDE=swrast
exec "$(dirname "$0")/oneshot.bin" "$@"
EOF
chmod +x oneshot
```

回滚就是把这些名字改回去。

---

## 诊断技巧（排查同类问题很好用）

- **动态库加载全轨迹**：在包装脚本里加

  ```sh
  export LD_DEBUG=libs
  export LD_DEBUG_OUTPUT=/tmp/lddebug
  ```

  启动一次后，`grep -h "version .* not found" /tmp/lddebug.*` 能直接指出
  「哪个库要求了哪个缺失的符号版本」——本次问题 2 就是这样定位的。

- **mesa 详细日志**：`export LIBGL_DEBUG=verbose`

- **Xwayland 下截图**：`ffmpeg -f x11grab` 抓 root 常常是黑屏，
  用 `python-xlib` 的 `GetImage()` 抓具体窗口更可靠。

---

## 注意事项

- **Steam「校验游戏完整性」会把改名的三个库还原**，届时游戏会再次启动失败，
  重新执行一次 `./oneshot-arm-fix.sh` 即可（脚本是幂等的）。
- 软件渲染（llvmpipe）+ FEX 模拟下 CPU 占用较高（实测约 250%），OneShot 这类
  2D 游戏帧率可接受，但不要指望 60 帧满帧。
- 启动方式**必须走 Steam**：手动 `./oneshot` 直跑会因为缺少 Steamworks 环境
  （steamshim 提供的 IPC）而在初始化阶段退出。
- 本修复假设你**合法拥有**该游戏，且主机为 aarch64 + FEX-Emu / Steam Linux Runtime。
  x86_64 原生机不需要这套修复。

## 兼容性

| 项目 | 实测环境 |
|---|---|
| 主机 | Orange Pi 5 Plus / RK3588，Armbian（Ubuntu） |
| 架构 | aarch64，x86_64 游戏经 FEX-Emu 翻译 |
| 运行时 | Steam Linux Runtime（scout-on-soldier）+ pressure-vessel |
| Mesa | 26.1.6（kisak-mesa PPA），x86_64 栈位于 `/run/gfx` |
| 游戏 | OneShot，Steam AppID 420530，Linux x86_64 版 |

## License

MIT
