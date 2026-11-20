-------------------------------------------------------------------------------
-- Title      : tb_hwla_async_reset_pkg
-- Project    : HWLA
-------------------------------------------------------------------------------
-- File       : tb_hwla_async_reset_pkg.vhd
-- Author     : mrosiere
-------------------------------------------------------------------------------
-- Description: Scenario async_reset of tb_hwla :
--              Asynchronous reset of both domains during an extraction : outputs
--              low without clock edge, the capture is lost, then a new capture (new
--              origin of the timestamp)
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

package tb_hwla_async_reset_pkg is

  -- Asynchronous reset of both domains during an extraction : outputs
  -- low without clock edge, the capture is lost, then a new capture (new
  -- origin of the timestamp)
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

end package tb_hwla_async_reset_pkg;

package body tb_hwla_async_reset_pkg is

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
    log(ID_SEQUENCER, "Asynchronous reset during an extraction", C_TB_SCOPE);
    arm_capture (v_first, "Reset", trig_clk, tb_req, tb_rsp);
    set_pulse   (v_first + cfg.pre_trigger + 2, 1, tb_req);
    wait_trigger(cfg, v_trigger, "Reset", tb_rsp);
    await_value (axis_if.tvalid, '1', 0 ns, cfg.timeout, ERROR, "Reset : first beat presented", C_TB_SCOPE);
    tb_req.pulses  <= C_NO_PULSE;

    trig_arst_b    <= '0';
    extract_arst_b <= '0';
    wait for 1 ns;
    check_value(tb_rsp.armed    , '0', ERROR, "Reset : armed_o low"        , C_TB_SCOPE);
    check_value(tb_rsp.triggered, '0', ERROR, "Reset : triggered_o low"    , C_TB_SCOPE);
    check_value(axis_if.tvalid  , '0', ERROR, "Reset : m_axis_tvalid_o low", C_TB_SCOPE);
    check_value(axis_if.tlast   , '0', ERROR, "Reset : m_axis_tlast_o low" , C_TB_SCOPE);
    wait for 5*cfg.trig_period + 5*cfg.extract_period;
    release_resets(trig_clk, trig_arst_b, extract_clk, extract_arst_b, tb_req, tb_rsp);
    wait for 2*cfg.depth*cfg.trig_period;
    check_stable(axis_if.tvalid, 2*cfg.depth*cfg.trig_period, ERROR, "Reset : the capture is lost", C_TB_SCOPE);

    -- New capture after the reset (new origin of the timestamp)
    arm_capture    (v_first, "After reset", trig_clk, tb_req, tb_rsp);
    set_pulse      (v_first + cfg.pre_trigger + 4, 1, tb_req);
    wait_trigger   (cfg, v_trigger, "After reset", tb_rsp);
    check_value    (v_trigger, v_first + cfg.pre_trigger + 4, ERROR, "After reset : trigger sample", C_TB_SCOPE);
    receive_capture(cfg, axis_cfg(cfg), v_first, v_trigger, "After reset", extract_clk, tb_req, tb_rsp, axis_if);
    wait_idle      (cfg, "After reset", tb_rsp, axis_if);
    tb_req.pulses  <= C_NO_PULSE;
  end procedure;

end package body tb_hwla_async_reset_pkg;
