/// SF Symbol for the menu-bar item: Off, On, or error (error wins).
func menuIconName(isOn: Bool, hasError: Bool) -> String {
    if hasError { return "exclamationmark.triangle" }
    return isOn ? "waveform" : "slider.vertical.3"
}
