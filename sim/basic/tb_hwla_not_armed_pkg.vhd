-------------------------------------------------------------------------------
-- Title      : tb_hwla_not_armed_pkg
-- Project    : HWLA
-------------------------------------------------------------------------------
-- File       : tb_hwla_not_armed_pkg.vhd
-- Author     : mrosiere
-------------------------------------------------------------------------------
-- Description: Scenario not_armed of tb_hwla :
--              Trigger pulse without arm_i : no capture, armed_o, triggered_o and
--              m_axis_tvalid_o stay low
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

package tb_hwla_not_armed_pkg is

  -- Trigger pulse without arm_i : no capture, armed_o, triggered_o and
  -- m_axis_tvalid_o stay low
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

end package tb_hwla_not_armed_pkg;

package body tb_hwla_not_armed_pkg is

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
  begin
    log(ID_SEQUENCER, "Not armed : the trigger is ignored", C_TB_SCOPE);
    set_pulse(tb_rsp.probe_cnt + 4, 3, tb_req);
    wait for 2*cfg.depth*cfg.trig_period;
    check_stable(tb_rsp.armed    , 2*cfg.depth*cfg.trig_period, ERROR, "Not armed : armed_o stays low"        , C_TB_SCOPE);
    check_stable(tb_rsp.triggered, 2*cfg.depth*cfg.trig_period, ERROR, "Not armed : triggered_o stays low"    , C_TB_SCOPE);
    check_stable(axis_if.tvalid  , 2*cfg.depth*cfg.trig_period, ERROR, "Not armed : m_axis_tvalid_o stays low", C_TB_SCOPE);
    tb_req.pulses <= C_NO_PULSE;
  end procedure;

end package body tb_hwla_not_armed_pkg;
