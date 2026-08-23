# synth/build.tcl -- non-project-mode Vivado synthesis for ABACUS.
#
# Not meant to be run by hand -- scripts/remote_synth.sh generates the
# tclargs and log path. Direct invocation for debugging:
#   vivado -mode batch -nojournal -log build/<top>_<mode>/vivado.log \
#          -source synth/build.tcl \
#          -tclargs top=<top> mode=full|ooc strict=0|1 part=<part> [clk_ns=<ns>]
#
# Options (k=v, any order):
#   top=       top-level module name              (default abacus_top)
#   part=      exact Xilinx part string           (see synth/list_parts.tcl)
#   mode=      full | ooc                         (default full)
#   filelist=  path to .f source list             (default synth/sources.f)
#   xdc=       path to constraints                (default constr/abacus.xdc)
#   outdir=    report/checkpoint root             (default build)
#   clk_ns=    clock period for ooc mode          (default 5.0)
#   clk_port=  clock port name for ooc mode       (default clk)
#   strict=    1 = nonzero exit on critical warns (default 1)
#
# Exit code is 0 only if synthesis completed, and (when strict=1) no
# CRITICAL WARNINGs were emitted. Reports are written either way -- strict
# mode gates the exit code at the end rather than aborting mid-flow, so a
# failing CI run still leaves every report to look at, not just a log.
#
# Non-project mode: no .xpr, no GUI state that can drift out of sync with
# git. Every run starts from source files on disk and ends with reports;
# nothing persists in a Vivado project database.

set script_dir [file normalize [file dirname [info script]]]
set repo_root  [file normalize [file join $script_dir ..]]

# ---------------------------------------------------------------------------
# 1. Parse tclargs (key=value pairs after -tclargs).
# ---------------------------------------------------------------------------
array set opt {
    top      abacus_top
    mode     full
    strict   1
    part     ""
    filelist synth/sources.f
    xdc      constr/abacus.xdc
    outdir   build
    clk_ns   5.0
    clk_port clk
}
foreach arg $argv {
    if {[regexp {^([a-z_]+)=(.*)$} $arg -> key val]} {
        if {[info exists opt($key)]} {
            set opt($key) $val
        } else {
            puts "ERROR: unknown option '$key'"
            exit 2
        }
    } else {
        puts "ERROR: bad argument '$arg' (expected key=value)"
        exit 2
    }
}

if {$opt(part) eq ""} {
    puts "ERROR: part= is required -- run --list-parts and cross-check board docs, do not guess"
    exit 2
}

set TOP      $opt(top)
set MODE     $opt(mode)
set STRICT   $opt(strict)
set PART     $opt(part)
set CLK_NS   $opt(clk_ns)
set CLK_PORT $opt(clk_port)
set FILELIST [file join $repo_root $opt(filelist)]
set XDC      [file join $repo_root $opt(xdc)]
set RUN_DIR  [file join $repo_root $opt(outdir) ${TOP}_${MODE}]
file mkdir $RUN_DIR

puts "=== ABACUS synth ==============================================="
puts "  top      : $TOP"
puts "  part     : $PART"
puts "  mode     : $MODE"
puts "  outdir   : $RUN_DIR"
puts "  vivado   : [version -short]"
puts "  host     : [info hostname]"
puts "  started  : [clock format [clock seconds]]"
puts "================================================================="

# ---------------------------------------------------------------------------
# 2. Fail fast on a bad part string rather than after reading every source.
# ---------------------------------------------------------------------------
if {[llength [get_parts -quiet $PART]] == 0} {
    puts "ERROR: part '$PART' not available in this Vivado install."
    puts "       Run synth/list_parts.tcl to see what is."
    exit 2
}

