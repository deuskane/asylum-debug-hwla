-------------------------------------------------------------------------------
-- Title      : hwla_extract
-- Project    : Asylum
-------------------------------------------------------------------------------
-- File       : hwla_extract.vhd
-- Author     : Mathieu Rosiere
-- Company    :
-- Created    : 2026-10-22
-- Last update: 2026-10-22
-- Platform   :
-- Standard   : VHDL'93/02
-------------------------------------------------------------------------------
-- Description:
-- Extraction part of the HWLA, in the extraction clock domain (clk_i).
-- Reads a capture in the RAM of the HWLA and sends it on an AXI-Stream
-- master interface :
-- * IDLE : wait for a capture (dump_req_i synchronized with sync2dffrn), then
--          start the read at dump_addr_i, the address of the oldest sample
--          (quasi-static : stable while dump_req_i = 1).
--   DUMP : read the DEPTH samples of the capture, from the oldest to the
--          newest (the read address wraps around the RAM), one beat per
--          sample. tlast is set with the last sample.
--   ACK  : the last beat is accepted, dump_ack_o = 1 until dump_req_i falls,
--          then IDLE.
-- * The RAM output register is the tdata register : a sample is read when
--   the beat is empty or accepted in the same clock cycle, so tdata is held
--   while tvalid = 1 and tready = 0, and the throughput is one sample per
--   clock cycle while tready = 1.
-- * tdata is the sample on the NB_PROBE LSB, the other bits are 0
--   (hwla_tdata_width : integer number of bytes).
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
use     asylum.techmap_pkg.ALL;
use     asylum.hwla_pkg.ALL;

entity hwla_extract is
  generic (
    NB_PROBE        : positive := 8;                                         -- Number of probes (width of a sample)
    DEPTH           : positive := 256                                        -- Number of samples of a capture (power of 2)
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
    ram_rdata_i     : in  std_logic_vector(NB_PROBE   -1 downto 0);          -- Sample read, one clock cycle after ram_re_o

    -- AXI-Stream master
    m_axis_tdata_o  : out std_logic_vector(hwla_tdata_width(NB_PROBE)-1 downto 0);
    m_axis_tvalid_o : out std_logic;
    m_axis_tready_i : in  std_logic;
    m_axis_tlast_o  : out std_logic                                          -- 1 : last sample of the capture
    );
end entity hwla_extract;

architecture rtl of hwla_extract is

  constant ADDR_WIDTH             : natural := log2(DEPTH);
  constant TDATA_WIDTH            : natural := hwla_tdata_width(NB_PROBE);

  type     state_t is (IDLE, DUMP, ACK);
  signal   state_r                : state_t;

  -- Handshake
  signal   dump_req_sync          : std_logic;
  signal   dump_ack_r             : std_logic;

  -- RAM read
  signal   re                     : std_logic;
  signal   raddr_r                : unsigned(ADDR_WIDTH-1 downto 0);
  signal   cnt_r                  : unsigned(ADDR_WIDTH-1 downto 0);
  signal   rd_done_r              : std_logic;

  -- AXI-Stream beat
  signal   tvalid_r               : std_logic;
  signal   tlast_r                : std_logic;

begin  -- architecture rtl

  -----------------------------------------------------------------------------
  -- Synchronization of the request from the trigger domain
  -----------------------------------------------------------------------------
  ins_dump_req_sync : sync2dffrn
    port map
    ( clk_i    => clk_i
     ,arst_b_i => arst_b_i
     ,d_i      => dump_req_i
     ,q_o      => dump_req_sync
    );

  -----------------------------------------------------------------------------
  -- Extraction FSM
  -----------------------------------------------------------------------------
  -- Read the next sample when the beat is empty or accepted in this cycle
  re                   <= '1' when state_r   = DUMP and
                                   rd_done_r = '0'  and
                                   (tvalid_r = '0' or m_axis_tready_i = '1') else
                          '0';

  process(clk_i,arst_b_i)
  begin
    if arst_b_i = '0'
    then
      state_r    <= IDLE;
      raddr_r    <= (others => '0');
      cnt_r      <= (others => '0');
      rd_done_r  <= '0';
      tvalid_r   <= '0';
      tlast_r    <= '0';
      dump_ack_r <= '0';
    elsif rising_edge(clk_i)
    then
      -- The beat is accepted (a new sample read below sets tvalid again)
      if m_axis_tready_i = '1'
      then
        tvalid_r <= '0';
      end if;

      case state_r is
        when IDLE =>
          -- New capture : start with the oldest sample
          if dump_req_sync = '1'
          then
            raddr_r   <= unsigned(dump_addr_i);
            cnt_r     <= (others => '0');
            rd_done_r <= '0';
            state_r   <= DUMP;
          end if;

        when DUMP =>
          -- Sample read : available in the RAM output register at the next
          -- clock cycle, with tvalid
          if re = '1'
          then
            raddr_r  <= raddr_r + 1;
            cnt_r    <= cnt_r   + 1;
            tvalid_r <= '1';

            -- Last sample of the capture
            if to_integer(cnt_r) = DEPTH-1
            then
              rd_done_r <= '1';
              tlast_r   <= '1';
            end if;
          end if;

          -- Last sample accepted : end of the extraction
          if tvalid_r = '1' and tlast_r = '1' and m_axis_tready_i = '1'
          then
            tlast_r    <= '0';
            dump_ack_r <= '1';
            state_r    <= ACK;
          end if;

        when ACK =>
          -- End of the handshake
          if dump_req_sync = '0'
          then
            dump_ack_r <= '0';
            state_r    <= IDLE;
          end if;
      end case;
    end if;
  end process;

  -----------------------------------------------------------------------------
  -- Outputs
  -----------------------------------------------------------------------------
  dump_ack_o           <= dump_ack_r;

  ram_re_o             <= re;
  ram_raddr_o          <= std_logic_vector(raddr_r);

  m_axis_tdata_o       <= std_logic_vector(resize(unsigned(ram_rdata_i), TDATA_WIDTH));
  m_axis_tvalid_o      <= tvalid_r;
  m_axis_tlast_o       <= tlast_r;

end architecture rtl;
