#!/bin/bash
# =================================================================
# LIB   : lib.sh
# Fungsi: Shared functions untuk semua script MedChain
# Usage : source scripts/lib.sh
# =================================================================

# -----------------------------------------------------------------
# KONSTANTA GLOBAL
# (tidak readonly agar aman saat di-source dari subshell)
# -----------------------------------------------------------------
DOMAIN="${DOMAIN:-medchain.id}"
FABRIC_CA_VERSION="${FABRIC_CA_VERSION:-1.5.7}"
ORGANIZATIONS="${ORGANIZATIONS:-${PROJECT_ROOT:-$PWD}/organizations}"
LOG_DIR="${LOG_DIR:-${PROJECT_ROOT:-$PWD}/logs}"

readonly CA_RETRY_MAX=12
readonly CA_RETRY_INTERVAL=5
readonly CONTAINER_WAIT_MAX=90

# -----------------------------------------------------------------
# WARNA
# -----------------------------------------------------------------
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly NC='\033[0m'

# -----------------------------------------------------------------
# LOGGING
# -----------------------------------------------------------------
_init_log() {
  mkdir -p "${LOG_DIR}"
  LOG_FILE="${LOG_DIR}/${SCRIPT_NAME:-setup}-$(date +%Y%m%d_%H%M%S).log"
  export LOG_FILE
}

_log_base() {
  local level="$1" color="$2" msg="$3"
  local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo -e "${color}[${level}]${NC} ${msg}"
  echo "[${ts}][${level}] ${msg}" >> "${LOG_FILE:-/tmp/medchain.log}"
}

log()   { _log_base "INFO " "${GREEN}"  "$1"; }
warn()  { _log_base "WARN " "${YELLOW}" "$1"; }
debug() { [[ "${VERBOSE:-false}" == "true" ]] && _log_base "DEBUG" "${DIM}" "$1" || true; }

error() {
  _log_base "ERROR" "${RED}" "$1"
  echo -e "${RED}${BOLD}[FATAL]${NC} Gagal pada: ${CURRENT_STEP:-unknown step}"
  echo -e "${YELLOW}[HINT ]${NC} Log lengkap: ${LOG_FILE:-/tmp/medchain.log}"
  _run_rollback
  _release_lock
  exit 1
}

# -----------------------------------------------------------------
# STEP TRACKER
# -----------------------------------------------------------------
CURRENT_STEP=""
COMPLETED_STEPS=()

step() {
  CURRENT_STEP="$1"
  echo ""
  echo -e "${BOLD}${BLUE}┌─ ${1}${NC}"
}

step_ok() {
  COMPLETED_STEPS+=("${CURRENT_STEP}")
  echo -e "${BOLD}${GREEN}└─ ✓ Selesai${NC}"
}

print_summary() {
  echo ""
  echo -e "${BOLD}${GREEN}══════════════════════════════════════${NC}"
  echo -e "${BOLD}${GREEN}  Ringkasan:${NC}"
  for s in "${COMPLETED_STEPS[@]+"${COMPLETED_STEPS[@]}"}"; do
    echo -e "${GREEN}  ✓${NC} ${s}"
  done
  echo -e "${BOLD}${GREEN}══════════════════════════════════════${NC}"
}

# -----------------------------------------------------------------
# LOCK FILE
# -----------------------------------------------------------------
LOCK_FILE="/tmp/medchain-${SCRIPT_NAME:-setup}.lock"

acquire_lock() {
  if [[ -f "${LOCK_FILE}" ]]; then
    local pid; pid="$(cat "${LOCK_FILE}")"
    if kill -0 "${pid}" 2>/dev/null; then
      error "Script sudah berjalan (PID: ${pid}). Hentikan dulu."
    fi
    warn "Stale lock ditemukan, dihapus."
    rm -f "${LOCK_FILE}"
  fi
  echo $$ > "${LOCK_FILE}"
}

_release_lock() {
  rm -f "${LOCK_FILE}" 2>/dev/null || true
}

# -----------------------------------------------------------------
# ROLLBACK REGISTRY
# -----------------------------------------------------------------
_ROLLBACK_STACK=()

