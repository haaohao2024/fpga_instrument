# Tang Mega 60K NEO Dock REV7 / instrument_board_stage11_rev7.
# Main oscillator: 50 MHz on V22. SPI front ends use 50MHz; system is a related divide-by-two.
create_clock -name sys_clk -period 20.000 -waveform {0.000 10.000} [get_ports {sys_clk}]

# Existing PLLA: 50 MHz -> 200 MHz serializer and 40 MHz pixels, phase=0.
# Both generated clocks retain their fixed 5:1 relation; do not declare them async.
create_generated_clock -name video_serial_clk -source [get_ports {sys_clk}] -master_clock sys_clk -multiply_by 4 [get_pins {u_instrument/video_pll/PLLA_inst/CLKOUT0}]
create_generated_clock -name video_pixel_clk -source [get_ports {sys_clk}] -master_clock sys_clk -multiply_by 4 -divide_by 5 [get_pins {u_instrument/video_pll/PLLA_inst/CLKOUT1}]

# Shared SPI SCK is sampled by synchronizers in the 50 MHz domain, not an RTL clock.
# FPGA transactions: 5 MHz; unselected SD traffic: up to 8 MHz in record mode.
# External input/output delays, reset/CDC exceptions, PLL physical placement and
# board electrical margins require a later netlist/STA review. REV7 does not
# specify those budgets. No blanket false paths or invented IO delays are added.

# Oscillator remains 50 MHz; only the system branch is divided.
create_generated_clock -name system_clk -source [get_ports {sys_clk}] -master_clock sys_clk -divide_by 2 [get_nets {system_clk_div2}]

# R58: Gowin starts this fabric-generated clock at Q with zero tCL unless
# source latency is specified. The input-clock -> divider CLK -> Q delay is
# therefore a separate implementation budget, verified after EVERY P&R.
# Fast-corner source interval: 1.8..2.6 ns. Slow source upper bound: 7.0 ns.
# Never accept these bounds without the divider clock-path report check.
# Same-system-clock paths retain their common source (verified in clock_probe).
set_clock_latency -source -early 1.800 [get_clocks {system_clk}]
set_clock_latency -source -late 2.600 [get_clocks {system_clk}]
# Use the fast source interval for hold; reserve the remaining 4.4ns slow
# source delay only on paths launched by system_clk into another domain.
# 4.435 includes the original 0.035ns uncertainty. Slow captures into
# system_clk use the earlier 1.8ns bound and are already conservative.
set_clock_uncertainty -setup -from [get_clocks {system_clk}] -to [get_clocks {sys_clk}] 4.435
set_clock_uncertainty -setup -from [get_clocks {system_clk}] -to [get_clocks {video_pixel_clk}] 4.435
set_clock_uncertainty -setup -from [get_clocks {system_clk}] -to [get_clocks {video_serial_clk}] 4.435

# Display bundled-data exchange only. No clock-domain-wide false paths.
# visual_bank_exchange: req_sync(2 FF), state 0 -> 1 -> 2, then capture.
# Earliest data capture is >=4 pixel cycles =100ns after publication.
# Keep a finite 40ns setup budget. Only the owned data Q->D hold paths are
# exempt: the return handshake prevents overwrite for >=80ns after capture.
set_false_path -to [get_pins {*exchange*req_sync_0*/D}]
set_false_path -to [get_pins {*exchange*ack_sync_0*/D}]
set_false_path -to [get_pins {*exchange*source_up_sync_0*/D}]
set_false_path -to [get_pins {*exchange*pixel_up_sync_0*/D}]
set_max_delay -from [get_regs {*exchange*held_metadata_*}] -to [get_regs {*exchange*front_metadata_*}] 40.000
set_max_delay -from [get_regs {*exchange*offered_bank_*}] -to [get_regs {*exchange*front_bank_*}] 40.000
set_false_path -hold -from [get_pins {*exchange*held_metadata_*/Q}] -to [get_pins {*exchange*front_metadata_*/D}]
set_false_path -hold -from [get_pins {*exchange*offered_bank_*/Q}] -to [get_pins {*exchange*front_bank_*/D}]

