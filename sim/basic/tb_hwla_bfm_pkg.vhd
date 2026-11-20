-------------------------------------------------------------------------------
-- Title      : tb_hwla_bfm_pkg
-- Project    : HWLA
-------------------------------------------------------------------------------
-- File       : tb_hwla_bfm_pkg.vhd
-- Author     : mrosiere
-------------------------------------------------------------------------------
-- Description: Helpers of the tb_hwla scenarios :
--              * Configuration of the bench (tb_cfg_t) : generics of tb_hwla
--                and the constants derived from them.
--              * Requests of the sequencer to the bench (tb_req_t) : arm_i,
--                mode of the probes, schedule of the trigger.
--              * Responses of the bench (tb_rsp_t) : armed_o, triggered_o
--                and the monitors (sample number, captures started).
--              * History : the probes and the trigger of each sample, as
--                sampled by the dut.
--              * Model : from the history, the samples stored by a capture
--                (CHANGE_ONLY, timestamp 0, trigger sample, pre / post
--                trigger samples) and its trigger sample.
--              * Capture : arm, wait for the trigger, receive the capture
--                with the UVVM AXI-Stream BFM and check it sample by sample
--                against the model, wait for the end of the handshake.
--              * Reset pulse of both domains.
-------------------------------------------------------------------------------
-- Copyright (c) 2026
-------------------------------------------------------------------------------
-- Revisions  :
-- Date        Version  Author   Description
-- 2026-11-20  1.0      mrosiere Created (helpers of the tb_hwla sequencer)
-------------------------------------------------------------------------------

library ieee;
use     ieee.std_logic_1164.all;
use     ieee.numeric_std.all;

library uvvm_util;
context uvvm_util.uvvm_util_context;

library bitvis_vip_axistream;
use     bitvis_vip_axistream.axistream_bfm_pkg.all;

library asylum;
use     asylum.hwla_pkg.all;