on_rollback() {
  _ROLLBACK_STACK+=("$1")
}

_run_rollback() {
  [[ ${#_ROLLBACK_STACK[@]} -eq 0 ]] && return
  warn "Menjalankan rollback..."
  for (( i=${#_ROLLBACK_STACK[@]}-1; i>=0; i-- )); do
    eval "${_ROLLBACK_STACK[$i]}" 2>/dev/null || true
  done
  warn "Rollback selesai."
}

_on_exit() {
  local code=$?
  _release_lock
  [[ $code -ne 0 ]] && echo -e "\n${RED}[EXIT]${NC} Script keluar dengan kode: ${code}"
  return $code
}
trap '_on_exit' EXIT

# -----------------------------------------------------------------
# DEPENDENCY CHECK
# -----------------------------------------------------------------
_cmd_exists() {
  local cmd="$1"
  if [[ "${cmd}" == *" "* ]]; then
    eval "${cmd} version" &>/dev/null || eval "${cmd} --version" &>/dev/null
  else
    command -v "${cmd}" &>/dev/null
  fi
}

check_deps() {
  local missing=()
  for cmd in "$@"; do
    _cmd_exists "${cmd}" || missing+=("${cmd}")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo -e "${RED}[ERROR]${NC} Dependency tidak ditemukan:"
    for dep in "${missing[@]}"; do
      echo -e "  ${RED}✗${NC} ${dep}"
    done
    echo -e "\n${YELLOW}[HINT ]${NC} Pastikan PATH sudah include Fabric binaries:"
    echo -e "  export PATH=\$PATH:/home/\$USER/fabric-tools/fabric-samples/bin"
    exit 1
  fi
}

# -----------------------------------------------------------------
# DOCKER HELPERS
# -----------------------------------------------------------------

# Tunggu container running + healthy
# Usage: wait_container <nama_container> [timeout_detik]
wait_container() {
  local name="$1"
  local timeout="${2:-${CONTAINER_WAIT_MAX}}"
  local elapsed=0

  echo -ne "${CYAN}[WAIT]${NC} Menunggu ${name}"
  while [[ $elapsed -lt $timeout ]]; do
    local status health
    status="$(docker inspect --format='{{.State.Status}}' "${name}" 2>/dev/null || echo 'missing')"
    health="$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${name}" 2>/dev/null || echo 'missing')"

    if [[ "${status}" == "running" && ( "${health}" == "healthy" || "${health}" == "none" ) ]]; then
      echo -e " ${GREEN}✓${NC}"
      return 0
    fi
    echo -ne "."
    sleep "${CA_RETRY_INTERVAL}"
    (( elapsed += CA_RETRY_INTERVAL ))
  done

  echo -e " ${RED}✗${NC}"
  error "Container ${name} tidak ready setelah ${timeout} detik."
}

# Tunggu CA endpoint merespons
# Otomatis fallback ke localhost jika hostname tidak resolve (WSL/dev)
# Usage: wait_ca <hostname> <port> <tls_cert>
wait_ca() {
  local hostname="$1"
  local port="$2"
  local tls_cert="$3"
  local attempt=1

  # Tentukan URL yang akan digunakan
  local check_url
  if getent hosts "${hostname}" >/dev/null 2>&1; then
    check_url="https://${hostname}:${port}"
  else
    check_url="https://localhost:${port}"
    warn "  Hostname ${hostname} tidak resolve, pakai localhost:${port}"
  fi

  echo -ne "${CYAN}[WAIT]${NC} Menunggu CA ${hostname}:${port}"
  while [[ $attempt -le $CA_RETRY_MAX ]]; do
    if fabric-ca-client getcacert \
        -u "${check_url}" \
        --tls.certfiles "${tls_cert}" \
        -M "/tmp/ca-check-$$" \
        >/dev/null 2>&1; then
      rm -rf "/tmp/ca-check-$$"
      echo -e " ${GREEN}✓${NC}"
      return 0
    fi
    echo -ne "."
    sleep "${CA_RETRY_INTERVAL}"
    (( attempt++ ))
  done

  echo -e " ${RED}✗${NC}"
  echo -e "${YELLOW}[HINT ]${NC} Tambahkan ke /etc/hosts:"
  echo -e "  echo '127.0.0.1 ${hostname}' | sudo tee -a /etc/hosts"
  error "CA ${hostname}:${port} tidak merespons setelah ${CA_RETRY_MAX} percobaan."
}

# -----------------------------------------------------------------
# FABRIC CA HELPERS
# -----------------------------------------------------------------

# Enroll identity ke CA
# FABRIC_CA_CLIENT_HOME = parent(home) agar tidak double-nest MSP
# Usage: ca_enroll <home> <url> <caname> <tls_cert> [extra_args...]
ca_enroll() {
  local home="$1" url="$2" caname="$3" tls_cert="$4"
  shift 4
  export FABRIC_CA_CLIENT_HOME="$(dirname "${home}")"
  fabric-ca-client enroll \
    -u "${url}" \
    --caname "${caname}" \
    --tls.certfiles "${tls_cert}" \
    -M "${home}" \
    "$@" \
    >> "${LOG_FILE:-/tmp/medchain.log}" 2>&1 \
    || error "Enroll gagal. Cek log: ${LOG_FILE:-/tmp/medchain.log}"
}

# Register identity — skip jika sudah terdaftar
# Usage: ca_register <home> <caname> <tls_cert> <id_name> <id_secret> <id_type>
ca_register() {
  local home="$1" caname="$2" tls_cert="$3"
  local id_name="$4" id_secret="$5" id_type="$6"
  export FABRIC_CA_CLIENT_HOME="$(dirname "${home}")"

  # Skip jika sudah terdaftar
  if fabric-ca-client identity list \
      --caname "${caname}" \
      --tls.certfiles "${tls_cert}" 2>/dev/null \
      | grep -q "Name: ${id_name}"; then
    debug "  '${id_name}' sudah terdaftar, skip."
    return 0
  fi

  fabric-ca-client register \
    --caname "${caname}" \
    --id.name "${id_name}" \
    --id.secret "${id_secret}" \
    --id.type "${id_type}" \
    --tls.certfiles "${tls_cert}" \
    >> "${LOG_FILE:-/tmp/medchain.log}" 2>&1 \
    || error "Register '${id_name}' gagal. Cek log: ${LOG_FILE:-/tmp/medchain.log}"
}

# Salin TLS artifacts ke lokasi standar
# Usage: copy_tls_artifacts <tls_dir>
copy_tls_artifacts() {
  local tls_dir="$1"
  cp "${tls_dir}"/tlscacerts/*.pem "${tls_dir}/ca.crt"    2>/dev/null || \
    cp "${tls_dir}"/cacerts/*.pem  "${tls_dir}/ca.crt"    2>/dev/null || true
  cp "${tls_dir}"/signcerts/*.pem  "${tls_dir}/server.crt" 2>/dev/null || true
  local key; key="$(ls "${tls_dir}/keystore/" 2>/dev/null | head -1)"
  [[ -n "${key}" ]] && cp "${tls_dir}/keystore/${key}" "${tls_dir}/server.key" 2>/dev/null || true
}

# Tulis NodeOU config.yaml — deteksi nama cacert otomatis
# Usage: write_ou_config <msp_dir>
write_ou_config() {
  local msp_dir="$1"
  local ca_cert; ca_cert="$(ls "${msp_dir}/cacerts/" 2>/dev/null | head -1)"
  [[ -z "${ca_cert}" ]] && error "Tidak ada cacert di ${msp_dir}/cacerts/"

  cat > "${msp_dir}/config.yaml" <<EOF
NodeOUs:
  Enable: true
  ClientOUIdentifier:
    Certificate: cacerts/${ca_cert}
    OrganizationalUnitIdentifier: client
  PeerOUIdentifier:
    Certificate: cacerts/${ca_cert}
    OrganizationalUnitIdentifier: peer
  AdminOUIdentifier:
    Certificate: cacerts/${ca_cert}
    OrganizationalUnitIdentifier: admin
  OrdererOUIdentifier:
    Certificate: cacerts/${ca_cert}
    OrganizationalUnitIdentifier: orderer
EOF
}