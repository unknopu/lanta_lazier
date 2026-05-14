#!/usr/bin/env bash
set -euo pipefail

# LANTA helper script
#
# This script connects to the LANTA transfer node and handles a few common
# account and file tasks:
#   - show your job queue
#   - cancel all jobs shown by myqueue
#   - show your compute balance
#   - discover home/project paths from myquota
#   - submit the shared Jupyter GPU job script
#   - upload local files/directories to LANTA
#
# Run "./script.sh --help" for the full argument reference.

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
readonly SCRIPT_NAME="$(basename "$0")"
readonly TRANSFER_HOST="transfer.lanta.nstda.or.th"
readonly TUNNEL_HOST="lanta.nstda.or.th"
readonly JUPYTER_GPU_SCRIPT="/project/zz992000-zdevb/Miniforge3/Jupyter_GPU/Jupyter_Script.sh"
readonly JUPYTER_ACCOUNT_SUFFIX="2005"

# ---------------------------------------------------------------------------
# Runtime state
# ---------------------------------------------------------------------------
user=""
upload_src=""
upload_target=""
running_time=""

show_queue="false"
show_balance="false"
init_env="false"
clear_all="false"

home_path=""
project_path=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage:
  ${SCRIPT_NAME} --user <username> [options]
  ${SCRIPT_NAME} --help

Connect to the LANTA transfer node and run common account, quota, environment,
and upload tasks.

Required:
  -u, -user, --user <username>
      LANTA username used for SSH/SCP connections.
      Example: --user myname

Options:
  --upload, -upload <source> [target]
      Upload a local file or directory to LANTA with scp -r.
      If [target] is not provided, the script uploads to your LANTA home path
      detected from myquota.

  --time <HH:MM>
      Runtime for the Jupyter GPU job submitted with --init.
      Runtime must be at least 30 minutes and no more than 24 hours.
      If omitted, the script prompts and defaults to 1:00.
      When running through curl | bash without terminal input, it uses 1:00.

  -q, --queue
      Show your LANTA job queue by running myqueue on the transfer node.
      This command exits after displaying the queue.

  --clear-all
      Show your LANTA job queue, then cancel every listed job with scancel.
      This command exits after cancelling the jobs.

  -bl, --balance
      Show your LANTA compute balance by running sbalance on the transfer node.
      This command exits after displaying the balance.

  --init
      Check that the shared Jupyter GPU job script exists, copy it to home_path,
      replace the account suffix 1xxx with 2005, then submit it with sbatch.
      When the Jupyter URL appears, forward it to localhost:80, 8080, 8888,
      9000, or 9999. The final output prints forwarded_url and token.
      This command exits after initialization.

  -h, --help
      Show this help message and exit.

Default behavior:
  When no action option is provided, the script runs myquota on the transfer node,
  prints the detected home_path and project_path, then exits.

Examples:
  ${SCRIPT_NAME} --user myname
  ${SCRIPT_NAME} -u myname --queue
  ${SCRIPT_NAME} -u myname --clear-all
  ${SCRIPT_NAME} -u myname --balance
  ${SCRIPT_NAME} -u myname --init
  ${SCRIPT_NAME} -u myname --time 2:00 --init
  ${SCRIPT_NAME} -u myname --upload ./data
  ${SCRIPT_NAME} -u myname --upload ./data /project/<project-id>/

Curl examples:
  curl -fsSL https://pangpuriye.info/jiaoben/lanta | bash -s -- -u myname --init
  curl -fsSL https://pangpuriye.info/jiaoben/lanta | bash -s -- -u myname --time 2:00 --init
  curl -fsSL https://pangpuriye.info/jiaoben/lanta | bash -s -- -u myname --clear-all
EOF
}

fail() {
  printf '%s\n' "$1" >&2
  printf 'Run %s --help for usage.\n' "${SCRIPT_NAME}" >&2
  exit 1
}

require_value() {
  local option="$1"
  local remaining="$2"

  if [[ "${remaining}" -lt 2 ]]; then
    fail "Missing value for ${option}"
  fi
}

remote() {
  ssh "${user}@${TRANSFER_HOST}" "$@"
}

local_port_busy() {
  local port="$1"

  if command -v lsof >/dev/null 2>&1; then
    lsof -n -P -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1
    return
  fi

  if command -v nc >/dev/null 2>&1; then
    nc -z 127.0.0.1 "${port}" >/dev/null 2>&1
    return
  fi

  return 1
}

