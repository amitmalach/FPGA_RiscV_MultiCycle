# Set the Vivado GUI up for the final report's manual screenshots.
#
#   make baseline                                   (writes build/baseline/post_route.dcp)
#   cd build && vivado -mode gui -nojournal -nolog
#   then, in a fresh session's Tcl Console:  source ../docs/design/scripts/gui_helper.tcl
#
# Opens a copy of the routed checkpoint in build/gui_helper/, so the checkpoint itself is never
# written, and moves Vivado's working directory there, so its by-products stay under build/.
# To open another checkpoint, `set gui_helper_dcp <path>` before sourcing. Then colours each
# module's cells and ports with the report's module colours (the table below), colours the worst
# setup path's cells red and selects the path, so that the Device window can fit the view to it
# (Auto-fit Selection). Every step is a Tcl command: no mouse moves, no clicks. The recipes in
# docs/design/figures/README.md take over once the console prints "gui_helper: done".
#
# The steps are chained with `after`, returning to the event loop between them: blocking right
# after open_checkpoint, for example with a plain `after <ms>`, leaves the "Loading device"
# dialog up.

set gui_helper_root [file normalize [file join [file dirname [info script]] .. .. ..]]
if {![info exists gui_helper_dcp]} {
    set gui_helper_dcp [file join $gui_helper_root build baseline post_route.dcp]
}

# The report's module colours, also tabled in docs/design/figures/README.md: name, RGB, cell
# name patterns, pattern excluded from them, ports. Okabe-Ito colours, which stay distinct
# under the common forms of colour blindness. sysclk_* are the top-level clock buffers and
# spiflash_cclk_access the STARTUPE2 primitive.
set gui_helper_modules {
    {core          {0 114 178}   cpu/*                             cpu/register_file/* {}}
    {register_file {86 180 233}  cpu/register_file/*               {} {}}
    {ram           {230 159 0}   ram/*                             {} {}}
    {bus           {240 228 66}  bus/*                             {} {LEDS[*]}}
    {uart          {0 158 115}   uart/*                            {} {uart_rx_out uart_tx_in}}
    {spiflash      {204 121 167} {spiflash/* spiflash_cclk_access} {} {spiflash_*}}
    {clock_reset   {153 153 153} {clockworks/* sysclk_*}           {} {RESET sysclk_*}}
}
set gui_helper_path_rgb {255 0 0}

proc gui_helper_open {} {
    global gui_helper_dcp gui_helper_root
    set dcp $gui_helper_dcp
    if {![file exists $dcp]} { error "gui_helper: no checkpoint at $dcp (run make baseline)" }
    set scratch [file join $gui_helper_root build gui_helper]
    file mkdir $scratch
    cd $scratch
    set copy [file join $scratch [file tail $dcp]]
    file copy -force $dcp $copy
    open_checkpoint $copy
    after 3000 gui_helper_colour
}

proc gui_helper_colour {} {
    global gui_helper_modules
    foreach module $gui_helper_modules {
        lassign $module name rgb patterns exclude ports
        set any {}
        foreach pattern $patterns { lappend any "NAME =~ \"$pattern\"" }
        set filter "IS_PRIMITIVE && ([join $any { || }])"
        if {$exclude ne ""} { append filter " && NAME !~ \"$exclude\"" }
        set cells [get_cells -quiet -hierarchical -filter $filter]
        set port_objects [expr {$ports eq "" ? {} : [get_ports -quiet $ports]}]
        # One call per object type: a Vivado object list holds one type only.
        foreach objects [list $cells $port_objects] {
            if {[llength $objects]} { highlight_objects -rgb $rgb $objects }
        }
        puts [format "gui_helper: %-14s %4d cells %3d ports  rgb %s" $name [llength $cells] \
              [llength $port_objects] $rgb]
    }
    after 1000 gui_helper_worst_path
}

proc gui_helper_worst_path {} {
    global gui_helper_path_rgb
    set path [get_timing_paths -setup -max_paths 1 -nworst 1]
    # Cells only: a highlighted net shows every branch of its fan-out. Selecting the path
    # draws just its own segments, and the Device window fits the view to it.
    highlight_objects -rgb $gui_helper_path_rgb [get_cells -of_objects $path]
    select_objects $path
    puts [format "gui_helper: worst path %s -> %s, slack %s ns, %s logic levels, data path %s ns" \
          [get_property STARTPOINT_PIN $path] [get_property ENDPOINT_PIN $path] \
          [get_property SLACK $path] [get_property LOGIC_LEVELS $path] \
          [get_property DATAPATH_DELAY $path]]
    puts "gui_helper: done"
}

after 1000 gui_helper_open
