import Testing

@testable import SessionNest

@Test func appThemeRawValuesAreStable() {
    #expect(AppTheme.allCases.map(\.rawValue) == ["system", "light", "dark"])
}

@Test func appThemeDisplayNamesAreReadable() {
    #expect(AppTheme.allCases.map(\.displayName) == ["跟随系统", "浅色", "深色"])
}

@Test func unknownStoredThemeFallsBackToSystem() {
    #expect(AppTheme(storedValue: "future") == .system)
}
