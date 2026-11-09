import SwiftUI

// A sheet's two ways out, one look each (DESIGN-SYSTEM.md, "One control for each job"):
//
// - It changes something: Cancel at the leading edge, the verb (Save, Add, Log) at the trailing
//   edge in the prominent style (HIG, Toolbars: "Use the .prominent style for key actions such as
//   Done or Submit"). `.sheetConfirm()` on that button.
// - It is only looked at (the forecast, a list whose rows save themselves, Settings): the
//   system's Close button, the × at the leading edge (HIG, Sheets: a Done alone says finishing is
//   the only way out; HIG, Toolbars: "Use the standard Back and Close buttons"). `SheetClose`.

extension View {
    /// The button that confirms a sheet, in its toolbar's `.confirmationAction` place: the
    /// system's prominent glass on iOS and iPadOS. The Mac's sheet already draws the confirming
    /// button as the default one, in the accent.
    @ViewBuilder func sheetConfirm() -> some View {
        #if os(iOS)
        buttonStyle(.glassProminent)
        #else
        self
        #endif
    }
}

/// The way out of a sheet that confirms nothing: the system's Close button.
struct SheetClose: ToolbarContent {
    var identifier = "sheet.close"
    let action: () -> Void

    init(id identifier: String = "sheet.close", _ action: @escaping () -> Void) {
        self.identifier = identifier
        self.action = action
    }

    var body: some ToolbarContent {
        #if os(iOS)
        ToolbarItem(placement: .cancellationAction) {
            Button(role: .close, action: action)
                .accessibilityIdentifier(identifier)
        }
        #else
        // A Mac sheet's way out is a word at the trailing edge, and Esc.
        ToolbarItem(placement: .cancellationAction) {
            Button("Close", action: action)
                .accessibilityIdentifier(identifier)
        }
        #endif
    }
}
