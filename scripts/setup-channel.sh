#!/bin/bash
# =================================================================
# SCRIPT : setup-channel.sh
# Fungsi : Generate genesis block, buat channel, join peer
# Fabric : 2.5.x
# Urutan : Jalankan SETELAH enroll-ca.sh
# Usage  : bash scripts/setup-channel.sh [--verbose]
# =================================================================
set -euo pipefail
IFS=$'\n\t'

export SCRIPT_NAME="setup-channel"
export PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export DOMAIN="${DOMAIN:-medchain.id}"
export VERBOSE="${VERBOSE:-false}"

source "${PROJECT_ROOT}/scripts/lib.sh"
_init_log

# -----------------------------------------------------------------
# KONFIGURASI
# -----------------------------------------------------------------
readonly CHANNEL_NAME="medchannel"
readonly ARTIFACTS="${PROJECT_ROOT}/channel-artifacts"

# Path di dalam container CLI
readonly CLI_CRYPTO="/etc/hyperledger/fabric/crypto"
readonly CLI_ARTIFACTS="/etc/hyperledger/fabric/channel-artifacts"
readonly ORDERER_CA="${CLI_CRYPTO}/ordererOrganizations/${DOMAIN}/orderers/orderer1.${DOMAIN}/msp/tlscacerts/tlsca.${DOMAIN}-cert.pem"
readonly ORDERER_ADDR="orderer1.${DOMAIN}:7050"

# -----------------------------------------------------------------
# HELPER: Jalankan perintah di CLI sebagai Klinik (default)
# -----------------------------------------------------------------
cli_klinik() {
  docker exec cli "$@" 2>>"${LOG_FILE}"
}

# -----------------------------------------------------------------
# HELPER: Jalankan perintah di CLI sebagai Akademik
# -----------------------------------------------------------------
cli_akademik() {
  docker exec \
    -e CORE_PEER_LOCALMSPID="AkademikMSP" \
    -e CORE_PEER_ADDRESS="peer0.akademik.${DOMAIN}:9051" \
    -e CORE_PEER_MSPCONFIGPATH="${CLI_CRYPTO}/peerOrganizations/akademik.${DOMAIN}/users/Admin@akademik.${DOMAIN}/msp" \
    -e CORE_PEER_TLS_ROOTCERT_FILE="${CLI_CRYPTO}/peerOrganizations/akademik.${DOMAIN}/peers/peer0.akademik.${DOMAIN}/tls/ca.crt" \
    cli "$@" 2>>"${LOG_FILE}"
}

# -----------------------------------------------------------------
# HELPER: Jalankan perintah di CLI sebagai Akademik
# -----------------------------------------------------------------
cli_dokter() {
  docker exec \
    -e CORE_PEER_LOCALMSPID="DokterMSP" \
    -e CORE_PEER_ADDRESS="peer0.dokter.${DOMAIN}:10051" \
    -e CORE_PEER_MSPCONFIGPATH="${CLI_CRYPTO}/peerOrganizations/dokter.${DOMAIN}/users/Admin@dokter.${DOMAIN}/msp" \
    -e CORE_PEER_TLS_ROOTCERT_FILE="${CLI_CRYPTO}/peerOrganizations/dokter.${DOMAIN}/peers/peer0.dokter.${DOMAIN}/tls/ca.crt" \
    cli "$@" 2>>"${LOG_FILE}"
}

# =================================================================
# STEP 1: Generate genesis block & channel artifacts
# =================================================================
gen_artifacts() {
  step "Step 1/6: Generate channel artifacts"

  export FABRIC_CFG_PATH="${PROJECT_ROOT}"
  mkdir -p "${ARTIFACTS}"

  log "  Genesis block..."
  configtxgen \
    -profile ThreeOrgsOrdererGenesis \
    -channelID system-channel \
    -outputBlock "${ARTIFACTS}/orderer.genesis.block" \
    >> "${LOG_FILE}" 2>&1 \
    || error "Gagal generate genesis block."

  log "  Channel transaction..."
  configtxgen \
    -profile ThreeOrgsChannel \
    -outputCreateChannelTx "${ARTIFACTS}/${CHANNEL_NAME}.tx" \
    -channelID "${CHANNEL_NAME}" \
    >> "${LOG_FILE}" 2>&1 \
    || error "Gagal generate channel tx."

  for org in "KlinikMSP" "AkademikMSP" "DokterMSP"; do
    log "  Anchor peer ${org}..."
    configtxgen \
      -profile ThreeOrgsChannel \
      -outputAnchorPeersUpdate "${ARTIFACTS}/${org}anchors.tx" \
      -channelID "${CHANNEL_NAME}" \
      -asOrg "${org}" \
      >> "${LOG_FILE}" 2>&1 \
      || error "Gagal generate anchor peer ${org}."
  done

  step_ok
}

# =================================================================
# STEP 2: Fix CouchDB permissions
# =================================================================
fix_couchdb() {
  step "Step 2/6: Fix CouchDB permissions"
  mkdir -p \
    "${PROJECT_ROOT}/data/couchdb/klinik-peer0" \
    "${PROJECT_ROOT}/data/couchdb/klinik-peer1" \
    "${PROJECT_ROOT}/data/couchdb/akademik" \
    "${PROJECT_ROOT}/data/couchdb/akademik-peer1" \
    "${PROJECT_ROOT}/data/couchdb/dokter-peer0" \
    "${PROJECT_ROOT}/data/couchdb/dokter-peer1"
  sudo chown -R 5984:5984 "${PROJECT_ROOT}/data/couchdb/" \
    || warn "chown CouchDB gagal, lanjutkan..."
  step_ok
}

