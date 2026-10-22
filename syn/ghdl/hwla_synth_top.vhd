-------------------------------------------------------------------------------
-- Title      : hwla_synth_top
-- Project    : Asylum
-------------------------------------------------------------------------------
-- File       : hwla_synth_top.vhd
-- Author     : Mathieu Rosiere
-------------------------------------------------------------------------------
-- Description:
-- Synthesis check top (lint_ghdl, lint_ghdl_synth) : hwla in the work
-- library (the toplevel of the edalize ghdl flow), same generics and ports.
-------------------------------------------------------------------------------
-- Copyright (c) 2026
-------------------------------------------------------------------------------
-- Revisions  :
-- Date        Version  Author   Description
-- 2026-10-22  1.0      mrosiere Created
-- 2026-10-22  2.0      mrosiere TIMESTAMP_WIDTH, CHANGE_ONLY, TDATA_WIDTH
-------------------------------------------------------------------------------

library ieee;
use     ieee.std_logic_1164.all;
library asylum;
use     asylum.hwla_pkg.all;

entity hwla_synth_top is
  generic (
    NB_PROBE         : positive := 8;
    DEPTH            : positive := 256;
    PRE_TRIGGER      : natural  := 128;
    TIMESTAMP_WIDTH  : natural  := 16;
    CHANGE_ONLY      : boolean  := true;
    TDATA_WIDTH      : natural  := 0
  );
  port (
    -- Trigger domain
    trig_clk_i       : in  std_logic;
    trig_arst_b_i    : in  std_logic;
    arm_i            : in  std_logic;
    trigger_i        : in  std_logic;
    probe_i          : in  std_logic_vector(NB_PROBE-1 downto 0);
    armed_o          : out std_logic;
    triggered_o      : out std_logic;

    -- Extraction domain
    extract_clk_i    : in  std_logic;
    extract_arst_b_i : in  std_logic;
    m_axis_tdata_o   : out std_logic_vector(hwla_tdata_width(hwla_sample_width(NB_PROBE,TIMESTAMP_WIDTH),TDATA_WIDTH)-1 downto 0);
    m_axis_tvalid_o  : out std_logic;
    m_axis_tready_i  : in  std_logic;
    m_axis_tlast_o   : out std_logic
  );
end entity hwla_synth_top;

architecture rtl of hwla_synth_top is
begin

  ins_hwla : entity asylum.hwla
    generic map (
      NB_PROBE         => NB_PROBE,
      DEPTH            => DEPTH,
      PRE_TRIGGER      => PRE_TRIGGER,
      TIMESTAMP_WIDTH  => TIMESTAMP_WIDTH,
      CHANGE_ONLY      => CHANGE_ONLY,
      TDATA_WIDTH      => TDATA_WIDTH
    )
    port map (
      trig_clk_i       => trig_clk_i,
      trig_arst_b_i    => trig_arst_b_i,
      arm_i            => arm_i,
      trigger_i        => trigger_i,
      probe_i          => probe_i,
      armed_o          => armed_o,
      triggered_o      => triggered_o,
      extract_clk_i    => extract_clk_i,
      extract_arst_b_i => extract_arst_b_i,
      m_axis_tdata_o   => m_axis_tdata_o,
      m_axis_tvalid_o  => m_axis_tvalid_o,
      m_axis_tready_i  => m_axis_tready_i,
      m_axis_tlast_o   => m_axis_tlast_o
    );

end architecture rtl;
