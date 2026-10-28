# Tang Mega 60K NEO Dock REV7 / instrument_board_stage11_rev7.
# Main oscillator: 50 MHz on V22. System40MHz, communication80MHz, audio128kHz.
create_clock -name sys_clk -period 20.000 -waveform {0.000 10.000} [get_ports {sys_clk}]

# Existing PLLA: 50 MHz -> 200 MHz serializer and 40 MHz pixels, phase=0.
# Both generated clocks retain their fixed 5:1 relation; do not declare them async.
create_generated_clock -name video_serial_clk -source [get_ports {sys_clk}] -master_clock sys_clk -multiply_by 4 [get_pins {u_instrument/video_pll/PLLA_inst/CLKOUT0}]
create_generated_clock -name video_pixel_clk -source [get_ports {sys_clk}] -master_clock sys_clk -multiply_by 4 -divide_by 5 [get_pins {u_instrument/video_pll/PLLA_inst/CLKOUT1}]

# SCK now clocks the small source-synchronous response serializer directly.
# The RX path remains oversampled at80MHz. Native recording uses20MHz with
# HIGH18.75ns/LOW31.25ns; control and legacy media retain10MHz.
create_clock -name record_spi_clk -period 50.000 -waveform {0.000 18.750} [get_ports {mcu_spi_sck}]
set_clock_uncertainty 1.200 -setup -to [get_clocks {record_spi_clk}]
# Provisional external return budget: reserve4ns for board return flight and
# MCU input setup, rather than leaving MISO unconstrained. This is an explicit
# engineering acceptance assumption, NOT a verified BL616 datasheet limit.
# Reconcile pad/board measurements before claiming physical qualification.
set_output_delay -max 4.000 -clock [get_clocks {record_spi_clk}] [get_ports {mcu_spi_miso}]
set_output_delay -min 0.000 -clock [get_clocks {record_spi_clk}] [get_ports {mcu_spi_miso}]
report_timing -setup -to [get_ports {mcu_spi_miso}] -max_paths 64 -max_common_paths 1
# Initial diagnostic run retains all crossings. No blanket async exception.
report_timing -setup -from [get_clocks {record_spi_clk}] -max_paths 128 -max_common_paths 1
report_timing -setup -to [get_clocks {record_spi_clk}] -max_paths 128 -max_common_paths 1
report_timing -hold -to [get_clocks {record_spi_clk}] -max_paths 128 -max_common_paths 1
# Control CS is used only at10MHz, LOW68.75ns. The oversampled TX
# changes on fast_fall. Routed-event acceptance remains independently bounded:
# SCK entry <=7.129ns +3*12.5ns detection +C2Q/return <=18.5ns
# +4ns external +1.2ns reserve =68.329ns <68.75ns.
# GOWIN max_delay includes launch insertion, output delay and uncertainty;
# 25ns below is its report relation, NOT a25ns Q-to-pad specification.
# scripts/review_spi_paths.py separately enforces the physical18.5ns return
# envelope and phase-independent low-time deadline on every routed result.
set_max_delay -from [get_pins {u_instrument/u_core/base/base_0/control/tx_*/Q}] -to [get_ports {mcu_spi_miso}] 25.000
report_timing -setup -from [get_pins {u_instrument/u_core/base/base_0/control/tx_*/Q}] -to [get_ports {mcu_spi_miso}] -max_paths 64 -max_common_paths 32
# Protocol-held controls: first byte and CS qualification settle during the
# MCU's1us CS setup. Route is decoded after byte3; both reply formats have
# identical version/state bytes4/5, and OE cannot depend on route before bit256.
# Request length bytes52/53 only change the OE tail after bit544 or later.
# Reset/ready remain fixed throughout transactions. These paths are bounded
# by100ns STA relations, well below their earliest protocol use; see
# audit/spi_event_boundaries.txt. No SCK-clocked bit/index path is included.
set_max_delay -from [get_pins {u_instrument/u_core/base/transport/first_tx_byte_*/Q u_instrument/u_core/base/transport/route_s1*_s0/Q u_instrument/u_core/base/transport/header_416_s0/Q u_instrument/u_core/base/transport/header_417_s0/Q u_instrument/u_core/base/transport/header_418_s0/Q u_instrument/u_core/base/transport/header_419_s0/Q u_instrument/u_core/base/transport/header_420_s0/Q u_instrument/u_core/base/transport/header_421_s0/Q u_instrument/u_core/base/transport/header_422_s0/Q u_instrument/u_core/base/transport/header_423_s0/Q u_instrument/u_core/base/transport/header_424_s0/Q u_instrument/u_core/base/transport/header_425_s0/Q u_instrument/u_core/base/transport/header_426_s0/Q u_instrument/u_core/base/transport/header_427_s0/Q u_instrument/u_core/base/transport/header_428_s0/Q u_instrument/u_core/base/transport/header_429_s0/Q u_instrument/u_core/base/transport/header_430_s0/Q u_instrument/u_core/base/transport/header_431_s0/Q u_instrument/u_core/base/transport/phy/cs_2_s0/Q u_instrument/u_core/base/base_0/control/phy/cs_2_s0/Q reset_release_1_s0/Q miso_ready_s0/Q}] -to [get_ports {mcu_spi_miso}] 100.000
report_timing -setup -to [get_ports {mcu_spi_miso}] -max_paths 128 -max_common_paths 128
# External SCK enters these preserved3-stage synchronizers asynchronously.
# Exempt only the first D pins; all interstage and edge-consumer checks remain.
set_false_path -to [get_pins {u_instrument/u_core/base/base_0/control/phy/ss_0_s0/D}]
set_false_path -to [get_pins {u_instrument/u_core/base/transport/phy/ss_0_s0/D}]
report_exceptions -hold -to [get_pins {*phy/ss_0_s0/D}] -max_paths 8
# Board flight/setup/load remain an explicit qualification assumption.

# Real PLL system clock, rationally related to 50MHz input. No fabric
# divider source-latency assumptions apply to this clock. Keep real 50/30
# crossing timing checks; failures are diagnostic, not false-pathed away.
create_generated_clock -name system_clk -source [get_ports {sys_clk}] -master_clock sys_clk -multiply_by 4 -divide_by 5 [get_pins {system_pll/PLLA_inst/CLKOUT0}]

create_generated_clock -name comm_clk -source [get_ports {sys_clk}] -master_clock sys_clk -multiply_by 8 -divide_by 5 [get_pins {system_pll/PLLA_inst/CLKOUT1}]

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
# Same register when synthesis replicates p[2] (gowin_replicate_reg_serializer_rst_*).
set_multicycle_path -setup -end 4 -from [get_pins {*display/rb/gowin_replicate_reg_serializer_rst*/Q}] -through [get_pins {*display/tx/phy/lane*/RESET}] -to [get_clocks {video_serial_clk}]
set_multicycle_path -hold -end 3 -from [get_pins {*display/rb/gowin_replicate_reg_serializer_rst*/Q}] -through [get_pins {*display/tx/phy/lane*/RESET}] -to [get_clocks {video_serial_clk}]
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

# Margin iteration2: real clocks remain 40/80MHz, audio remains 96kHz.
# Additional conservative setup/recovery reserve, not a clock change or exception.
# SUG940 5.2.4: uncertainty is deducted from required time. Report it separately.
set_clock_uncertainty 1.200 -setup -to [get_clocks {system_clk}]
set_clock_uncertainty 1.200 -setup -to [get_clocks {comm_clk}]
set_clock_uncertainty 1.200 -setup -to [get_clocks {video_pixel_clk}]
