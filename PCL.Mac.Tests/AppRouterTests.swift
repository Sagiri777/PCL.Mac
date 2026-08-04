import Testing
@testable import PCL_Mac

struct AppRouterTests {
    @Test func ordinaryPageGoesBackOneLevel() {
        let router = AppRouter()
        router.path = [.launch, .announcementHistory]

        router.goBack()

        #expect(router.path == [.launch])
    }

    @Test func subrouteContainerReturnsToItsParent() {
        let router = AppRouter()
        router.path = [.launch, .accountManagement, .accountList]

        router.goBack()

        #expect(router.path == [.launch])
    }

    @Test func rootCannotGoBack() {
        let router = AppRouter()

        router.goBack()

        #expect(router.path == [.launch])
        #expect(!router.canGoBack)
    }

    @Test func emptyPathFallsBackToLaunch() {
        let router = AppRouter()
        router.path = []

        #expect(router.getLast() == .launch)
        #expect(router.getRoot() == .launch)
        router.removeLast()
        #expect(router.path == [.launch])
    }
}
