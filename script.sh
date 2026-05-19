#!/usr/bin/env bash
set -euo pipefail

# LANTA helper script
#
# This script connects to the LANTA transfer node and handles a few common
# account and file tasks:
#   - show your job queue
#   - cancel all jobs shown by myqueue/squeue
#   - show your compute balance
#   - discover home/project paths from myquota
#   - generate and install your local SSH public key
#   - submit the GitHub-hosted Jupyter GPU job script
#   - upload local files/directories to LANTA
#   - run a quoted command on the LANTA login shell
#
# Run "./script.sh --help" for the full argument reference.

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
readonly SCRIPT_NAME="$(basename "$0")"
readonly TRANSFER_HOST="transfer.lanta.nstda.or.th"
readonly TUNNEL_HOST="lanta.nstda.or.th"
readonly JUPYTER_GPU_SCRIPT_URL="https://pangpuriye.info/jiaoben/jupyter_xianshika"

# ---------------------------------------------------------------------------
# Runtime state
# ---------------------------------------------------------------------------
user=""
upload_src=""
upload_target=""
running_time=""
pip_packages=""
remote_command=""

show_queue="false"
show_balance="false"
init_env="false"
clear_all="false"
auto_pub_gen="false"
slote_mode="false"

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
      Upload a local file or directory to LANTA through lanta.nstda.or.th with scp -r.
      If [target] is not provided, the script uploads to your LANTA home path
      detected from myquota.

  -t, --time <HH:MM>
      Runtime for the Jupyter GPU job submitted with --init.
      Runtime must be at least 30 minutes and no more than 24 hours.
      If omitted, the script uses 1:00.

  -q, --queue
      Show your LANTA job queue by running myqueue when available, otherwise squeue.
      This command exits after displaying the queue.

  --clear-all
      Show your LANTA job queue, then cancel every listed job with scancel.
      Uses myqueue when available, otherwise falls back to Slurm squeue.
      Also removes slurm-<job-id>.out files from your detected home_path and
      kills local processes listening on ports 80, 8080, 8888, 9000, and 9999,
      prints each deleted file.
      This command exits after cancelling the jobs.

  --auto-pub-gen
      List local ~/.ssh, show ~/.ssh/id_ed25519.pub, create the key if missing,
      then add the public key to remote ~/.ssh/authorized_keys.
      Missing keys are created as Ed25519 keys with an empty passphrase.
      Existing authorized_keys entries are detected and not duplicated.
      This command exits after installing the key.

  --pip "<package...>"
      SSH to lanta.nstda.or.th and install the quoted pip package args.
      Before running pip, the script loads Miniforge3/25.3.0-3 and cuda/11.8,
      activates ~/venv3.6.9/, prints which pip, then runs pip install <package...>.
      Example: --pip "numpy pandas matplotlib"
      This command exits after installing the packages.

  --cmd "<command>"
      SSH to lanta.nstda.or.th, load your login shell profile files, then run
      the quoted command.
      Example: --cmd "ollama list"
      This command exits after the command finishes.

  --slote
      Shortcut for the first two recommended steps:
      1. --auto-pub-gen
      2. --time 2:00 --init
      If you are lazy to follow the order, run this, but don't forget to run
      --clear-all after your job is done!!!!

  -bl, --balance
      Show your LANTA compute balance by running sbalance through the LANTA login shell.
      This command exits after displaying the balance.

  --init
      First initialize your LANTA home environment on lanta.nstda.or.th:
      load Miniforge3 and cuda/11.8, verify ./venv3.6.9 with conda env list,
      create ./venv3.6.9 with Python 3.6.9 if missing, and create workspace/.
      Then download jupyter.sh from GitHub to home_path through
      lanta.nstda.or.th, set its runtime, and submit it with sbatch through
      transfer.lanta.nstda.or.th. When the Jupyter URL appears, forward it to
      localhost:80, 8080, 8888, 9000, or 9999. The final output prints
      forwarded_url and token.
      This command exits after initialization.

  -h, --help
      Show this help message and exit.