package tb_hwla_bfm_pkg is

  constant C_TB_SCOPE         : string   := "TB_HWLA";
  constant C_PROBE_MAX        : positive := 64;      -- Largest NB_PROBE of the bench (history)
  constant C_HISTORY          : positive := 2**16;   -- History : last C_HISTORY samples

  type     natural_array_t is array (natural range <>) of natural;

  -- Schedule of the trigger : trigger_i = 1 for the samples start to
  -- start+length-1 of each pulse (length = 0 : no pulse)
  type     pulse_t is record
    start  : natural;
    length : natural;
  end record pulse_t;
  type     pulse_array_t is array (0 to 7) of pulse_t;
  constant C_NO_PULSE         : pulse_array_t := (others => (0, 0));

  -- Mode of the probes. COUNT : the probes are the sample number (inverted
  -- copies above bit 30), a new value at each sample. SPARSE : a new value
  -- (the sample number) with a probability of 1/4. FROZEN : no change.
  -- FORCE : the value probe_force of the requests.
  type     probe_mode_t is (MODE_COUNT, MODE_SPARSE, MODE_FROZEN, MODE_FORCE);

  -- Configuration of the bench : generics of tb_hwla and derived constants
  type     tb_cfg_t is record
    nb_probe          : positive;
    depth             : positive;
    pre_trigger       : natural;
    post_trigger      : natural;
    timestamp_width   : natural;
    change_only       : boolean;
    sample_width      : positive;  -- Timestamp and probes
    tdata_width       : positive;  -- Width of m_axis_tdata_o
    nb_beat           : positive;  -- Beats of a sample
    sample_bytes      : positive;  -- Bytes of a sample on the AXI-Stream
    trig_period       : time;
    extract_period    : time;
    frozen_test       : boolean;   -- Scenario frozen short enough
    frozen_period     : positive;  -- Frozen probes : a stored sample every frozen_period samples
    timeout           : time;      -- A capture and its extraction
    max_wait_cycles   : positive;  -- Same, in clock cycles of the extraction domain
    gap               : positive;  -- Continuous captures : samples between two trigger pulses
  end record tb_cfg_t;

  -- Requests of the sequencer to the bench (driven by the sequencer only)
  type     tb_req_t is record
    arm               : std_logic;         -- arm_i of the dut
    probe_mode        : probe_mode_t;
    probe_force       : std_logic_vector;  -- Probes of MODE_FORCE (NB_PROBE bits)
    pulses            : pulse_array_t;     -- Schedule of trigger_i
    ts_origin         : natural;           -- Sample with the timestamp 0 : first rising edge after the reset
  end record tb_req_t;

  -- Responses of the bench (one process or one port of the dut drives each
  -- element)
  type     tb_rsp_t is record
    armed             : std_logic;         -- armed_o of the dut
    triggered         : std_logic;         -- triggered_o of the dut
    probe_cnt         : natural;           -- Number of the sample on probe_i (sampled at the next rising edge of trig_clk_i)
    nb_arm            : natural;           -- Number of captures started (rises of armed_o)
    arm_sample        : natural;           -- First sample of the last capture started
  end record tb_rsp_t;

  -- History of the samples
  type     history_t is protected
    procedure            set         (sample : natural; probe : std_logic_vector; trigger : std_logic);
    impure function      get_probe   (sample : natural; nb_probe : positive) return std_logic_vector;
    impure function      get_trigger (sample : natural) return std_logic;
  end protected history_t;

  shared variable history     : history_t;

  -- Configuration of the bench from the generics of tb_hwla
  function tb_cfg
    (constant nb_probe           : in    positive
    ;constant depth              : in    positive
    ;constant pre_trigger        : in    natural
    ;constant timestamp_width    : in    natural
    ;constant change_only        : in    boolean
    ;constant tdata_width        : in    natural
    ;constant trig_clk_period    : in    positive
    ;constant extract_clk_period : in    positive
    ) return tb_cfg_t;

  -- Configuration of the AXI-Stream BFM : no back pressure, packet length
  -- checked
  function axis_cfg
    (constant cfg      : in    tb_cfg_t
    ) return t_axistream_bfm_config;

  -- Trigger value of the sample number sample
  function is_trigger
    (constant p        : in    pulse_array_t
    ;constant sample   : in    natural
    ) return std_logic;

  -- First trigger sample from the sample number from_sample, -1 if none
  function first_trigger
    (constant p        : in    pulse_array_t
    ;constant from_sample : in natural
    ) return integer;

  -- New value of the probes at the sample number sample : the sample number
  -- on the bits 0 to 30, inverted on the bits 31 to 61, ...
  function probe_value
    (constant sample   : in    natural
    ;constant nb_probe : in    positive
    ) return std_logic_vector;

  -- Timestamp of the sample number sample
  function timestamp
    (constant cfg       : in    tb_cfg_t
    ;constant ts_origin : in    natural
    ;constant sample    : in    natural
    ) return std_logic_vector;

  -- Model of a capture started at the sample first : the stored samples
  -- (sample numbers, from the oldest) and the trigger sample
  procedure model_capture
    (constant cfg       : in    tb_cfg_t
    ;constant ts_origin : in    natural
    ;constant probe_cnt : in    natural
    ;constant first     : in    natural
    ;variable samples   : out   natural_array_t
    ;variable trigger   : out   natural
    ;constant msg       : in    string
    );

  -- Pulse of the trigger : the samples start to start+length-1
  procedure set_pulse
    (constant start    : in    natural
    ;constant length   : in    natural
    ;signal   tb_req   : inout tb_req_t
    );

  -- Start a capture with a pulse of one clock cycle on arm_i, first is the
  -- number of the sample presented with arm_i = 1 : the first sample of the
  -- capture
  procedure arm_capture
    (variable first    : out   natural
    ;constant msg      : in    string
    ;signal   trig_clk : in    std_logic
    ;signal   tb_req   : inout tb_req_t
    ;signal   tb_rsp   : in    tb_rsp_t
    );

  -- Wait for the trigger of the capture : triggered_o rises one clock cycle
  -- after the rising edge that sampled the trigger sample, so trigger is the
  -- sample before the previous one
  procedure wait_trigger
    (constant cfg      : in    tb_cfg_t
    ;variable trigger  : out   natural
    ;constant msg      : in    string
    ;signal   tb_rsp   : in    tb_rsp_t
    );

  -- Receive a capture started at the sample first on the AXI-Stream, check
  -- its trigger and its DEPTH stored samples against the model
  procedure receive_capture
    (constant cfg         : in    tb_cfg_t
    ;constant axis_config : in    t_axistream_bfm_config
    ;constant first       : in    natural
    ;constant trigger     : in    natural
    ;constant msg         : in    string
    ;signal   extract_clk : in    std_logic
    ;signal   tb_req      : in    tb_req_t
    ;signal   tb_rsp      : in    tb_rsp_t
    ;signal   axis_if     : inout t_axistream_if
    );

  -- Wait for the end of the handshake : the dut can start a new capture
  procedure wait_idle
    (constant cfg      : in    tb_cfg_t
    ;constant msg      : in    string
    ;signal   tb_rsp   : in    tb_rsp_t
    ;signal   axis_if  : in    t_axistream_if
    );

  -- Release the resets, after a falling edge of each clock. The sample of
  -- the next rising edge of trig_clk_i has the timestamp 0
  procedure release_resets
    (signal   trig_clk       : in    std_logic
    ;signal   trig_arst_b    : out   std_logic
    ;signal   extract_clk    : in    std_logic
    ;signal   extract_arst_b : out   std_logic
    ;signal   tb_req         : inout tb_req_t
    ;signal   tb_rsp         : in    tb_rsp_t
    );

  -- Reset pulse of both domains (10 clock cycles of each clock)
  procedure do_reset
    (constant cfg            : in    tb_cfg_t
    ;signal   trig_clk       : in    std_logic
    ;signal   trig_arst_b    : out   std_logic
    ;signal   extract_clk    : in    std_logic
    ;signal   extract_arst_b : out   std_logic
    ;signal   tb_req         : inout tb_req_t
    ;signal   tb_rsp         : in    tb_rsp_t
    );

