import AppKit

// 关闭 stdout 缓冲，保证日志重定向到文件时也能实时输出
setvbuf(stdout, nil, _IONBF, 0)

// 顶层代码默认非 MainActor 隔离，但进程入口必然在主线程，显式声明后再构建 App
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // 菜单栏代理应用：不占 Dock、不抢焦点
    app.setActivationPolicy(.accessory)
    app.run()
}
