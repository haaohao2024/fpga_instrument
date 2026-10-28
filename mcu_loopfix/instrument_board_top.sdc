# Main clock only: no generated SPI/audio clock is used as an RTL clock.
# Board-specific external I/O delay budgets are not defined by this file.
create_clock -name sys_clk -period 20.000 [get_ports {clk}]
