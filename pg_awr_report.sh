#!/usr/bin/env bash
set -euo pipefail

INTERVAL_SECONDS=60
OUTPUT_FILE=""

usage() {
  cat <<'USAGE'
Usage: pg_awr_report.sh [-i interval_seconds] [-o output_file]

Environment variables:
  PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE

Defaults:
  interval_seconds = 60
  output_file = stdout
USAGE
}

while getopts ":i:o:h" opt; do
  case "$opt" in
    i) INTERVAL_SECONDS="$OPTARG" ;;
    o) OUTPUT_FILE="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

if ! command -v psql >/dev/null 2>&1; then
  echo "psql is required." >&2
  exit 1
fi

psql_query() {
  local sql="$1"
  psql -At -F $'\t' -v ON_ERROR_STOP=1 -c "$sql"
}

psql_query_quiet() {
  local sql="$1"
  psql -At -F $'\t' -v ON_ERROR_STOP=1 -c "$sql" 2>/dev/null || true
}

write_out() {
  if [[ -n "$OUTPUT_FILE" ]]; then
    printf "%s\n" "$1" >> "$OUTPUT_FILE"
  else
    printf "%s\n" "$1"
  fi
}

append_block() {
  if [[ -n "$OUTPUT_FILE" ]]; then
    cat >> "$OUTPUT_FILE"
  else
    cat
  fi
}

if [[ -n "$OUTPUT_FILE" ]]; then
  : > "$OUTPUT_FILE"
fi

START_TS=$(date '+%Y-%m-%d %H:%M:%S%z')
START_EPOCH=$(date +%s)

DB_CONNECT_OK=$(psql_query_quiet "select 1")
if [[ -z "$DB_CONNECT_OK" ]]; then
  echo "Database connection failed. Check PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE." >&2
  exit 1
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

DB1="$TMPDIR/db1.tsv"
DB2="$TMPDIR/db2.tsv"
BG1="$TMPDIR/bg1.tsv"
BG2="$TMPDIR/bg2.tsv"
STAT1="$TMPDIR/stat1.tsv"
STAT2="$TMPDIR/stat2.tsv"
WAIT_WINDOW="$TMPDIR/wait_window.tsv"

psql_query "select datname, xact_commit, xact_rollback, blks_read, blks_hit, tup_returned, tup_fetched, tup_inserted, tup_updated, tup_deleted, temp_bytes, temp_files, blk_read_time, blk_write_time from pg_stat_database" > "$DB1"
psql_query "select checkpoints_timed, checkpoints_req, checkpoint_write_time, checkpoint_sync_time, buffers_checkpoint, buffers_clean, maxwritten_clean, buffers_backend, buffers_backend_fsync, buffers_alloc from pg_stat_bgwriter" > "$BG1"

HAS_STATEMENTS=$(psql_query_quiet "select 1 from pg_extension where extname='pg_stat_statements' limit 1")
STAT_TOTAL_COL="total_exec_time"
STAT_MEAN_COL="mean_exec_time"
if [[ -n "$HAS_STATEMENTS" ]]; then
  HAS_TOTAL_EXEC=$(psql_query_quiet "select 1 from information_schema.columns where table_name='pg_stat_statements' and column_name='total_exec_time' limit 1")
  if [[ -z "$HAS_TOTAL_EXEC" ]]; then
    STAT_TOTAL_COL="total_time"
  fi
  HAS_MEAN_EXEC=$(psql_query_quiet "select 1 from information_schema.columns where table_name='pg_stat_statements' and column_name='mean_exec_time' limit 1")
  if [[ -z "$HAS_MEAN_EXEC" ]]; then
    STAT_MEAN_COL="mean_time"
  fi
fi
if [[ -n "$HAS_STATEMENTS" ]]; then
  psql_query "select dbid, sum(${STAT_TOTAL_COL}), sum(blk_read_time), sum(blk_write_time), sum(calls) from pg_stat_statements group by dbid" > "$STAT1"
fi

HAS_WAIT_SAMPLING=$(psql_query_quiet "select 1 from pg_extension where extname='pg_wait_sampling' limit 1")

sleep "$INTERVAL_SECONDS"

END_TS=$(date '+%Y-%m-%d %H:%M:%S%z')
END_EPOCH=$(date +%s)
ELAPSED=$((END_EPOCH - START_EPOCH))

