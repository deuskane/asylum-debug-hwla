-------------------------------------------------------------------------------
-- Title      : tb_hwla
-- Project    : HWLA
-------------------------------------------------------------------------------
-- File       : tb_hwla.vhd
-- Author     : mrosiere
-------------------------------------------------------------------------------
-- Description: UVVM self-checking testbench of the HWLA, two asynchronous
--              clocks (periods given by generics). The captures are received
--              with the UVVM AXI-Stream BFM and checked sample by sample
--              against a model (tb_hwla_bfm_pkg).
--              * Probes  : 4 modes (COUNT, SPARSE, FROZEN, FORCE), chosen
--                by the scenario.
--              * Trigger : driven from a schedule of pulses (sample numbers).
--              * History : the probes and the trigger of each sample, as
--                sampled by the dut.
--              * Monitors : first sample of each capture (rise of armed_o),
--                AXI-Stream protocol (tvalid, tdata, tlast held while
--                tready = 0, tlast only with tvalid, DEPTH*NB_BEAT beats per
--                capture).
--              TESTS_LIST : scenarios run in sequence, separated by ','
--                           (tb_hwla_tests_pkg), each one after a reset
--                           pulse of both domains ; "" : build and
--                           elaboration only. A scenario not applicable
--                           to the generics is an error.
-------------------------------------------------------------------------------
-- Revisions  :
-- Date        Version  Author   Description
-- 2026-10-22  1.0      mrosiere Created
-- 2026-10-22  2.0      mrosiere Timestamp, CHANGE_ONLY, TDATA_WIDTH : history
--                               and model of the stored samples, sparse and
--                               frozen probes
-- 2026-10-22  2.1      mrosiere One test per simulation (generic TEST)
-- 2026-11-20  3.0      mrosiere TESTS_LIST, one package per scenario
--                               (tb_hwla_<name>_pkg), helpers in
--                               tb_hwla_bfm_pkg, reset pulse before each
--                               scenario
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
use     asylum.string_pkg.all;

library work;
use     work.tb_hwla_bfm_pkg.all;
use     work.tb_hwla_tests_pkg.all;

