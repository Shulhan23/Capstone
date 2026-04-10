#!/bin/bash
# Script ini dipakai jika chaincode sudah ter-install
# tapi approve dan commit belum dilakukan
set -e

CHANNEL_NAME="medchannel"
CHAINCODE_NAME="medical"
CHAINCODE_VERSION="1.0"
CHAINCODE_SEQUENCE="1"
DOMAIN="example.com"

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
log()   { echo -e "${GREEN}[INFO]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

CLI_CRYPTO="/etc/hyperledger/fabric/crypto"
ORDERER_CA="${CLI_CRYPTO}/ordererOrganizations/${DOMAIN}/orderers/orderer.${DOMAIN}/msp/tlscacerts/tlsca.${DOMAIN}-cert.pem"
PEER0_KLINIK_CA="${CLI_CRYPTO}/peerOrganizations/klinik.${DOMAIN}/peers/peer0.klinik.${DOMAIN}/tls/ca.crt"
PEER0_AKADEMIK_CA="${CLI_CRYPTO}/peerOrganizations/akademik.${DOMAIN}/peers/peer0.akademik.${DOMAIN}/tls/ca.crt"

# Ambil Package ID dari yang sudah ter-install
log "Ambil Package ID..."
QUERY_RESULT=$(docker exec cli peer lifecycle chaincode queryinstalled 2>&1)
echo "$QUERY_RESULT"
CC_PACKAGE_ID=$(echo "$QUERY_RESULT" | grep "${CHAINCODE_NAME}_${CHAINCODE_VERSION}" | awk '{print $3}' | sed 's/,//')
[ -z "$CC_PACKAGE_ID" ] && error "Package ID tidak ditemukan. Jalankan deploy-chaincode.sh dulu."
log "Package ID: $CC_PACKAGE_ID"

# Approve Klinik
log "Approve KlinikMSP..."
docker exec cli peer lifecycle chaincode approveformyorg \
    -o orderer.${DOMAIN}:7050 \
    --ordererTLSHostnameOverride orderer.${DOMAIN} \
    --channelID ${CHANNEL_NAME} \
    --name ${CHAINCODE_NAME} \
    --version ${CHAINCODE_VERSION} \
    --package-id ${CC_PACKAGE_ID} \
    --sequence ${CHAINCODE_SEQUENCE} \
    --tls --cafile ${ORDERER_CA}
log "Approve Klinik selesai."

# Approve Akademik
log "Approve AkademikMSP..."
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
log "Approve Akademik selesai."

# Cek readiness
log "Cek readiness..."
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

# Commit
log "Commit..."
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

log "Verifikasi..."
docker exec cli peer lifecycle chaincode querycommitted \
    --channelID ${CHANNEL_NAME} --name ${CHAINCODE_NAME}

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN} Approve & Commit berhasil!${NC}"
echo -e "${GREEN}============================================${NC}"