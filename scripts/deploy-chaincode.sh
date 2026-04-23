#!/bin/bash
set -e

PROJECT_DIR=$PWD
CHANNEL_NAME="medchannel"
CHAINCODE_NAME="medical"
CHAINCODE_VERSION="1.0"
CHAINCODE_SEQUENCE="1"
DOMAIN="medchain.id"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

CLI_CRYPTO="/etc/hyperledger/fabric/crypto"
CLI_CC="/etc/hyperledger/fabric/chaincode"
ORDERER_CA="${CLI_CRYPTO}/ordererOrganizations/${DOMAIN}/orderers/orderer1.${DOMAIN}/msp/tlscacerts/tlsca.${DOMAIN}-cert.pem"
PEER0_KLINIK_CA="${CLI_CRYPTO}/peerOrganizations/klinik.${DOMAIN}/peers/peer0.klinik.${DOMAIN}/tls/ca.crt"
PEER0_AKADEMIK_CA="${CLI_CRYPTO}/peerOrganizations/akademik.${DOMAIN}/peers/peer0.akademik.${DOMAIN}/tls/ca.crt"
PEER0_DOKTER_CA="${CLI_CRYPTO}/peerOrganizations/dokter.${DOMAIN}/peers/peer0.dokter.${DOMAIN}/tls/ca.crt"

CC_POLICY="OutOf(2, 'KlinikMSP.member', 'AkademikMSP.member', 'DokterMSP.member')"

run_cli() {
    docker exec "$@"
}

query_committed_output() {
    docker exec \
        -e CORE_PEER_LOCALMSPID=KlinikMSP \
        -e CORE_PEER_ADDRESS=peer0.klinik.${DOMAIN}:7051 \
        -e CORE_PEER_MSPCONFIGPATH=${CLI_CRYPTO}/peerOrganizations/klinik.${DOMAIN}/users/Admin@klinik.${DOMAIN}/msp \
        -e CORE_PEER_TLS_ROOTCERT_FILE=${PEER0_KLINIK_CA} \
        cli peer lifecycle chaincode querycommitted \
        --channelID ${CHANNEL_NAME} \
        --name ${CHAINCODE_NAME} 2>&1 || true
}

is_committed() {
    local out
    out="$(query_committed_output)"
    echo "${out}" | grep -q "Version: ${CHAINCODE_VERSION}"
}

approve_or_skip() {
    local mspid="$1"
    local peer_addr="$2"
    local msp_path="$3"
    local tls_cert="$4"
    local label="$5"

    local output
    output=$(docker exec \
        -e CORE_PEER_LOCALMSPID=${mspid} \
        -e CORE_PEER_ADDRESS=${peer_addr} \
        -e CORE_PEER_MSPCONFIGPATH=${msp_path} \
        -e CORE_PEER_TLS_ROOTCERT_FILE=${tls_cert} \
        cli peer lifecycle chaincode approveformyorg \
        -o orderer1.${DOMAIN}:7050 \
        --ordererTLSHostnameOverride orderer1.${DOMAIN} \
        --channelID ${CHANNEL_NAME} \
        --name ${CHAINCODE_NAME} \
        --version ${CHAINCODE_VERSION} \
        --package-id ${CC_PACKAGE_ID} \
        --sequence ${CHAINCODE_SEQUENCE} \
        --signature-policy "${CC_POLICY}" \
        --tls --cafile ${ORDERER_CA} \
        --peerAddresses ${peer_addr} \
        --tlsRootCertFiles ${tls_cert} 2>&1) || true

    echo "${output}"

    if echo "${output}" | grep -qi "attempted to redefine uncommitted sequence"; then
        warn "Approve ${label} sudah pernah dilakukan, skip."
    elif echo "${output}" | grep -qi "Error:"; then
        error "Approve ${label} gagal."
    fi
}

# =====================================================
# STEP 1: PACKAGE
# =====================================================
log "Step 1: Packaging chaincode..."
docker exec cli peer lifecycle chaincode package \
    ${CLI_CC}/${CHAINCODE_NAME}.tar.gz \
    --path ${CLI_CC}/${CHAINCODE_NAME} \
    --lang node \
    --label ${CHAINCODE_NAME}_${CHAINCODE_VERSION}
log "Package berhasil."

