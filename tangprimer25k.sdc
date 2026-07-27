// Tang Primer 25K dock oscillator: 50 MHz on E2.
// The 40 MHz PLL output (clk_sys, which clocks essentially the whole design)
// is derived from this automatically by the Gowin timing engine.
create_clock -name clk50 -period 20 -waveform {0 10} [get_ports {clk50}]

// The two pushbuttons are asynchronous and pass through synchronizers
// (btn_debounce / the POR flops in the top level) before entering any logic.
set_false_path -from [get_ports {btn_s1}]
set_false_path -from [get_ports {btn_s2}]

// cam_pclk/cam_href/cam_vsync/cam_d are sampled as data, never used as a
// clock; cam_capture synchronizes them the same way.
set_false_path -from [get_ports {cam_pclk}]
set_false_path -from [get_ports {cam_href}]
set_false_path -from [get_ports {cam_vsync}]
set_false_path -from [get_ports {cam_d[*]}]