psql_query "select datname, xact_commit, xact_rollback, blks_read, blks_hit, tup_returned, tup_fetched, tup_inserted, tup_updated, tup_deleted, temp_bytes, temp_files, blk_read_time, blk_write_time from pg_stat_database" > "$DB2"
psql_query "select checkpoints_timed, checkpoints_req, checkpoint_write_time, checkpoint_sync_time, buffers_checkpoint, buffers_clean, maxwritten_clean, buffers_backend, buffers_backend_fsync, buffers_alloc from pg_stat_bgwriter" > "$BG2"

if [[ -n "$HAS_STATEMENTS" ]]; then
  psql_query "select dbid, sum(${STAT_TOTAL_COL}), sum(blk_read_time), sum(blk_write_time), sum(calls) from pg_stat_statements group by dbid" > "$STAT2"
fi

if [[ -n "$HAS_WAIT_SAMPLING" ]]; then
  psql_query "select wait_event_type, wait_event, count(*) from pg_wait_sampling_history where sample_time >= to_timestamp(${START_EPOCH}) and sample_time <= to_timestamp(${END_EPOCH}) group by wait_event_type, wait_event" > "$WAIT_WINDOW"
fi

DB_NAME=$(psql_query "select current_database()")
DB_ID=$(psql_query_quiet "select oid from pg_database where datname=current_database()")
INSTANCE_NAME=$(psql_query "select inet_server_addr()::text")
INSTANCE_NUM="1"
STARTUP_TIME=$(psql_query "select pg_postmaster_start_time()")
RELEASE=$(psql_query "select version()")

HOST_NAME=$(hostname || true)
PLATFORM=$(uname -srm || true)
CPUS=$(getconf _NPROCESSORS_ONLN || echo 0)
CORES="$CPUS"
SOCKETS=$(lscpu 2>/dev/null | awk -F: '/Socket\(s\)/{gsub(/ /, "", $2); print $2}' || true)
MEM_GB=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)

SESSIONS=$(psql_query "select count(*) from pg_stat_activity")
MAX_CONNECTIONS=$(psql_query "select setting from pg_settings where name='max_connections'")

write_out "## DB Information"
write_out ""
write_out "## PostgreSQL ${INTERVAL_SECONDS}-Second Snapshot Diagnostics (Single Instance | T1→T2)"
write_out ""
write_out "### PostgreSQL (${HOST_NAME:-server} | port ${PGPORT:-5432})"
write_out ""
write_out "### Connectivity Checks"
write_out ""
append_block <<EOF
| Item | Status | Details |
|---|---|---|
| OS Access | OK | Host: ${HOST_NAME:-N/A} |
| Database Connection | OK | DB: ${DB_NAME} |
EOF

write_out ""
write_out "### DB Information"
write_out ""
append_block <<EOF
**DB Name** | **DB Id** | **Instance** | **Inst num** | **Startup Time** | **Release**
---|---|---|---|---|---
${DB_NAME} | ${DB_ID:-N/A} | ${INSTANCE_NAME} | ${INSTANCE_NUM} | ${STARTUP_TIME} | ${RELEASE}
EOF

write_out ""
write_out "### Host Information"
write_out ""
append_block <<EOF
**Host Name** | **Platform** | **CPUs** | **Cores** | **Sockets** | **Memory (GB)**
---|---|---|---|---|---
${HOST_NAME:-N/A} | ${PLATFORM:-N/A} | ${CPUS} | ${CORES} | ${SOCKETS:-N/A} | ${MEM_GB:-N/A}
EOF

write_out ""
write_out "### Snapshot Information"
write_out ""
append_block <<EOF
**Snap Id** | **Snap Time** | **Sessions** | **Instances**
---|---|---|---
Begin Snap: | 1 | ${START_TS} | ${SESSIONS} | 1
End Snap: | 2 | ${END_TS} | ${SESSIONS} | 1
EOF

write_out ""
append_block <<EOF
**Elapsed** | **DB Time**
---|---
$(awk -v e="$ELAPSED" 'BEGIN{printf "%.2f (mins)", e/60}') | N/A
EOF

write_out ""
write_out "### Load Profile"
write_out ""