Default behavior:
  When no action option is provided, the script runs myquota on the transfer node,
  prints the detected home_path and project_path, then exits.

  Other useful commands:
       ${SCRIPT_NAME} --user myname
       ${SCRIPT_NAME} -u myname --balance
       ${SCRIPT_NAME} -u myname --queue
       ${SCRIPT_NAME} -u myname --cmd "ollama list"
       ${SCRIPT_NAME} -u myname --pip "numpy pandas matplotlib"
       ${SCRIPT_NAME} -u myname --upload ./data
       ${SCRIPT_NAME} -u myname --upload ./data /project/<project-id>/

Curl examples:
  Recommended running sequence:
    1. First-time SSH setup:
       curl -fsSL https://pangpuriye.info/jiaoben/lanta | bash -s -- -u myname --auto-pub-gen

    2. Start Jupyter for 2 hours:
       curl -fsSL https://pangpuriye.info/jiaoben/lanta | bash -s -- -u myname --time 2:00 --init

    Optional. Install pip packages into ~/venv3.6.9/ on the internet-access node:
       curl -fsSL https://pangpuriye.info/jiaoben/lanta | bash -s -- -u myname --pip "numpy pandas matplotlib"

    Optional. Run a command on lanta.nstda.or.th:
       curl -fsSL https://pangpuriye.info/jiaoben/lanta | bash -s -- -u myname --cmd "ollama list"

    Optional. Upload a local file through lanta.nstda.or.th:
       curl -fsSL https://pangpuriye.info/jiaoben/lanta | bash -s -- -u ub888 --upload ./yolo.pt /home/ub888/

    3. Clean up jobs, slurm output files, and local forwarded ports after your job is done:
       curl -fsSL https://pangpuriye.info/jiaoben/lanta | bash -s -- -u myname --clear-all

*********************************************
  If you are lazy to follow the order, run this, but don't forget to run 
  "--clear-all" after your job is done!!!!
*********************************************
       curl -fsSL https://pangpuriye.info/jiaoben/lanta | bash -s -- -u myname --slote

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

remote_transfer() {
  ssh -n "${user}@${TRANSFER_HOST}" "$@"
}

shell_quote_args() {
  local quoted=""
  local arg
  local arg_quoted

  for arg in "$@"; do
    printf -v arg_quoted '%q' "${arg}"
    quoted+="${quoted:+ }${arg_quoted}"
  done

  printf '%s' "${quoted}"
}

single_quote() {
  local value="$1"

  printf "'%s'" "${value//\'/\'\\\'\'}"
}

remote_lanta_login() {
  local command

  command=$(shell_quote_args "$@")
  remote_lanta_login_script "${command}"
}

remote_lanta_login_script() {
  local command="$1"
  local script

  script=$'shopt -s expand_aliases\n'
  script+=$'source /etc/profile >/dev/null 2>&1 || true\n'
  script+=$'source ~/.bash_profile >/dev/null 2>&1 || true\n'
  script+=$'source ~/.bash_login >/dev/null 2>&1 || true\n'
  script+=$'source ~/.profile >/dev/null 2>&1 || true\n'
  script+=$'source ~/.bashrc >/dev/null 2>&1 || true\n'
  script+="${command}"

  ssh -n "${user}@${TUNNEL_HOST}" "bash -lc $(single_quote "${script}")"
}

remote_queue_display_script() {
  cat <<'EOF'
queue_user="${USER:-}"
if [[ -z "${queue_user}" ]]; then
  queue_user=$(id -un)
fi

if type myqueue >/dev/null 2>&1; then
  myqueue
elif command -v squeue >/dev/null 2>&1; then
  squeue -u "${queue_user}"
else
  printf "%s\n" "Neither myqueue nor squeue is available on LANTA." >&2
  exit 127
fi
EOF
}

