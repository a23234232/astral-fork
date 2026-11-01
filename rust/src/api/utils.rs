/// 定义自动启动参数常量
pub const AUTOSTART_ARG: &str = "--autostart";

/// 检查是否具有管理员/sudo权限的函数
/// 在非Android系统上可用
#[cfg(not(target_os = "android"))]
pub fn check_sudo() -> bool {
    let is_elevated = elevated_command::Command::is_elevated();
    if !is_elevated {
        let exe_path = std::env::current_exe()
            .unwrap_or_default()
            .display()
            .to_string();

        let args: Vec<String> = std::env::args().collect();
        let mut stdcmd = std::process::Command::new(&exe_path);
        if args.contains(&AUTOSTART_ARG.to_owned()) {
            stdcmd.arg(AUTOSTART_ARG);
        }
        // 注意：用户取消系统密码框、或系统没有可用的提权手段时，crate 会返回 Err。
        // 这里绝对不能 panic：否则 Dart 侧收不到返回值，整个应用会直接崩溃（#189）。
        // 失败时仅记录原因并返回 false，由 Dart 侧决定继续以无特权模式运行。
        match elevated_command::Command::new(stdcmd).output() {
            Ok(_) => {}
            Err(e) => {
                eprintln!("elevated command failed: {e}");
                return false;
            }
        }
    }
    is_elevated
}

/// Android 平台的 check_sudo 实现
/// 在 Android 上始终返回 true，因为应用运行在沙箱环境中
#[cfg(target_os = "android")]
pub fn check_sudo() -> bool {
    true
}
