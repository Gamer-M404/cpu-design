create_clock -name fpga_clk -period 10 [get_ports fpga_clk]

#set_clock_groups -asynchronous -group [get_clocks -of_objects [get_pins U_clkgen/clk_out1]] \
#                               -group [get_clocks -of_objects [get_pins U_mig/U_mig/ui_clk]]
