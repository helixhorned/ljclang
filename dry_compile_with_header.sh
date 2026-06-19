#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 Philipp Kutin

set -e

function labeled_assert() {
	local label="$1"
	shift
	test "$@" || (echo "assertion failed: $label: $*" 1>&2 && false)
}

ThisDir=$(dirname "$0")

print_included_by="$ThisDir/print_included_by.lua"

if [ ! -x "$print_included_by" ]; then
	echo "ERROR: '$print_included_by' does not exist or is not executable." >&2
	exit 1
fi

concurrency_arg=

if [ "${1:0:2}" == '-j' ]; then
	concurrency_arg="$1"
	shift
fi

compiler_arg="$1"
inclusions_file="$2"
orig_header_name="$3"
mod_header_file="$4"
no_color_opt="$5"

if [[ -z "$compiler_arg" || -z "$inclusions_file" || -z "$orig_header_name" || -z "$mod_header_file" ]]; then
	exec >&2
	echo "Usage: $0 [-j<concurrency>] <compiler> <inclusions-file> <orig-header-name> <modified-header> [--no-color]"
	echo
	echo "- <compiler> may be an absolute or relative path"
	echo "- <inclusions-file> must name a file containing the output of 'print_inclusions.sh'"
	echo "- <orig-header-name> must name a header as it appears in <inclusions-file>"
	echo "- <modified-header> must name a header file to be used instead of the original one."
	echo "   It must contain an include guard (its presence is not checked, however)."
	exit 1
fi

if ! compiler=$(which "$compiler_arg"); then
	echo "ERROR: '$compiler_arg' does not resolve to an executable file." >&2
	exit 1
fi

if [ ! -r "$mod_header_file" ]; then
	echo "ERROR: '$mod_header_file' does not exist or is not readable." >&2
	exit 1
fi

if [[ -n "$no_color_opt" && "$no_color_opt" != '--no-color' ]]; then
	echo "ERROR: malformed last (optional) argument: must be '--no-color'." >&2
	exit 1
fi

max_jobs=1

if [ -n "$concurrency_arg" ]; then
	if [[ ! "$concurrency_arg" =~ ^-j[1-9][0-9]?$ ]]; then
		echo "ERROR: malformed concurrency specification, expecting '-j[1-9][0-9]?'." >&2
		exit 1
	fi

	max_jobs=${concurrency_arg:2}
fi

if [[ "$max_jobs" -gt 1 && "${BASH_VERSINFO[0]}" -lt 5 ]]; then
	# For 'wait -f':
	echo "ERROR: for concurrent processing, need at least Bash 5.0" >&2
	exit 1
fi

### 1. Obtain the included-by listing and from it, extract affected TU indexes.

function handle_included_by() {
	local enable=
	local to_match="$1"

	while read -r line; do
		if [ -z $enable ]; then
			if [[ "$line" == "$to_match" ]]; then
				enable=1
			fi
		else
			if [[ -z "$line" ]]; then
				break
			fi

			if [[ "$line" =~ \[TU_([0-9]+)\] ]]; then
				echo "${BASH_REMATCH[1]}"
			fi
		fi
	done
}

readarray -t tu_idxs < \
	<("$print_included_by" "$inclusions_file" | handle_included_by "* $orig_header_name" | sort -un)

affected_tu_count="${#tu_idxs[@]}"

if [ "$affected_tu_count" -eq 0 ]; then
	echo "ERROR: <orig-header-name> did not yield any affected translation units." >&2
	exit 1
fi

### 2. From inclusions file, extract+tweak compile commands corresponding to affected TUs.

tu_idxs_str="${tu_idxs[*]}"
tu_header_regex="^# \\[TU_(${tu_idxs_str// /|})\\] (.*) -E -H$"

new_args_lists=()

function filter_arguments() {
	# shellcheck disable=SC2206
	# We *want* the word splitting:
	local args=($1)
	local new_args=()

	for arg in "${args[@]}"; do
		local keep=1
		if [[ -n "$no_color_opt" ]]; then
			if [[ "$arg" == -fcolor-diagnostics || "$arg" == -fdiagnostics-color=always ]]; then
				keep=
			fi
		fi

		if [[ -n "$keep" ]]; then
			new_args+=("$arg")
		fi
	done

	echo "${new_args[*]}"
}