# ---------------------------------------------------------------------------
# 3. Read sources from a filelist rather than globbing rtl/. A glob can't
#    express package compile order or keep vendor sources (okHost/okLibrary)
#    out of an OOC run of a sub-block -- a filelist can: point --filelist at
#    a leaner .f for PE/array OOC checks and a fuller one for the full-chip
#    build.
#
#    Format: one path per line, relative to repo root. Blank lines and full-
#    line '#' comments are ignored. '+incdir+<path>' adds an include dir.
# ---------------------------------------------------------------------------
if {![file exists $FILELIST]} {
    puts "ERROR: filelist not found: $FILELIST"
    exit 2
}
set rtl_files {}
set incdirs {}
set fh [open $FILELIST r]
while {[gets $fh line] >= 0} {
    set line [string trim $line]
    if {$line eq "" || [string index $line 0] eq "#"} { continue }
    if {[string match "+incdir+*" $line]} {
        lappend incdirs [file normalize [file join $repo_root [string range $line [string length "+incdir+"] end]]]
        continue
    }
    set src [file normalize [file join $repo_root $line]]
    if {![file exists $src]} {
        puts "ERROR: source not found: $src"
        exit 2
    }
    lappend rtl_files $src
}
close $fh
if {[llength $rtl_files] == 0} {
    puts "ERROR: no sources listed in $FILELIST"
    exit 2
}
puts "Reading [llength $rtl_files] SystemVerilog file(s)."
if {[llength $incdirs] > 0} {
    read_verilog -sv -include_dirs $incdirs $rtl_files
} else {
    read_verilog -sv $rtl_files
}

if {$MODE ne "ooc"} {
    if {![file exists $XDC]} {
        puts "ERROR: no XDC at $XDC -- full mode needs board-level constraints (at least a clock)"
        exit 2
    }
    read_xdc $XDC
}

# ---------------------------------------------------------------------------
# 4. Elaborate + synthesize.
# ---------------------------------------------------------------------------
if {$MODE eq "ooc"} {
    # OOC has no board pinout -- write a small synthetic-clock XDC to
    # $RUN_DIR (rather than create_clock inline) so the constraint actually
    # used is a visible, inspectable artifact next to the reports.
    #
    # Read *before* synth_design, not after: applied afterward, timing-
    # driven synthesis never sees the target period, so it has no reason to
    # pack pipeline registers into the DSP (AREG/BREG/MREG/PREG -- the
    # whole point of dsp_audit.rpt, see ABACUS-21). This also means
    # get_ports can't validate $CLK_PORT yet -- nothing is elaborated until
    # synth_design runs -- so that check has to happen after, below.
    set gen [file join $RUN_DIR ooc_clock.xdc]
    set g [open $gen w]
    puts $g "create_clock -name virtual_clk -period $CLK_NS \[get_ports $CLK_PORT\]"
    close $g
    read_xdc $gen
    puts "OOC mode: synthetic clock ${CLK_NS}ns on port '$CLK_PORT' ($gen)."

    if {[catch {synth_design -top $TOP -part $PART -mode out_of_context -flatten_hierarchy rebuilt} err]} {
        puts "ERROR: synth_design failed:\n$err"
        exit 1
    }

    if {[llength [get_clocks -quiet]] == 0} {
        puts "ERROR: no clock was created -- check clk_port='$CLK_PORT' actually matches a port on $TOP"
        exit 2
    }
} else {
    if {[catch {synth_design -top $TOP -part $PART -flatten_hierarchy rebuilt} err]} {
        puts "ERROR: synth_design failed:\n$err"
        exit 1
    }
}

write_checkpoint -force [file join $RUN_DIR post_synth.dcp]

# ---------------------------------------------------------------------------
# 5. Reports.
# ---------------------------------------------------------------------------
report_utilization -file [file join $RUN_DIR utilization.rpt]
report_utilization -hierarchical -file [file join $RUN_DIR utilization_hier.rpt]
report_timing_summary -delay_type max -max_paths 10 -report_unconstrained \
    -file [file join $RUN_DIR timing_summary.rpt]
report_timing -sort_by group -max_paths 25 -nworst 1 -input_pins \
    -file [file join $RUN_DIR timing_worst.rpt]
report_methodology -file [file join $RUN_DIR methodology.rpt] -quiet
report_clock_networks -file [file join $RUN_DIR clocks.rpt] -quiet

