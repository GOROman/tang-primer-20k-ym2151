set_device -name GW2A-18C GW2A-LV18PG256C8/I7
set_option -top_module top
set_option -verilog_std v2001

add_file src/top.v
add_file src/song_rom.v
add_file src/lzss_stream.v
add_file src/nlg_player.v
add_file src/bos_adpcm_rom.v
add_file src/msm6258_player.v
add_file src/hdmi_opm_debug.v
add_file third_party/HDMI/dvi_tx/dvi_tx.v
add_file third_party/HDMI/gowin_rpll/TMDS_rPLL.v
add_file src/pinmap.cst
add_file third_party/PT8211/pt8211_drive.v
add_file third_party/PT8211/gowin_rpll/gowin_rpll.v

foreach file [glob cores/jt51/hdl/*.v] {
    add_file $file
}
add_file cores/jt51/ver/common/sep32.v
add_file cores/jt51/ver/common/sep32_cnt.v

run all
