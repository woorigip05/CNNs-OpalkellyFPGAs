# synth/list_parts.tcl -- print every part Vivado knows about, so you can
# cross-check the exact string (device + package + speed grade) against the
# Opal Kelly board docs before putting it in .synthrc. Do not guess: package
# and speed grade change the timing model, not just the pin count.
#
# Usage: vivado -mode batch -nolog -nojournal -source synth/list_parts.tcl

puts [format "%-24s %-14s %-8s %s" PART PACKAGE SPEED DEVICE]
foreach part [lsort [get_parts]] {
    set pkg    [get_property PACKAGE     [get_parts $part]]
    set speed  [get_property SPEED       [get_parts $part]]
    set device [get_property DEVICE      [get_parts $part]]
    puts [format "%-24s %-14s %-8s %s" $part $pkg $speed $device]
}