# ---------------------------------------------------------------------------
# 6. DSP audit -- AREG/BREG/MREG/PREG per DSP slice. All four =1 means the
#    input/multiply/output pipeline registers landed inside the DSP; any =0
#    means Vivado left a register in fabric, which caps Fmax below what the
#    DSP supports (see synth/README.md, matters for ABACUS-21).
#
#    Filtered on PRIMITIVE_TYPE rather than a hardcoded REF_NAME list, so
#    this keeps working across device families (DSP48E1 on 7-series,
#    DSP48E2 on UltraScale/+, DSP58 on Versal) without editing this file.
# ---------------------------------------------------------------------------
set dsps [get_cells -hierarchical -quiet -filter {PRIMITIVE_TYPE =~ "ARITHMETIC.DSP.*"}]
set dsp_report [open [file join $RUN_DIR dsp_audit.rpt] w]
puts $dsp_report "cell\tref\tAREG\tBREG\tMREG\tPREG"
foreach cell $dsps {
    set ref [get_property -quiet REF_NAME $cell]
    set a [get_property -quiet AREG $cell]
    set b [get_property -quiet BREG $cell]
    set m [get_property -quiet MREG $cell]
    set p [get_property -quiet PREG $cell]
    puts $dsp_report "$cell\t$ref\t$a\t$b\t$m\t$p"
}
close $dsp_report
set dsp_count [llength $dsps]
puts "DSP audit: $dsp_count DSP primitive(s)"

# ---------------------------------------------------------------------------
# 7. Machine-readable summary. failing_endpoints is capped at the max_paths
#    query below -- if it reads exactly 5000, TNS is a lower bound (see
#    synth/README.md caveat). Primitive counts come straight from the
#    post-synth netlist rather than parsed report text.
# ---------------------------------------------------------------------------
if {[catch {
    set worst_path [get_timing_paths -max_paths 1 -nworst 1 -delay_type max]
    set wns [format %.3f [get_property SLACK $worst_path]]
}]} {
    set wns "null"
}

set failing [get_timing_paths -quiet -max_paths 5000 -delay_type max -slack_less_than 0]
set failing_endpoints [llength $failing]
set tns 0.0
foreach p $failing { set tns [expr {$tns + [get_property SLACK $p]}] }
set tns [format %.3f $tns]

set lut_count  [llength [get_cells -hierarchical -quiet -filter {REF_NAME =~ "LUT*"}]]
set ff_count   [llength [get_cells -hierarchical -quiet -filter {REF_NAME =~ "FD*"}]]
set bram_count [llength [get_cells -hierarchical -quiet -filter {REF_NAME =~ "RAMB*"}]]

set json [open [file join $RUN_DIR summary.json] w]
puts $json [format {{
  "top": "%s",
  "mode": "%s",
  "part": "%s",
  "vivado": "%s",
  "timestamp": "%s",
  "wns_ns": %s,
  "tns_ns": %s,
  "failing_endpoints": %d,
  "luts": %d,
  "ffs": %d,
  "dsps": %d,
  "brams": %d
}} $TOP $MODE $PART [version -short] \
   [clock format [clock seconds] -format {%Y-%m-%dT%H:%M:%S}] \
   $wns $tns $failing_endpoints $lut_count $ff_count $dsp_count $bram_count]
close $json

puts "-----------------------------------------------------------------"
puts "  LUT $lut_count   FF $ff_count   DSP $dsp_count   BRAM $bram_count"
puts "  WNS $wns ns   TNS $tns ns   failing endpoints $failing_endpoints"
puts "  reports -> $RUN_DIR"
puts "-----------------------------------------------------------------"

# ---------------------------------------------------------------------------
# 8. Gate. Runs after every report is already on disk, so a strict failure
#    still leaves something to look at instead of just a log.
# ---------------------------------------------------------------------------
set n_cw [get_msg_config -count -severity {CRITICAL WARNING}]
puts "CRITICAL WARNINGs: $n_cw"
if {$STRICT && $n_cw > 0} {
    puts "FAIL: critical warnings present (strict=1). See vivado.log."
    exit 1
}
puts "PASS: $RUN_DIR"
exit 0