awk -v elapsed="$ELAPSED" -F $'\t' '
  FNR==NR {a[$1]=$0; next}
  {
    if (!($1 in a)) next;
    split(a[$1], x, "\t");
    db=$1;
    xact=(($2-x[2])+($3-x[3]));
    blks_read=($4-x[4]);
    blks_hit=($5-x[5]);
    tup_ret=($6-x[6]);
    tup_fet=($7-x[7]);
    tup_ins=($8-x[8]);
    tup_upd=($9-x[9]);
    tup_del=($10-x[10]);
    temp_bytes=($11-x[11]);
    temp_files=($12-x[12]);
    br_time=($13-x[13]);
    bw_time=($14-x[14]);

    tps=(elapsed>0)?xact/elapsed:0;
    hit_ratio=(blks_hit+blks_read>0)?blks_hit/(blks_hit+blks_read):0;
    printf "DB: %s\n", db;
    printf "**Metric** | **Per Second** | **Per Transaction**\n";
    printf "---|---|---\n";
    printf "Transactions: | %.2f | %.2f\n", tps, (xact>0)?1:0;
    printf "Logical reads (blocks): | %.2f | %.2f\n", (elapsed>0)?(blks_hit+blks_read)/elapsed:0, (xact>0)?(blks_hit+blks_read)/xact:0;
    printf "Physical reads (blocks): | %.2f | %.2f\n", (elapsed>0)?blks_read/elapsed:0, (xact>0)?blks_read/xact:0;
    printf "Rows returned: | %.2f | %.2f\n", (elapsed>0)?tup_ret/elapsed:0, (xact>0)?tup_ret/xact:0;
    printf "Rows fetched: | %.2f | %.2f\n", (elapsed>0)?tup_fet/elapsed:0, (xact>0)?tup_fet/xact:0;
    printf "Rows inserted: | %.2f | %.2f\n", (elapsed>0)?tup_ins/elapsed:0, (xact>0)?tup_ins/xact:0;
    printf "Rows updated: | %.2f | %.2f\n", (elapsed>0)?tup_upd/elapsed:0, (xact>0)?tup_upd/xact:0;
    printf "Rows deleted: | %.2f | %.2f\n", (elapsed>0)?tup_del/elapsed:0, (xact>0)?tup_del/xact:0;
    printf "Temp bytes (MB): | %.2f | %.2f\n", (elapsed>0)?temp_bytes/elapsed/1024/1024:0, (xact>0)?temp_bytes/xact/1024/1024:0;
    printf "Temp files: | %.2f | %.2f\n", (elapsed>0)?temp_files/elapsed:0, (xact>0)?temp_files/xact:0;
    printf "Buffer hit ratio: | %.4f | %.4f\n", hit_ratio, hit_ratio;
    printf "Block read time (ms): | %.2f | %.2f\n", (elapsed>0)?br_time/elapsed:0, (xact>0)?br_time/xact:0;
    printf "Block write time (ms): | %.2f | %.2f\n", (elapsed>0)?bw_time/elapsed:0, (xact>0)?bw_time/xact:0;
    printf "\n";
  }
' "$DB1" "$DB2" | append_block

write_out "Snapshot Delta (Target ${INTERVAL_SECONDS}s)"
append_block <<'EOF'

| Metric | Value | Notes |
|---|---|---|
EOF

awk -v elapsed="$ELAPSED" -F $'\t' '
  FNR==NR {a[$1]=$0; next}
  {
    if (!($1 in a)) next;
    split(a[$1], x, "\t");
    xact=(($2-x[2])+($3-x[3]));
    blks_read=($4-x[4]);
    blks_hit=($5-x[5]);
    tup_ret=($6-x[6]);
    tup_fet=($7-x[7]);
    tup_ins=($8-x[8]);
    tup_upd=($9-x[9]);
    tup_del=($10-x[10]);
    temp_bytes=($11-x[11]);
    hit_ratio=(blks_hit+blks_read>0)?blks_hit/(blks_hit+blks_read):0;
    printf "| Window_s | %d | Actual snapshot interval |\n", elapsed;
    printf "| TPS | %.2f | Δ(xact)/Δt |\n", (elapsed>0)?xact/elapsed:0;
    printf "| Buffer hit ratio | %.4f | Δ(hit)/(Δhit+Δread) |\n", hit_ratio;
    printf "| Rows returned/fetched per sec | %.0f / %.0f | Δ(tup_returned)/Δt, Δ(tup_fetched)/Δt |\n", (elapsed>0)?tup_ret/elapsed:0, (elapsed>0)?tup_fet/elapsed:0;
    printf "| Row writes per sec | ins %.0f/s, upd %.0f/s, del %.0f/s | Δ(tup_*)/Δt |\n", (elapsed>0)?tup_ins/elapsed:0, (elapsed>0)?tup_upd/elapsed:0, (elapsed>0)?tup_del/elapsed:0;
    printf "| Temp write rate | %.2f MB/s | Δ(temp_bytes)/Δt |\n", (elapsed>0)?temp_bytes/elapsed/1024/1024:0;
    exit;
  }