forward_jupyter_port() {
  local remote_output="$1"
  local jupyter_url
  local tunnel_spec
  local target_host=""
  local remote_port=""
  local local_port
  local forwarded_url
  local jupyter_token
  local token_regex='[?&]token=([^&#[:space:]]+)'

  jupyter_url=$(printf '%s\n' "${remote_output}" | sed -n 's/^jupyter_url=//p' | sed -n '1p')
  tunnel_spec=$(printf '%s\n' "${remote_output}" | sed -n 's/^tunnel_spec=//p' | sed -n '1p')

  if [[ -z "${jupyter_url}" ]]; then
    printf '%s\n' 'No Jupyter URL found, skipping local port forwarding.'
    return 0
  fi

  if [[ "${tunnel_spec}" =~ ^[0-9]+:([^:]+):([0-9]+)$ ]]; then
    target_host="${BASH_REMATCH[1]}"
    remote_port="${BASH_REMATCH[2]}"
  elif [[ "${jupyter_url}" =~ ^http://127[.]0[.]0[.]1:([0-9]+)/ ]]; then
    target_host="127.0.0.1"
    remote_port="${BASH_REMATCH[1]}"
  else
    printf 'Could not detect Jupyter port from URL: %s\n' "${jupyter_url}" >&2
    return 1
  fi

  for local_port in 80 8080 8888 9000 9999; do
    if local_port_busy "${local_port}"; then
      printf 'local port %s is busy, trying next port\n' "${local_port}"
      continue
    fi

    printf 'forwarding localhost:%s -> %s:%s through %s\n' "${local_port}" "${target_host}" "${remote_port}" "${TUNNEL_HOST}"
    if ssh -f -N -o ExitOnForwardFailure=yes -L "${local_port}:${target_host}:${remote_port}" "${user}@${TUNNEL_HOST}"; then
      forwarded_url="${jupyter_url/127.0.0.1:${remote_port}/localhost:${local_port}}"
      printf "\n\n\n==================== YOUR URL ====================\n"
      printf 'forwarded_url=%s\n' "${forwarded_url}"
      if [[ "${forwarded_url}" =~ ${token_regex} ]]; then
        jupyter_token="${BASH_REMATCH[1]}"
        printf 'token=%s\n' "${jupyter_token}"
      fi
      printf "==================== YOUR URL ====================\n"
      return 0
    fi

    printf 'could not use local port %s, trying next port\n' "${local_port}" >&2
  done

  printf '%s\n' 'Could not forward Jupyter port. Tried local ports: 80, 8080, 8888, 9000, 9999.' >&2
  return 1
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      -u|-user|--user)
        require_value "$1" "$#"
        user="$2"
        shift 2
        ;;
      --upload|-upload)
        require_value "$1" "$#"
        upload_src="$2"

        if [[ $# -ge 3 && "$3" != -* ]]; then
          upload_target="$3"
          shift 3
        else
          shift 2
        fi
        ;;
      --time)
        require_value "$1" "$#"
        running_time="$2"
        shift 2
        ;;
      -q|--queue)
        show_queue="true"
        shift
        ;;
      --clear-all)
        clear_all="true"
        shift
        ;;
      -bl|--balance)
        show_balance="true"
        shift
        ;;
      --init)
        init_env="true"
        shift
        ;;
      *)
        fail "Unknown option: $1"
        ;;
    esac
  done

  if [[ -z "${user}" ]]; then
    fail "Missing required option: --user <username>"
  fi
}

# ---------------------------------------------------------------------------
# LANTA path discovery
# ---------------------------------------------------------------------------
load_lanta_paths() {
  local paths

  paths=$(remote myquota | awk '/^\// {print $1}')
  home_path=$(printf '%s\n' "${paths}" | sed -n '1p')
  project_path=$(printf '%s\n' "${paths}" | sed -n '2p')

  if [[ -z "${home_path}" ]]; then
    fail "Could not detect home_path from myquota."
  fi
}

print_lanta_paths() {
  printf 'home_path=%s\n' "${home_path}"
  printf 'project_path=%s\n' "${project_path}"
}

