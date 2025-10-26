#!/usr/bin/env bash
set -e

# ==============================================================================
#
#           HTTP Client Library - Advanced Benchmark Runner (Corrected)
#
# ==============================================================================

# --- Configuration ---
NUM_REQUESTS_THROUGHPUT=50000
NUM_REQUESTS_LATENCY=300000
NUM_REQUESTS_MIXED=75000
WARMUP_RUNS=1
BENCHMARK_RUNS=30

BUILD_DIR="build_release"
LATENCY_DIR="latencies"

TCP_HOST="127.0.0.1"
TCP_PORT="8080"
UNIX_SOCKET="/tmp/httpc_benchmark.sock"
DATA_FILE="benchmark_data.bin"

# On atom cores you should choose your P cores via lscpu --extended and find the ones with the highest MHz
SERVER_CORE=2
CLIENT_CORE=3
REALTIME_PRIORITY=99

# --- Workload Size Definitions ---
SMALL_MIN=64; SMALL_MAX=8192
LARGE_MIN=500000; LARGE_MAX=1000000
MIXED_MIN=64; MIXED_MAX=1000000

# --- Helper Functions ---
function header {
    echo -e "\n==============================================================================\n  $1\n==============================================================================\n"
}

function set_performance_governor {
    echo "Setting CPU governor to 'performance' (may require sudo)."
    echo "performance" | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor > /dev/null
}

function restore_default_governor {
    echo "Restoring default CPU governor ('ondemand')."
    echo "ondemand" | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor > /dev/null
}

function generate_data {
    local min_len=$1; local max_len=$2; local NUM_REQUESTS=$3
    header "Generating Client Data (Sizes: ${min_len}B - ${max_len}B)"
    ./benchmark/data_generator --num-requests $NUM_REQUESTS --min-length $min_len --max-length $max_len --output $DATA_FILE
}

function run_benchmark_scenario {
    local scenario_name=$1
    local client_min_len=$2; local client_max_len=$3
    local server_min_len=$4; local server_max_len=$5
    local NUM_REQUESTS=$6

    generate_data "$client_min_len" "$client_max_len" "$NUM_REQUESTS"

    # TODO: --cap-add=SYS_NICE
    # chrt -f ${REALTIME_PRIORITY}
    local server_prefix="sudo taskset -c ${SERVER_CORE}"
    local client_prefix="sudo taskset -c ${CLIENT_CORE}"

    for transport in "tcp" "unix"; do
        if [ "$transport" == "tcp" ]; then
            local host_arg=$TCP_HOST; local port_arg=$TCP_PORT
            local server_cmd="$server_prefix ./benchmark/benchmark_server --transport tcp --host $TCP_HOST --port $TCP_PORT --verify false --num-responses $NUM_REQUESTS --min-length $server_min_len --max-length $server_max_len"
        else
            local host_arg=$UNIX_SOCKET; local port_arg=0
            local server_cmd="$server_prefix ./benchmark/benchmark_server --transport unix --unix-socket-path $UNIX_SOCKET --verify false --num-responses $NUM_REQUESTS --min-length $server_min_len --max-length $server_max_len"
        fi

        header "Running Scenario: '$scenario_name' (Transport: $transport) NUM_REQUESTS=$NUM_REQUESTS"

        local setup_cmd="$server_cmd & echo \$! > server.pid; sleep 2"
        local cleanup_cmd="kill \$(cat server.pid) 2>/dev/null || true; rm -f server.pid; sleep 1"

        local output_prefix="${LATENCY_DIR}/latencies"
        local common_args_our_clients="--num-requests ${NUM_REQUESTS} --data-file ${DATA_FILE} --no-verify --transport ${transport}"
        local hyperfine_output_file="hyperfine_results_${scenario_name}_${transport}.md"
        local commands=()

        # C
        commands+=("$client_prefix ./benchmark/httpc_client ${host_arg} ${port_arg} ${common_args_our_clients} --output-file ${output_prefix}_httpc_${transport}_${scenario_name}_copy.bin")
        commands+=("$client_prefix ./benchmark/httpc_client ${host_arg} ${port_arg} ${common_args_our_clients} --unsafe --output-file ${output_prefix}_httpc_${transport}_${scenario_name}_no_copy.bin")
        commands+=("$client_prefix ./benchmark/httpc_client ${host_arg} ${port_arg} ${common_args_our_clients} --unsafe --output-file ${output_prefix}_httpc_${transport}_${scenario_name}_vectored.bin --io-policy vectored")
        commands+=("$client_prefix ./benchmark/libcurl_client ${host_arg} ${port_arg} ${common_args_our_clients} --output-file ${output_prefix}_libcurl_${transport}_${scenario_name}.bin")
        # C++
        commands+=("$client_prefix ./benchmark/httpcpp_client --host ${host_arg} --port ${port_arg} ${common_args_our_clients} --output-file ${output_prefix}_httpcpp_${transport}_${scenario_name}_safe.bin")
        commands+=("$client_prefix ./benchmark/httpcpp_client --host ${host_arg} --port ${port_arg} ${common_args_our_clients} --output-file ${output_prefix}_httpcpp_${transport}_${scenario_name}_unsafe.bin --unsafe")
        commands+=("$client_prefix ./benchmark/boost_client --host ${host_arg} --port ${port_arg} ${common_args_our_clients} --output-file ${output_prefix}_boost_${transport}_${scenario_name}_safe.bin")
        commands+=("$client_prefix ./benchmark/boost_client --unsafe --host ${host_arg} --port ${port_arg} ${common_args_our_clients} --output-file ${output_prefix}_boost_${transport}_${scenario_name}_unsafe.bin")
        # Rust
        commands+=("$client_prefix ./httprust_client ${host_arg} ${port_arg} ${common_args_our_clients} --output-file ${output_prefix}_httprust_${transport}_${scenario_name}_safe.bin")
        commands+=("$client_prefix ./httprust_client ${host_arg} ${port_arg} ${common_args_our_clients} --output-file ${output_prefix}_httprust_${transport}_${scenario_name}_unsafe.bin --unsafe")
        # Python
        commands+=("$client_prefix ../.venv/bin/python3 ../benchmark/clients/python/httppy_client.py ${host_arg} ${port_arg} ${common_args_our_clients} --output-file ${output_prefix}_httppy_${transport}_${scenario_name}_safe.bin")
        commands+=("$client_prefix ../.venv/bin/python3 ../benchmark/clients/python/httppy_client.py ${host_arg} ${port_arg} ${common_args_our_clients} --output-file ${output_prefix}_httppy_${transport}_${scenario_name}_unsafe.bin --unsafe")
        commands+=("$client_prefix ../.venv/bin/python3 ../benchmark/clients/python/requests_client.py ${host_arg} ${port_arg} ${common_args_our_clients} --output-file ${output_prefix}_requests_${transport}_${scenario_name}.bin")

        # Baselines that only support TCP
        if [ "$transport" == "tcp" ]; then
            commands+=("$client_prefix ./reqwest_client ${host_arg} ${port_arg} ${common_args_our_clients} --output-file ${output_prefix}_reqwest_${transport}_${scenario_name}.bin")
        fi

        hyperfine --prepare "$setup_cmd" --cleanup "$cleanup_cmd" \
            --warmup ${WARMUP_RUNS} --runs ${BENCHMARK_RUNS} \
            --export-markdown "${hyperfine_output_file}" \
            "${commands[@]}"
    done
}

