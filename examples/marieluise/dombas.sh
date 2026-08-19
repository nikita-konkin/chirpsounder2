#!/usr/bin/env bash
#
# ntp-public.uit.no
# ntp.uit.no
#
# Create ionograms without knowledge of ionogram timings. Figure out the timings
# by listening to signals on the antenna.
#

INSTALL_PATH="$HOME/chirpsounder2"

# Python virtual environment
source "$INSTALL_PATH/.venv38/bin/activate"

# Cores 2-7 for everything this script starts. PHYSICAL core 0 -- which is
# cpu0 *and* cpu1 -- belongs to the recorder.
#
# The recorder was one of twelve processes queueing for four cores and lost up
# to 45% of its samples to the wait -- with CPU to spare, because the fault is
# latency, not throughput. It needs 0.8 of a core, but it needs it the instant a
# packet arrives. Pinning the shell is inherited by every child; the recorder
# widens its own mask back to core 0 below, which a process is always allowed
# to do. Core 7 stays in this pool on purpose: every NIC interrupt lands there.
#
# **2-7, not 1-7.** This box is an i7-4930MX: four physical cores, eight
# threads, and /sys/devices/system/cpu/cpu0/topology/thread_siblings_list reads
# `0-1`. A rank on cpu1 shares the recorder's execution units, its L1 and its
# L2 -- it is the same core, whatever the mask says. Patch 0008 wrote 1-7 and
# so gave the recorder a dedicated hyperthread on a core a consumer was using.
# Measured cost over 10.3 hours: clean whenever that sibling idled, a sustained
# 3.4% of the stream lost through the morning when it did not.
taskset -cp 2-7 $$ > /dev/null

# Make sure this is the right mpirun command
# (you might need mpirun instead of mpirun.mpich)
#
# --bind-to none is load-bearing, not tuning. Open MPI calls sched_setaffinity
# on every rank after fork, and 1.10.2 -- what this box runs -- defaults to
# --bind-to core for -np <= 2. It then places rank 0 on physical core 0 from
# the machine's own topology, with no reference to the mask it inherited.
# Measured here on 2026-08-13, with the taskset above already in place: both
# mpirun processes read 2-7, while a detect rank and a calc rank read 0,1 --
# the recorder's core -- and cores 4-7 sat unused. Without this flag the
# taskset ten lines up does nothing whatsoever for the ranks that do the work.
#
# If you switch to MPICH, drop the flag: Hydra does not bind by default.
MPIRUN="mpirun --bind-to none"

# ram disk buffer for fast i/o.
# if you have a fast SSD or raid, you can also use that
RINGBUFFER_DIR=/dev/shm/hf25
SAMPLE_RATE=25e6
# CONF_FILE="$INSTALL_PATH/examples/marieluise/dombas.ini"
CONF_FILE="${CONF_FILE:-$INSTALL_PATH/my_station.ini}"

# The recorder's LO. This replaces a bare `CENTER_FREQ=12.5e6` that sat here
# and was read by nothing -- the recorder had no way to accept it until 0014,
# so every launcher under examples/ sets this variable and not one of them
# passes it. It has been stale since the band moved to 20 MHz on 2026-08-19,
# and it looked authoritative the whole time.
#
# Reading it from the ini is the `TBD: change cpp program so that ini file
# defines USRP setup!` further down, answered for the one setting that had
# already caused damage. calc_ionograms builds its downconversion mixer from
# `center_freq` while the samples come from wherever the recorder tuned;
# nothing checks the two against each other and nothing can, since the LO is
# not in the Digital RF metadata. A mismatch dechirps by the difference and
# yields empty products with no error in any log -- it blinded the station
# twice on 2026-08-19.
#
# Read here, before this script starts anything, and fatal if it fails: an
# unreadable ini must stop the launch rather than fall back to the recorder's
# built-in 12.5e6, which is precisely the silent 12.5-vs-20 split that did the
# damage. Failing here costs a restart; failing quietly cost a day.
#
# `build_fvec=False` skips the detection frequency vector, which this does not
# need and which allocates n_samples_per_block floats to throw away.
CENTER_FREQ=$(python3 -c "import chirp_config, sys; print(chirp_config.chirp_config(sys.argv[1], verbose=False, build_fvec=False).center_freq)" "$CONF_FILE")
if [ -z "$CENTER_FREQ" ]; then
    echo "FATAL: could not read center_freq from $CONF_FILE" >&2
    exit 1
