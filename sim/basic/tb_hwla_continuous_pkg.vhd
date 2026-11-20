-------------------------------------------------------------------------------
-- Title      : tb_hwla_continuous_pkg
-- Project    : HWLA
-------------------------------------------------------------------------------
-- File       : tb_hwla_continuous_pkg.vhd
-- Author     : mrosiere
-------------------------------------------------------------------------------
-- Description: Scenario continuous of tb_hwla :
--              Continuous captures, arm_i held high : 4 trigger pulses, gap samples
--              apart, a capture per pulse, the next capture starts at the end of the
--              extraction of the previous one ; no capture after arm_i low
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

package tb_hwla_continuous_pkg is

  -- Continuous captures, arm_i held high : 4 trigger pulses, gap samples
  -- apart, a capture per pulse, the next capture starts at the end of the
  -- extraction of the previous one ; no capture after arm_i low
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

end package tb_hwla_continuous_pkg;

package body tb_hwla_continuous_pkg is

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
    variable v_pulses  : pulse_array_t := C_NO_PULSE;
  begin
    log(ID_SEQUENCER, "Continuous captures : arm_i held high", C_TB_SCOPE);
    wait until falling_edge(trig_clk);
    v_nb_arm      := tb_rsp.nb_arm;
    for i in 0 to 3 loop
      v_pulses(i) := (tb_rsp.probe_cnt + cfg.pre_trigger + 5 + i*cfg.gap, 1);
    end loop;
    tb_req.pulses <= v_pulses;
    tb_req.arm    <= '1';

    for i in 1 to 3 loop
      -- Capture i started
      if tb_rsp.nb_arm /= v_nb_arm + i
      then
        wait until tb_rsp.nb_arm = v_nb_arm + i for cfg.timeout;
      end if;
      check_value (tb_rsp.nb_arm, v_nb_arm + i, ERROR, "Continuous : capture " & to_string(i) & " started", C_TB_SCOPE);
      v_first := tb_rsp.arm_sample;
      wait_trigger(cfg, v_trigger, "Continuous " & to_string(i), tb_rsp);
      check_value (v_trigger, first_trigger(tb_req.pulses, v_first + cfg.pre_trigger), ERROR, "Continuous : first pulse after the pre-trigger samples", C_TB_SCOPE);

      -- No capture after the last one
      if i = 3
      then
        wait until falling_edge(trig_clk);
        tb_req.arm <= '0';
      end if;

      receive_capture(cfg, axis_cfg(cfg), v_first, v_trigger, "Continuous " & to_string(i), extract_clk, tb_req, tb_rsp, axis_if);
    end loop;
    wait_idle(cfg, "Continuous", tb_rsp, axis_if);
    wait for 2*cfg.depth*cfg.trig_period;
    check_value(tb_rsp.nb_arm, v_nb_arm + 3, ERROR, "Continuous : no capture after arm_i low", C_TB_SCOPE);
    tb_req.pulses <= C_NO_PULSE;
  end procedure;

end package body tb_hwla_continuous_pkg;
