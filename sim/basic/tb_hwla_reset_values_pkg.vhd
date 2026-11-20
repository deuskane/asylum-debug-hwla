-------------------------------------------------------------------------------
-- Title      : tb_hwla_reset_values_pkg
-- Project    : HWLA
-------------------------------------------------------------------------------
-- File       : tb_hwla_reset_values_pkg.vhd
-- Author     : mrosiere
-------------------------------------------------------------------------------
-- Description: Scenario reset_values of tb_hwla :
--              Outputs after the reset : armed_o, triggered_o, m_axis_tvalid_o
--              and m_axis_tlast_o low
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

package tb_hwla_reset_values_pkg is

  -- Outputs after the reset : armed_o, triggered_o, m_axis_tvalid_o
  -- and m_axis_tlast_o low
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

end package tb_hwla_reset_values_pkg;

package body tb_hwla_reset_values_pkg is

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
    log(ID_SEQUENCER, "Reset values", C_TB_SCOPE);
    check_value(tb_rsp.armed    , '0', ERROR, "Reset : armed_o low"        , C_TB_SCOPE);
    check_value(tb_rsp.triggered, '0', ERROR, "Reset : triggered_o low"    , C_TB_SCOPE);
    check_value(axis_if.tvalid  , '0', ERROR, "Reset : m_axis_tvalid_o low", C_TB_SCOPE);
    check_value(axis_if.tlast   , '0', ERROR, "Reset : m_axis_tlast_o low" , C_TB_SCOPE);
  end procedure;

end package body tb_hwla_reset_values_pkg;