normalize_running_time() {
  local hours
  local minutes
  local hours_value
  local minutes_value

  if [[ -z "${running_time}" ]]; then
    printf "\n--------------------\n"
    printf 'please specify running time (default 1h; hh:mm):\n'
    if [[ -t 0 ]]; then
      if ! read -r running_time; then
        running_time=""
      fi
    elif ! { read -r running_time </dev/tty; } 2>/dev/null; then
      running_time=""
    else
      running_time=""
    fi

    if [[ -z "${running_time}" ]]; then
      running_time="1:00"
    fi
  fi

  if [[ ! "${running_time}" =~ ^([0-9]{1,2}):([0-9]{1,2})$ ]]; then
    fail "Invalid --time value: ${running_time}. Use HH:MM, for example 1:30."
  fi

  hours="${BASH_REMATCH[1]}"
  minutes="${BASH_REMATCH[2]}"
  hours_value=$((10#${hours}))
  minutes_value=$((10#${minutes}))

  if (( hours_value == 0 && minutes_value == 0 )); then
    fail "Invalid --time value: 00:00 is not allowed."
  fi

  if (( hours_value > 24 )); then
    fail "Invalid --time hours: ${hours}. Hours must be between 0 and 24."
  fi

  if (( minutes_value > 59 )); then
    fail "Invalid --time minutes: ${minutes}. Minutes must be between 0 and 59."
  fi

  if (( hours_value == 24 && minutes_value != 0 )); then
    fail "Invalid --time value: ${running_time}. Maximum runtime is 24:00."
  fi

  if (( (hours_value * 60 + minutes_value) < 30 )); then
    fail "Invalid --time value: ${running_time}. Runtime must be at least 30 minutes."
  fi

  printf -v running_time '%d:%02d' "${hours_value}" "${minutes_value}"
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------
show_remote_queue() {
  remote myqueue
}

show_remote_balance() {
  remote sbalance
}

clear_all_remote_jobs() {
  local queue_output
  local job_ids
  local job_id

  queue_output=$(remote myqueue)
  printf '%s\n' "${queue_output}"

  job_ids=$(printf '%s\n' "${queue_output}" | awk '$1 ~ /^[0-9]+$/ {print $1}')
  if [[ -z "${job_ids}" ]]; then
    printf '%s\n' 'No jobs found to cancel.'
    return 0
  fi

  for job_id in ${job_ids}; do
    printf 'scancel %s\n' "${job_id}"
    remote scancel "${job_id}"
  done
}

submit_jupyter_gpu_script() {
  local remote_output
  local staged_script

  staged_script="${home_path}/$(basename "${JUPYTER_GPU_SCRIPT}")"

  printf "========= init env =========\n"
  printf 'submitting Jupyter GPU script: %s\n' "${JUPYTER_GPU_SCRIPT}"
  printf 'staging script at: %s\n' "${staged_script}"
  printf 'replacing account suffix 1xxx with: %s\n' "${JUPYTER_ACCOUNT_SUFFIX}"
  printf 'setting running time to: %s:00\n' "${running_time}"

  remote_output=$(remote bash -s -- "${JUPYTER_GPU_SCRIPT}" "${staged_script}" "${JUPYTER_ACCOUNT_SUFFIX}" "${running_time}:00" "${home_path}" <<'REMOTE_SCRIPT'
set -euo pipefail

jupyter_gpu_script="$1"
staged_script="$2"
account_suffix="$3"
running_time="$4"
home_path="$5"

if [[ ! -f "${jupyter_gpu_script}" ]]; then
  printf 'Missing Jupyter GPU script: %s\n' "${jupyter_gpu_script}" >&2
  exit 1
fi

cp "${jupyter_gpu_script}" "${staged_script}"
sed -i "s/1xxx/${account_suffix}/g" "${staged_script}"
sed -i -E "s/^#SBATCH[[:space:]]+-t[[:space:]]+[^[:space:]]+/#SBATCH -t ${running_time}/" "${staged_script}"

cd "${home_path}"
sbatch_output=$(sbatch "${staged_script}")
printf '%s\n' "${sbatch_output}"

job_id=$(printf '%s\n' "${sbatch_output}" | awk '/Submitted batch job/ {print $4}')
if [[ -z "${job_id}" ]]; then
  printf '%s\n' 'Could not detect job id from sbatch output.' >&2
  exit 1
fi

out_file="slurm-${job_id}.out"
url_pattern='http://127[.]0[.]0[.]1:[0-9]+/(tree|lab)[?]token=[^[:space:]]+'

printf "======================\n"
printf 'job_id=%s\n' "${job_id}"
printf 'slurm_output=%s/%s\n' "${home_path}" "${out_file}"
printf '%s\n' 'waiting for Jupyter URL...'

for _ in $(seq 1 60); do
  if [[ -f "${out_file}" ]]; then
    url=$(grep -Eo "${url_pattern}" "${out_file}" | head -n 1 || true)
    if [[ -n "${url}" ]]; then
      tunnel_spec=$(grep -Eo 'ssh[[:space:]]+-L[[:space:]]+[0-9]+:[^:[:space:]]+:[0-9]+' "${out_file}" | head -n 1 | awk '{print $3}' || true)
      cat "${out_file}"
      printf "* ======================= *\n"
      printf 'jupyter_url=%s\n' "${url}"
      if [[ -n "${tunnel_spec}" ]]; then
        printf 'tunnel_spec=%s\n' "${tunnel_spec}"
      fi
      printf "* ======================= *\n"
      exit 0
    fi
  fi
  sleep 2
done

if [[ -f "${out_file}" ]]; then
  cat "${out_file}"
fi

printf '%s\n' 'Jupyter URL not found yet. Check the slurm output file above after the job starts.'
REMOTE_SCRIPT
)
  printf '%s\n' "${remote_output}"
  forward_jupyter_port "${remote_output}"
  printf 'everything is now set, good luck!\n'
}

upload_to_lanta() {
  if [[ -z "${upload_target}" ]]; then
    upload_target="${home_path}"
  fi

  scp -r "${upload_src}" "${user}@${TRANSFER_HOST}:${upload_target}"
}

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"

  load_lanta_paths
  print_lanta_paths

  if [[ "${show_queue}" == "true" ]]; then
    show_remote_queue
    exit 0
  fi

  if [[ "${show_balance}" == "true" ]]; then
    show_remote_balance
    exit 0
  fi

  if [[ "${clear_all}" == "true" ]]; then
    clear_all_remote_jobs
    exit 0
  fi

  if [[ "${init_env}" == "true" ]]; then
    normalize_running_time
    submit_jupyter_gpu_script
    exit 0
  fi

  if [[ -n "${upload_src}" ]]; then
    upload_to_lanta
  fi
}

main "$@"
