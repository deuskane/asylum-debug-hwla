#!/usr/bin/env python3
#-----------------------------------------------------------------------------
# Title      : check_vcd
# Project    : Asylum
#-----------------------------------------------------------------------------
# File       : check_vcd.py
# Author     : mrosiere
#-----------------------------------------------------------------------------
# Description: post_run hook of sim_uart : checks the VCD files rebuilt by
#              hwla2vcd.py (--bus probe) from the UART bytes of tb_hwla_uart
#              against the reference written by the testbench :
#              * "s <sample> <probes>" : the probes change at this sample
#              * "t <sample>"          : trigger sample of a capture (in order)
#              The trigger of a VCD file is aligned on the trigger sample of
#              its capture, then the probes of the VCD are compared with the
#              reference at each sample of the capture, from its first stored
#              sample to its last one.
#-----------------------------------------------------------------------------
# Copyright (c) 2026
#-----------------------------------------------------------------------------
# Revisions  :
# Date        Version  Author   Description
# 2026-10-22  1.0      mrosiere Created
#-----------------------------------------------------------------------------

import argparse
import bisect
import sys


def read_ref(path):
    """Reference : sorted list of (sample, probes) changes, list of trigger samples"""
    changes, triggers = [], []
    with open(path) as f:
        for line in f:
            words = line.split()
            if not words:
                continue
            if words[0] == "s":
                changes.append((int(words[1]), int(words[2], 16)))
            elif words[0] == "t":
                triggers.append(int(words[1]))
    changes.sort()
    return changes, triggers


def read_vcd(path, bus):
    """VCD of hwla2vcd : list of (time, probes) changes, time of the trigger rise, end time"""
    ids, probes, trigger_rise, time = {}, [], None, 0
    with open(path) as f:
        for line in f:
            words = line.split()
            if not words:
                continue
            if words[0] == "$var":
                ids[words[3]] = words[4]
            elif words[0].startswith("#"):
                time = int(words[0][1:])
            elif words[0].startswith("b"):
                if ids.get(words[1]) == bus:
                    probes.append((time, int(words[0][1:], 2)))
            elif words[0][0] in "01" and ids.get(words[0][1:]) == "trigger":
                if words[0][0] == "1" and trigger_rise is None:
                    trigger_rise = time
    return probes, trigger_rise, time


def value_at(changes, keys, sample):
    """Probes of the reference at the sample number sample"""
    i = bisect.bisect_right(keys, sample) - 1
    if i < 0:
        raise ValueError(f"sample {sample} before the reference")
    return changes[i][1]


def main(argv=None):
    parser = argparse.ArgumentParser(description="Check the VCD files of hwla2vcd against the reference of tb_hwla_uart")
    parser.add_argument("ref", help="Reference file of the testbench")
    parser.add_argument("vcd", nargs="+", help="VCD files, one per capture, in order")
    parser.add_argument("--period", type=float, default=10.0, help="Period of the trigger clock in ns (default : 10)")
    parser.add_argument("--bus", default="probe", help="Name of the probe bus in the VCD files (default : probe)")
    args = parser.parse_args(argv)

    period_ps     = round(args.period * 1000)
    changes, trig = read_ref(args.ref)
    keys          = [s for s, _ in changes]
    errors        = 0

    if len(trig) != len(args.vcd):
        print(f"check_vcd : FAIL, {len(trig)} triggers in the reference, {len(args.vcd)} VCD files")
        return 1

    for n, (path, trig_sample) in enumerate(zip(args.vcd, trig)):
        probes, trig_time, end_time = read_vcd(path, args.bus)
        if trig_time is None or not probes:
            print(f"check_vcd : FAIL, {path} : no trigger or no probe")
            errors += 1
            continue

        # Sample number of the time 0 of the VCD, last sample (one clock cycle
        # before the end of the VCD)
        first   = trig_sample - trig_time // period_ps
        last    = first + end_time // period_ps - 1
        vcd_t   = [t // period_ps for t, _ in probes]
        nb_err  = 0
        for sample in range(first, last + 1):
            i   = bisect.bisect_right(vcd_t, sample - first) - 1
            got = probes[i][1]
            exp = value_at(changes, keys, sample)
            if got != exp:
                if nb_err < 10:
                    print(f"check_vcd : {path} : sample {sample} (time {(sample - first) * period_ps} ps) : probes 0x{got:x}, expected 0x{exp:x}")
                nb_err += 1
        print(f"check_vcd : capture {n} ({path}) : samples {first} to {last}, trigger sample {trig_sample}, "
              f"{len(probes)} changes, {nb_err} errors")
        errors += nb_err

    print("check_vcd : " + ("PASS" if errors == 0 else f"FAIL ({errors} errors)"))
    return 0 if errors == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
