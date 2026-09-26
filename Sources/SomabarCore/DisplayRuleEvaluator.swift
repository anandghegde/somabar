/// M12: what the display rules do to the layout the bar should show.
///
/// Like a trigger's show, a display rule never touches the stored layout: it is laid over the
/// active profile to build the effective layout, and the file keeps the person's sections.
extension DisplayRules {
    /// True when the display is wider than `showEverythingAbovePoints`.
    public func showsEverything(screenWidthPoints: Double) -> Bool {
        guard let threshold = showEverythingAbovePoints else { return false }
        return screenWidthPoints > Double(threshold)
    }

    /// The layout with every Hidden and Tucked item treated as Shown on a wide display.
    ///
    /// They join the left end of Shown in bar order (Tucked, then Hidden), so the items the person
    /// could already see do not move and what was nearest the divider stays nearest it. Locked
    /// items stay locked.
    public func apply(to layout: Layout, screenWidthPoints: Double) -> Layout {
        guard showsEverything(screenWidthPoints: screenWidthPoints) else { return layout }
        var result = layout
        result.shown = layout.tucked + layout.hidden + layout.shown
        result.hidden = []
        result.tucked = []
        return result
    }
}
