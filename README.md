<!--
  README GENERATION INSTRUCTIONS (for the next regeneration run)
  ----------------------------------------------------------------
  This README follows the common Asylum IP model. Regenerate it from the
  sources, never from the previous README text alone.

  Sources of truth (in priority order):
    1. hdl/*.vhd            : entities, generics, ports, packages
    2. hdl/csr/*.hjson      : register map (regtool); *_csr.md/.h are generated
    3. <IP>.core            : VLNV (name), filesets, targets, depends, revisions
    4. mk/targets.txt       : target list shown by `make help`; mk/defs.mk
    5. sim/, syn/, esw/, boards/ : testbenches, constraints, software
  Section order (keep it, same headings in every IP):
    CI badge / Title + one-line description + VLNV / Table of Contents /
    Introduction (Key Features) / Block Diagram / Top-Level (Parameters,
    Ports, Instantiation Example) / HDL Modules / Register Map /
    Verification / Synthesis / Design Notes (optional) /
    Directory Structure / Dependencies
  Rules:
    - Language: English. Tables: Parameters = Name|Type|Default|Description,
      Ports = Name|Direction|Type|Description (grouped by interface).
    - Register Map: link to the generated hdl/csr/<X>_csr.md (plus the
      .hjson source and _csr.h header); never copy register tables here.
    - Top-Level = sbi_* wrapper if present, else the entity used by the
      `default` target, else the main entity (libraries: list packages).
    - Write "This IP has no software-visible registers." / "No dedicated
      synthesis target ..." instead of removing a section.
    - Keep still-accurate hand-written content (ISA tables, results,
      images) in "Design Notes"; drop anything not backed by the sources.
    - Block diagram: doc/<NAME>.drawio (NAME = 4th field of the VLNV),
      top entity box with generics on top, inputs left, outputs right,
      bus interfaces as bold arrows, internal blocks colour-coded
      (CSR yellow, FIFO/memory green, core logic blue, external grey).
      Update it whenever ports/generics/sub-blocks change.
    - Do not edit generated files (hdl/csr/*_csr.*) or the CI badge URL.
-->
[![CI](https://github.com/deuskane/asylum-debug-hwla/actions/workflows/ci.yml/badge.svg)](https://github.com/deuskane/asylum-debug-hwla/actions/workflows/ci.yml)

# asylum-debug-hwla

**Hardware Logic Analyzer without CSR: NB_PROBE probes and a trigger captured in a trigger clock domain, a dual clock RAM, captures sent on an AXI-Stream master in an extraction clock domain. Optional timestamp and storage of the changes only.**

VLNV: `asylum:debug:HWLA:2.0.0`

## Table of Contents

1. [Introduction](#introduction)
2. [Block Diagram](#block-diagram)
3. [Top-Level](#top-level)
4. [HDL Modules](#hdl-modules)
5. [Register Map](#register-map)
6. [Verification](#verification)
7. [Synthesis](#synthesis)
8. [Design Notes](#design-notes)
9. [Directory Structure](#directory-structure)
10. [Dependencies](#dependencies)

## Introduction

This IP is the hardware logic analyzer (HWLA) of the Asylum project. It samples `NB_PROBE` probes and one trigger at each rising edge of the trigger clock, stores a capture of `DEPTH` samples around the trigger (`PRE_TRIGGER` samples before the trigger sample) in a RAM, and sends the capture on an AXI-Stream master interface clocked by another clock. It has no CSR: the configuration is made of generics, a capture is started with the `arm_i` input, and `armed_o` / `triggered_o` give its progress.

A stored sample is a timestamp (`TIMESTAMP_WIDTH` bits, number of clock cycles since the reset) and the probes. With `CHANGE_ONLY = true`, a sample is stored only when the probes change, so a capture of `DEPTH` samples covers a much longer time than `DEPTH` clock cycles. The AXI-Stream can be narrower than a sample (`TDATA_WIDTH`, e.g. 8 bits to drive `uart_tx_axis` directly), and [tools/hwla2vcd.py](tools/hwla2vcd.py) rebuilds a VCD file from the received bytes.

### Key Features

- Two clock domains: trigger part (`trig_clk_i`), extraction part (`extract_clk_i`), simple dual port RAM with one clock per port in between, 4-phase req/ack handshake with `sync2dffrn` synchronizers
- Probes and trigger registered together (input stage): the trigger flag of a sample is always the one of its probes
- `PRE_TRIGGER` stored samples before the trigger sample, `DEPTH - 1 - PRE_TRIGGER` after (0 to `DEPTH - 1` pre-trigger samples); the trigger is ignored until the pre-trigger samples are stored, so the trigger sample is always the sample number `PRE_TRIGGER` of the capture
- Single capture (pulse on `arm_i`) or continuous captures (`arm_i` held high: a new capture after each extraction)
- Timestamp of each stored sample (`TIMESTAMP_WIDTH`, 0 = no timestamp)
- `CHANGE_ONLY = true`: a sample is stored only if the probes changed, and also for the first sample of a capture, for the trigger sample and when the timestamp is 0 (at least one stored sample every `2**TIMESTAMP_WIDTH` clock cycles, so the time between two stored samples is always given by the timestamps)
- AXI-Stream master: one sample per beat (`TDATA_WIDTH = 0`, tdata rounded up to bytes) or `NB_BEAT` beats of `TDATA_WIDTH` bits per sample, from the LSB; `tlast` on the last beat of the capture; full throughput (one beat per clock cycle) with back pressure support
- No capture is started while the previous one is not extracted: the RAM is never written and read at the same time
- [tools/hwla2vcd.py](tools/hwla2vcd.py): VCD file rebuilt from the byte stream (file or serial port)

## Block Diagram

Diagram: [doc/HWLA.drawio](doc/HWLA.drawio) (open with diagrams.net or the VS Code Draw.io extension; `make -C doc` exports `doc/HWLA-Overview.png` with the drawio CLI).

- Trigger domain, `hwla_trigger` ([hdl/hwla_trigger.vhd](hdl/hwla_trigger.vhd)): the input stage registers `probe_i` and `trigger_i`; the timestamp counter counts the clock cycles; the store logic decides if the sample of the input stage is written in the RAM (`CHANGE_ONLY`); the capture FSM (`IDLE`, `FILL`, `ARMED`, `POST`, `DUMP`, `DUMP_END`) handles `arm_i`, the pre / post-trigger samples and the request to the extraction domain; the write address wraps around the RAM (circular buffer).
- `hwla_ram` ([hdl/hwla_ram.vhd](hdl/hwla_ram.vhd)): `DEPTH` words of `TIMESTAMP_WIDTH + NB_PROBE` bits, write port in the trigger domain, synchronous read port in the extraction domain.
- Extraction domain, `hwla_extract` ([hdl/hwla_extract.vhd](hdl/hwla_extract.vhd)): on the synchronized request, the extraction FSM (`IDLE`, `DUMP`, `ACK`) reads the `DEPTH` samples from the oldest one (`dump_addr`), and the beat logic sends each sample in `NB_BEAT` beats on the AXI-Stream; at the end of the capture, the acknowledge goes back to the trigger domain.

## Top-Level

Top-level entity: **`hwla`** ([hdl/hwla.vhd](hdl/hwla.vhd)), library `asylum`, component declared in `asylum.hwla_pkg`.

### Parameters

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `NB_PROBE` | positive | `8` | Number of probes |
| `DEPTH` | positive | `256` | Number of stored samples of a capture (power of 2, at least 2): depth of the RAM |
| `PRE_TRIGGER` | natural | `128` | Number of stored samples before the trigger sample (0 to `DEPTH - 1`) |
| `TIMESTAMP_WIDTH` | natural | `16` | Width of the timestamp of a sample (0: no timestamp) |
| `CHANGE_ONLY` | boolean | `true` | `true`: a sample is stored only if the probes changed (and for the first sample, the trigger sample, the timestamp 0); `false`: every sample is stored |
| `TDATA_WIDTH` | natural | `0` | Width of `m_axis_tdata_o` (multiple of 8); 0: one beat per sample, `tdata` is the sample rounded up to an integer number of bytes |

Derived values (functions of `asylum.hwla_pkg`): sample width `hwla_sample_width(NB_PROBE, TIMESTAMP_WIDTH) = NB_PROBE + TIMESTAMP_WIDTH`, tdata width `hwla_tdata_width(sample width, TDATA_WIDTH)`, number of beats per sample `hwla_nb_beat(sample width, TDATA_WIDTH)`.

### Ports

#### Trigger domain

| Name | Direction | Type | Description |
|------|-----------|------|-------------|
| `trig_clk_i` | in | std_logic | Trigger clock: the probes are sampled at each rising edge |
| `trig_arst_b_i` | in | std_logic | Asynchronous reset of the trigger domain, active low |
| `arm_i` | in | std_logic | 1: start a capture (taken into account when the HWLA is idle). Pulse: one capture; held high: a new capture after each extraction |
| `trigger_i` | in | std_logic | Trigger condition, active high (level) |
| `probe_i` | in | std_logic_vector(NB_PROBE-1 downto 0) | Probed signals (synchronous to `trig_clk_i`) |
| `armed_o` | out | std_logic | 1: capture started, trigger not yet seen (pre-trigger samples, then wait for the trigger) |
| `triggered_o` | out | std_logic | 1: trigger seen, capture not yet extracted (post-trigger samples, extraction) |

#### Extraction domain (AXI-Stream master)

| Name | Direction | Type | Description |
|------|-----------|------|-------------|
| `extract_clk_i` | in | std_logic | Extraction clock (AXI-Stream clock) |
| `extract_arst_b_i` | in | std_logic | Asynchronous reset of the extraction domain, active low |
| `m_axis_tdata_o` | out | std_logic_vector(hwla_tdata_width(...)-1 downto 0) | Beat of a sample (see [Stream Format](#stream-format)) |
| `m_axis_tvalid_o` | out | std_logic | Beat valid |
| `m_axis_tready_i` | in | std_logic | Beat accepted by the slave |
| `m_axis_tlast_o` | out | std_logic | Last beat of the capture |

### Instantiation Example

HWLA on a UART: 8 probes, 1024 samples, 16-bit timestamp, captures sent byte per byte to `uart_tx_axis` (see [sim/uart/tb_hwla_uart.vhd](sim/uart/tb_hwla_uart.vhd)).

```vhdl
library asylum;
use     asylum.hwla_pkg.all;

  ins_hwla : hwla
    generic map
    ( NB_PROBE         => 8
     ,DEPTH            => 1024
     ,PRE_TRIGGER      => 256
     ,TIMESTAMP_WIDTH  => 16
     ,CHANGE_ONLY      => true
     ,TDATA_WIDTH      => 8
    )
    port map
    ( trig_clk_i       => clk_design
     ,trig_arst_b_i    => arst_b_design
     ,arm_i            => '1'               -- continuous captures
     ,trigger_i        => my_trigger
     ,probe_i          => my_probes
     ,armed_o          => led_armed
     ,triggered_o      => led_triggered
     ,extract_clk_i    => clk_uart
     ,extract_arst_b_i => arst_b_uart
     ,m_axis_tdata_o   => uart_tdata
     ,m_axis_tvalid_o  => uart_tvalid
     ,m_axis_tready_i  => uart_tready
     ,m_axis_tlast_o   => open
    );
```

## HDL Modules

| File | Unit | Kind | Role |
|------|------|------|------|
| [hdl/hwla_pkg.vhd](hdl/hwla_pkg.vhd) | `hwla_pkg` | package | Functions `hwla_sample_width`, `hwla_tdata_width`, `hwla_nb_beat`; component declarations |
| [hdl/hwla.vhd](hdl/hwla.vhd) | `hwla` | entity | Top-level: `hwla_trigger` + `hwla_ram` + `hwla_extract` |
| [hdl/hwla_trigger.vhd](hdl/hwla_trigger.vhd) | `hwla_trigger` | entity | Trigger domain: input stage, timestamp, store logic (`CHANGE_ONLY`), capture FSM, RAM write port, request to the extraction domain, synchronizer of the acknowledge |
| [hdl/hwla_ram.vhd](hdl/hwla_ram.vhd) | `hwla_ram` | entity | Simple dual port RAM, write port clocked by `wclk_i`, synchronous read port clocked by `rclk_i` (read data held while `re_i = 0`), no reset |
| [hdl/hwla_extract.vhd](hdl/hwla_extract.vhd) | `hwla_extract` | entity | Extraction domain: synchronizer of the request, extraction FSM, RAM read port, beats of the AXI-Stream master, acknowledge |

## Register Map

This IP has no software-visible registers: the configuration is made of generics, the control and the status are the ports `arm_i`, `armed_o` and `triggered_o`.

## Verification

### Testbenches

| File | DUT | Description |
|------|-----|-------------|
| [sim/basic/tb_hwla.vhd](sim/basic/tb_hwla.vhd) | `hwla` | UVVM testbench, self-checking, generic (configuration of the HWLA, periods of the two asynchronous clocks, and `TEST`: one test per simulation, see [Tests](#tests)). The captures are received with the UVVM AXI-Stream BFM (`bitvis_vip_axistream`). A history records the probes and the trigger of each sample as sampled by the HWLA, and a model computes from it the samples stored by each capture (store rules, pre / post-trigger samples, trigger sample); every received sample is checked against the timestamp and the probes of its expected sample. Monitors: first sample of each capture (rise of `armed_o`), AXI-Stream protocol (tvalid, tdata, tlast held while tready = 0, tlast only with tvalid, `DEPTH x NB_BEAT` beats per capture). Probes: COUNT (a change at each sample), SPARSE (a change every 4 samples on average), FROZEN, FORCE. A test not applicable to the generics is an error |
| [sim/uart/tb_hwla_uart.vhd](sim/uart/tb_hwla_uart.vhd) | `hwla` + `uart_tx_axis` | UVVM testbench of the HWLA (`TDATA_WIDTH = 8`, generics `DEPTH`, `PRE_TRIGGER`, `TIMESTAMP_WIDTH`, `CHANGE_ONLY`) connected to `uart_baud_rate_gen` and `uart_tx_axis` of asylum-communication-uart (no CSR). 8 probes (counter, toggle, pulse, slow value), trigger on a value of the probes, 2 continuous captures. The UART line is received with the UVVM UART BFM (`bitvis_vip_uart`), each byte is checked against the AXI-Stream beat and written in `hwla_uart.hex`; the testbench also writes the reference `hwla_uart_ref.txt` (changes of the probes, trigger samples) and the arguments of the scripts from its generics (`hwla2vcd.args`, `check_vcd.args`). The `post_run` hooks rebuild the VCD files with `tools/hwla2vcd.py` and check them sample by sample with [sim/uart/check_vcd.py](sim/uart/check_vcd.py) |

### Targets

| Target | Toplevel | Description |
|--------|----------|-------------|
| `default` | `hwla` | HDL fileset (not a simulation) |
| `sim_<configuration>_<test>` | `tb_hwla` | One test of `tb_hwla` on one configuration of the HWLA (61 targets), see [Tests](#tests) |
| `sim_uart` | `tb_hwla_uart` | HWLA on `uart_tx_axis`, 32 samples, 8 pre-trigger samples, 16-bit timestamp, changes only (3 bytes per sample), then VCD rebuilt by `tools/hwla2vcd.py` and checked (`post_run` hooks) |
| `sim_uart_no_timestamp` | `tb_hwla_uart` | Same, 64 samples, 16 pre-trigger samples, no timestamp, every sample stored (1 byte per sample) |
| `lint_ghdl` | `hwla_synth_top` | Lint: GHDL `-Wall` analysis and elaboration (empty simulation) of `hwla` in the wrapper `syn/ghdl/hwla_synth_top.vhd` (work library) |
| `lint_ghdl_synth_default` | `hwla_synth_top` | Synthesis check (see below), default generics |
| `lint_ghdl_synth_pre_trigger_0` | `hwla_synth_top` | Synthesis check, `PRE_TRIGGER = 0` |
| `lint_ghdl_synth_pre_trigger_max` | `hwla_synth_top` | Synthesis check, `PRE_TRIGGER = 255` (no post-trigger sample) |
| `lint_ghdl_synth_all_samples` | `hwla_synth_top` | Synthesis check, `TIMESTAMP_WIDTH = 0`, `CHANGE_ONLY = false` |
| `lint_ghdl_synth_uart` | `hwla_synth_top` | Synthesis check, `TDATA_WIDTH = 8` (3 beats per sample) |
| `lint_ghdl_synth_min` | `hwla_synth_top` | Synthesis check, smallest configuration: 1 probe, 2 samples, no timestamp |

### Tests

`tb_hwla` runs one test per simulation (generic `TEST`), and each test runs on each configuration where it applies: target `sim_<configuration>_<test>` (for example `sim_basic_capture`, `sim_pre_trigger_max_frozen`). The parameters of a target are the configuration and the test.

| Configuration | NB_PROBE | DEPTH | PRE_TRIGGER | TIMESTAMP_WIDTH | CHANGE_ONLY | TDATA_WIDTH | Trigger / extraction clock |
|---------------|----------|-------|-------------|-----------------|-------------|-------------|----------------------------|
| `basic` | 12 | 32 | 10 | 16 | true | 0 (one 32-bit beat) | 10 ns / 18 ns |
| `pre_trigger_0` | 8 | 16 | 0 | 8 | true | 8 (2 beats) | 26 ns / 8 ns |
| `pre_trigger_max` | 33 | 64 | 63 (no post-trigger sample) | 4 (frequent wraps) | true | 16 (3 beats) | 6 ns / 34 ns |
| `same_period` | 16 | 128 | 64 | 0 | false (as the version 1.0.0) | 0 (one 16-bit beat) | 10 ns / 10 ns |
| `all_samples` | 8 | 32 | 16 | 16 | false | 32 (padding in the beat) | 14 ns / 10 ns |

| Test (`TEST`) | Description | Configurations |
|---------------|-------------|----------------|
| `reset_values` | Outputs after the reset | all |
| `not_armed` | Trigger ignored while not armed: no capture, no beat | all |
| `capture` | Single capture, trigger 7 samples after the pre-trigger samples | all |
| `pre_trigger_ignored` | Triggers during the pre-trigger samples ignored: last pre-trigger sample ignored, next one taken (`PRE_TRIGGER >= 3`) | all except `pre_trigger_0` |
| `level_trigger` | Level trigger already high at the arm: trigger sample = first sample after the pre-trigger samples | all |
| `late_trigger` | Trigger after 3 turns of the circular buffer | all |
| `back_pressure` | Random back pressure (tready low before random beats) | all |
| `stall` | Long stall: beat held, `arm_i` and trigger ignored until the end of the extraction, no capture afterwards | all |
| `continuous` | 3 continuous captures with `arm_i` held high, no capture after `arm_i` low | all |
| `sparse` | Sparse probes (a change every 4 samples on average), level trigger: often a trigger sample without change | all |
| `frozen` | Frozen probes: samples stored at the timestamp 0 only (`2**TIMESTAMP_WIDTH <= 64` or `CHANGE_ONLY = false`) | `pre_trigger_max`, `same_period`, `all_samples` |
| `first_sample` | First sample of a capture equal to the last stored sample of the previous capture: stored anyway (`PRE_TRIGGER > 0`) | all except `pre_trigger_0` |
| `async_reset` | Asynchronous reset during an extraction: capture lost, new capture afterwards (new origin of the timestamp) | all |

A `lint_ghdl_synth_*` target is `lint_ghdl` with the generics of its configuration (FuseSoC `parameters`) and a `pre_run` hook, `syn/ghdl/ghdl_synth.sh`, which adds `include ghdl_synth.mk` to the Makefile generated by edalize. The run step (`make run EXTRA_OPTIONS=<generics>`) then runs, in the build directory:

1. `ghdl --synth` of the toplevel (rule `ghdl_synth` of [syn/ghdl/ghdl_synth.mk](syn/ghdl/ghdl_synth.mk)), with the options of the target: `STD`, `ANALYZE_OPTIONS` (`-Wall`), `TOPLEVEL_LIBS`, `TOPLEVEL` and the generics. It writes `hwla_synth_top_synth.vhd` (netlist) and `hwla_synth_top_synth.log`, prints the warnings, and fails on a synthesis error (an inferred latch is one);
2. `ghdl -r --no-run`: elaboration with the same generics, without simulation.

To add a configuration, add a target with its `parameters` (the generics are declared in the `parameters` section of `HWLA.core`).

### How to Run

The default tool is GHDL (`mk/defs.mk`: `TOOL ?= ghdl`, `TARGET ?= sim_basic_capture`).

```bash
make help                 # variables, rules and target list (mk/targets.txt)
make sim_basic_capture    # run one target (log in log/)
make nonreg_sim           # run every sim_* target (TARGETS_FILTER=<regex> to select, e.g. TARGETS_FILTER=^sim_basic_)
make lint_ghdl            # GHDL -Wall lint (make nonreg_lint: every lint_* target)
make lint_ghdl_synth_default   # GHDL -Wall lint + ghdl --synth -Wall check of one configuration
make clean                # remove build/
```

Equivalent FuseSoC command:

```bash
fusesoc --cores-root . run --build-root build --target sim_basic_capture asylum:debug:HWLA:2.0.0
```

Outside CI, GHDL writes a waveform `dut.fst`. `sim_uart*` also leave `hwla_uart.hex`, `hwla_uart_ref.txt`, `hwla2vcd.args`, `check_vcd.args` and the rebuilt `hwla_uart_0.vcd`, `hwla_uart_1.vcd` in their build directory. CI ([.github/workflows/ci.yml](.github/workflows/ci.yml)) runs every `sim_*` target.

## Synthesis

No vendor synthesis target (the `lint_ghdl_synth_*` targets check the RTL with `ghdl --synth`, see [Targets](#targets)). The HDL sources of the `default` target contain no simulation-only construct (the generic checks are in `pragma translate_off` blocks). `hwla_ram` is a simple dual port RAM with one clock per port and a registered read: it is inferred as a block RAM (`ghdl --synth` infers one memory of `DEPTH x (TIMESTAMP_WIDTH + NB_PROBE)` bits, write port on `trig_clk_i`, read port on `extract_clk_i`). Besides the RAM, the trigger part has about `2 x NB_PROBE + TIMESTAMP_WIDTH + 2 x log2(DEPTH) + 8` flip-flops (input stage, last stored probes, timestamp, write address, counter, FSM, request, synchronizer) and the extraction part about `2 x log2(DEPTH) + log2(NB_BEAT) + 8` flip-flops plus the RAM output register.

Constraints for the clock domain crossings:

- `sync2dffrn` (asylum-target-techmap): 2-flip-flop synchronizers of `dump_req` and `dump_ack` (mark them `ASYNC_REG` or the vendor equivalent);
- `dump_addr` (trigger domain register, read by the extraction domain) is quasi-static: stable from the rise of `dump_req` to the fall of `dump_ack`; constrain it with a max delay (one period of `extract_clk_i`) or a false path;
- the RAM contents are written by the trigger domain and read by the extraction domain, never at the same time (block RAM: no constraint; distributed RAM: same as `dump_addr`).

## Design Notes

### Capture

- `IDLE`: nothing is recorded. When `arm_i = 1`, the capture starts with the sample of this rising edge (`armed_o` rises just after it).
- `FILL`: the `PRE_TRIGGER` first stored samples; the trigger is ignored (skipped when `PRE_TRIGGER = 0`).
- `ARMED`: the samples are stored in the circular buffer until the trigger: the first sample with `trigger_i = 1` is the trigger sample. `triggered_o` rises one clock cycle after the rising edge that sampled it.
- `POST`: the `DEPTH - 1 - PRE_TRIGGER` stored samples after the trigger sample (skipped when the post-trigger part is empty).
- `DUMP`, `DUMP_END`: request to the extraction domain, wait for the acknowledge and its fall (4-phase handshake), then `IDLE`. `arm_i` and the trigger are ignored until `IDLE`.

The trigger is a level: tie `trigger_i` to a combination of the probes, or to an edge detector of the user design. With a trigger already high when the capture starts, the trigger sample is the first sample after the pre-trigger samples. The two resets should be asserted together: a reset of one domain alone during a handshake is not supported.

### Stored Samples

With `CHANGE_ONLY = false`, every sample is stored: a capture is `DEPTH` consecutive clock cycles. With `CHANGE_ONLY = true`, a sample is stored when:

- its probes are different from the last stored sample,
- it is the first sample of the capture (initial value of the probes),
- it is the trigger sample (even without change),
- its timestamp is 0 (`TIMESTAMP_WIDTH > 0`): at least one stored sample every `2**TIMESTAMP_WIDTH` clock cycles.

The timestamp is the number of clock cycles since the reset, modulo `2**TIMESTAMP_WIDTH` (the sample of the first rising edge after the reset has the timestamp 0). The number of clock cycles between two consecutive stored samples is the difference of their timestamps modulo `2**TIMESTAMP_WIDTH`, where 0 means `2**TIMESTAMP_WIDTH`. With `CHANGE_ONLY = true` and very quiet probes, the pre-trigger and the post-trigger parts take up to `2**TIMESTAMP_WIDTH` clock cycles per stored sample; `CHANGE_ONLY = true` without timestamp loses the time between the stored samples.

### Stream Format

The captures are sent one after the other, a capture is `DEPTH` samples from the oldest one; the trigger sample is the sample number `PRE_TRIGGER`. A sample is `{timestamp, probes}` (probes on the `NB_PROBE` LSB), padded with 0 to `NB_BEAT x tdata width` bits, and sent in `NB_BEAT` beats from the LSB. `tlast` is set with the last beat of the capture. Example with 8 probes, a 16-bit timestamp and `TDATA_WIDTH = 8`: 3 bytes per sample, `probes`, `timestamp(7:0)`, `timestamp(15:8)`.

The first beat of a capture is sent a few clock cycles of `extract_clk_i` after the end of the capture (synchronization of the request), then one beat per clock cycle while `m_axis_tready_i = 1`. A beat is held while `m_axis_tready_i = 0`.

### VCD File (tools/hwla2vcd.py)

[tools/hwla2vcd.py](tools/hwla2vcd.py) (Python 3, no dependency; `pyserial` for `--port`) rebuilds a VCD file per capture from the byte stream: time 0 is the first sample of the capture, the probes (one wire per probe, or one bus with `--bus`) and a `trigger` wire, high during the clock cycle of the trigger sample. The parameters are the generics of the HWLA and the period of the trigger clock.

```bash
# Bytes received on a UART and saved in a file (Linux)
stty -F /dev/ttyUSB0 115200 raw -echo
cat /dev/ttyUSB0 > capture.bin
python3 tools/hwla2vcd.py capture.bin -n 8 -d 1024 -p 256 -t 16 -w 8 --period 20 --names valid,ready,d0,d1,d2,d3,d4,d5 -o capture.vcd

# Or read one capture directly on the serial port
python3 tools/hwla2vcd.py --port /dev/ttyUSB0 --baudrate 115200 --captures 1 -n 8 -d 1024 -p 256 -t 16 -w 8 --period 20 -o capture.vcd

gtkwave capture.vcd
```

`--format hex` reads a text file of hexadecimal bytes (as written by `tb_hwla_uart`), `--capture N` writes only the capture `N`. With several captures, the files are `<output>_<n>.vcd`. `--args-file FILE` (or `@FILE`) reads arguments from a file, one per line: for example the configuration of a HWLA (`--nb-probe`, `--depth`, ...), as `tb_hwla_uart` writes it in `hwla2vcd.args`.

## Directory Structure

```
asylum-debug-hwla/
├── HWLA.core               # FuseSoC core (asylum:debug:HWLA)
├── Makefile                # Common Asylum Makefile (FuseSoC wrapper)
├── mk/
│   ├── defs.mk             # FILE_CORE, default TARGET and TOOL
│   └── targets.txt         # Target list (generated from the .core)
├── .github/workflows/
│   └── ci.yml              # CI jobs (generated by make ci_generate)
├── doc/
│   ├── HWLA.drawio         # Block diagram
│   └── Makefile            # PNG export (drawio CLI)
├── hdl/
│   ├── hwla_pkg.vhd
│   ├── hwla.vhd
│   ├── hwla_trigger.vhd
│   ├── hwla_ram.vhd
│   └── hwla_extract.vhd
├── sim/
│   ├── basic/              # tb_hwla.vhd (UVVM, AXI-Stream BFM)
│   └── uart/               # tb_hwla_uart.vhd (UVVM, UART BFM), check_vcd.py (post_run hook of sim_uart*)
├── syn/ghdl/
│   ├── hwla_synth_top.vhd  # Lint / synthesis check top (hwla in the work library)
│   ├── ghdl_synth.sh       # pre_run hook of lint_ghdl_synth_*: includes ghdl_synth.mk in the edalize Makefile
│   └── ghdl_synth.mk       # ghdl_synth rule (ghdl --synth with the options of the target), prerequisite of run
└── tools/
    └── hwla2vcd.py         # VCD file rebuilt from the byte stream of the HWLA
```

## Dependencies

| Core | Used by (fileset) | Purpose |
|------|-------------------|---------|
| `asylum:utils:pkg` | `hdl` | Common packages (`math_pkg`: `log2`, `is_pow2`) |
| `asylum:target:techmap` | `hdl` | `sync2dffrn` synchronizers (`techmap_pkg`) |
| `bitvis:verification:uvvm` | `sim_basic`, `sim_uart` | UVVM utility library, AXI-Stream and UART VIP (testbench only) |
| `asylum:communication:uart` | `sim_uart` | `uart_tx_axis` and `uart_baud_rate_gen` (testbench only) |
