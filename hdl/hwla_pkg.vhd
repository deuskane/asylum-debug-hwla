-------------------------------------------------------------------------------
-- Title      : hwla_pkg
-- Project    : Asylum
-------------------------------------------------------------------------------
-- File       : hwla_pkg.vhd
-- Author     : Mathieu Rosiere
-------------------------------------------------------------------------------
-- Description: HWLA (Hardware Logic Analyzer) functions and components
-------------------------------------------------------------------------------
-- Revisions  :
-- Date        Version  Author   Description
-- 2026-10-22  1.0      mrosiere Created
-- 2026-10-22  2.0      mrosiere hwla_sample_width, hwla_nb_beat, TDATA_WIDTH
-------------------------------------------------------------------------------

library IEEE;
use     IEEE.STD_LOGIC_1164.ALL;
use     IEEE.NUMERIC_STD.ALL;
library asylum;
use     asylum.math_pkg.all;

package hwla_pkg is

  -----------------------------------------------------------------------------
  -- hwla_sample_width
  -----------------------------------------------------------------------------
  -- Width of a stored sample : the timestamp (MSB) and the probes (LSB)
  function hwla_sample_width (nb_probe        : positive;
                              timestamp_width : natural ) return positive;

  -----------------------------------------------------------------------------
  -- hwla_tdata_width
  -----------------------------------------------------------------------------
  -- Width of the AXI-Stream tdata : tdata_width, or when tdata_width = 0 the
  -- sample width rounded up to an integer number of bytes (AXI4-Stream)
  function hwla_tdata_width  (sample_width    : positive;
                              tdata_width     : natural ) return positive;

  -----------------------------------------------------------------------------
  -- hwla_nb_beat
  -----------------------------------------------------------------------------
  -- Number of AXI-Stream beats of a sample
  function hwla_nb_beat      (sample_width    : positive;
                              tdata_width     : natural ) return positive;

-- [COMPONENT_INSERT][BEGIN]
component hwla is
  generic (
    NB_PROBE         : positive := 8;                                        -- Number of probes
    DEPTH            : positive := 256;                                      -- Number of stored samples of a capture (power of 2)
    PRE_TRIGGER      : natural  := 128;                                      -- Number of stored samples before the trigger sample (0 to DEPTH-1)
    TIMESTAMP_WIDTH  : natural  := 16;                                       -- Width of the timestamp of a sample (0 : no timestamp)
    CHANGE_ONLY      : boolean  := true;                                     -- true : store a sample only if the probes changed
    TDATA_WIDTH      : natural  := 0                                         -- Width of tdata (multiple of 8), 0 : one beat per sample
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
    m_axis_tdata_o   : out std_logic_vector(hwla_tdata_width(hwla_sample_width(NB_PROBE,TIMESTAMP_WIDTH),TDATA_WIDTH)-1 downto 0); -- Beat of a sample
    m_axis_tvalid_o  : out std_logic;
    m_axis_tready_i  : in  std_logic;
    m_axis_tlast_o   : out std_logic                                         -- 1 : last beat of the capture
    );
end component hwla;

component hwla_ram is
  generic (
    WIDTH        : positive := 8;                                  -- Width of a word
    DEPTH        : positive := 256                                 -- Number of words (power of 2)
    );
  port (
    -- Write port (wclk_i domain)
    wclk_i       : in  std_logic;
    we_i         : in  std_logic;                                  -- 1 : write wdata_i at waddr_i
    waddr_i      : in  std_logic_vector(log2(DEPTH)-1 downto 0);
    wdata_i      : in  std_logic_vector(WIDTH      -1 downto 0);

    -- Read port (rclk_i domain)
    rclk_i       : in  std_logic;
    re_i         : in  std_logic;                                  -- 1 : read the word at raddr_i
    raddr_i      : in  std_logic_vector(log2(DEPTH)-1 downto 0);
    rdata_o      : out std_logic_vector(WIDTH      -1 downto 0)    -- Word read, held while re_i = 0
    );
end component hwla_ram;