remote_queue_job_ids_script() {
  cat <<'EOF'
queue_user="${USER:-}"
if [[ -z "${queue_user}" ]]; then
  queue_user=$(id -un)
fi

if command -v squeue >/dev/null 2>&1; then
  squeue -h -u "${queue_user}" -o "%A" | awk "NF {print \$1}" | sort -u
elif type myqueue >/dev/null 2>&1; then
  myqueue | awk "\$1 ~ /^[0-9]+/ {print \$1}" | sort -u
else
  printf "%s\n" "Neither myqueue nor squeue is available on LANTA." >&2
  exit 127
fi
EOF
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
  elif [[ "${jupyter_url}" =~ ^http://([^/:]+):([0-9]+)/ ]]; then
    target_host="${BASH_REMATCH[1]}"
    remote_port="${BASH_REMATCH[2]}"
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
      forwarded_url="${jupyter_url/${target_host}:${remote_port}/localhost:${local_port}}"
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

remove_jupyter_slurm_output() {
  local remote_output="$1"
  local job_id
  local slurm_file

  job_id=$(printf '%s\n' "${remote_output}" | sed -n 's/^job_id=//p' | sed -n '1p')
  if [[ -z "${job_id}" ]]; then
    return 0
  fi

  slurm_file="${home_path}/slurm-${job_id}.out"
  remote rm -f "${slurm_file}"
  printf 'removed_slurm_output=%s\n' "${slurm_file}"
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
      -t|--time)
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
      --auto-pub-gen)
        auto_pub_gen="true"
        shift
        ;;
      --pip)
        require_value "$1" "$#"
        pip_packages="$2"
        shift 2
        ;;
      --cmd)
        require_value "$1" "$#"
        remote_command="$2"
        shift 2
        ;;
      --slote)
        slote_mode="true"
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

  paths=$(remote_transfer myquota | awk '/^\// {print $1}')
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
    running_time="1:00"
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
  remote_lanta_login_script "$(remote_queue_display_script)"
}

show_remote_balance() {
  remote_lanta_login sbalance
}

run_remote_command() {
  printf "========= remote command =========\n"
  printf 'ssh_target=%s@%s\n' "${user}" "${TUNNEL_HOST}"
  printf 'command=%s\n' "${remote_command}"

  remote_lanta_login_script "${remote_command}"
}

initialize_home_environment() {
  local expected_env
  local init_script

  expected_env="${home_path}/venv3.6.9"

  printf "========= initialize home environment =========\n"
  printf 'ssh_target=%s@%s\n' "${user}" "${TUNNEL_HOST}"
  printf 'home_path=%s\n' "${home_path}"
  printf 'venv_path=%s\n' "${expected_env}"
  printf 'workspace_path=%s/workspace\n' "${home_path}"

  init_script=$(cat <<'REMOTE_SCRIPT'
home_path="$1"
expected_env="$2"

shopt -s expand_aliases
source /etc/profile >/dev/null 2>&1 || true
if ! type ml >/dev/null 2>&1; then
  source /usr/share/Modules/init/bash >/dev/null 2>&1 || true
fi
if ! type ml >/dev/null 2>&1; then
  source /etc/profile.d/modules.sh >/dev/null 2>&1 || true
fi

set -euo pipefail

cd "${home_path}"
printf 'running: ml load Miniforge3/25.3.0-3 cuda/11.8\n'
ml load Miniforge3/25.3.0-3 cuda/11.8

printf 'running: conda env list | grep %s\n' "${expected_env}"
if conda env list | grep -F "${expected_env}"; then
  printf 'confirmation\n'
else
  printf 'running: conda create --prefix ./venv3.6.9 python=3.6.9 -y\n'
  conda create --prefix ./venv3.6.9 python=3.6.9 -y
fi

eval "$(conda shell.bash hook)"
conda activate "${expected_env}"
printf 'running: which python\n'
which python
printf 'running: which pip\n'
which pip
printf 'running: pip install notebook ipykernel\n'
pip install notebook ipykernel

mkdir -p "${home_path}/workspace"
printf 'workspace_path=%s/workspace\n' "${home_path}"
REMOTE_SCRIPT
)

  ssh "${user}@${TUNNEL_HOST}" "bash -s -- $(single_quote "${home_path}") $(single_quote "${expected_env}")" <<<"${init_script}"
}

clear_all_remote_jobs() {
  local queue_output
  local job_ids
  local job_id

  queue_output=$(remote_lanta_login_script "$(remote_queue_display_script)")
  printf '%s\n' "${queue_output}"

  job_ids=$(remote_lanta_login_script "$(remote_queue_job_ids_script)")
  if [[ -z "${job_ids}" ]]; then
    printf '%s\n' 'No jobs found to cancel.'
  else
    for job_id in ${job_ids}; do
      printf "\n\n======================\n"
      printf 'scancel %s\n' "${job_id}"
      remote_lanta_login scancel "${job_id}"
    done
  fi

  remove_home_slurm_outputs
  kill_local_forwarding_ports
}

