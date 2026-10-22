-------------------------------------------------------------------------------
-- Title      : tb_hwla
-- Project    : HWLA
-------------------------------------------------------------------------------
-- File       : tb_hwla.vhd
-- Author     : mrosiere
-------------------------------------------------------------------------------
-- Description: UVVM self-checking testbench of the HWLA, two asynchronous
--              clocks (periods given by generics). The captures are received
--              with the UVVM AXI-Stream BFM and checked sample by sample.
--              * Probes  : 4 modes. COUNT : the probes are the sample number
--                (inverted copies above bit 30), a new value at each sample.
--                SPARSE : a new value (the sample number) with a probability
--                of 1/4. FROZEN : no change. FORCE : a given value.
--              * Trigger : driven from a schedule of pulses (sample numbers).
--              * History : the probes and the trigger of each sample, as
--                sampled by the dut.
--              * Model   : from the history, the samples stored by a capture
--                (CHANGE_ONLY, timestamp 0, trigger sample, pre / post
--                trigger samples) and its trigger sample. Each received
--                sample is checked against the timestamp and the probes of
--                the expected sample.
--              * Monitors : first sample of each capture (rise of armed_o),
--                AXI-Stream protocol (tvalid, tdata, tlast held while
--                tready = 0, tlast only with tvalid, DEPTH*NB_BEAT beats per
--                capture).
--              Tests : reset values, trigger ignored while not armed, single
--              capture, triggers ignored during the pre-trigger samples,
--              level trigger already high at the arm, trigger after several
--              turns of the circular buffer, random back pressure, long
--              stall with arm_i and trigger ignored during the extraction,
--              continuous captures (arm_i held high), sparse probes, frozen
--              probes (timestamp wrap), first sample of a capture equal to
--              the last stored sample, asynchronous reset during an
--              extraction.
-------------------------------------------------------------------------------
-- Revisions  :
-- Date        Version  Author   Description
-- 2026-10-22  1.0      mrosiere Created
-- 2026-10-22  2.0      mrosiere Timestamp, CHANGE_ONLY, TDATA_WIDTH : history
--                               and model of the stored samples, sparse and
--                               frozen probes
-------------------------------------------------------------------------------

library ieee;
use     ieee.std_logic_1164.all;
use     ieee.numeric_std.all;
use     ieee.math_real.all;

library uvvm_util;
context uvvm_util.uvvm_util_context;

library bitvis_vip_axistream;
use     bitvis_vip_axistream.axistream_bfm_pkg.all;

library asylum;
use     asylum.hwla_pkg.all;

entity tb_hwla is
  generic (
    NB_PROBE           : positive := 12;   -- Number of probes
    DEPTH              : positive := 32;   -- Number of stored samples of a capture (power of 2)
    PRE_TRIGGER        : natural  := 10;   -- Number of stored samples before the trigger sample
    TIMESTAMP_WIDTH    : natural  := 16;   -- Width of the timestamp (0 : no timestamp)
    CHANGE_ONLY        : boolean  := true; -- true : store a sample only if the probes changed
    TDATA_WIDTH        : natural  := 0;    -- Width of tdata, 0 : one beat per sample
    TRIG_CLK_PERIOD    : positive := 10;   -- Period of the trigger clock (ns, even : integer half period for the UVVM logs)
    EXTRACT_CLK_PERIOD : positive := 18    -- Period of the extraction clock (ns, even)
    );
end tb_hwla;

