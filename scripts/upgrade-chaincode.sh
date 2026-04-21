#!/bin/bash
set -e

CHAINCODE_VERSION="6.0"
CHAINCODE_SEQUENCE="5"

CHANNEL_NAME="medchannel"
CHAINCODE_NAME="medical"
DOMAIN="medchain.id"

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
log()   { echo -e "${GREEN}[INFO]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

CLI_CRYPTO="/etc/hyperledger/fabric/crypto"
CLI_CC="/etc/hyperledger/fabric/chaincode"
ORDERER_CA="${CLI_CRYPTO}/ordererOrganizations/${DOMAIN}/orderers/orderer1.${DOMAIN}/msp/tlscacerts/tlsca.${DOMAIN}-cert.pem"
PEER0_KLINIK_CA="${CLI_CRYPTO}/peerOrganizations/klinik.${DOMAIN}/peers/peer0.klinik.${DOMAIN}/tls/ca.crt"
PEER0_AKADEMIK_CA="${CLI_CRYPTO}/peerOrganizations/akademik.${DOMAIN}/peers/peer0.akademik.${DOMAIN}/tls/ca.crt"

log "Step 1/6: Copy package ke CLI container..."
docker cp ~/Capstone/chaincode/medical_v6.tar.gz \
    cli:${CLI_CC}/${CHAINCODE_NAME}_v${CHAINCODE_VERSION}.tar.gz
log "Package siap."

log "Step 2/6: Install ke peer Klinik..."
docker exec cli peer lifecycle chaincode install \
    ${CLI_CC}/${CHAINCODE_NAME}_v${CHAINCODE_VERSION}.tar.gz

log "Step 2/6: Install ke peer Akademik..."
docker exec \
    -e CORE_PEER_LOCALMSPID=AkademikMSP \
    -e CORE_PEER_ADDRESS=peer0.akademik.${DOMAIN}:9051 \
    -e CORE_PEER_MSPCONFIGPATH=${CLI_CRYPTO}/peerOrganizations/akademik.${DOMAIN}/users/Admin@akademik.${DOMAIN}/msp \
    -e CORE_PEER_TLS_ROOTCERT_FILE=${PEER0_AKADEMIK_CA} \
    cli peer lifecycle chaincode install \
    ${CLI_CC}/${CHAINCODE_NAME}_v${CHAINCODE_VERSION}.tar.gz

log "Step 3/6: Ambil Package ID..."
QUERY_RESULT=$(docker exec cli peer lifecycle chaincode queryinstalled 2>&1)
echo "$QUERY_RESULT"
CC_PACKAGE_ID=$(echo "$QUERY_RESULT" | grep "${CHAINCODE_NAME}_${CHAINCODE_VERSION}" | awk '{print $3}' | sed 's/,//')
[ -z "$CC_PACKAGE_ID" ] && error "Package ID tidak ditemukan."
log "Package ID: $CC_PACKAGE_ID"

log "Step 4/6: Approve KlinikMSP..."
docker exec cli peer lifecycle chaincode approveformyorg \
    -o orderer1.${DOMAIN}:7050 \
    --ordererTLSHostnameOverride orderer1.${DOMAIN} \
    --channelID ${CHANNEL_NAME} \
    --name ${CHAINCODE_NAME} \
    --version ${CHAINCODE_VERSION} \
    --package-id ${CC_PACKAGE_ID} \
    --sequence ${CHAINCODE_SEQUENCE} \
    --tls --cafile ${ORDERER_CA}

log "Step 4/6: Approve AkademikMSP..."
docker exec \
    -e CORE_PEER_LOCALMSPID=AkademikMSP \
    -e CORE_PEER_ADDRESS=peer0.akademik.${DOMAIN}:9051 \
    -e CORE_PEER_MSPCONFIGPATH=${CLI_CRYPTO}/peerOrganizations/akademik.${DOMAIN}/users/Admin@akademik.${DOMAIN}/msp \
    -e CORE_PEER_TLS_ROOTCERT_FILE=${PEER0_AKADEMIK_CA} \
    cli peer lifecycle chaincode approveformyorg \
    -o orderer1.${DOMAIN}:7050 \
    --ordererTLSHostnameOverride orderer1.${DOMAIN} \
    --channelID ${CHANNEL_NAME} \
    --name ${CHAINCODE_NAME} \
    --version ${CHAINCODE_VERSION} \
    --package-id ${CC_PACKAGE_ID} \
    --sequence ${CHAINCODE_SEQUENCE} \
    --tls --cafile ${ORDERER_CA}

log "Step 5/6: Cek readiness..."
READINESS=$(docker exec cli peer lifecycle chaincode checkcommitreadiness \
    --channelID ${CHANNEL_NAME} \
    --name ${CHAINCODE_NAME} \
    --version ${CHAINCODE_VERSION} \
    --sequence ${CHAINCODE_SEQUENCE} \
    --tls --cafile ${ORDERER_CA} \
    --output json)
echo "$READINESS"

KLINIK_READY=$(echo "$READINESS" | grep -o '"KlinikMSP": true' | wc -l)
AKADEMIK_READY=$(echo "$READINESS" | grep -o '"AkademikMSP": true' | wc -l)
[ "$KLINIK_READY" -eq 0 ] && error "KlinikMSP belum approve."
[ "$AKADEMIK_READY" -eq 0 ] && error "AkademikMSP belum approve."

log "Step 6/6: Commit..."
docker exec cli peer lifecycle chaincode commit \
    -o orderer1.${DOMAIN}:7050 \
    --ordererTLSHostnameOverride orderer1.${DOMAIN} \
    --channelID ${CHANNEL_NAME} \
    --name ${CHAINCODE_NAME} \
    --version ${CHAINCODE_VERSION} \
    --sequence ${CHAINCODE_SEQUENCE} \
    --tls --cafile ${ORDERER_CA} \
    --peerAddresses peer0.klinik.${DOMAIN}:7051 \
    --tlsRootCertFiles ${PEER0_KLINIK_CA} \
    --peerAddresses peer0.akademik.${DOMAIN}:9051 \
    --tlsRootCertFiles ${PEER0_AKADEMIK_CA}

log "Verifikasi..."
docker exec cli peer lifecycle chaincode querycommitted \
    --channelID ${CHANNEL_NAME} --name ${CHAINCODE_NAME}

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN} Upgrade berhasil! Versi: ${CHAINCODE_VERSION}${NC}"
echo -e "${GREEN}============================================${NC}"