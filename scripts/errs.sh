#!/bin/sh
# Builds and prints only compiler diagnostics (deduplicated, colour stripped).
swift build "$@" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E "^/[^ ]+:[0-9]+:[0-9]+: (error|warning)" | sort -u
swift build "$@" 2>&1 | tail -1