end package tb_hwla_bfm_pkg;

package body tb_hwla_bfm_pkg is

  type history_t is protected body
    type     probe_array_t is array (0 to C_HISTORY-1) of std_logic_vector(C_PROBE_MAX-1 downto 0);
    variable v_probe   : probe_array_t;
    variable v_trigger : std_logic_vector(0 to C_HISTORY-1);

    procedure set (sample : natural; probe : std_logic_vector; trigger : std_logic) is
      variable v_value : std_logic_vector(C_PROBE_MAX-1 downto 0) := (others => '0');
    begin
      v_value(probe'length-1 downto 0) := probe;
      v_probe  (sample mod C_HISTORY)  := v_value;
      v_trigger(sample mod C_HISTORY)  := trigger;
    end procedure;

    impure function get_probe (sample : natural; nb_probe : positive) return std_logic_vector is
    begin
      return v_probe(sample mod C_HISTORY)(nb_probe-1 downto 0);
    end function;

    impure function get_trigger (sample : natural) return std_logic is
    begin
      return v_trigger(sample mod C_HISTORY);
    end function;
  end protected body history_t;

  function tb_cfg
    (constant nb_probe           : in    positive
    ;constant depth              : in    positive
    ;constant pre_trigger        : in    natural
    ;constant timestamp_width    : in    natural
    ;constant change_only        : in    boolean
    ;constant tdata_width        : in    natural
    ;constant trig_clk_period    : in    positive
    ;constant extract_clk_period : in    positive
    ) return tb_cfg_t is
    variable v : tb_cfg_t;
  begin
    v.nb_probe        := nb_probe;
    v.depth           := depth;
    v.pre_trigger     := pre_trigger;
    v.post_trigger    := depth-1-pre_trigger;
    v.timestamp_width := timestamp_width;
    v.change_only     := change_only;
    v.sample_width    := hwla_sample_width(nb_probe, timestamp_width);
    v.tdata_width     := hwla_tdata_width (v.sample_width, tdata_width);
    v.nb_beat         := hwla_nb_beat     (v.sample_width, tdata_width);
    v.sample_bytes    := v.nb_beat*v.tdata_width/8;
    v.trig_period     := trig_clk_period    * 1 ns;
    v.extract_period  := extract_clk_period * 1 ns;

    -- Frozen probes : a stored sample every 2**TIMESTAMP_WIDTH samples
    -- (CHANGE_ONLY), run if this is short enough
    v.frozen_test     := (not change_only) or (timestamp_width > 0 and timestamp_width <= 6);
    v.frozen_period   := 2**minimum(timestamp_width, 6);

    -- Timeouts : a capture (with several turns of the circular buffer, or
    -- frozen probes) and its extraction, in time and in clock cycles of the
    -- extraction domain
    v.timeout         := (8*depth*v.frozen_period + 100) * (v.trig_period + v.extract_period);
    v.max_wait_cycles := 8*depth*v.frozen_period*(trig_clk_period/extract_clk_period + 1) + 100;

    -- Continuous captures (COUNT probes) : number of samples between two
    -- trigger pulses, more than a capture, its extraction and the handshake
    v.gap             := 4*depth + 2*depth*v.nb_beat*(extract_clk_period/trig_clk_period + 1) + 64;
    return v;
  end function;

  function axis_cfg
    (constant cfg      : in    tb_cfg_t
    ) return t_axistream_bfm_config is
    variable v_config : t_axistream_bfm_config := C_AXISTREAM_BFM_CONFIG_DEFAULT;
  begin
    v_config.max_wait_cycles     := cfg.max_wait_cycles;
    v_config.check_packet_length := true;
    return v_config;
  end function;

  function is_trigger
    (constant p        : in    pulse_array_t
    ;constant sample   : in    natural
    ) return std_logic is
  begin
    for i in p'range loop
      if sample >= p(i).start and sample < p(i).start + p(i).length
      then
        return '1';
      end if;
    end loop;
    return '0';
  end function;

  function first_trigger
    (constant p        : in    pulse_array_t
    ;constant from_sample : in natural
    ) return integer is
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

  function probe_value
    (constant sample   : in    natural
    ;constant nb_probe : in    positive
    ) return std_logic_vector is
    variable v_cnt   : unsigned(30 downto 0) := to_unsigned(sample, 31);
    variable v_probe : std_logic_vector(nb_probe-1 downto 0);
  begin
    for i in 0 to nb_probe-1 loop
      if (i/31) mod 2 = 0
      then
        v_probe(i) := v_cnt(i mod 31);
      else
        v_probe(i) := not v_cnt(i mod 31);
      end if;
    end loop;
    return v_probe;
  end function;

  function timestamp
    (constant cfg       : in    tb_cfg_t
    ;constant ts_origin : in    natural
    ;constant sample    : in    natural
    ) return std_logic_vector is
  begin
    return std_logic_vector(resize(to_unsigned(sample - ts_origin, 31), cfg.timestamp_width));
  end function;

  procedure model_capture
    (constant cfg       : in    tb_cfg_t
    ;constant ts_origin : in    natural
    ;constant probe_cnt : in    natural
    ;constant first     : in    natural
    ;variable samples   : out   natural_array_t
    ;variable trigger   : out   natural
    ;constant msg       : in    string
    ) is
    type     phase_t is (P_FILL, P_ARMED, P_POST, P_DONE);
    variable v_ring  : natural_array_t(0 to cfg.depth-1) := (others => 0);
    variable v_nb    : natural := 0;    -- Number of stored samples
    variable v_cnt   : natural := 0;    -- Number of stored samples in the phase
    variable v_phase : phase_t;
    variable v_n     : natural := first;
    variable v_probe : std_logic_vector(cfg.nb_probe-1 downto 0);
    variable v_last  : std_logic_vector(cfg.nb_probe-1 downto 0) := (others => '0');
    variable v_trig  : boolean;
    variable v_store : boolean;
  begin
    trigger := first;
    if cfg.pre_trigger = 0
    then
      v_phase := P_ARMED;
    else
      v_phase := P_FILL;
    end if;

    while v_phase /= P_DONE loop
      if v_n >= probe_cnt
      then
        alert(TB_ERROR, msg & " : model, sample " & to_string(v_n) & " not yet in the history", C_TB_SCOPE);
        exit;
      end if;

      -- Stored sample : every sample (CHANGE_ONLY = false), the first one,
      -- a change of the probes, the timestamp 0, the trigger sample
      v_probe := history.get_probe(v_n, cfg.nb_probe);
      v_trig  := v_phase = P_ARMED and history.get_trigger(v_n) = '1';
      v_store := (not cfg.change_only) or v_nb = 0 or v_probe /= v_last or v_trig or
                 (cfg.timestamp_width > 0 and unsigned(timestamp(cfg, ts_origin, v_n)) = 0);

      if v_store
      then
        v_ring(v_nb mod cfg.depth) := v_n;
        v_nb    := v_nb  + 1;
        v_cnt   := v_cnt + 1;
        v_last  := v_probe;
      end if;

      case v_phase is
        when P_FILL  =>
          if v_cnt = cfg.pre_trigger
          then
            v_cnt   := 0;
            v_phase := P_ARMED;
          end if;
        when P_ARMED =>
          if v_trig
          then
            trigger := v_n;
            v_cnt   := 0;
            if cfg.post_trigger = 0
            then
              v_phase := P_DONE;
            else
              v_phase := P_POST;
            end if;
          end if;
        when P_POST  =>
          if v_cnt = cfg.post_trigger
          then
            v_phase := P_DONE;
          end if;
        when P_DONE  =>
          null;
      end case;

      v_n := v_n + 1;
    end loop;

    -- The DEPTH last stored samples, from the oldest
    for k in 0 to cfg.depth-1 loop
      samples(k) := v_ring((v_nb + k) mod cfg.depth);
    end loop;
  end procedure;

  procedure set_pulse
    (constant start    : in    natural
    ;constant length   : in    natural
    ;signal   tb_req   : inout tb_req_t
    ) is
    variable v_pulses : pulse_array_t := C_NO_PULSE;
  begin
    v_pulses(0)   := (start, length);
    tb_req.pulses <= v_pulses;
  end procedure;

  procedure arm_capture
    (variable first    : out   natural
    ;constant msg      : in    string
    ;signal   trig_clk : in    std_logic
    ;signal   tb_req   : inout tb_req_t
    ;signal   tb_rsp   : in    tb_rsp_t
    ) is
    variable v_nb     : natural;
    variable v_sample : natural;
  begin
    wait until falling_edge(trig_clk);
    v_nb       := tb_rsp.nb_arm;
    v_sample   := tb_rsp.probe_cnt;
    tb_req.arm <= '1';
    wait until falling_edge(trig_clk);
    tb_req.arm <= '0';
    check_value(tb_rsp.nb_arm    , v_nb+1  , ERROR, msg & " : capture started (rise of armed_o)", C_TB_SCOPE);
    check_value(tb_rsp.arm_sample, v_sample, ERROR, msg & " : first sample of the capture is the sample with arm_i = 1", C_TB_SCOPE);
    first      := v_sample;
  end procedure;

  procedure wait_trigger
    (constant cfg      : in    tb_cfg_t
    ;variable trigger  : out   natural
    ;constant msg      : in    string
    ;signal   tb_rsp   : in    tb_rsp_t
    ) is
  begin
    await_value(tb_rsp.triggered, '1', 0 ns, cfg.timeout, ERROR, msg & " : triggered_o set", C_TB_SCOPE);
    check_value(tb_rsp.armed, '0', ERROR, msg & " : armed_o cleared by the trigger", C_TB_SCOPE);
    trigger := tb_rsp.probe_cnt - 2;
  end procedure;

  procedure receive_capture
    (constant cfg         : in    tb_cfg_t
    ;constant axis_config : in    t_axistream_bfm_config
    ;constant first       : in    natural
    ;constant trigger     : in    natural
    ;constant msg         : in    string
    ;signal   extract_clk : in    std_logic
    ;signal   tb_req      : in    tb_req_t
    ;signal   tb_rsp      : in    tb_rsp_t
    ;signal   axis_if     : inout t_axistream_if
    ) is
    variable v_bytes   : t_slv_array (0 to cfg.depth*cfg.sample_bytes-1)(7 downto 0);
    variable v_len     : natural;
    variable v_user    : t_user_array(0 to 0);
    variable v_strb    : t_strb_array(0 to 0);
    variable v_id      : t_id_array  (0 to 0);
    variable v_dest    : t_dest_array(0 to 0);
    variable v_samples : natural_array_t(0 to cfg.depth-1);
    variable v_model   : natural;   -- Trigger sample of the model
    variable v_sample  : std_logic_vector(cfg.sample_width-1 downto 0);
    variable v_word    : std_logic_vector(cfg.sample_bytes*8-1 downto 0);
    variable v_exp     : std_logic_vector(cfg.sample_bytes*8-1 downto 0);
  begin
    axistream_receive(v_bytes, v_len, v_user, v_strb, v_id, v_dest, msg, extract_clk, axis_if, C_TB_SCOPE, shared_msg_id_panel, axis_config);
    check_value(v_len, cfg.depth*cfg.sample_bytes, ERROR, msg & " : DEPTH samples, tlast with the last beat", C_TB_SCOPE);

    model_capture(cfg, tb_req.ts_origin, tb_rsp.probe_cnt, first, v_samples, v_model, msg);
    check_value(trigger, v_model, ERROR, msg & " : trigger sample (model)", C_TB_SCOPE);
    check_value(v_samples(cfg.pre_trigger), v_model, ERROR, msg & " : trigger sample after PRE_TRIGGER stored samples", C_TB_SCOPE);

    -- A sample : sample_bytes bytes, from the LSB
    for k in 0 to cfg.depth-1 loop
      for b in 0 to cfg.sample_bytes-1 loop
        v_word(8*b+7 downto 8*b) := v_bytes(k*cfg.sample_bytes+b);
      end loop;
      v_sample := timestamp(cfg, tb_req.ts_origin, v_samples(k)) & history.get_probe(v_samples(k), cfg.nb_probe);
      v_exp    := std_logic_vector(resize(unsigned(v_sample), cfg.sample_bytes*8));
      check_value(v_word, v_exp, ERROR,
                  msg & " : stored sample " & to_string(k) & " (sample number " & to_string(v_samples(k)) & ")",
                  C_TB_SCOPE, HEX, KEEP_LEADING_0, ID_NEVER);
    end loop;
    log(ID_SEQUENCER, msg & " : capture received, " & to_string(cfg.depth) & " stored samples from the samples " & to_string(v_samples(0)) &
                      " to " & to_string(v_samples(cfg.depth-1)) & ", trigger sample " & to_string(trigger), C_TB_SCOPE);
  end procedure;

  procedure wait_idle
    (constant cfg      : in    tb_cfg_t
    ;constant msg      : in    string
    ;signal   tb_rsp   : in    tb_rsp_t
    ;signal   axis_if  : in    t_axistream_if
    ) is
  begin
    await_value(tb_rsp.triggered, '0', 0 ns, cfg.timeout, ERROR, msg & " : triggered_o cleared after the extraction", C_TB_SCOPE);
    check_value(tb_rsp.armed , '0', ERROR, msg & " : idle, armed_o low"        , C_TB_SCOPE);
    check_value(axis_if.tvalid, '0', ERROR, msg & " : idle, m_axis_tvalid_o low", C_TB_SCOPE);
  end procedure;

  procedure release_resets
    (signal   trig_clk       : in    std_logic
    ;signal   trig_arst_b    : out   std_logic
    ;signal   extract_clk    : in    std_logic
    ;signal   extract_arst_b : out   std_logic
    ;signal   tb_req         : inout tb_req_t
    ;signal   tb_rsp         : in    tb_rsp_t
    ) is
  begin
    wait until falling_edge(trig_clk);
    trig_arst_b      <= '1';
    tb_req.ts_origin <= tb_rsp.probe_cnt;
    wait until falling_edge(extract_clk);
    extract_arst_b   <= '1';
  end procedure;

  procedure do_reset
    (constant cfg            : in    tb_cfg_t
    ;signal   trig_clk       : in    std_logic
    ;signal   trig_arst_b    : out   std_logic
    ;signal   extract_clk    : in    std_logic
    ;signal   extract_arst_b : out   std_logic
    ;signal   tb_req         : inout tb_req_t
    ;signal   tb_rsp         : in    tb_rsp_t
    ) is
  begin
    trig_arst_b    <= '0';
    extract_arst_b <= '0';
    wait for 10*cfg.trig_period + 10*cfg.extract_period;
    release_resets(trig_clk, trig_arst_b, extract_clk, extract_arst_b, tb_req, tb_rsp);
  end procedure;

end package body tb_hwla_bfm_pkg;
