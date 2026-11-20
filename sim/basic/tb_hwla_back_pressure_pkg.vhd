-------------------------------------------------------------------------------
-- Title      : tb_hwla_back_pressure_pkg
-- Project    : HWLA
-------------------------------------------------------------------------------
-- File       : tb_hwla_back_pressure_pkg.vhd
-- Author     : mrosiere
-------------------------------------------------------------------------------
-- Description: Scenario back_pressure of tb_hwla :
--              Random back pressure : tready low before random beats
-------------------------------------------------------------------------------
-- Copyright (c) 2026
-------------------------------------------------------------------------------
-- Revisions  :
-- Date        Version  Author   Description
-- 2026-11-20  1.0      mrosiere Created (split of tb_hwla)
-------------------------------------------------------------------------------

library ieee;
use     ieee.std_logic_1164.all;

library uvvm_util;
context uvvm_util.uvvm_util_context;

library bitvis_vip_axistream;
use     bitvis_vip_axistream.axistream_bfm_pkg.all;

library work;
use     work.tb_hwla_bfm_pkg.all;

package tb_hwla_back_pressure_pkg is

  -- Random back pressure : tready low before random beats
  procedure run
    (constant cfg            : in    tb_cfg_t
    ;signal   trig_clk       : in    std_logic
    ;signal   trig_arst_b    : out   std_logic
    ;signal   extract_clk    : in    std_logic
    ;signal   extract_arst_b : out   std_logic
    ;signal   tb_req         : inout tb_req_t
    ;signal   tb_rsp         : in    tb_rsp_t
    ;signal   axis_if        : inout t_axistream_if
    );

end package tb_hwla_back_pressure_pkg;

package body tb_hwla_back_pressure_pkg is

  procedure run
    (constant cfg            : in    tb_cfg_t
    ;signal   trig_clk       : in    std_logic
    ;signal   trig_arst_b    : out   std_logic
    ;signal   extract_clk    : in    std_logic
    ;signal   extract_arst_b : out   std_logic
    ;signal   tb_req         : inout tb_req_t
    ;signal   tb_rsp         : in    tb_rsp_t
    ;signal   axis_if        : inout t_axistream_if
    ) is
    variable v_first   : natural;   -- First sample of the capture
    variable v_trigger : natural;   -- Trigger sample of the capture (seen by the dut)
    variable v_axis_config : t_axistream_bfm_config := axis_cfg(cfg);
  begin
    log(ID_SEQUENCER, "Random back pressure (tready low before random beats)", C_TB_SCOPE);
    v_axis_config.ready_low_at_word_num          := C_MULTIPLE_RANDOM;
    v_axis_config.ready_low_multiple_random_prob := 0.5;
    v_axis_config.ready_low_duration             := C_RANDOM;
    v_axis_config.ready_low_max_random_duration  := 5;
    arm_capture    (v_first, "Back pressure", trig_clk, tb_req, tb_rsp);
    set_pulse      (v_first + cfg.pre_trigger + 3, 1, tb_req);
    wait_trigger   (cfg, v_trigger, "Back pressure", tb_rsp);
    check_value    (v_trigger, v_first + cfg.pre_trigger + 3, ERROR, "Back pressure : trigger sample", C_TB_SCOPE);
    receive_capture(cfg, v_axis_config, v_first, v_trigger, "Back pressure", extract_clk, tb_req, tb_rsp, axis_if);
    wait_idle      (cfg, "Back pressure", tb_rsp, axis_if);
  end procedure;

end package body tb_hwla_back_pressure_pkg;