# --- Main Execution ---


# Copy the functions and run them outside your container
#trap restore_default_governor EXIT
#set_performance_governor
#sudo sysctl -w net.core.wmem_max=16777216
#sudo sysctl -w net.core.rmem_max=16777216

cd "$BUILD_DIR"
mkdir -p "$LATENCY_DIR"
cmake --build . &> /dev/null
../.venv/bin/python3 -m pip install wheelhouse/httppy*.whl --force-reinstall &> /dev/null
rm -rf ../src/python/build

# Throughput Scenarios
run_benchmark_scenario "throughput_balanced_large" $LARGE_MIN $LARGE_MAX $LARGE_MIN $LARGE_MAX $NUM_REQUESTS_THROUGHPUT
run_benchmark_scenario "throughput_uplink_heavy"   $LARGE_MIN $LARGE_MAX $SMALL_MIN $SMALL_MAX $NUM_REQUESTS_THROUGHPUT
run_benchmark_scenario "throughput_downlink_heavy" $SMALL_MIN $SMALL_MAX $LARGE_MIN $LARGE_MAX $NUM_REQUESTS_THROUGHPUT

# Latency Scenario
run_benchmark_scenario "latency_small_small"       $SMALL_MIN $SMALL_MAX $SMALL_MIN $SMALL_MAX $NUM_REQUESTS_LATENCY

# Mixed Scenarios
run_benchmark_scenario "mixed_server_random"       $SMALL_MIN $SMALL_MAX $MIXED_MIN $MIXED_MAX $NUM_REQUESTS_MIXED
run_benchmark_scenario "mixed_balanced_random"     $MIXED_MIN $MIXED_MAX $MIXED_MIN $MIXED_MAX $NUM_REQUESTS_MIXED
run_benchmark_scenario "mixed_client_random"       $MIXED_MIN $MIXED_MAX $SMALL_MIN $SMALL_MAX $NUM_REQUESTS_MIXED

header "All benchmarks complete!"
echo "Latency files are in '${BUILD_DIR}/${LATENCY_DIR}'"
echo "Hyperfine results are in '${BUILD_DIR}/hyperfine_results_*.md'"