# =================================================================
# STEP 3: Start semua container
# =================================================================
start_containers() {
  step "Step 3/6: Start orderer, peer, cli containers"

  docker compose -f "${PROJECT_ROOT}/docker-compose.yaml" up -d \
    "orderer1.${DOMAIN}" \
    "orderer2.${DOMAIN}" \
    "orderer3.${DOMAIN}" \
    "couchdb.klinik.peer0" \
    "couchdb.akademik.peer0" \
    "couchdb.dokter.peer0" \
    "peer0.klinik.${DOMAIN}" \
    "peer0.akademik.${DOMAIN}" \
    "peer0.dokter.${DOMAIN}" \
    "cli" \
    >> "${LOG_FILE}" 2>&1 \
    || error "Gagal start containers."

  on_rollback "docker compose -f '${PROJECT_ROOT}/docker-compose.yaml' stop \
    orderer1.${DOMAIN} orderer2.${DOMAIN} orderer3.${DOMAIN} \
    peer0.klinik.${DOMAIN} peer0.akademik.${DOMAIN} peer0.dokter.${DOMAIN} cli 2>/dev/null || true"

  for c in \
    "orderer1.${DOMAIN}" \
    "orderer2.${DOMAIN}" \
    "orderer3.${DOMAIN}" \
    "peer0.klinik.${DOMAIN}" \
    "peer0.akademik.${DOMAIN}" \
    "peer0.dokter.${DOMAIN}" \
    "cli"; do
    wait_container "${c}" 120
  done
  log "  Menunggu service peer benar-benar siap..."
  sleep 10
  step_ok
}

# =================================================================
# STEP 4: Buat channel
# =================================================================
create_channel() {
  step "Step 4/6: Buat channel '${CHANNEL_NAME}'"

  cli_klinik peer channel create \
    -o "${ORDERER_ADDR}" \
    --ordererTLSHostnameOverride "orderer1.${DOMAIN}" \
    -c "${CHANNEL_NAME}" \
    -f "${CLI_ARTIFACTS}/${CHANNEL_NAME}.tx" \
    --outputBlock "${CLI_ARTIFACTS}/${CHANNEL_NAME}.block" \
    --tls --cafile "${ORDERER_CA}" \
    || error "Gagal membuat channel ${CHANNEL_NAME}."

  log "Channel '${CHANNEL_NAME}' berhasil dibuat."
  step_ok
}

# =================================================================
# STEP 5: Join peer ke channel
# =================================================================
join_peers() {
  step "Step 5/6: Join peer ke channel"

  log "  peer0.klinik..."
  cli_klinik peer channel join \
    -b "${CLI_ARTIFACTS}/${CHANNEL_NAME}.block" \
    || error "peer0.klinik gagal join channel."
  log "  peer0.klinik ✓"

  log "  peer0.akademik..."
  cli_akademik peer channel join \
    -b "${CLI_ARTIFACTS}/${CHANNEL_NAME}.block" \
    || error "peer0.akademik gagal join channel."
  log "  peer0.akademik ✓"

  log "  peer0.dokter..."
  cli_dokter peer channel join \
    -b "${CLI_ARTIFACTS}/${CHANNEL_NAME}.block" \
    || error "peer0.dokter gagal join channel."
  log "  peer0.dokter ✓"

  step_ok
}

# =================================================================
# STEP 6: Update anchor peers
# =================================================================
update_anchors() {
  step "Step 6/6: Update anchor peers"

  cli_klinik peer channel update \
    -o "${ORDERER_ADDR}" \
    --ordererTLSHostnameOverride "orderer1.${DOMAIN}" \
    -c "${CHANNEL_NAME}" \
    -f "${CLI_ARTIFACTS}/KlinikMSPanchors.tx" \
    --tls --cafile "${ORDERER_CA}" \
    || error "Gagal update anchor peer Klinik."
  log "  KlinikMSP ✓"

  cli_akademik peer channel update \
    -o "${ORDERER_ADDR}" \
    --ordererTLSHostnameOverride "orderer1.${DOMAIN}" \
    -c "${CHANNEL_NAME}" \
    -f "${CLI_ARTIFACTS}/AkademikMSPanchors.tx" \
    --tls --cafile "${ORDERER_CA}" \
    || error "Gagal update anchor peer Akademik."
  log "  AkademikMSP ✓"

  cli_dokter peer channel update \
    -o "${ORDERER_ADDR}" \
    --ordererTLSHostnameOverride "orderer1.${DOMAIN}" \
    -c "${CHANNEL_NAME}" \
    -f "${CLI_ARTIFACTS}/DokterMSPanchors.tx" \
    --tls --cafile "${ORDERER_CA}" \
    || error "Gagal update anchor peer Dokter."
  log "  DokterMSP ✓"

  log "  Verifikasi channel list:"
  cli_klinik peer channel list 2>>"${LOG_FILE}" || true

  step_ok
}

# =================================================================
# MAIN
# =================================================================
log "Memulai setup channel..."
log "Log: ${LOG_FILE}"

gen_artifacts
fix_couchdb
start_containers
create_channel
join_peers
update_anchors

print_summary
log "Channel setup selesai!"
log "Channel : ${CHANNEL_NAME}"
log "Langkah selanjutnya: bash scripts/deploy-chaincode.sh"
exit 0