' "$DB1" "$DB2" | append_block

write_out ""
write_out "Checkpoint Storm Assessment (Window)"
append_block <<'EOF'

| Item | Verdict | Evidence |
|---|---|---|
EOF

awk -F $'\t' -v elapsed="$ELAPSED" '
  FNR==NR {a=$0; next}
  {
    split(a, x, "\t");
    ckpt_t=($1-x[1]);
    ckpt_r=($2-x[2]);
    ckpt_w=($3-x[3]);
    ckpt_s=($4-x[4]);
    buf_clean=($6-x[6]);
    buf_backend=($8-x[8]);
    backend_fsync=($9-x[9]);
    total_ckpt=ckpt_t+ckpt_r;
    avg_write=(total_ckpt>0)?ckpt_w/total_ckpt/1000:0;
    avg_sync=(total_ckpt>0)?ckpt_s/total_ckpt/1000:0;

    if (buf_backend+buf_clean==0) {
      print "| Backend/cleaner dirty flush ratio | No flushes in window | buffers_backend + buffers_clean = 0 |";
    } else {
      print "| Backend/cleaner dirty flush ratio | Check window | buffers_backend + buffers_clean > 0 |";
    }
    printf "| Requested checkpoints | %d | Δ(checkpoints_req) |\n", ckpt_r;
    printf "| Backend fsync count | %d | Δ(buffers_backend_fsync) |\n", backend_fsync;
    if (total_ckpt>0) {
      printf "| Avg checkpoint write/sync seconds | %.2f / %.2f | Δ(checkpoint_write_time)/Δckpt, Δ(checkpoint_sync_time)/Δckpt |\n", avg_write, avg_sync;
    } else {
      print "| Avg checkpoint write/sync seconds | No checkpoints | Window has no checkpoints |";
    }
  }
' "$BG1" "$BG2" | append_block

write_out ""
write_out "### Instance Efficiency Percentages (Target 100%)"
write_out ""

BUFFER_HIT=$(awk -F $'\t' 'FNR==NR {a=$0; next} {split(a,x,"\t"); hit=($5-x[5]); read=($4-x[4]); if (hit+read>0) printf "%.2f", (hit/(hit+read))*100; else print "N/A"; exit}' "$DB1" "$DB2")

append_block <<EOF
**Buffer Hit %:** | **${BUFFER_HIT}** | **Library Hit %:** | **N/A**
**Soft Parse %:** | **N/A** | **Execute to Parse %:** | **N/A**
**Latch Hit %:** | **N/A** | **Parse CPU to Parse Elapsed %:** | **N/A**
EOF

if [[ -n "$HAS_WAIT_SAMPLING" && -s "$WAIT_WINDOW" ]]; then
  write_out ""
  write_out "### Top 10 Foreground Events by Total Wait Time"
  write_out ""
  awk -F $'\t' '
    {
      wait_type=$1;
      wait_event=$2;
      waits=$3;
      if (wait_type ~ /Client|Timeout|Activity/) next;
      print wait_event"\t"waits"\t"wait_type;
    }
  ' "$WAIT_WINDOW" | sort -k2,2nr | head -10 | awk 'BEGIN{print "**Event** | **Waits** | **Wait Class**\n---|---|---"} {print $1" | "$2" | "$3}' | append_block

  write_out ""
  write_out "### Wait Classes by Total Wait Time"
  write_out ""
  awk -F $'\t' '
    {
      wait_type=$1;
      waits=$3;
      class=wait_type;
      if (wait_type ~ /Client|Timeout|Activity/) class="Idle";
      sum[class]+=waits;
      total+=waits;
    }
    END{
      print "**Wait Class** | **Waits** | **% Total Waits**\n---|---|---";
      for (c in sum) {
        pct=(total>0)?(sum[c]/total*100):0;
        printf "%s | %.0f | %.2f%%\n", c, sum[c], pct;
      }
    }
  ' "$WAIT_WINDOW" | append_block
