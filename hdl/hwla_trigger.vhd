-------------------------------------------------------------------------------
-- Title      : hwla_trigger
-- Project    : Asylum
-------------------------------------------------------------------------------
-- File       : hwla_trigger.vhd
-- Author     : Mathieu Rosiere
-- Company    :
-- Created    : 2026-10-22
-- Last update: 2026-10-22
-- Platform   :
-- Standard   : VHDL'93/02
-------------------------------------------------------------------------------
-- Description:
-- Trigger part of the HWLA, in the trigger clock domain (clk_i). Records the
-- probes in the RAM of the HWLA, around the trigger :
-- * Input stage : probe_i and trigger_i are registered together, so a sample
--   is the value of the probes and of the trigger at a rising edge of clk_i.
-- * Timestamp (TIMESTAMP_WIDTH > 0) : number of clock cycles since the reset,
--   modulo 2**TIMESTAMP_WIDTH (the sample of the first rising edge after the
--   reset has the timestamp 0). A stored sample is the timestamp (MSB) and
--   the probes (LSB).
-- * Stored samples : with CHANGE_ONLY = false, every sample. With
--   CHANGE_ONLY = true, a sample is stored only :
--   - if the probes are different from the last stored sample,
--   - for the first sample of a capture,
--   - for the trigger sample,
--   - when the timestamp is 0 : at least one stored sample every
--     2**TIMESTAMP_WIDTH clock cycles, so the number of clock cycles between
--     two stored samples is given by their timestamps.
-- * A capture is DEPTH consecutive stored samples : PRE_TRIGGER samples, the
--   trigger sample, then POST_TRIGGER = DEPTH-1-PRE_TRIGGER samples.
-- * IDLE     : nothing is recorded, a capture starts when arm_i = 1. The
--              first sample of the capture is the sample of this clock cycle.
--   FILL     : store the PRE_TRIGGER first samples, the trigger is ignored
--              (skipped when PRE_TRIGGER = 0).
--   ARMED    : store the samples (circular buffer) and wait for the trigger :
--              the first sample with trigger = 1 is the trigger sample.
--   POST     : store the POST_TRIGGER samples after the trigger sample
--              (skipped when POST_TRIGGER = 0).
--   DUMP     : capture done, dump_req_o = 1 until the extraction domain has
--              read the whole capture (dump_ack_i = 1).
--   DUMP_END : wait for the end of the handshake (dump_ack_i = 0), then IDLE.
--   arm_i is only used in IDLE, the trigger only in ARMED.
-- * The write address wraps around the RAM : at the end of a capture, it is
--   the address of the oldest sample of the capture (dump_addr_o), stable
--   while dump_req_o = 1.
-- * Handshake with the extraction domain (4 phases, req/ack) : dump_req_o is
--   a register, dump_ack_i is synchronized with sync2dffrn. dump_addr_o is
--   quasi-static : it is stable from the rise of dump_req_o to the fall of
--   dump_ack_i.
-------------------------------------------------------------------------------
-- Copyright (c) 2026
-------------------------------------------------------------------------------
-- Revisions  :
-- Date        Version  Author   Description
-- 2026-10-22  1.0      mrosiere Created
-- 2026-10-22  2.0      mrosiere Timestamp (TIMESTAMP_WIDTH), store only the
--                               changes (CHANGE_ONLY)
-------------------------------------------------------------------------------

library IEEE;
use     IEEE.STD_LOGIC_1164.ALL;
use     IEEE.NUMERIC_STD.ALL;

library asylum;
use     asylum.math_pkg.ALL;
use     asylum.techmap_pkg.ALL;

entity hwla_trigger is
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
end entity hwla_trigger;

architecture rtl of hwla_trigger is

  constant ADDR_WIDTH             : natural := log2(DEPTH);
  constant POST_TRIGGER           : integer := DEPTH-1-PRE_TRIGGER; -- Number of samples after the trigger sample

  type     state_t is (IDLE, FILL, ARMED, POST, DUMP, DUMP_END);
  signal   state_r                : state_t;

  -- Input stage
  signal   probe_r                : std_logic_vector(NB_PROBE-1 downto 0);
  signal   trigger_r              : std_logic;

  -- Timestamp
  signal   timestamp_r            : unsigned(TIMESTAMP_WIDTH-1 downto 0);
  signal   timestamp_zero         : std_logic;

  -- Recording
  signal   record_en              : std_logic;
  signal   change                 : std_logic;
  signal   trigger_sample         : std_logic;
  signal   first_r                : std_logic;  -- The next stored sample is the first one of the capture
  signal   last_probe_r           : std_logic_vector(NB_PROBE-1 downto 0); -- Probes of the last stored sample
  signal   we                     : std_logic;
  signal   waddr_r                : unsigned(ADDR_WIDTH-1 downto 0);
  signal   cnt_r                  : unsigned(ADDR_WIDTH-1 downto 0);

  -- Handshake
  signal   dump_req_r             : std_logic;
  signal   dump_ack_sync          : std_logic;

