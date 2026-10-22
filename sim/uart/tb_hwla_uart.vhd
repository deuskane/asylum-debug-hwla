-------------------------------------------------------------------------------
-- Title      : tb_hwla_uart
-- Project    : HWLA
-------------------------------------------------------------------------------
-- File       : tb_hwla_uart.vhd
-- Author     : mrosiere
-------------------------------------------------------------------------------
-- Description: UVVM testbench of the HWLA connected to a UART transmitter :
--              the AXI-Stream of hwla (TDATA_WIDTH = 8) drives uart_tx_axis
--              (and its uart_baud_rate_gen) of asylum-communication-uart,
--              without CSR, in the extraction domain.
--              * Probes  : 8 probes, a pure function of the sample number :
--                4-bit counter (probes 3:0, +1 every 5 clock cycles), toggle
--                (probe 4, every 7 clock cycles), pulse (probe 5, one clock
--                cycle every 23), 2-bit slow value (probes 7:6, every 41
--                clock cycles). Trigger : counter = 12 and toggle = 1.
--              * arm_i is held high during NB_CAPTURE captures.
--              * The UART line is received with the UVVM UART BFM, each
--                received byte is checked against the AXI-Stream beat sent to
--                uart_tx_axis, and written in FILENAME_UART (hexadecimal, one
--                byte per line).
--              * FILENAME_REF : reference for the VCD rebuilt from
--                FILENAME_UART (post_run hook, tools/hwla2vcd.py and
--                sim/uart/check_vcd.py) : "s <sample> <probes>" for each
--                change of the probes, "t <sample>" for the trigger sample of
--                each capture.
-------------------------------------------------------------------------------
-- Revisions  :
-- Date        Version  Author   Description
-- 2026-10-22  1.0      mrosiere Created
-------------------------------------------------------------------------------

library ieee;
use     ieee.std_logic_1164.all;
use     ieee.numeric_std.all;

library std;
use     std.textio.all;

library uvvm_util;
context uvvm_util.uvvm_util_context;

library bitvis_vip_uart;
use     bitvis_vip_uart.uart_bfm_pkg.all;

library asylum;
use     asylum.hwla_pkg.all;
use     asylum.uart_pkg.all;

entity tb_hwla_uart is
  generic (
    DEPTH              : positive := 32;   -- Number of stored samples of a capture
    PRE_TRIGGER        : natural  := 8;    -- Number of stored samples before the trigger sample
    TIMESTAMP_WIDTH    : natural  := 16;   -- Width of the timestamp
    NB_CAPTURE         : positive := 2;    -- Number of captures sent on the UART
    TRIG_CLK_PERIOD    : positive := 10;   -- Period of the trigger clock (ns, even)
    EXTRACT_CLK_PERIOD : positive := 20;   -- Period of the extraction (UART) clock (ns, even)
    BAUD_TICK_CNT_MAX  : positive := 7     -- UART bit : BAUD_TICK_CNT_MAX+1 clock cycles of the extraction clock
    );
end tb_hwla_uart;

architecture sim of tb_hwla_uart is

  constant C_SCOPE            : string   := "TB_HWLA_UART";
  constant C_NB_PROBE         : positive := 8;
  constant C_TRIG_PERIOD      : time     := TRIG_CLK_PERIOD    * 1 ns;
  constant C_EXTRACT_PERIOD   : time     := EXTRACT_CLK_PERIOD * 1 ns;
  constant C_BIT_TIME         : time     := (BAUD_TICK_CNT_MAX+1) * C_EXTRACT_PERIOD;
  constant C_SAMPLE_BYTES     : positive := hwla_nb_beat(hwla_sample_width(C_NB_PROBE, TIMESTAMP_WIDTH), 8);
  constant C_NB_BYTE          : positive := NB_CAPTURE*DEPTH*C_SAMPLE_BYTES;
  constant C_TIMEOUT          : time     := NB_CAPTURE*(DEPTH*C_SAMPLE_BYTES*12*C_BIT_TIME + 1000*C_TRIG_PERIOD);

  constant FILENAME_UART      : string   := "hwla_uart.hex";
  constant FILENAME_REF       : string   := "hwla_uart_ref.txt";

  type     byte_array_t is array (0 to C_NB_BYTE-1) of std_logic_vector(7 downto 0);

  -- Probes of the sample number sample
  function probe_value (sample : natural) return std_logic_vector is
    variable v_probe : std_logic_vector(C_NB_PROBE-1 downto 0);
  begin
    v_probe(3 downto 0) := std_logic_vector(to_unsigned((sample / 5) mod 16, 4));
    v_probe(4)          := '1' when (sample / 7) mod 2 = 1 else '0';
    v_probe(5)          := '1' when  sample mod 23     = 0 else '0';
    v_probe(7 downto 6) := std_logic_vector(to_unsigned(((sample / 41) * 3) mod 4, 2));
    return v_probe;
  end function;

  -- Clocks & Resets
  signal   trig_clk_i         : std_logic := '0';
  signal   trig_clk_ena       : boolean   := true;
  signal   trig_arst_b_i      : std_logic := '0';
  signal   extract_clk_i      : std_logic := '0';
  signal   extract_clk_ena    : boolean   := true;
  signal   extract_arst_b_i   : std_logic := '0';

  -- hwla : trigger domain
  signal   arm_i              : std_logic := '0';
  signal   trigger_i          : std_logic;
  signal   probe_i            : std_logic_vector(C_NB_PROBE-1 downto 0);
  signal   armed_o            : std_logic;
  signal   triggered_o        : std_logic;

  -- hwla to uart_tx_axis
  signal   tdata              : std_logic_vector(7 downto 0);
  signal   tvalid             : std_logic;
  signal   tready             : std_logic;
  signal   tlast              : std_logic;

  -- UART
  signal   baud_tick          : std_logic;
  signal   cfg_baud_tick      : std_logic_vector(16-1 downto 0) := std_logic_vector(to_unsigned(BAUD_TICK_CNT_MAX, 16));
  signal   uart_tx            : std_logic;
  signal   uart_tx_debug      : uart_tx_debug_t;
  signal   terminate_loop     : std_logic := '0';

  -- Monitors
  signal   probe_cnt          : natural := 0;            -- Number of the sample on probe_i
  signal   beats              : byte_array_t;            -- Beats accepted by uart_tx_axis
  signal   nb_beat            : natural := 0;
  signal   nb_trigger         : natural := 0;
  signal   rx_done            : boolean := false;
  signal   ref_done           : boolean := false;

