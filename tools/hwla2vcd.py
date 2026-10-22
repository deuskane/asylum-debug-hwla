#!/usr/bin/env python3
#-----------------------------------------------------------------------------
# Title      : hwla2vcd
# Project    : Asylum
#-----------------------------------------------------------------------------
# File       : hwla2vcd.py
# Author     : mrosiere
#-----------------------------------------------------------------------------
# Description: Rebuild a VCD file from the content of the HWLA, as sent by
#              its AXI-Stream master interface : for example on a UART with
#              uart_tx_axis (TDATA_WIDTH = 8), saved in a file or read on a
#              serial port.
#              Byte stream : the captures one after the other.
#              * A capture is DEPTH stored samples, from the oldest. The
#                trigger sample is the sample PRE_TRIGGER.
#              * A sample is NB_BEAT beats of TDATA_WIDTH bits, from the LSB,
#                and the bytes of a beat are from the LSB (tdata(7:0) first).
#              * A sample is the probes (NB_PROBE LSB) and the timestamp
#                (TIMESTAMP_WIDTH bits above).
#              Time : with a timestamp, the number of clock cycles between
#              two stored samples is the difference of their timestamps
#              modulo 2**TIMESTAMP_WIDTH (0 means 2**TIMESTAMP_WIDTH : the
#              HWLA stores at least one sample every 2**TIMESTAMP_WIDTH clock
#              cycles). Without timestamp, the samples are consecutive
#              (CHANGE_ONLY = false).
#              VCD : time 0 is the first sample of the capture, the probes
#              (one wire per probe or one bus) and a "trigger" wire, high
#              during the clock cycle of the trigger sample. One VCD file
#              per capture (<output>_<n>.vcd when there are several).
#-----------------------------------------------------------------------------
# Copyright (c) 2026
#-----------------------------------------------------------------------------
# Revisions  :
# Date        Version  Author   Description
# 2026-10-22  1.0      mrosiere Created
#-----------------------------------------------------------------------------

import argparse
import os
import sys
from dataclasses import dataclass


