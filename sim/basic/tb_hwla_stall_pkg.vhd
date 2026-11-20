-------------------------------------------------------------------------------
-- Title      : tb_hwla_stall_pkg
-- Project    : HWLA
-------------------------------------------------------------------------------
-- File       : tb_hwla_stall_pkg.vhd
-- Author     : mrosiere
-------------------------------------------------------------------------------
-- Description: Scenario stall of tb_hwla :
--              Long stall : the first beat is held while tready = 0, the capture is
--              held until the end of the extraction, arm_i and the trigger are
--              ignored during the extraction
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

package tb_hwla_stall_pkg is

  -- Long stall : the first beat is held while tready = 0, the capture is
  -- held until the end of the extraction, arm_i and the trigger are
  -- ignored during the extraction
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

end package tb_hwla_stall_pkg;

package body tb_hwla_stall_pkg is

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
    variable v_nb_arm  : natural;
  begin
    log(ID_SEQUENCER, "Long stall : capture held, arm_i and trigger ignored until the end of the extraction", C_TB_SCOPE);
    arm_capture (v_first, "Stall", trig_clk, tb_req, tb_rsp);
    set_pulse   (v_first + cfg.pre_trigger + 1, 1, tb_req);
    wait_trigger(cfg, v_trigger, "Stall", tb_rsp);

    -- First beat presented, tready low : the beat is held
    await_value (axis_if.tvalid, '1', 0 ns, cfg.timeout, ERROR, "Stall : first beat presented", C_TB_SCOPE);
    wait for 50*cfg.extract_period;
    check_stable(axis_if.tvalid  , 50*cfg.extract_period, ERROR, "Stall : tvalid held while tready = 0", C_TB_SCOPE);
    check_stable(axis_if.tdata   , 50*cfg.extract_period, ERROR, "Stall : tdata held while tready = 0" , C_TB_SCOPE);
    check_value (tb_rsp.triggered, '1', ERROR, "Stall : triggered_o high until the end of the extraction", C_TB_SCOPE);

    -- A new arm and a new trigger before the end of the extraction
    v_nb_arm   := tb_rsp.nb_arm;
    wait until falling_edge(trig_clk);
    tb_req.arm <= '1';
    set_pulse(tb_rsp.probe_cnt, 3, tb_req);
    wait until falling_edge(trig_clk);
    tb_req.arm <= '0';
    wait for 5*cfg.trig_period;
    check_value(tb_rsp.nb_arm, v_nb_arm, ERROR, "Stall : arm_i ignored during the extraction", C_TB_SCOPE);
    tb_req.pulses <= C_NO_PULSE;

    receive_capture(cfg, axis_cfg(cfg), v_first, v_trigger, "Stall", extract_clk, tb_req, tb_rsp, axis_if);
    wait_idle      (cfg, "Stall", tb_rsp, axis_if);
    wait for 2*cfg.depth*cfg.trig_period;
    check_value (tb_rsp.nb_arm , v_nb_arm, ERROR, "Stall : no capture after the extraction", C_TB_SCOPE);
    check_stable(axis_if.tvalid, 2*cfg.depth*cfg.trig_period, ERROR, "Stall : m_axis_tvalid_o stays low", C_TB_SCOPE);
  end procedure;

end package body tb_hwla_stall_pkg;