function extract_compile_commands() {
	local src_file_regex="^= (.+)$"
	local tentative_tu_idx=
	local tentative_command=

	while read -r line; do
		if [ -z "$tentative_command" ]; then
			if [[ "$line" =~ $tu_header_regex ]]; then
				tentative_tu_idx="${BASH_REMATCH[1]}"
				tentative_command=$(filter_arguments "${BASH_REMATCH[2]}")
			fi
		else
			if [[ ! "$line" =~ $src_file_regex ]]; then
				echo "ERROR: [TU_$tentative_tu_idx] line is not followed by '= <source-file>' line." >&2
				exit 1
			fi

			# -fsyntax-only: Run the preprocessor, parser and semantic analysis stages
			new_args_lists+=("$tentative_command -fsyntax-only ${BASH_REMATCH[1]} -include ${mod_header_file}")
			tentative_command=
			tentative_tu_idx=
		fi
	done
}

extract_compile_commands < "$inclusions_file"
new_command_count="${#new_args_lists[@]}"

if [ "$new_command_count" -ne "$affected_tu_count" ]; then
	echo "ERROR: did not extract exactly $affected_tu_count compile commands from affected TU indexes." >&2
	exit 1
fi

if [ "$max_jobs" -gt "$new_command_count" ]; then
	max_jobs="$new_command_count"
fi

### 3a. Functions common to serial and concurrent cases

function process_translation_unit() {
	local ci="$1"
	# shellcheck disable=SC2086
	"$compiler" ${new_args_lists[ci]} || true
}

### 3b. Invoke compiler with prepared commands

if [ "$max_jobs" -eq 1 ]; then
	## Serial processing
	for ci in "${!new_args_lists[@]}"; do
		process_translation_unit "$ci"
	done
	exit 0
fi

## Concurrent processing

labeled_assert max_jobs "$max_jobs" -ge 2

lock_file=/proc/$$/status
g_pids=()
to_reap_count=0

# ----------

function process_tu() {
	ci="$1"

	local result
	result=$(process_translation_unit "$ci")

	exec {lock_fd}< "$lock_file"
	flock "$lock_fd"

	printf "%s" "$result"
}

function find_command_index() {
	local pid="$1"
	labeled_assert find_command_index:pid -n "$pid"
	pid_count="${#g_pids[@]}"

	for ((i=0; i < pid_count; i++)); do
		if [ "${g_pids[i]}" -eq "$pid" ]; then
			echo "$i"
			return
		fi
	done

	assert -z unreachable
	exit 101
}

function spawn_coprocess() {
	local ci="$1"
	labeled_assert spawn_coprocess:ci -n "$ci"

	process_tu "$ci" &
	local pid=$!
	to_reap_count=$((to_reap_count + 1))
	g_pids[ci]="$pid"
}

# ----------

# Make Ctrl-C terminate all children (and self -- cannot recurse 'SIGINT').
#
# shellcheck disable=SC2064
# We *want* our PID to expand now:
trap "kill -SIGTERM -$$" SIGINT

for ((ci=0; ci < max_jobs; ci++)); do
	spawn_coprocess "$ci"
done

labeled_assert to_reap_count "$to_reap_count" -eq "$max_jobs"

ci="$max_jobs"

while [ "$to_reap_count" -gt 0 ]; do
	wait -nf -p stopped_pid || ignore_failure
	to_reap_count=$((to_reap_count - 1))

	# If we can, first spawn a new child.
	if [ "$ci" -lt "$new_command_count" ]; then
		spawn_coprocess "$ci"
		ci=$((ci + 1))
	fi

	# Take care of the terminated one.

	labeled_assert stopped_pid -n "$stopped_pid"
	finished_ci=$(find_command_index "$stopped_pid")

	g_pids[finished_ci]=-1
done
