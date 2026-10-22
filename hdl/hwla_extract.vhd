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
-- master interface, one sample in NB_BEAT beats of TDATA_WIDTH bits :
-- * IDLE : wait for a capture (dump_req_i synchronized with sync2dffrn), then
--          start the read at dump_addr_i, the address of the oldest sample
--          (quasi-static : stable while dump_req_i = 1).
--   DUMP : read the DEPTH samples of the capture, from the oldest to the
--          newest (the read address wraps around the RAM). tlast is set with
--          the last beat of the last sample.
--   ACK  : the last beat is accepted, dump_ack_o = 1 until dump_req_i falls,
--          then IDLE.
-- * Beats : the sample, padded with 0 to NB_BEAT*TDATA_WIDTH bits, is sent
--   from the LSB to the MSB, TDATA_WIDTH bits per beat. TDATA_WIDTH = 0 :
--   one beat per sample, tdata is the sample padded with 0 to an integer
--   number of bytes (hwla_tdata_width, hwla_nb_beat).
-- * The RAM output register holds the sample : the next sample is read when
--   there is no beat or when the last beat of the sample is accepted in the
--   same clock cycle, so tdata is held while tvalid = 1 and tready = 0, and
--   the throughput is one beat per clock cycle while tready = 1.
-------------------------------------------------------------------------------
-- Copyright (c) 2026
-------------------------------------------------------------------------------
-- Revisions  :
-- Date        Version  Author   Description
-- 2026-10-22  1.0      mrosiere Created
-- 2026-10-22  2.0      mrosiere SAMPLE_WIDTH, sample sent in several beats
--                               (TDATA_WIDTH)
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
end entity hwla_extract;

architecture rtl of hwla_extract is

  constant ADDR_WIDTH             : natural  := log2(DEPTH);
  constant BEAT_WIDTH             : positive := hwla_tdata_width(SAMPLE_WIDTH, TDATA_WIDTH);
  constant NB_BEAT                : positive := hwla_nb_beat    (SAMPLE_WIDTH, TDATA_WIDTH);

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

  -- AXI-Stream beats
  signal   sample                 : std_logic_vector(NB_BEAT*BEAT_WIDTH-1 downto 0);
  signal   beat_r                 : natural range 0 to NB_BEAT-1;           -- Beat of the sample on tdata
  signal   last_beat              : std_logic;
  signal   accept                 : std_logic;
  signal   tvalid_r               : std_logic;
  signal   tlast_r                : std_logic;                              -- The sample is the last one of the capture

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
  -- Beat accepted, last beat of the sample
  accept               <= tvalid_r and m_axis_tready_i;
  last_beat            <= '1' when beat_r = NB_BEAT-1 else
                          '0';

  -- Beat counter : next beat of the sample when a beat is accepted, back to
  -- the first beat after the last one
  gen_beat_cnt : if NB_BEAT > 1
  generate
    process(clk_i,arst_b_i)
    begin
      if arst_b_i = '0'
      then
        beat_r <= 0;
      elsif rising_edge(clk_i)
      then
        if accept = '1'
        then
          if last_beat = '1'
          then
            beat_r <= 0;
          else
            beat_r <= beat_r + 1;
          end if;
        end if;
      end if;
    end process;
  end generate gen_beat_cnt;

  gen_one_beat : if NB_BEAT = 1
  generate
    beat_r <= 0;
  end generate gen_one_beat;

  -- Read the next sample when there is no beat or when the last beat of the
  -- sample is accepted in this cycle
  re                   <= '1' when state_r   = DUMP and
                                   rd_done_r = '0'  and
                                   (tvalid_r = '0' or (accept = '1' and last_beat = '1')) else
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
      -- Last beat of the sample accepted (a new sample read below sets
      -- tvalid again)
      if accept = '1' and last_beat = '1'
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

          -- Last beat of the last sample accepted : end of the extraction
          if accept = '1' and last_beat = '1' and tlast_r = '1'
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

  -- Beat beat_r of the sample, from the LSB
  sample               <= std_logic_vector(resize(unsigned(ram_rdata_i), NB_BEAT*BEAT_WIDTH));

  process(sample, beat_r)
  begin
    m_axis_tdata_o <= sample(BEAT_WIDTH-1 downto 0);

    for i in 1 to NB_BEAT-1 loop
      if beat_r = i
      then
        m_axis_tdata_o <= sample((i+1)*BEAT_WIDTH-1 downto i*BEAT_WIDTH);
      end if;
    end loop;
  end process;

  m_axis_tvalid_o      <= tvalid_r;
  m_axis_tlast_o       <= tlast_r and last_beat;

end architecture rtl;
