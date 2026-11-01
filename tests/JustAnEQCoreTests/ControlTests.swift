import JustAnEQRT
import Testing

@Test func atomicStopHandshakeAndParameterRoundTrip() throws {
    let control = try #require(eq_control_create())
    defer { eq_control_destroy(control) }
    #expect(!eq_has_fault(control))
    eq_mark_fault(control)
    #expect(eq_has_fault(control))
    #expect(!eq_stop_requested(control))
    #expect(!eq_is_silent(control))
    for index: Int32 in 0..<17 {
        #expect(eq_get_parameter(control, index) == 0)
        let value = Float(index) * 0.5 - 3
        eq_set_parameter(control, index, value)
        #expect(eq_get_parameter(control, index) == value)
    }
    eq_request_stop(control)
    #expect(eq_stop_requested(control))
    #expect(!eq_is_silent(control))
    eq_mark_silent(control)
    #expect(eq_is_silent(control))
}