# =====================================================
# STEP 2: INSTALL KE PEER KLINIK
# =====================================================
log "Step 2: Install ke peer Klinik..."
INSTALL_KLINIK_OUTPUT=$(docker exec \
    -e CORE_PEER_LOCALMSPID=KlinikMSP \
    -e CORE_PEER_ADDRESS=peer0.klinik.${DOMAIN}:7051 \
    -e CORE_PEER_MSPCONFIGPATH=${CLI_CRYPTO}/peerOrganizations/klinik.${DOMAIN}/users/Admin@klinik.${DOMAIN}/msp \
    -e CORE_PEER_TLS_ROOTCERT_FILE=${PEER0_KLINIK_CA} \
    cli peer lifecycle chaincode install \
    ${CLI_CC}/${CHAINCODE_NAME}.tar.gz 2>&1) || true
echo "${INSTALL_KLINIK_OUTPUT}"
if echo "${INSTALL_KLINIK_OUTPUT}" | grep -qi "chaincode already successfully installed"; then
    warn "Chaincode di Klinik sudah terinstall, skip."
elif echo "${INSTALL_KLINIK_OUTPUT}" | grep -qi "Error:"; then
    error "Install ke Klinik gagal."
fi
log "Install ke Klinik berhasil."

# =====================================================
# STEP 3: INSTALL KE PEER AKADEMIK
# =====================================================
log "Step 3: Install ke peer Akademik..."
INSTALL_AKADEMIK_OUTPUT=$(docker exec \
    -e CORE_PEER_LOCALMSPID=AkademikMSP \
    -e CORE_PEER_ADDRESS=peer0.akademik.${DOMAIN}:9051 \
    -e CORE_PEER_MSPCONFIGPATH=${CLI_CRYPTO}/peerOrganizations/akademik.${DOMAIN}/users/Admin@akademik.${DOMAIN}/msp \
    -e CORE_PEER_TLS_ROOTCERT_FILE=${PEER0_AKADEMIK_CA} \
    cli peer lifecycle chaincode install \
    ${CLI_CC}/${CHAINCODE_NAME}.tar.gz 2>&1) || true
echo "${INSTALL_AKADEMIK_OUTPUT}"
if echo "${INSTALL_AKADEMIK_OUTPUT}" | grep -qi "chaincode already successfully installed"; then
    warn "Chaincode di Akademik sudah terinstall, skip."
elif echo "${INSTALL_AKADEMIK_OUTPUT}" | grep -qi "Error:"; then
    error "Install ke Akademik gagal."
fi
log "Install ke Akademik berhasil."

# =====================================================
# STEP 4:INSTALL KE PEER DOKTER
# =====================================================

log "Step 4: Install ke peer Dokter..."
INSTALL_DOKTER_OUTPUT=$(docker exec \
    -e CORE_PEER_LOCALMSPID=DokterMSP \
    -e CORE_PEER_ADDRESS=peer0.dokter.${DOMAIN}:10051 \
    -e CORE_PEER_MSPCONFIGPATH=${CLI_CRYPTO}/peerOrganizations/dokter.${DOMAIN}/users/Admin@dokter.${DOMAIN}/msp \
    -e CORE_PEER_TLS_ROOTCERT_FILE=${PEER0_DOKTER_CA} \
    cli peer lifecycle chaincode install \
    ${CLI_CC}/${CHAINCODE_NAME}.tar.gz 2>&1) || true
echo "${INSTALL_DOKTER_OUTPUT}"
if echo "${INSTALL_DOKTER_OUTPUT}" | grep -qi "chaincode already successfully installed"; then
    warn "Chaincode di Dokter sudah terinstall, skip."
elif echo "${INSTALL_DOKTER_OUTPUT}" | grep -qi "Error:"; then
    error "Install ke Dokter gagal."
fi
log "Install ke Dokter berhasil."

# =====================================================
# STEP 5: DAPATKAN PACKAGE ID
# =====================================================
log "Step 5: Query Package ID..."
QUERY_RESULT=$(docker exec \
    -e CORE_PEER_LOCALMSPID=KlinikMSP \
    -e CORE_PEER_ADDRESS=peer0.klinik.${DOMAIN}:7051 \
    -e CORE_PEER_MSPCONFIGPATH=${CLI_CRYPTO}/peerOrganizations/klinik.${DOMAIN}/users/Admin@klinik.${DOMAIN}/msp \
    -e CORE_PEER_TLS_ROOTCERT_FILE=${PEER0_KLINIK_CA} \
    cli peer lifecycle chaincode queryinstalled)
