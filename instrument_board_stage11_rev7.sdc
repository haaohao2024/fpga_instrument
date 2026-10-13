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

# Display bundled-data exchange only. No clock-domain-wide false paths.
# visual_bank_exchange: req_sync(2 FF), state 0 -> 1 -> 2, then capture.
# Earliest data capture is >=4 pixel cycles =100ns after publication.
# Keep a finite 40ns setup budget and retain data-bus hold checking.
set_false_path -to [get_pins {*exchange*req_sync_0*/D}]
set_false_path -to [get_pins {*exchange*ack_sync_0*/D}]
set_false_path -to [get_pins {*exchange*source_up_sync_0*/D}]
set_false_path -to [get_pins {*exchange*pixel_up_sync_0*/D}]
set_max_delay -from [get_regs {*exchange*held_metadata_*}] -to [get_regs {*exchange*front_metadata_*}] 40.000
set_max_delay -from [get_regs {*exchange*offered_bank_*}] -to [get_regs {*exchange*front_bank_*}] 40.000
