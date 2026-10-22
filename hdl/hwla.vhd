-------------------------------------------------------------------------------
-- Title      : hwla
-- Project    : Asylum
-------------------------------------------------------------------------------
-- File       : hwla.vhd
-- Author     : Mathieu Rosiere
-- Company    :
-- Created    : 2026-10-22
-- Last update: 2026-10-22
-- Platform   :
-- Standard   : VHDL'93/02
-------------------------------------------------------------------------------
-- Description:
-- HWLA : Hardware Logic Analyzer, without CSR. Two clock domains :
-- * Trigger domain (trig_clk_i) : hwla_trigger samples NB_PROBE probes and
--   one trigger at each clock cycle and records a capture of DEPTH samples
--   around the trigger (PRE_TRIGGER samples before the trigger sample) in
--   the RAM. A capture starts with arm_i, armed_o / triggered_o give the
--   progress of the capture.
-- * RAM : hwla_ram, simple dual port RAM, write port in the trigger domain,
--   read port in the extraction domain.
-- * Extraction domain (extract_clk_i) : hwla_extract reads the capture, from
--   the oldest sample to the newest, and sends it on the AXI-Stream master
--   interface, one sample per beat, tlast with the last sample.
-- The two domains communicate with a 4 phases req/ack handshake (one
-- synchronizer per direction) : no capture is started while the previous
-- one is not extracted, so the RAM is never written and read at the same
-- time.
-- The two resets are asynchronous, active low, and should be asserted
-- together.
-------------------------------------------------------------------------------
-- Copyright (c) 2026
-------------------------------------------------------------------------------
-- Revisions  :
-- Date        Version  Author   Description
-- 2026-10-22  1.0      mrosiere Created
-------------------------------------------------------------------------------

library IEEE;
use     IEEE.STD_LOGIC_1164.ALL;
use     IEEE.NUMERIC_STD.ALL;

library asylum;
use     asylum.math_pkg.ALL;
use     asylum.hwla_pkg.ALL;

entity hwla is
  generic (
    NB_PROBE         : positive := 8;                                        -- Number of probes (width of a sample)
    DEPTH            : positive := 256;                                      -- Number of samples of a capture (power of 2)
    PRE_TRIGGER      : natural  := 128                                       -- Number of samples before the trigger sample (0 to DEPTH-1)
    );
  port (
    -- Trigger domain
    trig_clk_i       : in  std_logic;
    trig_arst_b_i    : in  std_logic;                                        -- Asynchronous reset, active low
    arm_i            : in  std_logic;                                        -- 1 : start a capture (when idle). Tied to 1 : a new capture after each extraction
    trigger_i        : in  std_logic;                                        -- 1 : trigger condition
    probe_i          : in  std_logic_vector(NB_PROBE-1 downto 0);            -- Probed signals
    armed_o          : out std_logic;                                        -- 1 : capture started, trigger not yet seen
    triggered_o      : out std_logic;                                        -- 1 : trigger seen, capture not yet extracted

    -- Extraction domain
    extract_clk_i    : in  std_logic;
    extract_arst_b_i : in  std_logic;                                        -- Asynchronous reset, active low
    m_axis_tdata_o   : out std_logic_vector(hwla_tdata_width(NB_PROBE)-1 downto 0); -- Sample on the NB_PROBE LSB, other bits 0
    m_axis_tvalid_o  : out std_logic;
    m_axis_tready_i  : in  std_logic;
    m_axis_tlast_o   : out std_logic                                         -- 1 : last sample of the capture
    );
end entity hwla;

architecture rtl of hwla is

  constant ADDR_WIDTH             : natural := log2(DEPTH);

  -- RAM write port (trigger domain)
  signal   ram_we                 : std_logic;
  signal   ram_waddr              : std_logic_vector(ADDR_WIDTH-1 downto 0);
  signal   ram_wdata              : std_logic_vector(NB_PROBE  -1 downto 0);

  -- RAM read port (extraction domain)
  signal   ram_re                 : std_logic;
  signal   ram_raddr              : std_logic_vector(ADDR_WIDTH-1 downto 0);
  signal   ram_rdata              : std_logic_vector(NB_PROBE  -1 downto 0);

  -- Handshake between the two domains
  signal   dump_req               : std_logic;                               -- Trigger domain register
  signal   dump_addr              : std_logic_vector(ADDR_WIDTH-1 downto 0); -- Trigger domain register, quasi-static
  signal   dump_ack               : std_logic;                               -- Extraction domain register

begin  -- architecture rtl

  -----------------------------------------------------------------------------
  -- Trigger part
  -----------------------------------------------------------------------------
  ins_hwla_trigger : hwla_trigger
    generic map
    ( NB_PROBE    => NB_PROBE
     ,DEPTH       => DEPTH
     ,PRE_TRIGGER => PRE_TRIGGER
     )
    port map
    ( clk_i       => trig_clk_i
     ,arst_b_i    => trig_arst_b_i
     ,arm_i       => arm_i
     ,trigger_i   => trigger_i
     ,probe_i     => probe_i
     ,armed_o     => armed_o
     ,triggered_o => triggered_o
     ,ram_we_o    => ram_we
     ,ram_waddr_o => ram_waddr
     ,ram_wdata_o => ram_wdata
     ,dump_req_o  => dump_req
     ,dump_addr_o => dump_addr
     ,dump_ack_i  => dump_ack
    );

  -----------------------------------------------------------------------------
  -- RAM
  -----------------------------------------------------------------------------
  ins_hwla_ram : hwla_ram
    generic map
    ( WIDTH       => NB_PROBE
     ,DEPTH       => DEPTH
     )
    port map
    ( wclk_i      => trig_clk_i
     ,we_i        => ram_we
     ,waddr_i     => ram_waddr
     ,wdata_i     => ram_wdata
     ,rclk_i      => extract_clk_i
     ,re_i        => ram_re
     ,raddr_i     => ram_raddr
     ,rdata_o     => ram_rdata
    );

  -----------------------------------------------------------------------------
  -- Extraction part
  -----------------------------------------------------------------------------
  ins_hwla_extract : hwla_extract
    generic map
    ( NB_PROBE        => NB_PROBE
     ,DEPTH           => DEPTH
     )
    port map
    ( clk_i           => extract_clk_i
     ,arst_b_i        => extract_arst_b_i
     ,dump_req_i      => dump_req
     ,dump_addr_i     => dump_addr
     ,dump_ack_o      => dump_ack
     ,ram_re_o        => ram_re
     ,ram_raddr_o     => ram_raddr
     ,ram_rdata_i     => ram_rdata
     ,m_axis_tdata_o  => m_axis_tdata_o
     ,m_axis_tvalid_o => m_axis_tvalid_o
     ,m_axis_tready_i => m_axis_tready_i
     ,m_axis_tlast_o  => m_axis_tlast_o
    );

end architecture rtl;