fi

write_out ""
write_out "### Host CPU"
write_out ""
if [[ -r /proc/loadavg ]]; then
  LOAD_AVG=$(awk '{print $1" "$2" "$3}' /proc/loadavg)
else
  LOAD_AVG="N/A"
fi

CPU_STAT_START=$(awk '/cpu /{print $2,$3,$4,$5,$6,$7,$8}' /proc/stat)
sleep 1
CPU_STAT_END=$(awk '/cpu /{print $2,$3,$4,$5,$6,$7,$8}' /proc/stat)

CPU_PCT=$(awk -v start="$CPU_STAT_START" -v end="$CPU_STAT_END" '
  BEGIN{
    split(start, s, " ");
    split(end, e, " ");
    for (i=1;i<=7;i++) {diff[i]=e[i]-s[i]; total+=diff[i];}
    user=diff[1]+diff[2];
    sys=diff[3];
    idle=diff[4];
    iowait=diff[5];
    if (total==0) total=1;
    printf "%.1f\t%.1f\t%.1f\t%.1f", user/total*100, sys/total*100, iowait/total*100, idle/total*100;
  }
')

append_block <<EOF
**CPUs** | **Cores** | **Sockets** | **Load Average (1m/5m/15m)** | **%User** | **%System** | **%WIO** | **%Idle**
---|---|---|---|---|---|---|---
${CPUS} | ${CORES} | ${SOCKETS:-N/A} | ${LOAD_AVG} | $(echo "$CPU_PCT" | awk -F $'\t' '{print $1}') | $(echo "$CPU_PCT" | awk -F $'\t' '{print $2}') | $(echo "$CPU_PCT" | awk -F $'\t' '{print $3}') | $(echo "$CPU_PCT" | awk -F $'\t' '{print $4}')
EOF

write_out ""
write_out "### IO Profile"
write_out ""
awk -v elapsed="$ELAPSED" -F $'\t' '
  FNR==NR {a[$1]=$0; next}
  {
    if (!($1 in a)) next;
    split(a[$1], x, "\t");
    blks_read=($4-x[4]);
    blks_hit=($5-x[5]);
    printf "**Read+Write Per Second** | **Read Per Second** | **Write Per Second**\n";
    printf "---|---|---\n";
    printf "Database (blocks): | %.2f | %.2f\n", (elapsed>0)?(blks_read+blks_hit)/elapsed:0, (elapsed>0)?blks_read/elapsed:0;
    exit;
  }
' "$DB1" "$DB2" | append_block

write_out ""
write_out "### Memory Statistics"
write_out ""
HOST_MEM=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)
SHARED_BUFFERS=$(psql_query "select setting::int/128 from pg_settings where name='shared_buffers'")
WORK_MEM=$(psql_query "select setting::int/1024 from pg_settings where name='work_mem'")

append_block <<EOF
**Begin** | **End**
---|---
Host Mem (MB): | ${HOST_MEM} | ${HOST_MEM}
Shared Buffers (MB): | ${SHARED_BUFFERS} | ${SHARED_BUFFERS}
Work Mem (MB): | ${WORK_MEM} | ${WORK_MEM}
% Host Mem used for DB Memory: | $(awk -v sb="$SHARED_BUFFERS" -v hm="$HOST_MEM" 'BEGIN{if (hm>0) printf "%.2f", sb/hm*100; else print "0.00"}') | $(awk -v sb="$SHARED_BUFFERS" -v hm="$HOST_MEM" 'BEGIN{if (hm>0) printf "%.2f", sb/hm*100; else print "0.00"}')
EOF

write_out ""
write_out "### Cache Sizes"
write_out ""
EFFECTIVE_CACHE=$(psql_query "select setting from pg_settings where name='effective_cache_size'")
MAINT_WORK_MEM=$(psql_query "select setting from pg_settings where name='maintenance_work_mem'")

