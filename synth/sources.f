# synth/sources.f -- compile order for the full-chip build.
#
# Compile order matters for packages: list them first. Paths are relative
# to the repo root. Blank lines and full-line '#' comments are ignored.
# Use +incdir+<path> for `include search paths.
#
# Grow this file as modules land -- one line per file below, roughly in the
# order things get instantiated (packages, then datapath, then control,
# then top). When okHost/okLibrary vendor sources show up for the full-chip
# build, keep them in a separate synth_top-only filelist (e.g.
# sources_top.f) rather than adding them here, so `--filelist synth/sources.f`
# stays usable for OOC checks of individual blocks (pe_mac, systolic_array)
# without dragging vendor IP into that elaboration.

# --- adder (ABACUS-13 toolchain smoke test) ---
rtl/adder.sv
