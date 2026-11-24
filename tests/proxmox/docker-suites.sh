#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Robert Paleka
#
# Every test suite of the lab, in Docker, one after the other, on a throwaway
# Debian machine (a VM: the suites need loop devices). As root:
#
#     bash docker-suites.sh [SUITE...]     default: all of them
#
# Logs in /root/dfsuites/SUITE.log, a line per suite in /root/dfsuites/summary.
# Environment: BRANCH (coexist), for both the daemon and the lab.

set -u
BRANCH=${BRANCH:-coexist}
W=/root/dfsuites
SUITES=${*:-test arrays sizes showcase existing coexist machine tiers extras}
mkdir -p $W
say() { echo "[$(date +%H:%M:%S)] $*"; }
export DEBIAN_FRONTEND=noninteractive

if ! command -v docker >/dev/null; then
	say "installing Docker"
	apt-get update -q >/dev/null 2>&1
	apt-get install -y -q docker.io docker-compose git ca-certificates curl > $W/tools.log 2>&1 || { echo "Docker could not be installed (see $W/tools.log)"; exit 99; }
fi
if docker compose version >/dev/null 2>&1; then DC="docker compose"; else DC=docker-compose; fi
say "$($DC version 2>&1 | head -1)"

cd $W
rm -rf diskflux-daemon diskflux-lab
git clone -q -b "$BRANCH" https://github.com/paleka/diskflux.git diskflux-daemon || exit 99
git -C diskflux-daemon fetch -q --tags
git clone -q -b "$BRANCH" https://github.com/paleka/diskflux-lab.git diskflux-lab || exit 99
say "daemon $(git -C diskflux-daemon rev-parse --short HEAD), lab $(git -C diskflux-lab rev-parse --short HEAD)"
cd diskflux-lab
: > $W/summary
FAILED=0
for s in $SUITES; do
	f=docker-compose.$s.yml
	[ -f $f ] || { echo "suite $s: no $f" | tee -a $W/summary; FAILED=$((FAILED+1)); continue; }
	say "suite $s"
	start=$(date +%s)
	$DC -f $f up --build --abort-on-container-exit --exit-code-from tests > $W/$s.log 2>&1; rc=$?
	$DC -f $f down -v >/dev/null 2>&1
	res=$(grep -aEo 'passed: [0-9]+ +failed: [0-9]+' $W/$s.log | tail -1)
	line="suite $s: exit $rc, ${res:-no result line}, $(( ($(date +%s) - start) / 60 )) min"
	echo "$line" | tee -a $W/summary
	[ $rc = 0 ] || { FAILED=$((FAILED+1)); grep -a 'FAIL' $W/$s.log | head -20; }
done
say "done: $FAILED of $(echo $SUITES | wc -w) suites failed"
exit $FAILED
