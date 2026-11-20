-------------------------------------------------------------------------------
-- Title      : tb_hwla_tests_pkg
-- Project    : HWLA
-------------------------------------------------------------------------------
-- File       : tb_hwla_tests_pkg.vhd
-- Author     : mrosiere
-------------------------------------------------------------------------------
-- Description: Scenarios of tb_hwla : names (valid items of TESTS_LIST),
--              scenarios not applicable to the configuration, dispatch
--              (run_test) to the package of each scenario (tb_hwla_<name>_pkg)
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

library asylum;
use     asylum.string_pkg.all;

library work;
use     work.tb_hwla_bfm_pkg.all;

package tb_hwla_tests_pkg is

  -- Names of the scenarios (valid items of TESTS_LIST)
  constant C_TESTS : string := "reset_values,not_armed,capture,pre_trigger_ignored,level_trigger,late_trigger,back_pressure,stall,continuous,sparse,frozen,first_sample,async_reset";

  -- false : the scenario name does not apply to the configuration cfg
  -- (pre_trigger_ignored : PRE_TRIGGER >= 3, frozen : short timestamp or
  -- every sample stored, first_sample : PRE_TRIGGER > 0)
  function test_applies
    (constant name           : in    string
    ;constant cfg            : in    tb_cfg_t
    ) return boolean;

  -- Run the scenario name
  procedure run_test
    (constant name           : in    string
    ;constant cfg            : in    tb_cfg_t
    ;signal   trig_clk       : in    std_logic
    ;signal   trig_arst_b    : out   std_logic
    ;signal   extract_clk    : in    std_logic
    ;signal   extract_arst_b : out   std_logic
    ;signal   tb_req         : inout tb_req_t
    ;signal   tb_rsp         : in    tb_rsp_t
    ;signal   axis_if        : inout t_axistream_if
    );

end package tb_hwla_tests_pkg;

package body tb_hwla_tests_pkg is

  function test_applies
    (constant name           : in    string
    ;constant cfg            : in    tb_cfg_t
    ) return boolean is
  begin
    if    string_eq(name, "pre_trigger_ignored")
    then
      return cfg.pre_trigger >= 3;
    elsif string_eq(name, "frozen")
    then
      return cfg.frozen_test;
    elsif string_eq(name, "first_sample")
    then
      return cfg.pre_trigger > 0;
    else
      return true;
    end if;
  end function;

  procedure run_test
    (constant name           : in    string
    ;constant cfg            : in    tb_cfg_t
    ;signal   trig_clk       : in    std_logic
    ;signal   trig_arst_b    : out   std_logic
    ;signal   extract_clk    : in    std_logic
    ;signal   extract_arst_b : out   std_logic
    ;signal   tb_req         : inout tb_req_t
    ;signal   tb_rsp         : in    tb_rsp_t
    ;signal   axis_if        : inout t_axistream_if
    ) is
  begin
    if    string_eq(name, "reset_values")
    then
      work.tb_hwla_reset_values_pkg.run(cfg, trig_clk, trig_arst_b, extract_clk, extract_arst_b, tb_req, tb_rsp, axis_if);
    elsif string_eq(name, "not_armed")
    then
      work.tb_hwla_not_armed_pkg.run(cfg, trig_clk, trig_arst_b, extract_clk, extract_arst_b, tb_req, tb_rsp, axis_if);
    elsif string_eq(name, "capture")
    then
      work.tb_hwla_capture_pkg.run(cfg, trig_clk, trig_arst_b, extract_clk, extract_arst_b, tb_req, tb_rsp, axis_if);
    elsif string_eq(name, "pre_trigger_ignored")
    then
      work.tb_hwla_pre_trigger_ignored_pkg.run(cfg, trig_clk, trig_arst_b, extract_clk, extract_arst_b, tb_req, tb_rsp, axis_if);
    elsif string_eq(name, "level_trigger")
    then
      work.tb_hwla_level_trigger_pkg.run(cfg, trig_clk, trig_arst_b, extract_clk, extract_arst_b, tb_req, tb_rsp, axis_if);
    elsif string_eq(name, "late_trigger")
    then
      work.tb_hwla_late_trigger_pkg.run(cfg, trig_clk, trig_arst_b, extract_clk, extract_arst_b, tb_req, tb_rsp, axis_if);
    elsif string_eq(name, "back_pressure")
    then
      work.tb_hwla_back_pressure_pkg.run(cfg, trig_clk, trig_arst_b, extract_clk, extract_arst_b, tb_req, tb_rsp, axis_if);
    elsif string_eq(name, "stall")
    then
      work.tb_hwla_stall_pkg.run(cfg, trig_clk, trig_arst_b, extract_clk, extract_arst_b, tb_req, tb_rsp, axis_if);
    elsif string_eq(name, "continuous")
    then
      work.tb_hwla_continuous_pkg.run(cfg, trig_clk, trig_arst_b, extract_clk, extract_arst_b, tb_req, tb_rsp, axis_if);
    elsif string_eq(name, "sparse")
    then
      work.tb_hwla_sparse_pkg.run(cfg, trig_clk, trig_arst_b, extract_clk, extract_arst_b, tb_req, tb_rsp, axis_if);
    elsif string_eq(name, "frozen")
    then
      work.tb_hwla_frozen_pkg.run(cfg, trig_clk, trig_arst_b, extract_clk, extract_arst_b, tb_req, tb_rsp, axis_if);
    elsif string_eq(name, "first_sample")
    then
      work.tb_hwla_first_sample_pkg.run(cfg, trig_clk, trig_arst_b, extract_clk, extract_arst_b, tb_req, tb_rsp, axis_if);
    elsif string_eq(name, "async_reset")
    then
      work.tb_hwla_async_reset_pkg.run(cfg, trig_clk, trig_arst_b, extract_clk, extract_arst_b, tb_req, tb_rsp, axis_if);
    else
      alert(TB_ERROR, "Unknown test " & name, C_TB_SCOPE);
    end if;
  end procedure;

end package body tb_hwla_tests_pkg;