fi
echo "LO $CENTER_FREQ Hz (from $CONF_FILE)"

# Ringbuffer cap, enforced by `drf ringbuffer` below. Roughly 200 MB under half
# the machine's RAM for a tmpfs; far more on an SSD or raid.
#
# It also sets how far back a consumer can reach, which is what decides whether
# a sounding can be analysed at all:
#
#   seconds of history = RINGBUFFER_SIZE / (sample_rate * 4 bytes per sample)
#
# At 25 MS/s that is 100 MB/s, so 12000MB holds 120 s. A sounding has to start
# processing within that window of its t0; find_timings.py prints the margin
# for each one as "N s left". Measured start latency here is 65-117 s.
RINGBUFFER_SIZE=14000MB

cd "$INSTALL_PATH" || exit 1

# Show which Python is actually being used
echo "Python: $(which python3)"
echo "Python version: $(python3 --version)"
echo "Python executable: $(python3 -c 'import sys; print(sys.executable)')"

# kill possibly existing runtime
# stop all processes
./stop_ringbuffer.sh || true

# delete old data from ram disk
# rm -Rf "$RINGBUFFER_DIR"
mkdir -p "$RINGBUFFER_DIR"

mkdir -p logs

# --- producers first, and the trimmer with them ----------------------------
#
# Order is load-bearing here, and getting it wrong fails silently twice over.
#
# Every consumer opens a DigitalRFReader whose channel list is fixed when it is
# constructed, so one started before the recorder created ch0 can never see
# that channel. patches/0002 makes losing that race recoverable instead of a
# permanent hang, but not losing it is better.
#
# And nothing deleted old data, because `drf ringbuffer` was never started --
# every example under examples/ringbuffer/ runs it, and stop_ringbuffer.sh
# already expects to have to kill it. Without it /dev/shm reaches 100%, the
# writer can no longer allocate, and the recording develops holes that surface
# downstream as "missing data - skipping" while the recorder, the detector and
# every plot carry on looking healthy. Two days of soundings went that way.
echo "rx_uhd_ext_gps (restarting every 24 hours)"
(
    while true;
    do
        # 0-1 is ONE physical core, not two -- they are hyperthread siblings.
        # See the taskset at the top of this script.
        taskset -c 0-1 ./rx_uhd_ext_gps --outdir="$RINGBUFFER_DIR" --usrp_args=recv_buff_size=500000000 --center-freq="$CENTER_FREQ" > logs/thor.log 2>&1

        sleep 5

        echo "Restarting recording (every 24 hours)."
        echo "Rotating logs"

        logrotate "$INSTALL_PATH/examples/marieluise/tgo-logrotate.conf" \
            -s logs/rotate.status
    done
) &
sleep 10

echo "drf ringbuffer ($RINGBUFFER_SIZE)"
drf ringbuffer -z "$RINGBUFFER_SIZE" "$RINGBUFFER_DIR" -p 2 > logs/ringbuffer.log 2>&1 &
sleep 10

# --- consumers -------------------------------------------------------------
#
# `python3 -u` throughout. stdout redirected to a file is block-buffered, so a
# process that is merely waiting looks exactly like one that has wedged, and
# whatever it said before hanging never reaches the log at all.
echo "sync_iono_data.py"
python3 -u sync_iono_data.py --config "$CONF_FILE" > logs/sync.log 2>&1 &

echo "iono_housekeeping.py"
python3 -u iono_housekeeping.py --config "$CONF_FILE" > logs/housekeeping.log 2>&1 &

echo "detections2metadata.py"
python3 -u detections2metadata.py --config "$CONF_FILE" > logs/detections2metadata.log 2>&1 &

