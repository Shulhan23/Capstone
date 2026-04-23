#!/bin/bash
# =================================================================
# SCRIPT : setup-production.sh
# Fungsi : Setup production network medchain.id (entry point)
# Fabric : 2.5.x
# Usage  : bash scripts/setup-production.sh [--verbose] [--skip-clean]
# =================================================================
set -euo pipefail
IFS=$'\n\t'

export SCRIPT_NAME="setup-production"
export PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DOMAIN="medchain.id"
export VERBOSE=false
SKIP_CLEAN=false

# Parse argumen
for arg in "$@"; do
  case $arg in
    --verbose)    export VERBOSE=true ;;
    --skip-clean) SKIP_CLEAN=true ;;
    --help)
      echo "Usage: $0 [--verbose] [--skip-clean]"
      echo "  --verbose     Tampilkan output debug"
      echo "  --skip-clean  Lewati pembersihan artefak lama"
      exit 0 ;;
    *) echo "Argumen tidak dikenal: $arg. Gunakan --help"; exit 1 ;;
  esac
done

# Load shared library
# shellcheck source=scripts/lib.sh
source "${PROJECT_ROOT}/scripts/lib.sh"
_init_log

# Tampilkan header
echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║   MedChain Production Setup v2.5     ║${NC}"
echo -e "${BOLD}${CYAN}║   Domain: ${DOMAIN}           ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════╝${NC}"
echo -e "${DIM}  Log: ${LOG_DIR}/${NC}"
echo ""

acquire_lock

# =================================================================
# STEP 1: Cek dependencies
# =================================================================
step "Step 1/5: Cek dependencies"
check_deps docker "docker compose" fabric-ca-client configtxgen

# Tampilkan versi
log "Docker   : $(docker --version | awk '{print $3}' | tr -d ',')"
log "Configtxgen: $(configtxgen --version 2>&1 | head -1)"
log "CA Client: $(fabric-ca-client version 2>&1 | grep Version | awk '{print $2}')"
step_ok

# =================================================================
# STEP 2: Bersihkan artefak lama
# =================================================================
step "Step 2/5: Bersihkan artefak lama"
if [[ "${SKIP_CLEAN}" == "true" ]]; then
  warn "  --skip-clean aktif, lewati pembersihan."
else
  # Stop & hapus semua container + volume
  docker compose -f "${PROJECT_ROOT}/docker-compose.yaml" down -v \
    2>>"${LOG_FILE}" || true
  docker rm -f cli 2>/dev/null || true

  # Hapus artefak lama
  sudo rm -rf \
    "${PROJECT_ROOT}/organizations/ordererOrganizations" \
    "${PROJECT_ROOT}/organizations/peerOrganizations" \
    "${PROJECT_ROOT}/channel-artifacts" \
    "${PROJECT_ROOT}/data" \
    "${PROJECT_ROOT}/organizations/fabric-ca"   

  log "Semua artefak lama dihapus."

  # Daftarkan rollback: kalau gagal nanti, bersihkan lagi
  on_rollback "docker compose -f '${PROJECT_ROOT}/docker-compose.yaml' down -v 2>/dev/null || true"
fi
step_ok

# =================================================================
# STEP 3: Start Fabric CA containers
# =================================================================
step "Step 3/5: Start Fabric CA containers"

bash "${PROJECT_ROOT}/scripts/init-ca-config.sh" \
  || error "init-ca-config.sh gagal."

docker compose -f "${PROJECT_ROOT}/docker-compose.yaml" up -d \
  "ca.orderer.${DOMAIN}" \
  "ca.klinik.${DOMAIN}" \
  "ca.akademik.${DOMAIN}" \
  "ca.dokter.${DOMAIN}" \
  2>>"${LOG_FILE}" \
  || error "Gagal start CA containers."


# Tunggu setiap container benar-benar Up
for ca in "ca.orderer.${DOMAIN}" "ca.klinik.${DOMAIN}" "ca.akademik.${DOMAIN}" "ca.dokter.${DOMAIN}"; do
  wait_container "${ca}" 60
done

# Tunggu CA endpoints merespons (bukan sekadar container Up)
wait_ca "ca.orderer.${DOMAIN}"  7054 "${ORGANIZATIONS}/fabric-ca/orderer/tls-cert.pem"
wait_ca "ca.klinik.${DOMAIN}"   8054 "${ORGANIZATIONS}/fabric-ca/klinik/tls-cert.pem"
wait_ca "ca.akademik.${DOMAIN}" 9054 "${ORGANIZATIONS}/fabric-ca/akademik/tls-cert.pem"
wait_ca "ca.dokter.${DOMAIN}" 10054 "${ORGANIZATIONS}/fabric-ca/dokter/tls-cert.pem"

step_ok

# =================================================================
# STEP 4: Enroll identities
# =================================================================
step "Step 4/5: Enroll identities via Fabric CA"
bash "${PROJECT_ROOT}/scripts/enroll-ca.sh" \
  || error "enroll-ca.sh gagal."
step_ok

# =================================================================
# STEP 5: Setup channel
# =================================================================
step "Step 5/5: Setup channel"
bash "${PROJECT_ROOT}/scripts/setup-channel.sh" \
  || error "setup-channel.sh gagal."
step_ok

# =================================================================
# SELESAI
# =================================================================
print_summary

echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║   Production network berhasil di-setup! ✓    ║${NC}"
echo -e "${BOLD}${GREEN}╠══════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}${GREEN}║  Services:                                   ║${NC}"
echo -e "${GREEN}║  CA Orderer   : https://ca.orderer.${DOMAIN}:7054  ║${NC}"
echo -e "${GREEN}║  CA Klinik    : https://ca.klinik.${DOMAIN}:8054   ║${NC}"
echo -e "${GREEN}║  CA Akademik  : https://ca.akademik.${DOMAIN}:9054 ║${NC}"
echo -e "${GREEN}║  CA Dokter    : https://ca.dokter.${DOMAIN}:10054  ║${NC}"
echo -e "${GREEN}║  Orderer 1    : orderer1.${DOMAIN}:7050      ║${NC}"
echo -e "${GREEN}║  Peer Klinik  : peer0.klinik.${DOMAIN}:7051  ║${NC}"
echo -e "${GREEN}║  Peer Akademik: peer0.akademik.${DOMAIN}:9051║${NC}"
echo -e "${GREEN}║  Prometheus   : http://localhost:9090        ║${NC}"
echo -e "${GREEN}║  Grafana      : http://localhost:3000        ║${NC}"
echo -e "${GREEN}║  Peer Dokter  : peer0.dokter.${DOMAIN}:10051        ║${NC}"
echo -e "${BOLD}${GREEN}╠══════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  Langkah selanjutnya:                        ║${NC}"
echo -e "${GREEN}║    bash scripts/deploy-chaincode.sh          ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════╝${NC}"