begin  -- architecture rtl

  -----------------------------------------------------------------------------
  -- Input stage
  -----------------------------------------------------------------------------
  -- The probes and the trigger have the same latency : the trigger flag of a
  -- sample is always the one of its probes
  process(clk_i,arst_b_i)
  begin
    if arst_b_i = '0'
    then
      probe_r   <= (others => '0');
      trigger_r <= '0';
    elsif rising_edge(clk_i)
    then
      probe_r   <= probe_i;
      trigger_r <= trigger_i;
    end if;
  end process;

  -----------------------------------------------------------------------------
  -- Timestamp
  -----------------------------------------------------------------------------
  gen_timestamp : if TIMESTAMP_WIDTH > 0
  generate
    -- Timestamp of the sample of the input stage : reset to -1, so the sample
    -- of the first rising edge after the reset has the timestamp 0
    process(clk_i,arst_b_i)
    begin
      if arst_b_i = '0'
      then
        timestamp_r <= (others => '1');
      elsif rising_edge(clk_i)
      then
        timestamp_r <= timestamp_r + 1;
      end if;
    end process;

    timestamp_zero <= '1' when timestamp_r = 0 else
                      '0';
  end generate gen_timestamp;

  gen_no_timestamp : if TIMESTAMP_WIDTH = 0
  generate
    timestamp_zero <= '0';
  end generate gen_no_timestamp;

  -----------------------------------------------------------------------------
  -- Synchronization of the acknowledge from the extraction domain
  -----------------------------------------------------------------------------
  ins_dump_ack_sync : sync2dffrn
    port map
    ( clk_i    => clk_i
     ,arst_b_i => arst_b_i
     ,d_i      => dump_ack_i
     ,q_o      => dump_ack_sync
    );

  -----------------------------------------------------------------------------
  -- Capture FSM
  -----------------------------------------------------------------------------
  -- The samples are recorded in FILL, ARMED and POST
  record_en            <= '1' when state_r = FILL  or
                                   state_r = ARMED or
                                   state_r = POST  else
                          '0';

  -- Sample to store : every sample (CHANGE_ONLY = false), the first one of
  -- the capture, a change of the probes, timestamp 0
  change               <= '1' when (not CHANGE_ONLY)          or
                                   first_r        = '1'       or
                                   probe_r       /= last_probe_r or
                                   timestamp_zero = '1'       else
                          '0';

  -- The trigger sample is always stored
  trigger_sample       <= '1' when state_r = ARMED and trigger_r = '1' else
                          '0';

  -- The sample of the input stage is written in the RAM
  we                   <= record_en and (change or trigger_sample);

  process(clk_i,arst_b_i)
  begin
    if arst_b_i = '0'
    then
      state_r      <= IDLE;
      waddr_r      <= (others => '0');
      cnt_r        <= (others => '0');
      first_r      <= '0';
      last_probe_r <= (others => '0');
      dump_req_r   <= '0';
    elsif rising_edge(clk_i)
    then
      -- Write address : next address after each stored sample, wraps around
      -- the RAM (DEPTH is a power of 2)
      if we = '1'
      then
        waddr_r      <= waddr_r + 1;
        first_r      <= '0';
        last_probe_r <= probe_r;
      end if;

      case state_r is
        when IDLE =>
          cnt_r <= (others => '0');

          -- Start a capture : the sample of this clock cycle (in the input
          -- stage at the next clock cycle) is the first one
          if arm_i = '1'
          then
            first_r <= '1';

            if PRE_TRIGGER = 0
            then
              state_r <= ARMED;
            else
              state_r <= FILL;
            end if;
          end if;

        when FILL =>
          if we = '1'
          then
            cnt_r <= cnt_r + 1;

            -- Last pre-trigger sample : the next one can be the trigger sample
            if to_integer(cnt_r) = PRE_TRIGGER-1
            then
              cnt_r   <= (others => '0');
              state_r <= ARMED;
            end if;
          end if;

        when ARMED =>
          -- The sample written in this clock cycle is the trigger sample.
          -- The PRE_TRIGGER previous stored samples are still in the RAM.
          if trigger_sample = '1'
          then
            if POST_TRIGGER = 0
            then
              dump_req_r <= '1';
              state_r    <= DUMP;
            else
              state_r    <= POST;
            end if;
          end if;

        when POST =>
          if we = '1'
          then
            cnt_r <= cnt_r + 1;

            -- Last post-trigger sample : end of the capture
            if to_integer(cnt_r) = POST_TRIGGER-1
            then
              dump_req_r <= '1';
              state_r    <= DUMP;
            end if;
          end if;

        when DUMP =>
          -- The whole capture is extracted
          if dump_ack_sync = '1'
          then
            dump_req_r <= '0';
            state_r    <= DUMP_END;
          end if;

        when DUMP_END =>
          -- End of the handshake : a new request can be sent
          if dump_ack_sync = '0'
          then
            state_r    <= IDLE;
          end if;
      end case;
    end if;
  end process;

  -----------------------------------------------------------------------------
  -- Outputs
  -----------------------------------------------------------------------------
  ram_we_o             <= we;
  ram_waddr_o          <= std_logic_vector(waddr_r);
  ram_wdata_o          <= std_logic_vector(timestamp_r) & probe_r;

  -- After the last sample of the capture, the write address is the address of
  -- the oldest sample. It does not change until the next capture.
  dump_req_o           <= dump_req_r;
  dump_addr_o          <= std_logic_vector(waddr_r);

  armed_o              <= '1' when state_r = FILL  or
                                   state_r = ARMED else
                          '0';
  triggered_o          <= '1' when state_r = POST  or
                                   state_r = DUMP  or
                                   state_r = DUMP_END else
                          '0';

-- pragma translate_off
  assert PRE_TRIGGER <= DEPTH-1
    report "hwla_trigger : PRE_TRIGGER (" & integer'image(PRE_TRIGGER) & ") must be lower than DEPTH (" & integer'image(DEPTH) & ")"
    severity failure;
-- pragma translate_on

end architecture rtl;
