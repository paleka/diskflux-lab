#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Robert Paleka
#
# Throws the demo lab away and starts a new one. Run by demo-reset.timer.
set -u
LAB=$(cd "$(dirname "$0")/.." && pwd)
cd "$LAB" || exit 1
C="docker compose -f docker-compose.yml -f demo/demo.yml"
$C down -v
# the loop devices of the lab are attached in the container but belong to the machine
losetup -D
$C up -d