echo "$QUERY_RESULT"

CC_PACKAGE_ID=$(echo "$QUERY_RESULT" | grep "${CHAINCODE_NAME}_${CHAINCODE_VERSION}" | awk '{print $3}' | sed 's/,//')

if [ -z "$CC_PACKAGE_ID" ]; then
    error "Package ID tidak ditemukan."
fi
log "Package ID: $CC_PACKAGE_ID"

if is_committed; then
    warn "Chaincode ${CHAINCODE_NAME} sudah committed di channel ${CHANNEL_NAME}, skip approve dan commit."
else
    # =====================================================
    # STEP 5: APPROVE DARI KLINIK
    # =====================================================
    log "Step 6: Approve dari KlinikMSP..."
    approve_or_skip \
        "KlinikMSP" \
        "peer0.klinik.${DOMAIN}:7051" \
        "${CLI_CRYPTO}/peerOrganizations/klinik.${DOMAIN}/users/Admin@klinik.${DOMAIN}/msp" \
        "${PEER0_KLINIK_CA}" \
        "KlinikMSP"
    log "Approve Klinik berhasil."

    # =====================================================
    # STEP 6: APPROVE DARI AKADEMIK
    # =====================================================
    log "Step 7: Approve dari AkademikMSP..."
    approve_or_skip \
        "AkademikMSP" \
        "peer0.akademik.${DOMAIN}:9051" \
        "${CLI_CRYPTO}/peerOrganizations/akademik.${DOMAIN}/users/Admin@akademik.${DOMAIN}/msp" \
        "${PEER0_AKADEMIK_CA}" \
        "AkademikMSP"
    log "Approve Akademik berhasil."

    # =====================================================
    # STEP 7: APPROVE DARI DOKTER
    # =====================================================
    log "Step 8: Approve dari DokterMSP..."
    approve_or_skip \
        "DokterMSP" \
        "peer0.dokter.${DOMAIN}:10051" \
        "${CLI_CRYPTO}/peerOrganizations/dokter.${DOMAIN}/users/Admin@dokter.${DOMAIN}/msp" \
        "${PEER0_DOKTER_CA}" \
        "DokterMSP"
    log "Approve Dokter berhasil."

    # =====================================================
    # STEP 7: CEK READINESS
    # =====================================================
    log "Step 9: Cek readiness..."
    READINESS_OUTPUT=$(docker exec \
        -e CORE_PEER_LOCALMSPID=KlinikMSP \
        -e CORE_PEER_ADDRESS=peer0.klinik.${DOMAIN}:7051 \
        -e CORE_PEER_MSPCONFIGPATH=${CLI_CRYPTO}/peerOrganizations/klinik.${DOMAIN}/users/Admin@klinik.${DOMAIN}/msp \
        -e CORE_PEER_TLS_ROOTCERT_FILE=${PEER0_KLINIK_CA} \
        cli peer lifecycle chaincode checkcommitreadiness \
        --channelID ${CHANNEL_NAME} \
        --name ${CHAINCODE_NAME} \
        --version ${CHAINCODE_VERSION} \
        --sequence ${CHAINCODE_SEQUENCE} \
        --signature-policy "${CC_POLICY}" \
        --tls --cafile ${ORDERER_CA} \
        --output json 2>&1) || true
    echo "${READINESS_OUTPUT}"

    if ! echo "${READINESS_OUTPUT}" | grep -Eq '"KlinikMSP"[[:space:]]*:[[:space:]]*true'; then
        warn "KlinikMSP belum ready."
    fi
    if ! echo "${READINESS_OUTPUT}" | grep -Eq '"AkademikMSP"[[:space:]]*:[[:space:]]*true'; then
        warn "AkademikMSP belum ready."
    fi
    if ! echo "${READINESS_OUTPUT}" | grep -Eq '"DokterMSP"[[:space:]]*:[[:space:]]*true'; then
        warn "DokterMSP belum ready."
    fi

    READY_COUNT=0
    echo "${READINESS_OUTPUT}" | grep -Eq '"KlinikMSP"[[:space:]]*:[[:space:]]*true' && READY_COUNT=$((READY_COUNT+1))
    echo "${READINESS_OUTPUT}" | grep -Eq '"AkademikMSP"[[:space:]]*:[[:space:]]*true' && READY_COUNT=$((READY_COUNT+1))
    echo "${READINESS_OUTPUT}" | grep -Eq '"DokterMSP"[[:space:]]*:[[:space:]]*true' && READY_COUNT=$((READY_COUNT+1))

    if [ "${READY_COUNT}" -lt 2 ]; then
        error "Belum memenuhi mayoritas approval untuk commit."
    fi

    # =====================================================
    # STEP 8: COMMIT
    # =====================================================
    log "Step 10: Commit chaincode ke channel..."
    COMMIT_OUTPUT=$(docker exec \
        -e CORE_PEER_LOCALMSPID=KlinikMSP \
        -e CORE_PEER_ADDRESS=peer0.klinik.${DOMAIN}:7051 \
        -e CORE_PEER_MSPCONFIGPATH=${CLI_CRYPTO}/peerOrganizations/klinik.${DOMAIN}/users/Admin@klinik.${DOMAIN}/msp \
        -e CORE_PEER_TLS_ROOTCERT_FILE=${PEER0_KLINIK_CA} \
        cli peer lifecycle chaincode commit \
        -o orderer1.${DOMAIN}:7050 \
        --ordererTLSHostnameOverride orderer1.${DOMAIN} \
        --channelID ${CHANNEL_NAME} \
        --name ${CHAINCODE_NAME} \
        --version ${CHAINCODE_VERSION} \
        --sequence ${CHAINCODE_SEQUENCE} \
        --signature-policy "${CC_POLICY}" \
        --tls --cafile ${ORDERER_CA} \
        --peerAddresses peer0.klinik.${DOMAIN}:7051 \
        --tlsRootCertFiles ${PEER0_KLINIK_CA} \
        --peerAddresses peer0.akademik.${DOMAIN}:9051 \
        --tlsRootCertFiles ${PEER0_AKADEMIK_CA} \
        --peerAddresses peer0.dokter.${DOMAIN}:10051 \
        --tlsRootCertFiles ${PEER0_DOKTER_CA} 2>&1) || true
    echo "${COMMIT_OUTPUT}"

    if echo "${COMMIT_OUTPUT}" | grep -qi "Error:"; then
        if is_committed; then
            warn "Commit sudah pernah berhasil, lanjut."
        else
            error "Commit gagal."
        fi
    fi
    log "Commit berhasil."
