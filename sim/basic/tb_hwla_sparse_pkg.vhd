-------------------------------------------------------------------------------
-- Title      : tb_hwla_sparse_pkg
-- Project    : HWLA
-------------------------------------------------------------------------------
-- File       : tb_hwla_sparse_pkg.vhd
-- Author     : mrosiere
-------------------------------------------------------------------------------
-- Description: Scenario sparse of tb_hwla :
--              Sparse probes (a change every 4 samples on average), two captures with
--              a level trigger from a late sample : the trigger sample is often a
--              sample without change (stored because it is the trigger sample)
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

package tb_hwla_sparse_pkg is

  -- Sparse probes (a change every 4 samples on average), two captures with
  -- a level trigger from a late sample : the trigger sample is often a
  -- sample without change (stored because it is the trigger sample)
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

end package tb_hwla_sparse_pkg;

package body tb_hwla_sparse_pkg is

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
    log(ID_SEQUENCER, "Sparse probes : a change every 4 samples on average", C_TB_SCOPE);
    tb_req.probe_mode <= MODE_SPARSE;
    wait for 4*cfg.trig_period;
    for i in 1 to 2 loop
      arm_capture    (v_first, "Sparse " & to_string(i), trig_clk, tb_req, tb_rsp);
      set_pulse      (v_first + 3*cfg.pre_trigger + 5*i, 64*cfg.depth, tb_req);
      wait_trigger   (cfg, v_trigger, "Sparse " & to_string(i), tb_rsp);
      receive_capture(cfg, axis_cfg(cfg), v_first, v_trigger, "Sparse " & to_string(i), extract_clk, tb_req, tb_rsp, axis_if);
      wait_idle      (cfg, "Sparse " & to_string(i), tb_rsp, axis_if);
      tb_req.pulses <= C_NO_PULSE;
    end loop;
  end procedure;

end package body tb_hwla_sparse_pkg;
