-------------------------------------------------------------------------------
-- Title      : tb_hwla_pre_trigger_ignored_pkg
-- Project    : HWLA
-------------------------------------------------------------------------------
-- File       : tb_hwla_pre_trigger_ignored_pkg.vhd
-- Author     : mrosiere
-------------------------------------------------------------------------------
-- Description: Scenario pre_trigger_ignored of tb_hwla :
--              Triggers during the pre-trigger samples are ignored : a pulse on the
--              third sample, a pulse on the last pre-trigger sample and on the first
--              sample after, this one is the trigger sample (PRE_TRIGGER >= 3)
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

package tb_hwla_pre_trigger_ignored_pkg is

  -- Triggers during the pre-trigger samples are ignored : a pulse on the
  -- third sample, a pulse on the last pre-trigger sample and on the first
  -- sample after, this one is the trigger sample (PRE_TRIGGER >= 3)
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

end package tb_hwla_pre_trigger_ignored_pkg;

package body tb_hwla_pre_trigger_ignored_pkg is

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
    variable v_pulses  : pulse_array_t := C_NO_PULSE;
  begin
    log(ID_SEQUENCER, "Triggers during the pre-trigger samples are ignored", C_TB_SCOPE);
    arm_capture    (v_first, "Pre-trigger", trig_clk, tb_req, tb_rsp);
    v_pulses(0)   := (v_first + 2                  , 1);
    v_pulses(1)   := (v_first + cfg.pre_trigger - 1, 2);
    tb_req.pulses <= v_pulses;
    wait_trigger   (cfg, v_trigger, "Pre-trigger", tb_rsp);
    check_value    (v_trigger, v_first + cfg.pre_trigger, ERROR, "Pre-trigger : trigger sample", C_TB_SCOPE);
    receive_capture(cfg, axis_cfg(cfg), v_first, v_trigger, "Pre-trigger", extract_clk, tb_req, tb_rsp, axis_if);
    wait_idle      (cfg, "Pre-trigger", tb_rsp, axis_if);
  end procedure;

end package body tb_hwla_pre_trigger_ignored_pkg;