# These explicit paths preserve clock insertion evidence even when the
# divider is not among the globally worst setup/hold paths.
report_timing -setup -to [get_pins {system_clk_div2_s1/D}] -max_paths 4
report_timing -hold -to [get_pins {system_clk_div2_s1/D}] -max_paths 4
report_timing -setup -from [get_pins {*exchange*held_metadata_*/Q}] -to [get_pins {*exchange*front_metadata_*/D}] -max_paths 5000 -max_common_paths 1
report_exceptions -hold -to [get_pins {*exchange*front_metadata_*/D}] -max_paths 5000 -max_common_paths 1

# R58 gated serializer: see audit/gate_boundary_proof.txt. The existing
# pixel reset is retained, and DHCE stays disabled for two more pixel
# cycles after it releases. Only the serializer's FCLK recovery deadline
# is extended; its PCLK recovery and all data paths retain their checks.
# At most three extra FCLK periods (15ns) are budgeted, less than the
# verified stop/release/start guard interval. Hold pairing restores the
# original removal edge. Do not use these exceptions with ungated FCLK.
set_multicycle_path -setup -end 4 -from [get_pins {*display/rb/p_2_s0/Q}] -through [get_pins {*display/tx/phy/lane*/RESET}] -to [get_clocks {video_serial_clk}]
set_multicycle_path -hold -end 3 -from [get_pins {*display/rb/p_2_s0/Q}] -through [get_pins {*display/tx/phy/lane*/RESET}] -to [get_clocks {video_serial_clk}]
# DHCE's native four-stage enable synchronizer permits a bounded enable
# arrival during the reset guard window. Source holds each run/stop level
# across that window; normal operation never modulates this clock.
set_max_delay -from [get_pins {*display/rb/gate_release_1_s0/Q}] -to [get_pins {*display/tx/phy/clock_gate.gate/CEN}] 10.000
# Asynchronous assertion / synchronous release synchronizer entry only.
# p[0] resolves before p[1],p[2]; later D inputs retain the asserted value
# while the entry releases. All interstage Q->D checks remain enabled.
set_false_path -to [get_pins {*display/rb/p_*/PRESET}]
set_false_path -to [get_pins {*display/rb/gate_release_*/PRESET}]
report_timing -recovery -to [get_pins {*display/tx/phy/lane*/RESET}] -max_paths 32 -max_common_paths 8
report_timing -removal -to [get_pins {*display/tx/phy/lane*/RESET}] -max_paths 32 -max_common_paths 8
report_timing -setup -to [get_pins {*display/tx/phy/clock_gate.gate/CEN}] -max_paths 4
report_timing -hold -to [get_pins {*display/tx/phy/clock_gate.gate/CEN}] -max_paths 4
report_exceptions -recovery -max_paths 64 -max_common_paths 8
report_exceptions -removal -max_paths 64 -max_common_paths 8

# R58 expanded endpoint reporting.
report_timing -setup -max_paths 5000 -max_common_paths 1
report_timing -hold -max_paths 5000 -max_common_paths 1
report_timing -recovery -max_paths 5000 -max_common_paths 1
report_timing -removal -max_paths 5000 -max_common_paths 1

# R58 explicit handoff coverage; reporting only, no extra exceptions.
report_timing -setup -to [get_pins {*related_handoff.half_cycle*/D}] -max_paths 32 -max_common_paths 1
report_timing -setup -to [get_pins {*map_handoff.half_cycle*/D}] -max_paths 32 -max_common_paths 1
report_timing -setup -from [get_pins {*related_handoff.half_cycle*/Q}] -to [get_pins {*related_handoff.system_copy*/D}] -max_paths 32 -max_common_paths 1
report_timing -setup -from [get_pins {*map_handoff.half_cycle*/Q}] -max_paths 64 -max_common_paths 4
report_timing -hold -to [get_pins {*related_handoff.half_cycle*/D}] -max_paths 32 -max_common_paths 1
report_timing -hold -to [get_pins {*map_handoff.half_cycle*/D}] -max_paths 32 -max_common_paths 1
report_timing -hold -from [get_pins {*related_handoff.half_cycle*/Q}] -to [get_pins {*related_handoff.system_copy*/D}] -max_paths 32 -max_common_paths 1
report_timing -hold -from [get_pins {*map_handoff.half_cycle*/Q}] -max_paths 64 -max_common_paths 4