remove_home_slurm_outputs() {
  local deleted_files

  deleted_files=$(remote_lanta_login find "${home_path}" -maxdepth 1 -type f -name 'slurm-[0-9]*.out' -delete -print)
  if [[ -z "${deleted_files}" ]]; then
    printf 'No slurm output files found in %s.\n' "${home_path}"
    return 0
  fi

  printf '%s\n' 'Deleted slurm output files:'
  printf '%s\n' "${deleted_files}"
}

kill_local_forwarding_ports() {
  local local_port
  local pids
  local pid

  if ! command -v lsof >/dev/null 2>&1; then
    printf '%s\n' 'lsof is not available; skipping local port cleanup.' >&2
    return 0
  fi

  for local_port in 80 8080 8888 9000 9999; do
    pids=$(lsof -tiTCP:"${local_port}" -sTCP:LISTEN 2>/dev/null || true)
    if [[ -z "${pids}" ]]; then
      printf 'No local process found on port %s.\n' "${local_port}"
      continue
    fi

    for pid in ${pids}; do
      printf 'kill -9 %s # local port %s\n' "${pid}" "${local_port}"
      if kill -9 "${pid}" 2>/dev/null; then
        printf 'killed local process %s on port %s.\n' "${pid}" "${local_port}"
      else
        printf 'Could not kill local process %s on port %s.\n' "${pid}" "${local_port}" >&2
      fi
    done
  done
}

