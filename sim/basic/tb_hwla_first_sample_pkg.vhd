-------------------------------------------------------------------------------
-- Title      : tb_hwla_first_sample_pkg
-- Project    : HWLA
-------------------------------------------------------------------------------
-- File       : tb_hwla_first_sample_pkg.vhd
-- Author     : mrosiere
-------------------------------------------------------------------------------
-- Description: Scenario first_sample of tb_hwla :
--              First sample of a capture equal to the last stored sample of the
--              previous capture : stored anyway (first sample of the capture)
--              (PRE_TRIGGER > 0)
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

package tb_hwla_first_sample_pkg is

  -- First sample of a capture equal to the last stored sample of the
  -- previous capture : stored anyway (first sample of the capture)
  -- (PRE_TRIGGER > 0)
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

end package tb_hwla_first_sample_pkg;

package body tb_hwla_first_sample_pkg is

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
    variable v_samples : natural_array_t(0 to cfg.depth-1);
    variable v_model   : natural;
  begin
    log(ID_SEQUENCER, "First sample of the capture equal to the last stored sample", C_TB_SCOPE);

    -- A first capture gives the last stored sample
    arm_capture    (v_first, "Previous capture", trig_clk, tb_req, tb_rsp);
    set_pulse      (v_first + cfg.pre_trigger + 3, 1, tb_req);
    wait_trigger   (cfg, v_trigger, "Previous capture", tb_rsp);
    receive_capture(cfg, axis_cfg(cfg), v_first, v_trigger, "Previous capture", extract_clk, tb_req, tb_rsp, axis_if);
    wait_idle      (cfg, "Previous capture", tb_rsp, axis_if);
    tb_req.pulses <= C_NO_PULSE;
    model_capture  (cfg, tb_req.ts_origin, tb_rsp.probe_cnt, v_first, v_samples, v_model, "Previous capture");

    -- The first sample is stored (first sample of the capture), even without
    -- change. Level trigger from the third sample : the trigger sample is the
    -- first one after the pre-trigger samples, so the first sample is in the
    -- capture
    tb_req.probe_force <= history.get_probe(v_samples(cfg.depth-1), cfg.nb_probe);
    tb_req.probe_mode  <= MODE_FORCE;
    wait for 4*cfg.trig_period;
    arm_capture    (v_first, "First sample", trig_clk, tb_req, tb_rsp);
    tb_req.probe_mode  <= MODE_SPARSE;
    set_pulse      (v_first + 2, 64*cfg.depth, tb_req);
    wait_trigger   (cfg, v_trigger, "First sample", tb_rsp);
    receive_capture(cfg, axis_cfg(cfg), v_first, v_trigger, "First sample", extract_clk, tb_req, tb_rsp, axis_if);
    wait_idle      (cfg, "First sample", tb_rsp, axis_if);
    tb_req.pulses <= C_NO_PULSE;
  end procedure;

end package body tb_hwla_first_sample_pkg;
