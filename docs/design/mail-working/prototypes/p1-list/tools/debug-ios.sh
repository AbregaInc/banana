#!/bin/zsh
# usage: debug-ios.sh <host> <variant>  : prints the DEBUG lines of the debug scenario
UDID=E5232BE0-8F82-4E85-A03B-5CA7160571E2
xcrun simctl launch --console-pty --terminate-running-process $UDID com.boris.banana.proto.p1list --host $1 --variant $2 --scenario debug 2>&1 | grep "DEBUG" | cut -c1-250 &
sleep ${3:-26}; xcrun simctl terminate $UDID com.boris.banana.proto.p1list >/dev/null 2>&1; wait