architecture sim of tb_hwla is

  constant C_SCOPE            : string   := "TB_HWLA";
  constant C_TRIG_PERIOD      : time     := TRIG_CLK_PERIOD    * 1 ns;
  constant C_EXTRACT_PERIOD   : time     := EXTRACT_CLK_PERIOD * 1 ns;
  constant C_SAMPLE_WIDTH     : positive := hwla_sample_width(NB_PROBE, TIMESTAMP_WIDTH);
  constant C_TDATA_WIDTH      : positive := hwla_tdata_width (C_SAMPLE_WIDTH, TDATA_WIDTH);
  constant C_NB_BEAT          : positive := hwla_nb_beat     (C_SAMPLE_WIDTH, TDATA_WIDTH);
  constant C_SAMPLE_BYTES     : positive := C_NB_BEAT*C_TDATA_WIDTH/8;  -- Bytes of a sample on the AXI-Stream
  constant C_POST_TRIGGER     : natural  := DEPTH-1-PRE_TRIGGER;

  -- Frozen probes test : a stored sample every 2**TIMESTAMP_WIDTH samples
  -- (CHANGE_ONLY), run if this is short enough
  constant C_FROZEN_TEST      : boolean  := (not CHANGE_ONLY) or (TIMESTAMP_WIDTH > 0 and TIMESTAMP_WIDTH <= 6);
  constant C_FROZEN_PERIOD    : positive := 2**minimum(TIMESTAMP_WIDTH, 6);

  -- Timeouts : a capture (with several turns of the circular buffer, or
  -- frozen probes) and its extraction, in time and in clock cycles of the
  -- extraction domain
  constant C_TIMEOUT          : time     := (8*DEPTH*C_FROZEN_PERIOD + 100) * (C_TRIG_PERIOD + C_EXTRACT_PERIOD);
  constant C_MAX_WAIT_CYCLES  : positive := 8*DEPTH*C_FROZEN_PERIOD*(TRIG_CLK_PERIOD/EXTRACT_CLK_PERIOD + 1) + 100;

  -- Continuous captures (COUNT probes) : number of samples between two
  -- trigger pulses, more than a capture, its extraction and the handshake
  constant C_GAP              : positive := 4*DEPTH + 2*DEPTH*C_NB_BEAT*(EXTRACT_CLK_PERIOD/TRIG_CLK_PERIOD + 1) + 64;

  -- History : last C_HISTORY samples
  constant C_HISTORY          : positive := 2**16;

  type     natural_array_t is array (natural range <>) of natural;

  -- Schedule of the trigger : trigger_i = 1 for the samples start to
  -- start+length-1 of each pulse (length = 0 : no pulse)
  type     pulse_t is record
    start  : natural;
    length : natural;
  end record pulse_t;
  type     pulse_array_t is array (0 to 7) of pulse_t;
  constant C_NO_PULSE         : pulse_array_t := (others => (0, 0));

  -- Mode of the probes
  type     probe_mode_t is (MODE_COUNT, MODE_SPARSE, MODE_FROZEN, MODE_FORCE);

  -- Trigger value of the sample number sample
  function is_trigger (p : pulse_array_t; sample : natural) return std_logic is
  begin
    for i in p'range loop
      if sample >= p(i).start and sample < p(i).start + p(i).length
      then
        return '1';
      end if;
    end loop;
    return '0';
  end function;

  -- First trigger sample from the sample number from_sample, -1 if none
  function first_trigger (p : pulse_array_t; from_sample : natural) return integer is
    variable v_first : integer := -1;
    variable v_cand  : natural;
  begin
    for i in p'range loop
      if p(i).length > 0 and p(i).start + p(i).length > from_sample
      then
        if p(i).start > from_sample
        then
          v_cand := p(i).start;
        else
          v_cand := from_sample;
        end if;

        if v_first < 0 or v_cand < v_first
        then
          v_first := v_cand;
        end if;
      end if;
    end loop;
    return v_first;
  end function;

  -- New value of the probes at the sample number sample : the sample number
  -- on the bits 0 to 30, inverted on the bits 31 to 61, ...
  function probe_value (sample : natural) return std_logic_vector is
    variable v_cnt   : unsigned(30 downto 0) := to_unsigned(sample, 31);
    variable v_probe : std_logic_vector(NB_PROBE-1 downto 0);
  begin
    for i in 0 to NB_PROBE-1 loop
      if (i/31) mod 2 = 0
      then
        v_probe(i) := v_cnt(i mod 31);
      else
        v_probe(i) := not v_cnt(i mod 31);
      end if;
    end loop;
    return v_probe;
  end function;

  -- History of the samples
  type t_history is protected
    procedure set (sample : natural; probe : std_logic_vector; trigger : std_logic);
    impure function get_probe   (sample : natural) return std_logic_vector;
    impure function get_trigger (sample : natural) return std_logic;
  end protected t_history;

  type t_history is protected body
    type     probe_array_t is array (0 to C_HISTORY-1) of std_logic_vector(NB_PROBE-1 downto 0);
    variable v_probe   : probe_array_t;
    variable v_trigger : std_logic_vector(0 to C_HISTORY-1);

    procedure set (sample : natural; probe : std_logic_vector; trigger : std_logic) is
    begin
      v_probe  (sample mod C_HISTORY) := probe;
      v_trigger(sample mod C_HISTORY) := trigger;
    end procedure;

    impure function get_probe   (sample : natural) return std_logic_vector is
    begin
      return v_probe(sample mod C_HISTORY);
    end function;

    impure function get_trigger (sample : natural) return std_logic is
    begin
      return v_trigger(sample mod C_HISTORY);
    end function;
  end protected body t_history;

  shared variable history     : t_history;

  -- Clocks & Resets
  signal   trig_clk_i         : std_logic := '0';
  signal   trig_clk_ena       : boolean   := true;
  signal   trig_arst_b_i      : std_logic := '0';
  signal   extract_clk_i      : std_logic := '0';
  signal   extract_clk_ena    : boolean   := true;
  signal   extract_arst_b_i   : std_logic := '0';

  -- dut : trigger domain
  signal   arm_i              : std_logic := '0';
  signal   trigger_i          : std_logic;
  signal   probe_i            : std_logic_vector(NB_PROBE-1 downto 0) := probe_value(0);
  signal   armed_o            : std_logic;
  signal   triggered_o        : std_logic;

  -- dut : extraction domain
  signal   m_axis_tdata_o     : std_logic_vector(C_TDATA_WIDTH-1 downto 0);
  signal   m_axis_tvalid_o    : std_logic;
  signal   m_axis_tready_i    : std_logic;
  signal   m_axis_tlast_o     : std_logic;
  signal   axis_if            : t_axistream_if(tdata(C_TDATA_WIDTH  -1 downto 0),
                                               tkeep(C_TDATA_WIDTH/8-1 downto 0),
                                               tuser(0 downto 0),
                                               tstrb(C_TDATA_WIDTH/8-1 downto 0),
                                               tid  (0 downto 0),
                                               tdest(0 downto 0));

  -- Stimuli of the trigger domain
  signal   probe_cnt          : natural := 0;            -- Number of the sample on probe_i (sampled at the next rising edge of trig_clk_i)
  signal   probe_mode         : probe_mode_t := MODE_COUNT;
  signal   probe_force        : std_logic_vector(NB_PROBE-1 downto 0) := (others => '0'); -- Probes of the FORCE mode
  signal   pulses             : pulse_array_t := C_NO_PULSE;
  signal   ts_origin          : natural := 0;            -- Sample with the timestamp 0 : first rising edge after the reset

  -- Capture monitor
  signal   nb_arm             : natural := 0;            -- Number of captures started
  signal   arm_sample         : natural := 0;            -- First sample of the last capture started