install_pip_libraries() {
  local pip_args=()
  local remote_args

  read -r -a pip_args <<<"${pip_packages}"
  if (( ${#pip_args[@]} == 0 )); then
    fail "Missing package names for --pip"
  fi

  remote_args=$(shell_quote_args "${pip_args[@]}")

  printf "========= pip install =========\n"
  printf 'ssh_target=%s@%s\n' "${user}" "${TUNNEL_HOST}"
  printf 'packages=%s\n' "${pip_packages}"

  ssh "${user}@${TUNNEL_HOST}" "bash -s -- ${remote_args}" <<'REMOTE_SCRIPT'
shopt -s expand_aliases
source /etc/profile >/dev/null 2>&1 || true
if ! type ml >/dev/null 2>&1; then
  source /usr/share/Modules/init/bash >/dev/null 2>&1 || true
fi
if ! type ml >/dev/null 2>&1; then
  source /etc/profile.d/modules.sh >/dev/null 2>&1 || true
fi

set -euo pipefail

printf 'running: ml load Miniforge3/25.3.0-3 cuda/11.8\n'
ml load Miniforge3/25.3.0-3 cuda/11.8

eval "$(conda shell.bash hook)"

printf 'running: conda activate ~/venv3.6.9/\n'
conda activate ~/venv3.6.9/

printf 'running: which pip\n'
which pip

printf 'running: pip install'
printf ' %q' "$@"
printf '\n'
pip install "$@"
REMOTE_SCRIPT
}

auto_pub_gen() {
  local ssh_dir="${HOME}/.ssh"
  local private_key="${ssh_dir}/id_ed25519"
  local public_key="${private_key}.pub"
  local public_key_value
  local remote_script

  printf 'local_ssh_dir=%s\n' "${ssh_dir}"
  if [[ -d "${ssh_dir}" ]]; then
    ls -la "${ssh_dir}"
  else
    mkdir -p "${ssh_dir}"
    chmod 700 "${ssh_dir}"
    printf 'created %s\n' "${ssh_dir}"
  fi

  if [[ -f "${public_key}" ]]; then
    printf 'found %s\n' "${public_key}"
  elif [[ -f "${private_key}" ]]; then
    printf 'found %s but missing public key; regenerating %s\n' "${private_key}" "${public_key}"
    ssh-keygen -y -f "${private_key}" >"${public_key}"
    chmod 644 "${public_key}"
  else
    printf 'creating %s and %s\n' "${private_key}" "${public_key}"
    ssh-keygen -q -t ed25519 -N "" -f "${private_key}" -C "${user}@lanta"
    chmod 600 "${private_key}"
    chmod 644 "${public_key}"
  fi

  public_key_value=$(cat "${public_key}")
  if [[ -z "${public_key_value}" ]]; then
    fail "Public key is empty: ${public_key}"
  fi

  printf '\npublic_key_file=%s\n' "${public_key}"
  printf '%s\n\n' "${public_key_value}"

  remote_script=$'set -euo pipefail\n'
  remote_script+=$'umask 077\n'
  remote_script+=$'public_key="$1"\n'
  remote_script+=$'mkdir -p ~/.ssh\n'
  remote_script+=$'touch ~/.ssh/authorized_keys\n'
  remote_script+=$'chmod 700 ~/.ssh\n'
  remote_script+=$'chmod 600 ~/.ssh/authorized_keys\n'
  remote_script+=$'if grep -qxF "ssh-ed25519" ~/.ssh/authorized_keys; then\n'
  remote_script+=$'  tmp_file=$(mktemp)\n'
  remote_script+=$'  awk '\''$0 != "ssh-ed25519" {print}'\'' ~/.ssh/authorized_keys > "${tmp_file}"\n'
  remote_script+=$'  cat "${tmp_file}" > ~/.ssh/authorized_keys\n'
  remote_script+=$'  rm -f "${tmp_file}"\n'
  remote_script+=$'  chmod 600 ~/.ssh/authorized_keys\n'
  remote_script+=$'  printf "%s\\n" "removed incomplete ssh-ed25519 entry from ~/.ssh/authorized_keys"\n'
  remote_script+=$'fi\n'
  remote_script+=$'if grep -qxF "${public_key}" ~/.ssh/authorized_keys; then\n'
  remote_script+=$'  printf "%s\\n" "public key already exists in ~/.ssh/authorized_keys"\n'
  remote_script+=$'else\n'
  remote_script+=$'  printf "%s\\n" "${public_key}" >> ~/.ssh/authorized_keys\n'
  remote_script+=$'  printf "%s\\n" "public key added to ~/.ssh/authorized_keys"\n'
  remote_script+=$'fi\n'

  ssh "${user}@${TRANSFER_HOST}" "bash -s -- $(single_quote "${public_key_value}")" <<<"${remote_script}"
}

submit_jupyter_gpu_script() {
  local remote_output
  local remote_output_file
  local staged_script

  staged_script="${home_path}/jupyter.sh"

  printf "========= init env =========\n"
  printf 'downloading Jupyter GPU script: %s\n' "${JUPYTER_GPU_SCRIPT_URL}"
  printf 'download host: %s\n' "${TUNNEL_HOST}"
  printf 'submit host: %s\n' "${TRANSFER_HOST}"
  printf 'staging script at: %s\n' "${staged_script}"
  printf 'setting running time to: %s:00\n' "${running_time}"

  ssh "${user}@${TUNNEL_HOST}" "bash -s -- $(single_quote "${JUPYTER_GPU_SCRIPT_URL}") $(single_quote "${staged_script}") $(single_quote "${running_time}:00")" <<'REMOTE_SCRIPT'
set -euo pipefail

jupyter_gpu_script_url="$1"
staged_script="$2"
running_time="$3"

if ! command -v curl >/dev/null 2>&1; then
  printf '%s\n' 'curl is required to download jupyter.sh on LANTA.' >&2
  exit 1
fi

rm -f "${staged_script}"
curl -fsSL "${jupyter_gpu_script_url}" -o "${staged_script}"
sed -i -E "s/^#SBATCH[[:space:]]+-t[[:space:]]+[^[:space:]]+/#SBATCH -t ${running_time}/" "${staged_script}"
sed -i -E 's/[[:space:]]+--notebook-dir=\$\(pwd\)//g' "${staged_script}"
sed -i -E 's/^conda activate ~\/venv\//eval "$(conda shell.bash hook)"\
conda activate ~\/venv3.6.9\/\
which python\
which pip\
which jupyter/' "${staged_script}"
sed -i -E 's/^jupyter notebook/python -m jupyter notebook/' "${staged_script}"
chmod 700 "${staged_script}"
printf 'downloaded_script=%s\n' "${staged_script}"
REMOTE_SCRIPT

  remote_output_file=$(mktemp "${TMPDIR:-/tmp}/${SCRIPT_NAME}.jupyter.XXXXXX")
  trap 'rm -f "${remote_output_file}"' RETURN

  printf 'submitting staged script on %s...\n' "${TRANSFER_HOST}"
  remote bash -s -- "${staged_script}" "${home_path}" <<'REMOTE_SCRIPT' | tee "${remote_output_file}"
set -euo pipefail

staged_script="$1"
home_path="$2"

cleanup_staged_script() {
  rm -f "${staged_script}"
}
trap cleanup_staged_script EXIT

if [[ ! -f "${staged_script}" ]]; then
  printf 'Missing staged Jupyter script: %s\n' "${staged_script}" >&2
  exit 1
fi

cd "${home_path}"
printf 'running: sbatch %s\n' "${staged_script}"
sbatch_output=$(sbatch "${staged_script}")
printf '%s\n' "${sbatch_output}"

job_id=$(printf '%s\n' "${sbatch_output}" | awk '/Submitted batch job/ {print $4}')
if [[ -z "${job_id}" ]]; then
  printf '%s\n' 'Could not detect job id from sbatch output.' >&2
  exit 1
fi

out_file="slurm-${job_id}.out"
url_pattern='http://[^[:space:]]+[?&]token=[^[:space:]]+'

printf "======================\n"
printf 'job_id=%s\n' "${job_id}"
printf '%s\n' 'waiting for Jupyter URL...'

for attempt in $(seq 1 450); do
  if [[ -f "${out_file}" ]]; then
    urls=$(grep -Eo "${url_pattern}" "${out_file}" || true)
    url=$(printf '%s\n' "${urls}" | grep -Ev '^http://(localhost|127[.]0[.]0[.]1):' | head -n 1 || true)
    if [[ -z "${url}" ]]; then
      url=$(printf '%s\n' "${urls}" | head -n 1 || true)
    fi

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

  job_state=$(squeue -h -j "${job_id}" -o "%T" 2>/dev/null | head -n 1 || true)
  if [[ -z "${job_state}" && -f "${out_file}" ]]; then
    cat "${out_file}"
    printf '%s\n' 'Jupyter job ended before a notebook URL was found.' >&2
    exit 1
  fi

  if (( attempt % 15 == 0 )); then
    if [[ -n "${job_state}" ]]; then
      printf 'still waiting for Jupyter URL; job_state=%s\n' "${job_state}"
    else
      printf '%s\n' 'still waiting for Jupyter URL; job is not visible in squeue yet'
    fi
  fi

  sleep 2
done

if [[ -f "${out_file}" ]]; then
  cat "${out_file}"
fi

printf '%s\n' 'Jupyter URL was not found before the wait timeout.' >&2
exit 1
REMOTE_SCRIPT

  remote_output=$(cat "${remote_output_file}")
  rm -f "${remote_output_file}"
  trap - RETURN

  if forward_jupyter_port "${remote_output}"; then
    remove_jupyter_slurm_output "${remote_output}"
  else
    return 1
  fi

  printf 'everything is now set, good luck!\n'
}

upload_to_lanta() {
  if [[ -z "${upload_target}" ]]; then
    upload_target="${home_path}"
  fi

  scp -r "${upload_src}" "${user}@${TUNNEL_HOST}:${upload_target}"
}

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  load_lanta_paths
  print_lanta_paths

  if [[ "${slote_mode}" == "true" ]]; then
    auto_pub_gen
    running_time="2:00"
    load_lanta_paths
    print_lanta_paths
    initialize_home_environment
    normalize_running_time
    submit_jupyter_gpu_script
    exit 0
  fi

  if [[ "${auto_pub_gen}" == "true" ]]; then
    auto_pub_gen
    exit 0
  fi

  if [[ -n "${pip_packages}" ]]; then
    install_pip_libraries
    exit 0
  fi

  if [[ -n "${remote_command}" ]]; then
    run_remote_command
    exit 0
  fi

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
    initialize_home_environment
    submit_jupyter_gpu_script
    exit 0
  fi

  if [[ -n "${upload_src}" ]]; then
    upload_to_lanta
  fi
}

main "$@"
