import Foundation

/// 控制按钮条协调器：全局同一时刻只允许一个面板的控制条可见。
/// 悬停切换面板时，旧面板的控制条立即收起（不等 4 秒自动隐藏计时器），
/// 新面板的控制条随即显示——条永远跟随当前悬停的投屏画面。
final class DeviceControlBarCoordinator {
    static let shared = DeviceControlBarCoordinator()

    private(set) weak var activeOwner: DevicePanelView?

    /// 面板请求显示自己的控制条：隐藏其他所有面板的条，并把自己设为活跃面板
    func requestShow(_ owner: DevicePanelView) {
        if activeOwner !== owner {
            activeOwner?.controlBarCoordinatorHide()
            activeOwner = owner
        }
    }

    /// 面板的控制条收起时调用：只有当前活跃面板自己才能清空记录
    func requestHide(_ owner: DevicePanelView) {
        if activeOwner === owner {
            activeOwner = nil
        }
    }

    /// 面板销毁/捕获结束时调用
    func resign(_ owner: DevicePanelView) {
        if activeOwner === owner {
            activeOwner = nil
        }
    }
}