#=============================================================================
# Configuration of the HWLA
#=============================================================================
@dataclass
class HwlaConfig:
    nb_probe        : int
    depth           : int
    pre_trigger     : int
    timestamp_width : int
    tdata_width     : int     # 0 : one beat per sample

    @property
    def sample_width(self):
        """Width of a stored sample : timestamp and probes"""
        return self.nb_probe + self.timestamp_width

    @property
    def beat_width(self):
        """Width of tdata (hwla_tdata_width)"""
        if self.tdata_width == 0:
            return 8 * ((self.sample_width + 7) // 8)
        return self.tdata_width

    @property
    def nb_beat(self):
        """Number of beats of a sample (hwla_nb_beat)"""
        return (self.sample_width + self.beat_width - 1) // self.beat_width

    @property
    def sample_bytes(self):
        """Number of bytes of a sample in the byte stream"""
        return self.nb_beat * self.beat_width // 8

    @property
    def capture_bytes(self):
        """Number of bytes of a capture in the byte stream"""
        return self.depth * self.sample_bytes

    def check(self):
        if self.nb_probe < 1:
            raise ValueError("NB_PROBE must be at least 1")
        if self.depth < 2 or self.depth & (self.depth - 1):
            raise ValueError("DEPTH must be a power of 2, at least 2")
        if not 0 <= self.pre_trigger < self.depth:
            raise ValueError("PRE_TRIGGER must be in 0 to DEPTH-1")
        if self.timestamp_width < 0:
            raise ValueError("TIMESTAMP_WIDTH must be positive or 0")
        if self.tdata_width < 0 or self.tdata_width % 8:
            raise ValueError("TDATA_WIDTH must be 0 or a multiple of 8")


#=============================================================================
# Decoding
#=============================================================================
@dataclass
class Sample:
    probes    : int
    timestamp : int
    time      : int = 0       # Clock cycles from the first sample of the capture


def read_input(args):
    """Bytes of the input : binary file, text file of hexadecimal bytes, or serial port"""
    if args.port:
        try:
            import serial
        except ImportError:
            sys.exit("hwla2vcd : --port needs pyserial (pip install pyserial)")
        cfg  = config_from_args(args)
        size = cfg.capture_bytes * args.captures
        with serial.Serial(args.port, args.baudrate, timeout=args.timeout) as port:
            data = port.read(size)
        if len(data) < size:
            print(f"hwla2vcd : warning, {len(data)} bytes received on {args.port}, {size} expected", file=sys.stderr)
        return data

    if args.input == "-":
        raw = sys.stdin.buffer.read()
    else:
        with open(args.input, "rb") as f:
            raw = f.read()

    if args.format == "hex":
        # Hexadecimal bytes separated by spaces or new lines, # starts a comment
        data = bytearray()
        for line in raw.decode("ascii").splitlines():
            for word in line.split("#")[0].split():
                data.append(int(word, 16))
        return bytes(data)
    return raw


def decode_captures(data, cfg):
    """Split the byte stream in captures, a capture is a list of DEPTH samples"""
    nb_capture = len(data) // cfg.capture_bytes
    rest       = len(data) %  cfg.capture_bytes
    if rest:
        print(f"hwla2vcd : warning, {rest} bytes at the end of the stream ignored (incomplete capture)", file=sys.stderr)

    probe_mask = (1 << cfg.nb_probe) - 1
    ts_mask    = (1 << cfg.timestamp_width) - 1
    captures   = []
    for c in range(nb_capture):
        samples = []
        for s in range(cfg.depth):
            offset = c * cfg.capture_bytes + s * cfg.sample_bytes
            word   = int.from_bytes(data[offset:offset + cfg.sample_bytes], "little")
            samples.append(Sample(probes    = word & probe_mask,
                                  timestamp = (word >> cfg.nb_probe) & ts_mask))
        compute_times(samples, cfg)
        captures.append(samples)
    return captures


def compute_times(samples, cfg):
    """Time of each sample, in clock cycles from the first sample"""
    period = 1 << cfg.timestamp_width
    for prev, cur in zip(samples, samples[1:]):
        if cfg.timestamp_width:
            delta = (cur.timestamp - prev.timestamp) % period
            if delta == 0:
                delta = period
        else:
            delta = 1
        cur.time = prev.time + delta


#=============================================================================
# VCD
#=============================================================================
def vcd_id(index):
    """Short VCD identifier of the variable number index"""
    chars = [chr(c) for c in range(33, 127)]
    ident = ""
    index += 1
    while index:
        index, r = divmod(index - 1, len(chars))
        ident = chars[r] + ident
    return ident


def write_vcd(path, samples, cfg, names, bus, period_ps, comment):
    """VCD of a capture : probes and trigger, time 0 is the first sample"""
    trig_time = samples[cfg.pre_trigger].time

    with open(path, "w") as f:
        f.write(f"$comment\n  {comment}\n$end\n")
        f.write("$timescale 1ps $end\n")
        f.write("$scope module hwla $end\n")
        f.write(f"$var wire 1 {vcd_id(0)} trigger $end\n")
        if bus:
            f.write(f"$var wire {cfg.nb_probe} {vcd_id(1)} {bus} [{cfg.nb_probe-1}:0] $end\n")
        else:
            for i, name in enumerate(names):
                f.write(f"$var wire 1 {vcd_id(i+1)} {name} $end\n")
        f.write("$upscope $end\n$enddefinitions $end\n")

        def dump_probes(value, prev):
            """VCD lines of the probes that changed"""
            lines = []
            if bus:
                if prev is None or value != prev:
                    lines.append(f"b{value:0{cfg.nb_probe}b} {vcd_id(1)}")
            else:
                for i in range(cfg.nb_probe):
                    bit = (value >> i) & 1
                    if prev is None or bit != (prev >> i) & 1:
                        lines.append(f"{bit}{vcd_id(i+1)}")
            return lines

        # Events : (time in clock cycles, probes or None, trigger or None)
        events = {}
        for s in samples:
            events.setdefault(s.time, [None, None])[0] = s.probes
        events.setdefault(trig_time    , [None, None])[1] = 1
        events.setdefault(trig_time + 1, [None, None])[1] = 0

        # Time 0 (first sample) : initial values, then the changes only
        prev = None
        for t in sorted(events):
            probes, trig = events[t]
            lines = []
            if t == 0 or trig is not None:
                lines.append(f"{trig or 0}{vcd_id(0)}")
            if probes is not None:
                lines += dump_probes(probes, prev)
                prev = probes
            if t == 0:
                f.write("#0\n$dumpvars\n" + "\n".join(lines) + "\n$end\n")
            elif lines:
                f.write(f"#{t * period_ps}\n" + "\n".join(lines) + "\n")
        # End of the capture : one clock cycle after the last sample
        f.write(f"#{(max(events) + 1) * period_ps}\n")


#=============================================================================
# Main
#=============================================================================
def config_from_args(args):
    cfg = HwlaConfig(nb_probe        = args.nb_probe,
                     depth           = args.depth,
                     pre_trigger     = args.pre_trigger,
                     timestamp_width = args.timestamp_width,
                     tdata_width     = args.tdata_width)
    cfg.check()
    return cfg


def main(argv=None):
    parser = argparse.ArgumentParser(description="Rebuild a VCD file from the content of the HWLA (byte stream of its AXI-Stream, e.g. received on a UART)")
    parser.add_argument("input", nargs="?", default="-", help="Input file (- : standard input), ignored with --port")
    parser.add_argument("-o", "--output", help="Output VCD file (default : input with .vcd), <output>_<n>.vcd per capture when there are several")
    parser.add_argument("-f", "--format", choices=["bin", "hex"], default="bin", help="Input format : raw bytes (default) or text of hexadecimal bytes")
    parser.add_argument("--port", help="Read the captures on a serial port (pyserial) instead of a file")
    parser.add_argument("--baudrate", type=int, default=115200, help="Baud rate of the serial port (default : 115200)")
    parser.add_argument("--captures", type=int, default=1, help="Number of captures to read on the serial port (default : 1)")
    parser.add_argument("--timeout", type=float, default=10.0, help="Timeout of the serial port, in s (default : 10)")
    parser.add_argument("-n", "--nb-probe", type=int, required=True, help="NB_PROBE of the HWLA")
    parser.add_argument("-d", "--depth", type=int, required=True, help="DEPTH of the HWLA")
    parser.add_argument("-p", "--pre-trigger", type=int, required=True, help="PRE_TRIGGER of the HWLA")
    parser.add_argument("-t", "--timestamp-width", type=int, default=16, help="TIMESTAMP_WIDTH of the HWLA (default : 16)")
    parser.add_argument("-w", "--tdata-width", type=int, default=8, help="TDATA_WIDTH of the HWLA (default : 8, as for uart_tx_axis)")
    parser.add_argument("--period", type=float, default=10.0, help="Period of the trigger clock in ns (default : 10)")
    parser.add_argument("--names", help="Names of the probes, from probe 0, separated by commas")
    parser.add_argument("--bus", help="Dump the probes as one bus with this name, instead of one wire per probe")
    parser.add_argument("--capture", type=int, help="Write only the capture number CAPTURE (from 0)")
    args = parser.parse_args(argv)

    try:
        cfg = config_from_args(args)
    except ValueError as e:
        parser.error(str(e))

    names = [f"probe{i}" for i in range(cfg.nb_probe)]
    if args.names:
        given = [n.strip() for n in args.names.split(",")]
        if len(given) > cfg.nb_probe:
            parser.error(f"--names : {len(given)} names for {cfg.nb_probe} probes")
        names[:len(given)] = given

    captures = decode_captures(read_input(args), cfg)
    if not captures:
        sys.exit("hwla2vcd : no complete capture in the input")

    if args.output:
        base = os.path.splitext(args.output)[0]
    elif args.port or args.input == "-":
        base = "hwla"
    else:
        base = os.path.splitext(args.input)[0]

    selected = range(len(captures)) if args.capture is None else [args.capture]
    period_ps = round(args.period * 1000)
    for n in selected:
        if n >= len(captures):
            sys.exit(f"hwla2vcd : capture {n} not in the input ({len(captures)} captures)")
        samples = captures[n]
        path    = f"{base}.vcd" if len(selected) == 1 else f"{base}_{n}.vcd"
        comment = (f"hwla2vcd : capture {n}, NB_PROBE {cfg.nb_probe}, DEPTH {cfg.depth}, PRE_TRIGGER {cfg.pre_trigger}, "
                   f"TIMESTAMP_WIDTH {cfg.timestamp_width}, TDATA_WIDTH {cfg.tdata_width}, period {args.period} ns")
        write_vcd(path, samples, cfg, names, args.bus, period_ps, comment)
        print(f"hwla2vcd : capture {n} : {cfg.depth} samples, {samples[-1].time + 1} clock cycles, "
              f"trigger at the clock cycle {samples[cfg.pre_trigger].time} -> {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
