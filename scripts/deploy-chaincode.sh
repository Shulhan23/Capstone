#!/bin/bash
set -e

PROJECT_DIR=$PWD
CHANNEL_NAME="medchannel"
CHAINCODE_NAME="medical"
CHAINCODE_VERSION="1.0"
CHAINCODE_SEQUENCE="1"
DOMAIN="example.com"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Path di dalam CLI container
CLI_CRYPTO="/etc/hyperledger/fabric/crypto"
CLI_CC="/etc/hyperledger/fabric/chaincode"
ORDERER_CA="${CLI_CRYPTO}/ordererOrganizations/${DOMAIN}/orderers/orderer.${DOMAIN}/msp/tlscacerts/tlsca.${DOMAIN}-cert.pem"
PEER0_KLINIK_CA="${CLI_CRYPTO}/peerOrganizations/klinik.${DOMAIN}/peers/peer0.klinik.${DOMAIN}/tls/ca.crt"
PEER0_AKADEMIK_CA="${CLI_CRYPTO}/peerOrganizations/akademik.${DOMAIN}/peers/peer0.akademik.${DOMAIN}/tls/ca.crt"

# =====================================================
# STEP 1: PACKAGE
# =====================================================
log "Step 1: Packaging chaincode..."
docker exec cli peer lifecycle chaincode package \
    ${CLI_CC}/${CHAINCODE_NAME}.tar.gz \
    --path ${CLI_CC}/${CHAINCODE_NAME} \
    --lang node \
    --label ${CHAINCODE_NAME}_${CHAINCODE_VERSION}
log "Package berhasil: ${CHAINCODE_NAME}.tar.gz"

# =====================================================
# STEP 2: INSTALL KE PEER KLINIK
# =====================================================
log "Step 2: Install ke peer Klinik..."
docker exec cli peer lifecycle chaincode install \
    ${CLI_CC}/${CHAINCODE_NAME}.tar.gz
log "Install ke Klinik berhasil."

# =====================================================
# STEP 3: INSTALL KE PEER AKADEMIK
# =====================================================
log "Step 3: Install ke peer Akademik..."
docker exec \
    -e CORE_PEER_LOCALMSPID=AkademikMSP \
    -e CORE_PEER_ADDRESS=peer0.akademik.${DOMAIN}:9051 \
    -e CORE_PEER_MSPCONFIGPATH=${CLI_CRYPTO}/peerOrganizations/akademik.${DOMAIN}/users/Admin@akademik.${DOMAIN}/msp \
    -e CORE_PEER_TLS_ROOTCERT_FILE=${PEER0_AKADEMIK_CA} \
    cli peer lifecycle chaincode install \
    ${CLI_CC}/${CHAINCODE_NAME}.tar.gz
log "Install ke Akademik berhasil."

# =====================================================
# STEP 4: DAPATKAN PACKAGE ID
# =====================================================
log "Step 4: Query Package ID..."
QUERY_RESULT=$(docker exec cli peer lifecycle chaincode queryinstalled)
echo "$QUERY_RESULT"

# Ambil Package ID otomatis
CC_PACKAGE_ID=$(echo "$QUERY_RESULT" | grep "${CHAINCODE_NAME}_${CHAINCODE_VERSION}" | awk '{print $3}' | sed 's/,//')

if [ -z "$CC_PACKAGE_ID" ]; then
    error "Package ID tidak ditemukan. Cek output queryinstalled di atas."
fi
log "Package ID: $CC_PACKAGE_ID"

# =====================================================
# STEP 5: APPROVE DARI KLINIK
# =====================================================
log "Step 5: Approve dari KlinikMSP..."
docker exec cli peer lifecycle chaincode approveformyorg \
    -o orderer.${DOMAIN}:7050 \
    --ordererTLSHostnameOverride orderer.${DOMAIN} \
    --channelID ${CHANNEL_NAME} \
    --name ${CHAINCODE_NAME} \
    --version ${CHAINCODE_VERSION} \
    --package-id ${CC_PACKAGE_ID} \
    --sequence ${CHAINCODE_SEQUENCE} \
    --tls --cafile ${ORDERER_CA}
log "Approve Klinik berhasil."

# =====================================================
# STEP 6: APPROVE DARI AKADEMIK
# =====================================================
log "Step 6: Approve dari AkademikMSP..."
docker exec \
    -e CORE_PEER_LOCALMSPID=AkademikMSP \
    -e CORE_PEER_ADDRESS=peer0.akademik.${DOMAIN}:9051 \
    -e CORE_PEER_MSPCONFIGPATH=${CLI_CRYPTO}/peerOrganizations/akademik.${DOMAIN}/users/Admin@akademik.${DOMAIN}/msp \
    -e CORE_PEER_TLS_ROOTCERT_FILE=${PEER0_AKADEMIK_CA} \
    cli peer lifecycle chaincode approveformyorg \
    -o orderer.${DOMAIN}:7050 \
    --ordererTLSHostnameOverride orderer.${DOMAIN} \
    --channelID ${CHANNEL_NAME} \
    --name ${CHAINCODE_NAME} \
    --version ${CHAINCODE_VERSION} \
    --package-id ${CC_PACKAGE_ID} \
    --sequence ${CHAINCODE_SEQUENCE} \
    --tls --cafile ${ORDERER_CA}
log "Approve Akademik berhasil."

# =====================================================
# STEP 7: CEK READINESS
# =====================================================
log "Step 7: Cek readiness..."
docker exec cli peer lifecycle chaincode checkcommitreadiness \
    --channelID ${CHANNEL_NAME} \
    --name ${CHAINCODE_NAME} \
    --version ${CHAINCODE_VERSION} \
    --sequence ${CHAINCODE_SEQUENCE} \
    --tls --cafile ${ORDERER_CA} \
    --output json
# Kedua org harus true sebelum lanjut

# =====================================================
# STEP 8: COMMIT
# =====================================================
log "Step 8: Commit chaincode ke channel..."
docker exec cli peer lifecycle chaincode commit \
    -o orderer.${DOMAIN}:7050 \
    --ordererTLSHostnameOverride orderer.${DOMAIN} \
    --channelID ${CHANNEL_NAME} \
    --name ${CHAINCODE_NAME} \
    --version ${CHAINCODE_VERSION} \
    --sequence ${CHAINCODE_SEQUENCE} \
    --tls --cafile ${ORDERER_CA} \
    --peerAddresses peer0.klinik.${DOMAIN}:7051 \
    --tlsRootCertFiles ${PEER0_KLINIK_CA} \
    --peerAddresses peer0.akademik.${DOMAIN}:9051 \
    --tlsRootCertFiles ${PEER0_AKADEMIK_CA}
log "Commit berhasil."

# =====================================================
# STEP 9: VERIFIKASI
# =====================================================
log "Step 9: Verifikasi chaincode aktif..."
docker exec cli peer lifecycle chaincode querycommitted \
    --channelID ${CHANNEL_NAME} \
    --name ${CHAINCODE_NAME}

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN} Chaincode berhasil di-deploy!${NC}"
echo -e "${GREEN} Nama    : ${CHAINCODE_NAME}${NC}"
echo -e "${GREEN} Channel : ${CHANNEL_NAME}${NC}"
echo -e "${GREEN} Versi   : ${CHAINCODE_VERSION}${NC}"
echo -e "${GREEN}============================================${NC}"