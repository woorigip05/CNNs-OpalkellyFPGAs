# constr/abacus.xdc -- board-level constraints, full-mode synthesis.
#
# Placeholder: only a clock, no PACKAGE_PIN/IOSTANDARD yet. synth_design
# doesn't need pin locations -- only implementation/bitstream generation
# does -- and guessing real Opal Kelly pin numbers without the board's
# actual pin-out doc would be the exact "looks real and isn't" mistake
# synth/README.md already warns about for the part string.
#
# 5.000ns (200MHz) is a sanity-check period, not a measured board oscillator
# frequency -- replace it once the real clock source for `clk` is known.
# Add PACKAGE_PIN/IOSTANDARD per port once abacus_top exists and is wired
# to the board.
create_clock -name clk -period 5.000 [get_ports clk]
