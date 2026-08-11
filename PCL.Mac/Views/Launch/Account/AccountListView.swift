//
//  AccountListView.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/6/30.
//

import SwiftUI

struct AccountListView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var dataManager: DataManager = .shared
    @ObservedObject private var accountManager: AccountManager = .shared
    @ObservedObject private var settings: AppSettings = .shared
    
    var body: some View {
        ScrollView {
            VStack {
                StaticMyCard(title: "账号列表") {
                    VStack(spacing: 0) {
                        if accountManager.accounts.isEmpty {
                            Text("账号列表为空")
                                .font(.system(size: 14))
                                .foregroundStyle(Color("TextColor"))
                            Button("添加账号") {
                                dataManager.router.removeLast()
                                dataManager.router.append(.newAccount)
                            }
                            .buttonStyle(.link)
                        } else {
                            ForEach(accountManager.accounts) { account in
                                AccountView(account: account)
                            }
                        }
                    }
                }
            }
            .padding()
            .padding(.bottom, 25)
        }
        .scrollIndicators(.never)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: accountManager.accounts)
    }
}

fileprivate struct AccountView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var accountManager: AccountManager = .shared
    @ObservedObject private var dataManager: DataManager = .shared
    @ObservedObject private var settings: AppSettings = .shared
    
    @State private var isHovered: Bool = false
    
    let account: AnyAccount
    
    var body: some View {
        MyListItem(isSelected: accountManager.accountId == account.id) {
            HStack {
                Button {
                    accountManager.accountId = account.id
                } label: {
                    HStack(spacing: 10) {
                        MinecraftAvatar(account: account, src: account.uuid.uuidString, size: 40)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(account.name)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(isHovered ? settings.theme.getTextStyle() : AnyShapeStyle(Color("TextColor")))
                        Text(account.uuid.uuidString.lowercased())
                                .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color(hex: 0x8C8C8C))
                            .textSelection(.enabled)
                            MyTag(label: account.authMethodName, backgroundColor: Color(hex: 0x8C8C8C, alpha: 0.2))
                                .font(.system(size: 11))
                                .foregroundStyle(Color("TextColor"))
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("选择账号 \(account.name)，\(account.authMethodName)")
                Spacer()
                HStack {
                    Button {
                        Task {
                            do {
                                try await SkinCacheStorage.shared.loadSkin(account: account)
                                hint("刷新成功！", .finish)
                            } catch {
                                hint("无法刷新头像：\(error.localizedDescription)", .critical)
                            }
                        }
                    } label: {
                        Image("RefreshIcon")
                    }
                    .buttonStyle(.plain)
                    .help("刷新头像")
                    .accessibilityLabel("刷新 \(account.name) 的头像")
                    Button(role: .destructive) {
                        accountManager.removeAccount(id: account.id)
                    } label: {
                        Image(systemName: "xmark")
                            .bold()
                    }
                    .buttonStyle(.plain)
                    .help("删除账号")
                    .accessibilityLabel("删除账号 \(account.name)")
                }
                .foregroundStyle(AppSettings.shared.theme.getTextStyle())
                .padding(.horizontal, 8)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isHovered)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: accountManager.accountId)
        .onHover { hover in
            isHovered = hover
        }
    }
}

public extension AnyAccount {
    var authMethodName: String {
        switch self {
        case .microsoft:  return "微软账号"
        case .offline:    return "离线账号"
        case .yggdrasil(let account):  return account.authenticationServerName
        }
    }
}