begin

  clock_generator(trig_clk_i   , trig_clk_ena   , C_TRIG_PERIOD   , "Trigger clock");
  clock_generator(extract_clk_i, extract_clk_ena, C_EXTRACT_PERIOD, "Extraction clock");

  -----------------------------------------------------------------------------
  -- dut
  -----------------------------------------------------------------------------
  dut : hwla
    generic map (
      NB_PROBE         => NB_PROBE
     ,DEPTH            => DEPTH
     ,PRE_TRIGGER      => PRE_TRIGGER
     ,TIMESTAMP_WIDTH  => TIMESTAMP_WIDTH
     ,CHANGE_ONLY      => CHANGE_ONLY
     ,TDATA_WIDTH      => TDATA_WIDTH
    )
    port map (
      trig_clk_i       => trig_clk_i
     ,trig_arst_b_i    => trig_arst_b_i
     ,arm_i            => arm_i
     ,trigger_i        => trigger_i
     ,probe_i          => probe_i
     ,armed_o          => armed_o
     ,triggered_o      => triggered_o
     ,extract_clk_i    => extract_clk_i
     ,extract_arst_b_i => extract_arst_b_i
     ,m_axis_tdata_o   => m_axis_tdata_o
     ,m_axis_tvalid_o  => m_axis_tvalid_o
     ,m_axis_tready_i  => m_axis_tready_i
     ,m_axis_tlast_o   => m_axis_tlast_o
    );

  -- AXI-Stream BFM : the dut has no tkeep, tstrb, tuser, tid, tdest
  axis_if.tdata         <= m_axis_tdata_o;
  axis_if.tvalid        <= m_axis_tvalid_o;
  axis_if.tlast         <= m_axis_tlast_o;
  axis_if.tkeep         <= (others => '1');
  axis_if.tstrb         <= (others => '1');
  axis_if.tuser         <= (others => '0');
  axis_if.tid           <= (others => '0');
  axis_if.tdest         <= (others => '0');
  m_axis_tready_i       <= axis_if.tready;

  -----------------------------------------------------------------------------
  -- Stimuli of the trigger domain
  -----------------------------------------------------------------------------
  -- A new sample at each rising edge of trig_clk_i
  p_probe : process
    variable v_seed1 : positive := 7;
    variable v_seed2 : positive := 11;
    variable v_rand  : real;
  begin
    wait until rising_edge(trig_clk_i);

    -- Sample of this rising edge
    history.set(probe_cnt, probe_i, trigger_i);
    probe_cnt <= probe_cnt + 1;

    -- Probes of the next sample
    uniform(v_seed1, v_seed2, v_rand);
    case probe_mode is
      when MODE_COUNT  =>
        probe_i <= probe_value(probe_cnt + 1);
      when MODE_SPARSE =>
        if v_rand < 0.25
        then
          probe_i <= probe_value(probe_cnt + 1);
        end if;
      when MODE_FROZEN =>
        null;
      when MODE_FORCE  =>
        probe_i <= probe_force;
    end case;
  end process p_probe;

  trigger_i             <= is_trigger(pulses, probe_cnt);

  -----------------------------------------------------------------------------
  -- Capture monitor
  -----------------------------------------------------------------------------
  -- armed_o rises just after the rising edge that sampled arm_i = 1, the
  -- sample of this rising edge is the first one of the capture
  p_arm_monitor : process
  begin
    wait until rising_edge(armed_o);
    arm_sample <= probe_cnt - 1;
    nb_arm     <= nb_arm + 1;
  end process p_arm_monitor;

  -----------------------------------------------------------------------------
  -- AXI-Stream protocol monitor
  -----------------------------------------------------------------------------
  -- Signals sampled at the rising edge of extract_clk_i
  p_axis_monitor : process
    variable v_stall  : boolean := false;
    variable v_tdata  : std_logic_vector(C_TDATA_WIDTH-1 downto 0);
    variable v_tlast  : std_logic;
    variable v_beats  : natural := 0;
  begin
    wait until rising_edge(extract_clk_i);

    if extract_arst_b_i = '0'
    then
      v_stall := false;
      v_beats := 0;
    else
      -- A beat not accepted at the previous rising edge is held
      if v_stall
      then
        check_value(m_axis_tvalid_o, '1'    , ERROR, "AXI-Stream : tvalid held until tready", C_SCOPE, ID_NEVER);
        check_value(m_axis_tdata_o , v_tdata, ERROR, "AXI-Stream : tdata held until tready" , C_SCOPE, HEX, KEEP_LEADING_0, ID_NEVER);
        check_value(m_axis_tlast_o , v_tlast, ERROR, "AXI-Stream : tlast held until tready" , C_SCOPE, ID_NEVER);
      end if;

      if m_axis_tvalid_o = '0'
      then
        check_value(m_axis_tlast_o , '0'    , ERROR, "AXI-Stream : tlast only with tvalid"  , C_SCOPE, ID_NEVER);
      end if;

      -- Accepted beat : a capture is DEPTH samples of NB_BEAT beats
      if m_axis_tvalid_o = '1' and m_axis_tready_i = '1'
      then
        v_beats := v_beats + 1;
        if m_axis_tlast_o = '1'
        then
          check_value(v_beats, DEPTH*C_NB_BEAT, ERROR, "AXI-Stream : DEPTH*NB_BEAT beats in a capture", C_SCOPE);
          v_beats := 0;
        end if;
      end if;

      v_stall := m_axis_tvalid_o = '1' and m_axis_tready_i = '0';
      v_tdata := m_axis_tdata_o;
      v_tlast := m_axis_tlast_o;
    end if;
  end process p_axis_monitor;

  -----------------------------------------------------------------------------
  -- Sequencer
  -----------------------------------------------------------------------------
  p_main : process
    variable v_axis_config : t_axistream_bfm_config := C_AXISTREAM_BFM_CONFIG_DEFAULT;
    variable v_first       : natural;   -- First sample of a capture
    variable v_trigger     : natural;   -- Trigger sample of a capture (seen by the dut)
    variable v_nb_arm      : natural;
    variable v_pulses      : pulse_array_t;
    variable v_last_probe  : std_logic_vector(NB_PROBE-1 downto 0); -- Probes of the last stored sample of the last capture

    -- Timestamp of the sample number sample
    impure function timestamp(sample : natural) return std_logic_vector is
    begin
      return std_logic_vector(resize(to_unsigned(sample - ts_origin, 31), TIMESTAMP_WIDTH));
    end function;

    -- Model of a capture started at the sample first : the stored samples
    -- (sample numbers, from the oldest) and the trigger sample
    procedure model_capture(first       : natural;
                            variable samples : out natural_array_t;
                            variable trigger : out natural;
                            msg         : string) is
      type     phase_t is (P_FILL, P_ARMED, P_POST, P_DONE);
      variable v_ring  : natural_array_t(0 to DEPTH-1) := (others => 0);
      variable v_nb    : natural := 0;    -- Number of stored samples
      variable v_cnt   : natural := 0;    -- Number of stored samples in the phase
      variable v_phase : phase_t;
      variable v_n     : natural := first;
      variable v_probe : std_logic_vector(NB_PROBE-1 downto 0);
      variable v_last  : std_logic_vector(NB_PROBE-1 downto 0) := (others => '0');
      variable v_trig  : boolean;
      variable v_store : boolean;
    begin
      trigger := first;
      if PRE_TRIGGER = 0
      then
        v_phase := P_ARMED;
      else
        v_phase := P_FILL;
      end if;

      while v_phase /= P_DONE loop
        if v_n >= probe_cnt
        then
          alert(TB_ERROR, msg & " : model, sample " & to_string(v_n) & " not yet in the history", C_SCOPE);
          exit;
        end if;

        -- Stored sample : every sample (CHANGE_ONLY = false), the first one,
        -- a change of the probes, the timestamp 0, the trigger sample
        v_probe := history.get_probe(v_n);
        v_trig  := v_phase = P_ARMED and history.get_trigger(v_n) = '1';
        v_store := (not CHANGE_ONLY) or v_nb = 0 or v_probe /= v_last or v_trig or
                   (TIMESTAMP_WIDTH > 0 and unsigned(timestamp(v_n)) = 0);

        if v_store
        then
          v_ring(v_nb mod DEPTH) := v_n;
          v_nb    := v_nb  + 1;
          v_cnt   := v_cnt + 1;
          v_last  := v_probe;
        end if;

        case v_phase is
          when P_FILL  =>
            if v_cnt = PRE_TRIGGER
            then
              v_cnt   := 0;
              v_phase := P_ARMED;
            end if;
          when P_ARMED =>
            if v_trig
            then
              trigger := v_n;
              v_cnt   := 0;
              if C_POST_TRIGGER = 0
              then
                v_phase := P_DONE;
              else
                v_phase := P_POST;
              end if;
            end if;
          when P_POST  =>
            if v_cnt = C_POST_TRIGGER
            then
              v_phase := P_DONE;
            end if;
          when P_DONE  =>
            null;
        end case;

        v_n := v_n + 1;
      end loop;

      -- The DEPTH last stored samples, from the oldest
      for k in 0 to DEPTH-1 loop
        samples(k) := v_ring((v_nb + k) mod DEPTH);
      end loop;
    end procedure;

    -- Start a capture with a pulse of one clock cycle on arm_i, first is the
    -- number of the sample presented with arm_i = 1 : the first sample of
    -- the capture
    procedure arm_capture(variable first : out natural; msg : string) is
      variable v_nb     : natural;
      variable v_sample : natural;
    begin
      wait until falling_edge(trig_clk_i);
      v_nb     := nb_arm;
      v_sample := probe_cnt;
      arm_i    <= '1';
      wait until falling_edge(trig_clk_i);
      arm_i    <= '0';
      check_value(nb_arm    , v_nb+1  , ERROR, msg & " : capture started (rise of armed_o)", C_SCOPE);
      check_value(arm_sample, v_sample, ERROR, msg & " : first sample of the capture is the sample with arm_i = 1", C_SCOPE);
      first    := v_sample;
    end procedure;

    -- Wait for the trigger of the capture : triggered_o rises one clock cycle
    -- after the rising edge that sampled the trigger sample, so trigger is
    -- the sample before the previous one
    procedure wait_trigger(variable trigger : out natural; msg : string) is
    begin
      await_value(triggered_o, '1', 0 ns, C_TIMEOUT, ERROR, msg & " : triggered_o set", C_SCOPE);
      check_value(armed_o, '0', ERROR, msg & " : armed_o cleared by the trigger", C_SCOPE);
      trigger := probe_cnt - 2;
    end procedure;

    -- Receive a capture started at the sample first on the AXI-Stream, check
    -- its trigger and its DEPTH stored samples against the model
    procedure receive_capture(first : natural; trigger : natural; msg : string) is
      variable v_bytes   : t_slv_array (0 to DEPTH*C_SAMPLE_BYTES-1)(7 downto 0);
      variable v_len     : natural;
      variable v_user    : t_user_array(0 to 0);
      variable v_strb    : t_strb_array(0 to 0);
      variable v_id      : t_id_array  (0 to 0);
      variable v_dest    : t_dest_array(0 to 0);
      variable v_samples : natural_array_t(0 to DEPTH-1);
      variable v_model   : natural;   -- Trigger sample of the model
      variable v_sample  : std_logic_vector(C_SAMPLE_WIDTH-1 downto 0);
      variable v_word    : std_logic_vector(C_SAMPLE_BYTES*8-1 downto 0);
      variable v_exp     : std_logic_vector(C_SAMPLE_BYTES*8-1 downto 0);
    begin
      axistream_receive(v_bytes, v_len, v_user, v_strb, v_id, v_dest, msg, extract_clk_i, axis_if, C_SCOPE, shared_msg_id_panel, v_axis_config);
      check_value(v_len, DEPTH*C_SAMPLE_BYTES, ERROR, msg & " : DEPTH samples, tlast with the last beat", C_SCOPE);

      model_capture(first, v_samples, v_model, msg);
      check_value(trigger, v_model, ERROR, msg & " : trigger sample (model)", C_SCOPE);
      check_value(v_samples(PRE_TRIGGER), v_model, ERROR, msg & " : trigger sample after PRE_TRIGGER stored samples", C_SCOPE);

      -- A sample : C_SAMPLE_BYTES bytes, from the LSB
      for k in 0 to DEPTH-1 loop
        for b in 0 to C_SAMPLE_BYTES-1 loop
          v_word(8*b+7 downto 8*b) := v_bytes(k*C_SAMPLE_BYTES+b);
        end loop;
        v_sample := timestamp(v_samples(k)) & history.get_probe(v_samples(k));
        v_exp    := std_logic_vector(resize(unsigned(v_sample), C_SAMPLE_BYTES*8));
        check_value(v_word, v_exp, ERROR,
                    msg & " : stored sample " & to_string(k) & " (sample number " & to_string(v_samples(k)) & ")",
                    C_SCOPE, HEX, KEEP_LEADING_0, ID_NEVER);
      end loop;
      v_last_probe := history.get_probe(v_samples(DEPTH-1));
      log(ID_SEQUENCER, msg & " : capture received, " & to_string(DEPTH) & " stored samples from the samples " & to_string(v_samples(0)) &
                        " to " & to_string(v_samples(DEPTH-1)) & ", trigger sample " & to_string(trigger), C_SCOPE);
    end procedure;

    -- Wait for the end of the handshake : the dut can start a new capture
    procedure wait_idle(msg : string) is
    begin
      await_value(triggered_o, '0', 0 ns, C_TIMEOUT, ERROR, msg & " : triggered_o cleared after the extraction", C_SCOPE);
      check_value(armed_o        , '0', ERROR, msg & " : idle, armed_o low"        , C_SCOPE);
      check_value(m_axis_tvalid_o, '0', ERROR, msg & " : idle, m_axis_tvalid_o low", C_SCOPE);
    end procedure;

    -- Pulse of the trigger
    procedure set_pulse(start : natural; length : natural) is
    begin
      v_pulses    := C_NO_PULSE;
      v_pulses(0) := (start, length);
      pulses      <= v_pulses;
    end procedure;

    -- Release the resets, after a falling edge of each clock. The sample of
    -- the next rising edge of trig_clk_i has the timestamp 0
    procedure release_resets is
    begin
      wait until falling_edge(trig_clk_i);
      trig_arst_b_i    <= '1';
      ts_origin        <= probe_cnt;
      wait until falling_edge(extract_clk_i);
      extract_arst_b_i <= '1';
    end procedure;

  begin
    axis_if                           <= init_axistream_if_signals(false, C_TDATA_WIDTH, 1, 1, 1);
    v_axis_config.max_wait_cycles     := C_MAX_WAIT_CYCLES;
    v_axis_config.check_packet_length := true;
    disable_log_msg(ID_PACKET_DATA);  -- One message per byte

    trig_arst_b_i    <= '0';
    extract_arst_b_i <= '0';
    wait for 10*C_TRIG_PERIOD + 10*C_EXTRACT_PERIOD;
    release_resets;

    log(ID_SEQUENCER, "Reset released, starting HWLA basic test : NB_PROBE " & to_string(NB_PROBE) &
                      ", DEPTH " & to_string(DEPTH) & ", PRE_TRIGGER " & to_string(PRE_TRIGGER) &
                      ", TIMESTAMP_WIDTH " & to_string(TIMESTAMP_WIDTH) & ", CHANGE_ONLY " & to_string(CHANGE_ONLY) &
                      ", " & to_string(C_NB_BEAT) & " beat(s) of " & to_string(C_TDATA_WIDTH) & " bits per sample" &
                      ", trigger clock " & to_string(C_TRIG_PERIOD) & ", extraction clock " & to_string(C_EXTRACT_PERIOD), C_SCOPE);

    ------------------------------------------------
    log(ID_LOG_HDR, "1. Reset values", C_SCOPE);
    ------------------------------------------------
    check_value(armed_o        , '0', ERROR, "Reset : armed_o low"        , C_SCOPE);
    check_value(triggered_o    , '0', ERROR, "Reset : triggered_o low"    , C_SCOPE);
    check_value(m_axis_tvalid_o, '0', ERROR, "Reset : m_axis_tvalid_o low", C_SCOPE);
    check_value(m_axis_tlast_o , '0', ERROR, "Reset : m_axis_tlast_o low" , C_SCOPE);

    ------------------------------------------------
    log(ID_LOG_HDR, "2. Not armed : the trigger is ignored", C_SCOPE);
    ------------------------------------------------
    set_pulse(probe_cnt + 4, 3);
    wait for 2*DEPTH*C_TRIG_PERIOD;
    check_stable(armed_o        , 2*DEPTH*C_TRIG_PERIOD, ERROR, "Not armed : armed_o stays low"        , C_SCOPE);
    check_stable(triggered_o    , 2*DEPTH*C_TRIG_PERIOD, ERROR, "Not armed : triggered_o stays low"    , C_SCOPE);
    check_stable(m_axis_tvalid_o, 2*DEPTH*C_TRIG_PERIOD, ERROR, "Not armed : m_axis_tvalid_o stays low", C_SCOPE);
    pulses <= C_NO_PULSE;

    -- Tests 3 to 9 : COUNT probes (a change at each sample, every sample is
    -- stored), the trigger sample is known from the schedule

    ------------------------------------------------
    log(ID_LOG_HDR, "3. Capture, trigger 7 samples after the pre-trigger samples", C_SCOPE);
    ------------------------------------------------
    arm_capture(v_first, "Capture");
    set_pulse(v_first + PRE_TRIGGER + 7, 1);
    wait_trigger   (v_trigger, "Capture");
    check_value    (v_trigger, v_first + PRE_TRIGGER + 7, ERROR, "Capture : trigger sample", C_SCOPE);
    receive_capture(v_first, v_trigger, "Capture");
    wait_idle      ("Capture");

    ------------------------------------------------
    log(ID_LOG_HDR, "4. Triggers during the pre-trigger samples are ignored", C_SCOPE);
    ------------------------------------------------
    if PRE_TRIGGER >= 3
    then
      -- A pulse on the third sample, a pulse on the last pre-trigger sample
      -- and on the first sample after : this one is the trigger sample
      arm_capture(v_first, "Pre-trigger");
      v_pulses    := C_NO_PULSE;
      v_pulses(0) := (v_first + 2              , 1);
      v_pulses(1) := (v_first + PRE_TRIGGER - 1, 2);
      pulses      <= v_pulses;
      wait_trigger   (v_trigger, "Pre-trigger");
      check_value    (v_trigger, v_first + PRE_TRIGGER, ERROR, "Pre-trigger : trigger sample", C_SCOPE);
      receive_capture(v_first, v_trigger, "Pre-trigger");
      wait_idle      ("Pre-trigger");
    else
      log(ID_SEQUENCER, "Pre-trigger : skipped, PRE_TRIGGER lower than 3", C_SCOPE);
    end if;

    ------------------------------------------------
    log(ID_LOG_HDR, "5. Level trigger, already high when the capture starts", C_SCOPE);
    ------------------------------------------------
    -- The trigger sample is the first sample after the pre-trigger samples
    set_pulse(probe_cnt, 4*DEPTH);
    wait for 3*C_TRIG_PERIOD;
    arm_capture(v_first, "Level");
    wait_trigger   (v_trigger, "Level");
    check_value    (v_trigger, v_first + PRE_TRIGGER, ERROR, "Level : trigger sample", C_SCOPE);
    receive_capture(v_first, v_trigger, "Level");
    wait_idle      ("Level");
    pulses    <= C_NO_PULSE;

    ------------------------------------------------
    log(ID_LOG_HDR, "6. Trigger after 3 turns of the circular buffer", C_SCOPE);
    ------------------------------------------------
    arm_capture(v_first, "Late trigger");
    set_pulse(v_first + PRE_TRIGGER + 3*DEPTH + 5, 1);
    wait for 3*DEPTH*C_TRIG_PERIOD;
    check_value(armed_o    , '1', ERROR, "Late trigger : armed_o still high"  , C_SCOPE);
    check_value(triggered_o, '0', ERROR, "Late trigger : triggered_o still low", C_SCOPE);
    wait_trigger   (v_trigger, "Late trigger");
    check_value    (v_trigger, v_first + PRE_TRIGGER + 3*DEPTH + 5, ERROR, "Late trigger : trigger sample", C_SCOPE);
    receive_capture(v_first, v_trigger, "Late trigger");
    wait_idle      ("Late trigger");

    ------------------------------------------------
    log(ID_LOG_HDR, "7. Random back pressure (tready low before random beats)", C_SCOPE);
    ------------------------------------------------
    v_axis_config.ready_low_at_word_num         := C_MULTIPLE_RANDOM;
    v_axis_config.ready_low_multiple_random_prob:= 0.5;
    v_axis_config.ready_low_duration            := C_RANDOM;
    v_axis_config.ready_low_max_random_duration := 5;
    arm_capture(v_first, "Back pressure");
    set_pulse(v_first + PRE_TRIGGER + 3, 1);
    wait_trigger   (v_trigger, "Back pressure");
    check_value    (v_trigger, v_first + PRE_TRIGGER + 3, ERROR, "Back pressure : trigger sample", C_SCOPE);
    receive_capture(v_first, v_trigger, "Back pressure");
    wait_idle      ("Back pressure");
    v_axis_config.ready_low_at_word_num         := 0;
    v_axis_config.ready_low_duration            := 0;

    ------------------------------------------------
    log(ID_LOG_HDR, "8. Long stall : capture held, arm_i and trigger ignored until the end of the extraction", C_SCOPE);
    ------------------------------------------------
    arm_capture(v_first, "Stall");
    set_pulse(v_first + PRE_TRIGGER + 1, 1);
    wait_trigger(v_trigger, "Stall");

    -- First beat presented, tready low : the beat is held
    await_value(m_axis_tvalid_o, '1', 0 ns, C_TIMEOUT, ERROR, "Stall : first beat presented", C_SCOPE);
    wait for 50*C_EXTRACT_PERIOD;
    check_stable(m_axis_tvalid_o, 50*C_EXTRACT_PERIOD, ERROR, "Stall : tvalid held while tready = 0", C_SCOPE);
    check_stable(m_axis_tdata_o , 50*C_EXTRACT_PERIOD, ERROR, "Stall : tdata held while tready = 0" , C_SCOPE);
    check_value (triggered_o    , '1', ERROR, "Stall : triggered_o high until the end of the extraction", C_SCOPE);

    -- A new arm and a new trigger before the end of the extraction
    v_nb_arm  := nb_arm;
    wait until falling_edge(trig_clk_i);
    arm_i     <= '1';
    set_pulse(probe_cnt, 3);
    wait until falling_edge(trig_clk_i);
    arm_i     <= '0';
    wait for 5*C_TRIG_PERIOD;
    check_value(nb_arm, v_nb_arm, ERROR, "Stall : arm_i ignored during the extraction", C_SCOPE);
    pulses    <= C_NO_PULSE;

    receive_capture(v_first, v_trigger, "Stall");
    wait_idle      ("Stall");
    wait for 2*DEPTH*C_TRIG_PERIOD;
    check_value (nb_arm         , v_nb_arm, ERROR, "Stall : no capture after the extraction", C_SCOPE);
    check_stable(m_axis_tvalid_o, 2*DEPTH*C_TRIG_PERIOD, ERROR, "Stall : m_axis_tvalid_o stays low", C_SCOPE);

    ------------------------------------------------
    log(ID_LOG_HDR, "9. Continuous captures : arm_i held high", C_SCOPE);
    ------------------------------------------------
    -- 4 trigger pulses, C_GAP samples apart : a capture per pulse, the next
    -- capture starts at the end of the extraction of the previous one
    wait until falling_edge(trig_clk_i);
    v_nb_arm  := nb_arm;
    v_pulses  := C_NO_PULSE;
    for i in 0 to 3 loop
      v_pulses(i) := (probe_cnt + PRE_TRIGGER + 5 + i*C_GAP, 1);
    end loop;
    pulses    <= v_pulses;
    arm_i     <= '1';

    for i in 1 to 3 loop
      -- Capture i started
      if nb_arm /= v_nb_arm + i
      then
        wait until nb_arm = v_nb_arm + i for C_TIMEOUT;
      end if;
      check_value(nb_arm, v_nb_arm + i, ERROR, "Continuous : capture " & to_string(i) & " started", C_SCOPE);
      v_first   := arm_sample;
      wait_trigger(v_trigger, "Continuous " & to_string(i));
      check_value (v_trigger, first_trigger(pulses, v_first + PRE_TRIGGER), ERROR, "Continuous : first pulse after the pre-trigger samples", C_SCOPE);

      -- No capture after the last one
      if i = 3
      then
        wait until falling_edge(trig_clk_i);
        arm_i   <= '0';
      end if;

      receive_capture(v_first, v_trigger, "Continuous " & to_string(i));
    end loop;
    wait_idle("Continuous");
    wait for 2*DEPTH*C_TRIG_PERIOD;
    check_value(nb_arm, v_nb_arm + 3, ERROR, "Continuous : no capture after arm_i low", C_SCOPE);
    pulses    <= C_NO_PULSE;

    ------------------------------------------------
    log(ID_LOG_HDR, "10. Sparse probes : a change every 4 samples on average", C_SCOPE);
    ------------------------------------------------
    -- Level trigger from a late sample : the trigger sample is often a
    -- sample without change (stored because it is the trigger sample)
    probe_mode <= MODE_SPARSE;
    wait for 4*C_TRIG_PERIOD;
    for i in 1 to 2 loop
      arm_capture(v_first, "Sparse " & to_string(i));
      set_pulse(v_first + 3*PRE_TRIGGER + 5*i, 64*DEPTH);
      wait_trigger   (v_trigger, "Sparse " & to_string(i));
      receive_capture(v_first, v_trigger, "Sparse " & to_string(i));
      wait_idle      ("Sparse " & to_string(i));
      pulses    <= C_NO_PULSE;
    end loop;

    ------------------------------------------------
    log(ID_LOG_HDR, "11. Frozen probes : samples stored at the timestamp 0 only", C_SCOPE);
    ------------------------------------------------
    if C_FROZEN_TEST
    then
      probe_mode <= MODE_FROZEN;
      wait for 4*C_TRIG_PERIOD;
      arm_capture(v_first, "Frozen");
      set_pulse(v_first + 5, 2*DEPTH*C_FROZEN_PERIOD + 100);
      wait_trigger   (v_trigger, "Frozen");
      receive_capture(v_first, v_trigger, "Frozen");
      wait_idle      ("Frozen");
      pulses    <= C_NO_PULSE;
    else
      log(ID_SEQUENCER, "Frozen : skipped, 2**TIMESTAMP_WIDTH too large", C_SCOPE);
    end if;
    probe_mode <= MODE_COUNT;

    ------------------------------------------------
    log(ID_LOG_HDR, "12. First sample of the capture equal to the last stored sample", C_SCOPE);
    ------------------------------------------------
    -- The first sample is stored (first sample of the capture), even without
    -- change. Level trigger from the third sample : the trigger sample is the
    -- first one after the pre-trigger samples, so the first sample is in the
    -- capture
    probe_force <= v_last_probe;
    probe_mode  <= MODE_FORCE;
    wait for 4*C_TRIG_PERIOD;
    arm_capture(v_first, "First sample");
    probe_mode  <= MODE_SPARSE;
    set_pulse(v_first + 2, 64*DEPTH);
    wait_trigger   (v_trigger, "First sample");
    receive_capture(v_first, v_trigger, "First sample");
    wait_idle      ("First sample");
    pulses      <= C_NO_PULSE;
    probe_mode  <= MODE_COUNT;

    ------------------------------------------------
    log(ID_LOG_HDR, "13. Asynchronous reset during an extraction", C_SCOPE);
    ------------------------------------------------
    arm_capture(v_first, "Reset");
    set_pulse(v_first + PRE_TRIGGER + 2, 1);
    wait_trigger(v_trigger, "Reset");
    await_value(m_axis_tvalid_o, '1', 0 ns, C_TIMEOUT, ERROR, "Reset : first beat presented", C_SCOPE);
    pulses           <= C_NO_PULSE;

    trig_arst_b_i    <= '0';
    extract_arst_b_i <= '0';
    wait for 1 ns;
    check_value(armed_o        , '0', ERROR, "Reset : armed_o low"        , C_SCOPE);
    check_value(triggered_o    , '0', ERROR, "Reset : triggered_o low"    , C_SCOPE);
    check_value(m_axis_tvalid_o, '0', ERROR, "Reset : m_axis_tvalid_o low", C_SCOPE);
    check_value(m_axis_tlast_o , '0', ERROR, "Reset : m_axis_tlast_o low" , C_SCOPE);
    wait for 5*C_TRIG_PERIOD + 5*C_EXTRACT_PERIOD;
    release_resets;
    wait for 2*DEPTH*C_TRIG_PERIOD;
    check_stable(m_axis_tvalid_o, 2*DEPTH*C_TRIG_PERIOD, ERROR, "Reset : the capture is lost", C_SCOPE);

    -- New capture after the reset (new origin of the timestamp)
    arm_capture(v_first, "After reset");
    set_pulse(v_first + PRE_TRIGGER + 4, 1);
    wait_trigger   (v_trigger, "After reset");
    check_value    (v_trigger, v_first + PRE_TRIGGER + 4, ERROR, "After reset : trigger sample", C_SCOPE);
    receive_capture(v_first, v_trigger, "After reset");
    wait_idle      ("After reset");
    pulses    <= C_NO_PULSE;

    ------------------------------------------------
    -- End of simulation
    ------------------------------------------------
    wait for 10*C_TRIG_PERIOD + 10*C_EXTRACT_PERIOD;
    log(ID_LOG_HDR, "Simulation Finished", C_SCOPE);
    report_alert_counters(FINAL);
    std.env.stop;
    wait;
  end process p_main;

end sim;