fi

# =====================================================
# STEP 9: VERIFIKASI
# =====================================================
log "Step 11: Verifikasi chaincode aktif..."
VERIFY_OUTPUT=$(docker exec \
    -e CORE_PEER_LOCALMSPID=KlinikMSP \
    -e CORE_PEER_ADDRESS=peer0.klinik.${DOMAIN}:7051 \
    -e CORE_PEER_MSPCONFIGPATH=${CLI_CRYPTO}/peerOrganizations/klinik.${DOMAIN}/users/Admin@klinik.${DOMAIN}/msp \
    -e CORE_PEER_TLS_ROOTCERT_FILE=${PEER0_KLINIK_CA} \
    cli peer lifecycle chaincode querycommitted \
    --channelID ${CHANNEL_NAME} \
    --name ${CHAINCODE_NAME} 2>&1) || true
echo "${VERIFY_OUTPUT}"

if echo "${VERIFY_OUTPUT}" | grep -q "Version: ${CHAINCODE_VERSION}"; then
    log "Verifikasi berhasil."
else
    error "Chaincode belum ter-commit di channel."
fi

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN} Chaincode berhasil di-deploy!${NC}"
echo -e "${GREEN} Nama    : ${CHAINCODE_NAME}${NC}"
echo -e "${GREEN} Channel : ${CHANNEL_NAME}${NC}"
echo -e "${GREEN} Versi   : ${CHAINCODE_VERSION}${NC}"
echo -e "${GREEN} Policy  : ${CC_POLICY}${NC}"
echo -e "${GREEN}============================================${NC}"