entity tb_hwla is
  generic (
    TESTS_LIST         : string   := "";   -- Scenarios, e.g. "reset_values,capture"
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
  constant C_CFG              : tb_cfg_t := tb_cfg(NB_PROBE, DEPTH, PRE_TRIGGER, TIMESTAMP_WIDTH, CHANGE_ONLY, TDATA_WIDTH,
                                                   TRIG_CLK_PERIOD, EXTRACT_CLK_PERIOD);

  -- Clocks & Resets
  signal   trig_clk_i         : std_logic := '0';
  signal   trig_clk_ena       : boolean   := true;
  signal   trig_arst_b_i      : std_logic := '0';
  signal   extract_clk_i      : std_logic := '0';
  signal   extract_clk_ena    : boolean   := true;
  signal   extract_arst_b_i   : std_logic := '0';

  -- dut : trigger domain
  signal   trigger_i          : std_logic;
  signal   probe_i            : std_logic_vector(NB_PROBE-1 downto 0) := probe_value(0, NB_PROBE);

  -- dut : extraction domain
  signal   m_axis_tdata_o     : std_logic_vector(C_CFG.tdata_width-1 downto 0);
  signal   m_axis_tvalid_o    : std_logic;
  signal   m_axis_tready_i    : std_logic;
  signal   m_axis_tlast_o     : std_logic;
  signal   axis_if            : t_axistream_if(tdata(C_CFG.tdata_width  -1 downto 0),
                                               tkeep(C_CFG.tdata_width/8-1 downto 0),
                                               tuser(0 downto 0),
                                               tstrb(C_CFG.tdata_width/8-1 downto 0),
                                               tid  (0 downto 0),
                                               tdest(0 downto 0));

  -- Requests of the sequencer, responses of the bench
  signal   tb_req             : tb_req_t(probe_force(NB_PROBE-1 downto 0)) := (arm         => '0',
                                                                                probe_mode  => MODE_COUNT,
                                                                                probe_force => (others => '0'),
                                                                                pulses      => C_NO_PULSE,
                                                                                ts_origin   => 0);
  signal   tb_rsp             : tb_rsp_t := (armed      => '0',
                                             triggered  => '0',
                                             probe_cnt  => 0,
                                             nb_arm     => 0,
                                             arm_sample => 0);

begin

  clock_generator(trig_clk_i   , trig_clk_ena   , C_CFG.trig_period   , "Trigger clock");
  clock_generator(extract_clk_i, extract_clk_ena, C_CFG.extract_period, "Extraction clock");

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
     ,arm_i            => tb_req.arm
     ,trigger_i        => trigger_i
     ,probe_i          => probe_i
     ,armed_o          => tb_rsp.armed
     ,triggered_o      => tb_rsp.triggered
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
    history.set(tb_rsp.probe_cnt, probe_i, trigger_i);
    tb_rsp.probe_cnt <= tb_rsp.probe_cnt + 1;

    -- Probes of the next sample
    uniform(v_seed1, v_seed2, v_rand);
    case tb_req.probe_mode is
      when MODE_COUNT  =>
        probe_i <= probe_value(tb_rsp.probe_cnt + 1, NB_PROBE);
      when MODE_SPARSE =>
        if v_rand < 0.25
        then
          probe_i <= probe_value(tb_rsp.probe_cnt + 1, NB_PROBE);
        end if;
      when MODE_FROZEN =>
        null;
      when MODE_FORCE  =>
        probe_i <= tb_req.probe_force;
    end case;
  end process p_probe;

  trigger_i             <= is_trigger(tb_req.pulses, tb_rsp.probe_cnt);

  -----------------------------------------------------------------------------
  -- Capture monitor
  -----------------------------------------------------------------------------
  -- armed_o rises just after the rising edge that sampled arm_i = 1, the
  -- sample of this rising edge is the first one of the capture
  p_arm_monitor : process
  begin
    wait until rising_edge(tb_rsp.armed);
    tb_rsp.arm_sample <= tb_rsp.probe_cnt - 1;
    tb_rsp.nb_arm     <= tb_rsp.nb_arm + 1;
  end process p_arm_monitor;

  -----------------------------------------------------------------------------
  -- AXI-Stream protocol monitor
  -----------------------------------------------------------------------------
  -- Signals sampled at the rising edge of extract_clk_i
  p_axis_monitor : process
    variable v_stall  : boolean := false;
    variable v_tdata  : std_logic_vector(C_CFG.tdata_width-1 downto 0);
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
          check_value(v_beats, DEPTH*C_CFG.nb_beat, ERROR, "AXI-Stream : DEPTH*NB_BEAT beats in a capture", C_SCOPE);
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
  p_sequencer : process
  begin
    disable_log_msg(ID_PACKET_DATA);  -- One message per byte
    log(ID_LOG_HDR, "HWLA : NB_PROBE " & to_string(NB_PROBE) &
                    ", DEPTH " & to_string(DEPTH) & ", PRE_TRIGGER " & to_string(PRE_TRIGGER) &
                    ", TIMESTAMP_WIDTH " & to_string(TIMESTAMP_WIDTH) & ", CHANGE_ONLY " & to_string(CHANGE_ONLY) &
                    ", " & to_string(C_CFG.nb_beat) & " beat(s) of " & to_string(C_CFG.tdata_width) & " bits per sample" &
                    ", trigger clock " & to_string(C_CFG.trig_period) & ", extraction clock " & to_string(C_CFG.extract_period) &
                    ", TESTS_LIST : " & TESTS_LIST, C_SCOPE);

    if NB_PROBE > C_PROBE_MAX
    then
      alert(TB_ERROR, "NB_PROBE larger than the history of the bench (" & to_string(C_PROBE_MAX) & ")", C_SCOPE);
    end if;

    -- Every name is checked before the first scenario
    for i in 1 to list_length(TESTS_LIST) loop
      if not list_contains(C_TESTS, list_item(TESTS_LIST, i))
      then
        alert(TB_ERROR, "Unknown test """ & list_item(TESTS_LIST, i) & """ (tests : " & C_TESTS & ")", C_SCOPE);
      elsif not test_applies(list_item(TESTS_LIST, i), C_CFG)
      then
        alert(TB_ERROR, "Test """ & list_item(TESTS_LIST, i) & """ not applicable to the generics", C_SCOPE);
      end if;
    end loop;

    for i in 1 to list_length(TESTS_LIST) loop
      -- Reset pulse, stimuli idle (arm_i low, no trigger pulse, COUNT
      -- probes, tready low) : each scenario starts from reset
      tb_req.arm        <= '0';
      tb_req.probe_mode <= MODE_COUNT;
      tb_req.pulses     <= C_NO_PULSE;
      axis_if           <= init_axistream_if_signals(false, C_CFG.tdata_width, 1, 1, 1);
      do_reset(C_CFG, trig_clk_i, trig_arst_b_i, extract_clk_i, extract_arst_b_i, tb_req, tb_rsp);

      log(ID_LOG_HDR, "TEST " & integer'image(i) & "/" & integer'image(list_length(TESTS_LIST)) & " : " & list_item(TESTS_LIST, i), C_SCOPE);
      run_test(list_item(TESTS_LIST, i), C_CFG, trig_clk_i, trig_arst_b_i, extract_clk_i, extract_arst_b_i, tb_req, tb_rsp, axis_if);
    end loop;

    ------------------------------------------------
    -- End of simulation
    ------------------------------------------------
    wait for 10*C_CFG.trig_period + 10*C_CFG.extract_period;
    log(ID_LOG_HDR, "Simulation Finished", C_SCOPE);
    report_alert_counters(FINAL);
    std.env.stop;
    wait;
  end process p_sequencer;

end sim;