begin

  clock_generator(trig_clk_i   , trig_clk_ena   , C_TRIG_PERIOD   , "Trigger clock");
  clock_generator(extract_clk_i, extract_clk_ena, C_EXTRACT_PERIOD, "Extraction clock");

  -----------------------------------------------------------------------------
  -- HWLA : 8-bit AXI-Stream
  -----------------------------------------------------------------------------
  ins_hwla : hwla
    generic map (
      NB_PROBE         => C_NB_PROBE
     ,DEPTH            => DEPTH
     ,PRE_TRIGGER      => PRE_TRIGGER
     ,TIMESTAMP_WIDTH  => TIMESTAMP_WIDTH
     ,CHANGE_ONLY      => true
     ,TDATA_WIDTH      => 8
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
     ,m_axis_tdata_o   => tdata
     ,m_axis_tvalid_o  => tvalid
     ,m_axis_tready_i  => tready
     ,m_axis_tlast_o   => tlast
    );

  -----------------------------------------------------------------------------
  -- UART transmitter : baud rate generator and uart_tx_axis, no parity
  -----------------------------------------------------------------------------
  ins_uart_baud_rate_gen : uart_baud_rate_gen
    generic map (
      BAUD_TICK_CNT_WIDTH     => 16
    )
    port map (
      clk_i                   => extract_clk_i
     ,arst_b_i                => extract_arst_b_i
     ,baud_tick_en_i          => '1'
     ,baud_tick_o             => baud_tick
     ,baud_tick_half_o        => open
     ,cfg_baud_tick_cnt_max_i => cfg_baud_tick
    );

  ins_uart_tx_axis : uart_tx_axis
    generic map (
      WIDTH                   => 8
    )
    port map (
      clk_i                   => extract_clk_i
     ,arst_b_i                => extract_arst_b_i
     ,s_axis_tdata_i          => tdata
     ,s_axis_tvalid_i         => tvalid
     ,s_axis_tready_o         => tready
     ,uart_tx_o               => uart_tx
     ,uart_cts_b_i            => '0'
     ,baud_tick_i             => baud_tick
     ,parity_enable_i         => '0'
     ,parity_odd_i            => '0'
     ,debug_o                 => uart_tx_debug
    );

  -----------------------------------------------------------------------------
  -- Probes and trigger, reference of the probes
  -----------------------------------------------------------------------------
  probe_i               <= probe_value(probe_cnt);
  trigger_i             <= '1' when probe_i(3 downto 0) = x"C" and probe_i(4) = '1' else
                           '0';

  -- A new sample at each rising edge of trig_clk_i, a reference line for
  -- each change of the probes
  p_probe : process
    file     f_ref    : text open write_mode is FILENAME_REF;
    variable v_line   : line;
    variable v_last   : std_logic_vector(C_NB_PROBE-1 downto 0);
    variable v_first  : boolean := true;
  begin
    wait until rising_edge(trig_clk_i) or ref_done;

    if ref_done
    then
      file_close(f_ref);
      wait;
    end if;

    if v_first or probe_i /= v_last
    then
      write(v_line, string'("s "));
      write(v_line, probe_cnt);
      write(v_line, string'(" "));
      hwrite(v_line, probe_i);
      writeline(f_ref, v_line);
    end if;

    v_first   := false;
    v_last    := probe_i;
    probe_cnt <= probe_cnt + 1;
  end process p_probe;

  -- Trigger sample of each capture, in the reference file after the changes
  -- of the probes (appended at the end of the simulation)
  p_trigger_monitor : process
    type     natural_array_t is array (0 to NB_CAPTURE-1) of natural;
    variable v_trigger : natural_array_t;
    variable v_line    : line;
    file     f_ref     : text;
  begin
    for i in 0 to NB_CAPTURE-1 loop
      wait until rising_edge(triggered_o);
      v_trigger(i) := probe_cnt - 2;
      nb_trigger   <= i + 1;
      log(ID_SEQUENCER, "Capture " & to_string(i) & " : trigger sample " & to_string(v_trigger(i)), C_SCOPE);
    end loop;

    wait until ref_done;
    wait for 1 ns;
    file_open(f_ref, FILENAME_REF, append_mode);
    for i in 0 to NB_CAPTURE-1 loop
      write(v_line, string'("t "));
      write(v_line, v_trigger(i));
      writeline(f_ref, v_line);
    end loop;
    file_close(f_ref);
    wait;
  end process p_trigger_monitor;

  -----------------------------------------------------------------------------
  -- AXI-Stream monitor : beats accepted by uart_tx_axis
  -----------------------------------------------------------------------------
  p_axis_monitor : process
  begin
    wait until rising_edge(extract_clk_i);
    if tvalid = '1' and tready = '1' and nb_beat < C_NB_BYTE
    then
      beats(nb_beat) <= tdata;
      nb_beat        <= nb_beat + 1;
    end if;
  end process p_axis_monitor;

  -----------------------------------------------------------------------------
  -- UART receiver : each byte is the AXI-Stream beat, written in FILENAME_UART
  -----------------------------------------------------------------------------
  p_uart_rx : process
    file     f_uart   : text open write_mode is FILENAME_UART;
    variable v_line   : line;
    variable v_byte   : std_logic_vector(7 downto 0);
    variable v_config : t_uart_bfm_config := C_UART_BFM_CONFIG_DEFAULT;
  begin
    v_config.bit_time      := C_BIT_TIME;
    v_config.parity        := PARITY_NONE;
    v_config.num_stop_bits := STOP_BITS_ONE;
    v_config.timeout       := C_TIMEOUT;

    -- UART line idle after the reset
    wait until extract_arst_b_i = '1';
    wait for C_BIT_TIME;

    for i in 0 to C_NB_BYTE-1 loop
      uart_receive(v_byte, "UART byte " & to_string(i), uart_tx, terminate_loop, v_config, C_SCOPE);
      check_value(i < nb_beat, ERROR, "UART byte " & to_string(i) & " : beat sent to uart_tx_axis", C_SCOPE, ID_NEVER);
      check_value(v_byte, beats(i), ERROR, "UART byte " & to_string(i) & " : AXI-Stream beat", C_SCOPE, HEX, KEEP_LEADING_0, ID_NEVER);
      hwrite(v_line, v_byte);
      writeline(f_uart, v_line);
    end loop;

    file_close(f_uart);
    rx_done <= true;
    wait;
  end process p_uart_rx;

  -----------------------------------------------------------------------------
  -- Sequencer
  -----------------------------------------------------------------------------
  p_main : process
  begin
    disable_log_msg(ID_BFM);  -- One message per UART byte

    trig_arst_b_i    <= '0';
    extract_arst_b_i <= '0';
    wait for 10*C_TRIG_PERIOD + 10*C_EXTRACT_PERIOD;
    wait until falling_edge(trig_clk_i);
    trig_arst_b_i    <= '1';
    wait until falling_edge(extract_clk_i);
    extract_arst_b_i <= '1';

    log(ID_LOG_HDR, "HWLA on a UART : " & to_string(NB_CAPTURE) & " captures of " & to_string(DEPTH) & " samples, " &
                    to_string(C_SAMPLE_BYTES) & " bytes per sample, UART bit " & to_string(C_BIT_TIME), C_SCOPE);

    -- Continuous captures, until the last trigger
    wait until falling_edge(trig_clk_i);
    arm_i <= '1';
    if nb_trigger < NB_CAPTURE
    then
      wait until nb_trigger = NB_CAPTURE for C_TIMEOUT;
    end if;
    check_value(nb_trigger, NB_CAPTURE, ERROR, "All the captures triggered", C_SCOPE);
    wait until falling_edge(trig_clk_i);
    arm_i <= '0';

    -- All the bytes on the UART
    if not rx_done
    then
      wait until rx_done for C_TIMEOUT;
    end if;
    check_value(rx_done, ERROR, "All the bytes received on the UART", C_SCOPE);
    check_value(nb_beat, C_NB_BYTE, ERROR, "Number of AXI-Stream beats", C_SCOPE);

    -- No more capture
    wait for 4*DEPTH*C_SAMPLE_BYTES*C_BIT_TIME/4;
    check_value(nb_beat, C_NB_BYTE, ERROR, "No beat after the last capture", C_SCOPE);
    check_value(armed_o or triggered_o, '0', ERROR, "HWLA idle after the last capture", C_SCOPE);

    ref_done <= true;
    wait for 10*C_TRIG_PERIOD;
    log(ID_LOG_HDR, "Simulation Finished", C_SCOPE);
    report_alert_counters(FINAL);
    std.env.stop;
    wait;
  end process p_main;

end sim;
