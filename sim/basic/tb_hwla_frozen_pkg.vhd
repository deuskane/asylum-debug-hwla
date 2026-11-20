-------------------------------------------------------------------------------
-- Title      : tb_hwla_frozen_pkg
-- Project    : HWLA
-------------------------------------------------------------------------------
-- File       : tb_hwla_frozen_pkg.vhd
-- Author     : mrosiere
-------------------------------------------------------------------------------
-- Description: Scenario frozen of tb_hwla :
--              Frozen probes : samples stored at the timestamp 0 only, timestamp
--              wrap (2**TIMESTAMP_WIDTH small, or CHANGE_ONLY = false)
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

package tb_hwla_frozen_pkg is

  -- Frozen probes : samples stored at the timestamp 0 only, timestamp
  -- wrap (2**TIMESTAMP_WIDTH small, or CHANGE_ONLY = false)
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

end package tb_hwla_frozen_pkg;

package body tb_hwla_frozen_pkg is

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
    log(ID_SEQUENCER, "Frozen probes : samples stored at the timestamp 0 only", C_TB_SCOPE);
    tb_req.probe_mode <= MODE_FROZEN;
    wait for 4*cfg.trig_period;
    arm_capture    (v_first, "Frozen", trig_clk, tb_req, tb_rsp);
    set_pulse      (v_first + 5, 2*cfg.depth*cfg.frozen_period + 100, tb_req);
    wait_trigger   (cfg, v_trigger, "Frozen", tb_rsp);
    receive_capture(cfg, axis_cfg(cfg), v_first, v_trigger, "Frozen", extract_clk, tb_req, tb_rsp, axis_if);
    wait_idle      (cfg, "Frozen", tb_rsp, axis_if);
    tb_req.pulses <= C_NO_PULSE;
  end procedure;

end package body tb_hwla_frozen_pkg;
