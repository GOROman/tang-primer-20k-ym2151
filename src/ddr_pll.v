module ddr_pll(input wire clkin, input wire reset,
               output wire clkout, output wire lock);
    wire gnd = 1'b0;
    wire unused_p, unused_d, unused_d3;
    rPLL rpll_inst(
        .CLKOUT(clkout), .LOCK(lock), .CLKOUTP(unused_p),
        .CLKOUTD(unused_d), .CLKOUTD3(unused_d3), .RESET(reset),
        .RESET_P(gnd), .CLKIN(clkin), .CLKFB(gnd),
        .FBDSEL(6'd0), .IDSEL(6'd0), .ODSEL(6'd0),
        .PSDA(4'd0), .DUTYDA(4'd0), .FDLY(4'd0));
    defparam rpll_inst.FCLKIN = "27";
    defparam rpll_inst.IDIV_SEL = 3;
    defparam rpll_inst.FBDIV_SEL = 58;
    defparam rpll_inst.ODIV_SEL = 2;
    defparam rpll_inst.DYN_IDIV_SEL = "false";
    defparam rpll_inst.DYN_FBDIV_SEL = "false";
    defparam rpll_inst.DYN_ODIV_SEL = "false";
    defparam rpll_inst.PSDA_SEL = "0000";
    defparam rpll_inst.DYN_DA_EN = "true";
    defparam rpll_inst.DUTYDA_SEL = "1000";
    defparam rpll_inst.CLKOUT_FT_DIR = 1'b1;
    defparam rpll_inst.CLKOUTP_FT_DIR = 1'b1;
    defparam rpll_inst.CLKOUT_DLY_STEP = 0;
    defparam rpll_inst.CLKOUTP_DLY_STEP = 0;
    defparam rpll_inst.CLKFB_SEL = "internal";
    defparam rpll_inst.CLKOUT_BYPASS = "false";
    defparam rpll_inst.CLKOUTP_BYPASS = "false";
    defparam rpll_inst.CLKOUTD_BYPASS = "false";
    defparam rpll_inst.DYN_SDIV_SEL = 2;
    defparam rpll_inst.CLKOUTD_SRC = "CLKOUT";
    defparam rpll_inst.CLKOUTD3_SRC = "CLKOUT";
    defparam rpll_inst.DEVICE = "GW2A-18C";
endmodule