# receive_digisonde.py x5 and the plotters used to run here. The receivers are
# ringbuffer consumers, not downloaders: they demodulate the digisondes off air
# from /dev/shm, and five of them cost this recorder ~969 dropped sample events
# and ~65,000 dropped datagrams per second. DOB does not use those products --
# their range zero is a configured offset_us, not a measured delay. The
# plotters are gone because the web UI renders on demand. See patches/0007 and
# docs/2026-08-11-recorder-packet-loss.md.

echo "detect_chirps.py"
$MPIRUN -np 2 python3 -u detect_chirps.py --config "$CONF_FILE" > logs/detect.log 2>&1 &

# Only in serendipitous mode: find_timings.py writes the par-*.h5 that
# calc_ionograms.py's serendipitous branch consumes, and in realtime mode
# nothing reads them. Without it that branch waits for ever on an input no
# process is producing -- no error, no output, no ionograms.
#
# The config is POSITIONAL here. find_timings.py reads sys.argv[1] rather than
# --config, and given the flag it prints "No config provided - Using defaults"
# and quietly scans a data directory belonging to someone else.
SERENDIPITOUS=$(python3 -c "import chirp_config, sys; print(chirp_config.chirp_config(sys.argv[1], verbose=False).serendipitous)" "$CONF_FILE")
if [ "$SERENDIPITOUS" = "True" ]; then
    echo "find_timings.py (serendipitous mode)"
    python3 -u find_timings.py "$CONF_FILE" > logs/find_timings.log 2>&1 &
    sleep 10
fi

# One transmitter per MPI rank -- `st = conf.sounder_timings[rank]` at
# calc_ionograms.py:452, with no guard -- so in scheduled mode this count is
# part of the schedule and not a tuning knob. Hardcoded, every schedule change
# is two edits, and forgetting the second one fails silently: too few ranks and
# the transmitters past the cut are never sounded, too many and one rank dies
# of IndexError while the rest carry on. The log reads as healthy either way,
# because for the ranks that survive it is.
#
# In search mode the timings come from find_timings.py and the ranks are free
# parallelism, so the answer there stays 2: as a single process this lost 4.28%
# of soundings, and at four ranks the machine saturated badly enough that the
# RECORDER lost 63% of its stream.
NP_IONO=$(python3 - "$CONF_FILE" <<'PY'
import configparser, json, sys

parser = configparser.ConfigParser()
parser.read(sys.argv[1])
flag = parser.get("lfm", "serendipitous", fallback="true")
scheduled = flag.strip().strip('"').lower() in ("false", "0", "no")
try:
    timings = json.loads(parser.get("lfm", "sounder_timings", fallback="") or "[]")
except ValueError:
    timings = []
if not scheduled:
    print(2)
elif timings and all(isinstance(entry, list) for entry in timings):
    print(len(timings))
else:
    print(1)
PY
)
# An empty result means python3 failed, not that the schedule is empty. 2 is
# the value this patch replaced, so the fallback is the old behaviour rather
# than a silent drop to one rank.
[ -n "$NP_IONO" ] || NP_IONO=2

# It reads its rank from MPI.COMM_WORLD (calc_ionograms.py:99-101). -np is the
# one parameter here whose wrongness is invisible in the log, so it goes in the
# log.
echo "calc_ionograms.py -np $NP_IONO"
$MPIRUN -np "$NP_IONO" python3 -u calc_ionograms.py --config "$CONF_FILE" > logs/ionograms.log 2>&1 &

echo "station_monitor.py"
python3 -u station_monitor.py --config "$CONF_FILE" > logs/station_monitor.log 2>&1 &

# The recorder loop is a background child now, so this script has to stay in
# the foreground: systemd's Restart=always supervises *this* process, and
# KillMode=control-group takes the whole tree down with it.
#
# It supervises only this script, though. A background child that dies -- or
# wedges, which is worse -- leaves the unit "active (running)". Whatever
# watches this station should watch the age of the newest product, not the
# unit state.
echo "all processes started; waiting"
wait
