// Tang Primer 25K dock oscillator: 50 MHz on E2.
// The PLL outputs (clk_sys 40 MHz, cam_xclk 24 MHz) are derived from this
// automatically by the Gowin timing engine.
create_clock -name clk50 -period 20 -waveform {0 10} [get_ports {clk50}]

// The camera's outputs are all sampled as data by cam_capture, which runs on
// clk_cap; none of them is a clock.  PCLK is therefore constrained the same
// way as the rest of the DVP bus.
set_false_path -from [get_ports {cam_pclk}]
set_false_path -from [get_ports {cam_href}]
set_false_path -from [get_ports {cam_vsync}]
set_false_path -from [get_ports {cam_d[*]}]

// The two pushbuttons are asynchronous and pass through synchronizers
// (btn_debounce / the POR flops in the top level) before entering any logic.
set_false_path -from [get_ports {btn_s1}]
set_false_path -from [get_ports {btn_s2}]

// clk_sys (CLKOUT0) and clk_cap (CLKOUT2) come from the same PLL, so they have
// a fixed phase relationship and the timing engine relates them.  That is left
// alone deliberately: with related clocks the cross-domain paths through
// async_fifo are meaningfully analysable, and closing them is strictly
// stronger than declaring them asynchronous.  async_fifo's Gray-coded
// pointers and synchronisers stay regardless -- they are what makes the
// crossing correct if the clock plan ever changes to something unrelated.