component hwla_trigger is
  generic (
    NB_PROBE        : positive := 8;                               -- Number of probes
    DEPTH           : positive := 256;                             -- Number of stored samples of a capture (power of 2)
    PRE_TRIGGER     : natural  := 128;                             -- Number of stored samples before the trigger sample (0 to DEPTH-1)
    TIMESTAMP_WIDTH : natural  := 16;                              -- Width of the timestamp of a sample (0 : no timestamp)
    CHANGE_ONLY     : boolean  := true                             -- true : store a sample only if the probes changed
    );
  port (
    -- Clock & Reset (trigger domain)
    clk_i        : in  std_logic;
    arst_b_i     : in  std_logic;                                  -- Asynchronous reset, active low

    -- Control and probes
    arm_i        : in  std_logic;                                  -- 1 : start a capture (when idle)
    trigger_i    : in  std_logic;                                  -- 1 : trigger condition
    probe_i      : in  std_logic_vector(NB_PROBE-1 downto 0);      -- Probed signals

    -- Status
    armed_o      : out std_logic;                                  -- 1 : capture started, trigger not yet seen
    triggered_o  : out std_logic;                                  -- 1 : trigger seen, capture not yet extracted

    -- RAM write port
    ram_we_o     : out std_logic;
    ram_waddr_o  : out std_logic_vector(log2(DEPTH)-1 downto 0);
    ram_wdata_o  : out std_logic_vector(TIMESTAMP_WIDTH+NB_PROBE-1 downto 0); -- Timestamp & probes

    -- Handshake with the extraction domain
    dump_req_o   : out std_logic;                                  -- 1 : capture done, to be extracted
    dump_addr_o  : out std_logic_vector(log2(DEPTH)-1 downto 0);   -- Address of the oldest sample, stable while dump_req_o = 1
    dump_ack_i   : in  std_logic                                   -- 1 : capture extracted (asynchronous, extraction domain)
    );
end component hwla_trigger;

component hwla_extract is
  generic (
    SAMPLE_WIDTH    : positive := 24;                                        -- Width of a sample (timestamp and probes)
    DEPTH           : positive := 256;                                       -- Number of samples of a capture (power of 2)
    TDATA_WIDTH     : natural  := 0                                          -- Width of tdata (multiple of 8), 0 : one beat per sample
    );
  port (
    -- Clock & Reset (extraction domain)
    clk_i           : in  std_logic;
    arst_b_i        : in  std_logic;                                         -- Asynchronous reset, active low

    -- Handshake with the trigger domain
    dump_req_i      : in  std_logic;                                         -- 1 : capture done, to be extracted (asynchronous, trigger domain)
    dump_addr_i     : in  std_logic_vector(log2(DEPTH)-1 downto 0);          -- Address of the oldest sample, stable while dump_req_i = 1
    dump_ack_o      : out std_logic;                                         -- 1 : capture extracted

    -- RAM read port
    ram_re_o        : out std_logic;
    ram_raddr_o     : out std_logic_vector(log2(DEPTH)-1 downto 0);
    ram_rdata_i     : in  std_logic_vector(SAMPLE_WIDTH-1 downto 0);         -- Sample read, one clock cycle after ram_re_o

    -- AXI-Stream master
    m_axis_tdata_o  : out std_logic_vector(hwla_tdata_width(SAMPLE_WIDTH,TDATA_WIDTH)-1 downto 0);
    m_axis_tvalid_o : out std_logic;
    m_axis_tready_i : in  std_logic;
    m_axis_tlast_o  : out std_logic                                          -- 1 : last beat of the capture
    );
end component hwla_extract;

-- [COMPONENT_INSERT][END]

end hwla_pkg;

package body hwla_pkg is

  -----------------------------------------------------------------------------
  -- hwla_sample_width
  -----------------------------------------------------------------------------
  function hwla_sample_width (nb_probe        : positive;
                              timestamp_width : natural ) return positive is
  begin
    return nb_probe + timestamp_width;
  end function;

  -----------------------------------------------------------------------------
  -- hwla_tdata_width
  -----------------------------------------------------------------------------
  function hwla_tdata_width  (sample_width    : positive;
                              tdata_width     : natural ) return positive is
  begin
    if tdata_width = 0
    then
      return 8*((sample_width+7)/8);
    else
      return tdata_width;
    end if;
  end function;

  -----------------------------------------------------------------------------
  -- hwla_nb_beat
  -----------------------------------------------------------------------------
  function hwla_nb_beat      (sample_width    : positive;
                              tdata_width     : natural ) return positive is
    constant TW : positive := hwla_tdata_width(sample_width, tdata_width);
  begin
    return (sample_width+TW-1)/TW;
  end function;

end package body hwla_pkg;
