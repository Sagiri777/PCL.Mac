//
//  OtherSettingsView.swift
//  PCL.Mac
//

import SwiftUI

struct OtherSettingsView: View {
    @ObservedObject private var settings: AppSettings = .shared
    @ObservedObject private var announcementManager: AnnouncementManager = .shared
    @ObservedObject private var accountManager: AccountManager = .shared
    @State private var newAvatarTemplate: String = ""

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            StaticMyCard(title: "首页内容") {
                VStack(spacing: 14) {
                    settingToggle("显示公告", isOn: $settings.showAnnouncements)
                        .onChange(of: settings.showAnnouncements) { announcementManager.reload() }

                    settingToggle("使用自定义公告源", isOn: $settings.useCustomAnnouncementSource)
                        .disabled(!settings.showAnnouncements)
                        .onChange(of: settings.useCustomAnnouncementSource) { announcementManager.reload() }

                    if settings.showAnnouncements && settings.useCustomAnnouncementSource {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("公告源根地址")
                                .font(.system(size: 12, weight: .medium))
                            TextField("https://example.com/announcements", text: $settings.customAnnouncementSource)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { announcementManager.reload() }
                            Text("地址下需提供 latest.json；历史公告可使用 history/{number}.json。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack {
                                Text(announcementManager.lastError ?? "当前：\(announcementManager.activeSourceDescription)")
                                    .font(.caption)
                                    .foregroundStyle(announcementManager.lastError == nil ? Color.secondary : Color.red)
                                Spacer()
                                Button(announcementManager.isLoading ? "正在刷新…" : "测试并刷新") {
                                    announcementManager.reload()
                                }
                                .disabled(announcementManager.isLoading)
                            }
                        }
                        .padding(.leading, 22)
                    }

                    Divider()
                    settingToggle("显示开发版本警告", isOn: $settings.showDevelopmentWarning)
                    settingToggle("首页显示开发日志", isOn: $settings.showDevelopmentLogs)
                    settingToggle("左上角显示当前路径", isOn: $settings.showCurrentRoute)

                    Text("路径和日志属于开发调试信息，默认关闭；关闭后不会影响页面导航或日志文件记录。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(18)
            }
            .padding()

            StaticMyCard(index: 1, title: "下载") {
                VStack(alignment: .leading, spacing: 14) {
                    OptionStack("文件下载源") {
                        MyPicker(selected: $settings.fileDownloadSource, entries: [.mirror, .both, .official]) { option in
                            switch option {
                            case .official: "尽量使用官方源"
                            case .both: "优先使用官方源，在加载缓慢时换用镜像源"
                            case .mirror: "尽量使用镜像源"
                            }
                        }
                    }

                    OptionStack("版本列表源") {
                        MyPicker(selected: $settings.versionManifestSource, entries: [.mirror, .both, .official]) { option in
                            switch option {
                            case .official: "尽量使用官方源"
                            case .both: "优先使用官方源，在加载缓慢时换用镜像源"
                            case .mirror: "尽量使用镜像源（可能缺少刚刚更新的版本）"
                            }
                        }
                    }

                    Divider()

                    Toggle("无障碍：自动确认官方网页下载", isOn: $settings.accessibilityBrowserAutomationDownloadEnabled)
                        .toggleStyle(.switch)
                        .font(.system(size: 13))
                    Text("默认关闭。开启后，仅对受限 CurseForge 队列中已验证的项目和文件使用内置浏览器自动打开官方下载页；不会自动登录或填写表单，文件仍须通过 SHA-1 校验后才会写入实例。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(18)
            }
            .padding()

            StaticMyCard(index: 2, title: "代理") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("启用 HTTP/HTTPS 代理", isOn: $settings.proxyEnabled)
                        .toggleStyle(.switch)
                        .font(.system(size: 13))
                        .onChange(of: settings.proxyEnabled) { Requests.invalidateProxySessions() }
                    Text("启用后所有网络请求（皮肤/CDN/微软登录/版本列表）走代理。常用于访问被墙的官方 Mojang 资源。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Text("主机")
                            .font(.system(size: 12))
                            .frame(width: 40, alignment: .leading)
                        TextField("127.0.0.1", text: $settings.proxyHost)
                            .textFieldStyle(.roundedBorder)
                            .disabled(!settings.proxyEnabled)
                            .frame(maxWidth: 200)
                            // 代理端点变了要丢弃缓存的 session，否则新设置对已建立的连接无效。
                            .onSubmit { Requests.invalidateProxySessions() }
                        Text("端口")
                            .font(.system(size: 12))
                            .frame(width: 40, alignment: .leading)
                        TextField("20122", text: Binding(
                            get: { settings.proxyPort > 0 ? String(settings.proxyPort) : "" },
                            set: { settings.proxyPort = Int($0) ?? 0 }
                        ))
                            .textFieldStyle(.roundedBorder)
                            .disabled(!settings.proxyEnabled)
                            .frame(width: 100)
                            .onSubmit { Requests.invalidateProxySessions() }
                    }
                    HStack {
                        MyButton(text: "测试代理") {
                            Requests.invalidateProxySessions()
                            testProxy()
                        }
                        .frame(width: 100, height: 28)
                        .disabled(!settings.proxyEnabled || settings.proxyHost.isEmpty || settings.proxyPort <= 0)
                        Text("点击后通过代理请求 api.ipify.org 测试连通性")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Divider().padding(.vertical, 4)

                    Text("代理覆盖范围（关闭总开关后所有类别都不走代理）")
                        .font(.system(size: 12, weight: .medium))

                    VStack(alignment: .leading, spacing: 6) {
                        proxyToggle("头像/CDN", subtitle: "mc-heads、crafatar、textures.minecraft.net、uapis.cn", isOn: $settings.proxyForAvatar)
                        proxyToggle("微软登录", subtitle: "login.live.com、login.microsoftonline.com", isOn: $settings.proxyForMicrosoftLogin)
                        proxyToggle("Minecraft 服务", subtitle: "user.auth.xboxlive.com、xsts.auth.xboxlive.com、api.minecraftservices.com", isOn: $settings.proxyForMinecraftAPI)
                        proxyToggle("游戏下载/版本列表", subtitle: "Mojang 官方源、Modrinth", isOn: $settings.proxyForGameDownload)
                        proxyToggle("公告", subtitle: "PCL 公告服务器", isOn: $settings.proxyForAnnouncement)
                        proxyToggle("其他", subtitle: "未分类请求", isOn: $settings.proxyForOther)
                    }
                    .disabled(!settings.proxyEnabled)
                }
                .padding(18)
            }
            .padding()

            StaticMyCard(index: 3, title: "头像") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("启用 HTTP/HTTPS 代理后访问被墙的 CDN（如 crafatar.com、textures.minecraft.net）会走代理。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Text("缓存时间")
                            .font(.system(size: 12))
                        Slider(value: Binding(
                            get: { Double(settings.avatarCacheDays) },
                            set: { settings.avatarCacheDays = Int($0.rounded()) }
                        ), in: 0...30, step: 1)
                        .frame(width: 200)
                        Text("\(settings.avatarCacheDays) 天")
                            .font(.system(size: 12))
                            .frame(width: 60, alignment: .leading)
                        Text("0 = 不缓存")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 10) {
                        MyButton(text: "立即刷新所有头像") {
                            SkinCacheStorage.shared.clearAll()
                            for account in accountManager.accounts {
                                Task {
                                    do {
                                        _ = try await SkinCacheStorage.shared.refreshSkin(account: account)
                                    } catch {
                                        err("刷新头像失败 (\(account.uuid)): \(error.localizedDescription)")
                                    }
                                }
                            }
                            HintManager.default.add(.init(text: "已清空缓存，正在刷新所有账号头像…", type: .finish))
                        }
                        .frame(width: 200, height: 32)
                        Text("清空所有缓存并重新拉取。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    Text("CDN 模板 fallback 列表（按优先级排列）。{uuid} = 去掉短横线的小写 UUID；{username} = 账号 username。JSON 响应（Content-Type: application/json）会被自动解析并提取 skin_url。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(Array(settings.avatarSources.enumerated()), id: \.offset) { idx, template in
                        HStack(spacing: 6) {
                            Text("\(idx + 1).")
                                .frame(width: 22, alignment: .trailing)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            TextField("https://example.com/avatar/{uuid}", text: Binding(
                                get: { settings.avatarSources[idx] },
                                set: { settings.avatarSources[idx] = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            Button(action: { moveAvatarSource(from: idx, to: idx - 1) }) {
                                Image(systemName: "arrow.up").frame(width: 20, height: 20)
                            }
                            .buttonStyle(.borderless)
                            .disabled(idx == 0)
                            Button(action: { moveAvatarSource(from: idx, to: idx + 1) }) {
                                Image(systemName: "arrow.down").frame(width: 20, height: 20)
                            }
                            .buttonStyle(.borderless)
                            .disabled(idx == settings.avatarSources.count - 1)
                            Button(role: .destructive, action: { settings.avatarSources.remove(at: idx) }) {
                                Image(systemName: "trash").frame(width: 20, height: 20)
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    HStack(spacing: 6) {
                        TextField("新增：https://your.cdn/avatar/{uuid}", text: $newAvatarTemplate)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                        MyButton(text: "添加") {
                            let trimmed = newAvatarTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            guard trimmed.contains("{uuid}") || trimmed.contains("{username}") else {
                                HintManager.default.add(.init(text: "URL 必须包含 {uuid} 或 {username} 占位符", type: .critical))
                                return
                            }
                            settings.avatarSources.append(trimmed)
                            newAvatarTemplate = ""
                        }
                        .frame(width: 70, height: 26)
                        MyButton(text: "重置默认") {
                            settings.avatarSources = [
                                "https://mc-heads.net/avatar/{uuid}",
                                "https://minotar.net/helm/{uuid}",
                                "https://crafatar.com/skins/{uuid}",
                                "https://uapis.cn/api/v1/game/minecraft/userinfo?username={username}"
                            ]
                        }
                        .frame(width: 90, height: 26)
                    }
                }
                .padding(18)
            }
            .padding()

            StaticMyCard(index: 4, title: "维护") {
                HStack {
                    MyButton(text: "打开日志") {
                        NSWorkspace.shared.activateFileViewerSelecting([SharedConstants.shared.logURL])
                    }
                    .frame(width: 140, height: 35)
                    Spacer()
                    Text(SharedConstants.shared.editionName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .padding()
        }
    }

    private func settingToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .toggleStyle(.switch)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func proxyToggle(_ title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top) {
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .frame(width: 200, alignment: .leading)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
    }

    private func moveAvatarSource(from src: Int, to dst: Int) {
        guard src != dst, dst >= 0, dst < settings.avatarSources.count else { return }
        let item = settings.avatarSources.remove(at: src)
        settings.avatarSources.insert(item, at: dst)
    }

    /// 测试代理连通性：调 api.ipify.org 取出口 IP。
    private func testProxy() {
        HintManager.default.add(.init(text: "正在测试代理 \(settings.proxyHost):\(settings.proxyPort)…", type: .info))
        Task {
            let response = await Requests.get("https://api.ipify.org", ignoredFailureStatusCodes: Array(100...599))
            if response.statusCode == 200, let data = response.data,
               let ip = String(data: data, encoding: .utf8) {
                HintManager.default.add(.init(text: "代理连通，出口 IP: \(ip)", type: .finish))
            } else {
                HintManager.default.add(.init(text: "代理测试失败 HTTP \(response.statusCode)", type: .critical))
            }
        }
    }
}
