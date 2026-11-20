-------------------------------------------------------------------------------
-- Title      : tb_hwla_capture_pkg
-- Project    : HWLA
-------------------------------------------------------------------------------
-- File       : tb_hwla_capture_pkg.vhd
-- Author     : mrosiere
-------------------------------------------------------------------------------
-- Description: Scenario capture of tb_hwla :
--              Single capture, trigger 7 samples after the pre-trigger samples
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

package tb_hwla_capture_pkg is

  -- Single capture, trigger 7 samples after the pre-trigger samples
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

end package tb_hwla_capture_pkg;

package body tb_hwla_capture_pkg is

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
  begin
    log(ID_SEQUENCER, "Capture, trigger 7 samples after the pre-trigger samples", C_TB_SCOPE);
    arm_capture    (v_first, "Capture", trig_clk, tb_req, tb_rsp);
    set_pulse      (v_first + cfg.pre_trigger + 7, 1, tb_req);
    wait_trigger   (cfg, v_trigger, "Capture", tb_rsp);
    check_value    (v_trigger, v_first + cfg.pre_trigger + 7, ERROR, "Capture : trigger sample", C_TB_SCOPE);
    receive_capture(cfg, axis_cfg(cfg), v_first, v_trigger, "Capture", extract_clk, tb_req, tb_rsp, axis_if);
    wait_idle      (cfg, "Capture", tb_rsp, axis_if);
  end procedure;

end package body tb_hwla_capture_pkg;