append_block <<EOF
**Begin** | **End**
---|---
Shared Buffers: | ${SHARED_BUFFERS}MB | ${SHARED_BUFFERS}MB
Work Mem: | ${WORK_MEM}MB | ${WORK_MEM}MB
Effective Cache Size: | ${EFFECTIVE_CACHE}kB | ${EFFECTIVE_CACHE}kB
Maintenance Work Mem: | ${MAINT_WORK_MEM}kB | ${MAINT_WORK_MEM}kB
EOF

write_out ""
write_out "### Instance Bottleneck Assessment (Based on AAS and Wait Profile)"
write_out ""

DB_TIME_MS="0"
if [[ -n "$HAS_STATEMENTS" ]]; then
  DB_TIME_MS=$(awk -F $'\t' '
    FNR==NR {a[$1]=$2; next}
    {delta=$2-(a[$1]?a[$1]:0); sum+=delta}
    END{printf "%.0f", sum}
  ' "$STAT1" "$STAT2")
fi

AAS=$(awk -v dbms="$DB_TIME_MS" -v elapsed="$ELAPSED" -v cpu="$CPUS" 'BEGIN{if (elapsed>0 && cpu>0) printf "%.3f", (dbms/1000)/elapsed/cpu; else print "0.000"}')

MAIN_WAIT="N/A"
if [[ -n "$HAS_WAIT_SAMPLING" && -s "$WAIT_WINDOW" ]]; then
  MAIN_WAIT=$(awk -F $'\t' '
    {
      wait_type=$1;
      waits=$3;
      if (wait_type ~ /Client|Timeout|Activity/) next;
      sum[wait_type]+=waits;
    }
    END{
      max=0; best="";
      for (c in sum) {if (sum[c]>max) {max=sum[c]; best=c;}}
      if (best=="") {print "N/A"} else {print best;}
    }
  ' "$WAIT_WINDOW")
fi

SUMMARY_NOTE="Idle or light workload in this window. No major database-layer bottleneck detected. If performance issues persist, collect another snapshot during peak workload.";
if awk "BEGIN{exit !(${AAS} > 1)}"; then
  SUMMARY_NOTE="AAS is above 1. Review Top SQL and wait classes to locate dominant bottlenecks.";
fi

append_block <<EOF
| Dimension | Result | Notes |
|---|---|---|
| AAS (Normalized) | ${AAS} | Current window DB Time / elapsed / effective CPU cores |
| Main Wait Type | ${MAIN_WAIT} | Aggregated from Top Wait Classes section |
| Overall Assessment | ${SUMMARY_NOTE} | Default to idle/light when AAS≤1 (当 AAS≤1 时默认为空闲/轻载) |
EOF

write_out ""
write_out "### Connection State Summary (pg_stat_activity)"
write_out ""
CONN_STATES=$(psql_query "select state, count(*) from pg_stat_activity group by state order by count desc")
if [[ -n "$CONN_STATES" ]]; then
  append_block <<'EOF'
| State | Count |
|---|---|
EOF
  printf "%s\n" "$CONN_STATES" | awk -F $'\t' '{print "| "$1" | "$2" |"}' | append_block
fi

write_out ""
write_out "### Connection Utilization (max_connections)"
write_out ""
USED_CONN=$(psql_query "select count(*) from pg_stat_activity")
if [[ -n "$MAX_CONNECTIONS" ]]; then
  UTIL=$(awk -v used="$USED_CONN" -v max="$MAX_CONNECTIONS" 'BEGIN{if (max>0) printf "%.2f", used/max*100; else print "0.00"}')
  STATUS="Normal"
  if awk "BEGIN{exit !(${UTIL} > 80)}"; then
    STATUS="High"
  fi
  append_block <<EOF
| Item | Value | Status |
|---|---|---|
| Max connections | ${MAX_CONNECTIONS} | — |
| Used connections | ${USED_CONN} | — |
| Remaining | $(awk -v used="$USED_CONN" -v max="$MAX_CONNECTIONS" 'BEGIN{print max-used}') | — |
| Utilization % | ${UTIL} | ${STATUS} |
EOF
fi

write_out ""
write_out "### Session Details (Top 10 by runtime)"
write_out ""
SESSION_ROWS=$(psql_query "select pid, usename, application_name, state, coalesce(wait_event_type,''), coalesce(wait_event,''), now()-query_start as runtime, left(regexp_replace(query, '\\s+', ' ', 'g'), 120) from pg_stat_activity where pid <> pg_backend_pid() order by runtime desc limit 10")
if [[ -n "$SESSION_ROWS" ]]; then
  append_block <<'EOF'
| PID | User | App | State | Wait Type | Wait Event | Runtime | SQL Snippet |
|---|---|---|---|---|---|---|---|
EOF
  printf "%s\n" "$SESSION_ROWS" | awk -F $'\t' '{print "| "$1" | "$2" | "$3" | "$4" | "$5" | "$6" | "$7" | "$8" |"}' | append_block
fi

write_out ""
write_out "### Lock Waits Summary"
write_out ""
LOCK_ROWS=$(psql_query "select locktype, mode, granted, count(*) from pg_locks where not granted group by locktype, mode, granted order by count desc")
if [[ -n "$LOCK_ROWS" ]]; then
  append_block <<'EOF'
| Lock Type | Lock Mode | Granted | Count |
|---|---|---|---|
EOF
  printf "%s\n" "$LOCK_ROWS" | awk -F $'\t' '{print "| "$1" | "$2" | "$3" | "$4" |"}' | append_block
fi

write_out ""
write_out "### Long Transactions (>5 min)"
write_out ""
LONG_TX=$(psql_query "select pid, usename, state, now()-xact_start as xact_age, left(regexp_replace(query, '\\s+', ' ', 'g'), 120) from pg_stat_activity where xact_start is not null and now()-xact_start > interval '5 minutes' order by xact_age desc")
if [[ -n "$LONG_TX" ]]; then
  append_block <<'EOF'
| PID | User | State | Transaction Age | SQL Snippet |
|---|---|---|---|---|
EOF
  printf "%s\n" "$LONG_TX" | awk -F $'\t' '{print "| "$1" | "$2" | "$3" | "$4" | "$5" |"}' | append_block
fi

write_out ""
write_out "### Key Parameter Snapshot (Tuning Related)"
write_out ""
PARAMS=$(psql_query "select name, setting from pg_settings where name in ('shared_buffers','work_mem','maintenance_work_mem','effective_cache_size','max_connections','checkpoint_timeout','checkpoint_completion_target','wal_buffers','wal_writer_delay','max_wal_size','min_wal_size','random_page_cost','effective_io_concurrency','autovacuum','autovacuum_vacuum_scale_factor','autovacuum_analyze_scale_factor','track_io_timing') order by name")
if [[ -n "$PARAMS" ]]; then
  append_block <<'EOF'
| Parameter | Value |
|---|---|
EOF
  printf "%s\n" "$PARAMS" | awk -F $'\t' '{print "| "$1" | "$2" |"}' | append_block
fi

write_out ""
write_out "### Top SQL (by average execution time)"
write_out ""
if [[ -n "$HAS_STATEMENTS" ]]; then
  TOP_SQL=$(psql_query "select md5(query), left(regexp_replace(query, '\\s+', ' ', 'g'), 120), calls, round(${STAT_MEAN_COL}/1000,4), round(${STAT_TOTAL_COL}/1000,2), round(blk_read_time/1000,2), round((${STAT_TOTAL_COL} - blk_read_time - blk_write_time)/1000,2) from pg_stat_statements order by ${STAT_MEAN_COL} desc limit 5")
  if [[ -n "$TOP_SQL" ]]; then
    append_block <<'EOF'
| md5(query) | SQL Snippet | Calls | Avg Exec_s | Total Exec_s | IO_s | CPU_s |
|---|---|---|---|---|---|---|
EOF
    printf "%s\n" "$TOP_SQL" | awk -F $'\t' '{print "| "$1" | "$2" | "$3" | "$4" | "$5" | "$6" | "$7" |"}' | append_block
  fi
fi

write_out ""
write_out "### Log Scan Summary"
write_out ""
LOG_COLLECTOR=$(psql_query "select setting from pg_settings where name='logging_collector'")
LOG_DEST=$(psql_query "select setting from pg_settings where name='log_destination'")
LOG_DIR=$(psql_query "select setting from pg_settings where name='log_directory'")
DATA_DIR=$(psql_query "select setting from pg_settings where name='data_directory'")

append_block <<EOF
| Item | Value |
|---|---|
| logging_collector | ${LOG_COLLECTOR} |
| log_destination | ${LOG_DEST} |
| log_directory | ${LOG_DIR} |
| data_directory | ${DATA_DIR} |
EOF
