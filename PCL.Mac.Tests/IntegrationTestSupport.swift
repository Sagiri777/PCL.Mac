import Foundation

/// 真实网络、账号或系统安装测试默认关闭。显式设置
/// `PCL_RUN_INTEGRATION_TESTS=1` 后才运行，避免 CI 和本机测试产生外部副作用。
let pclIntegrationTestsEnabled = ProcessInfo.processInfo.environment["PCL_RUN_INTEGRATION_TESTS"] == "1"
