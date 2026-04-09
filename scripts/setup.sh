#!/bin/bash
# =================================================================
# setup.sh — Generate artefak & setup channel medchannel
# Jalankan sekali saat pertama kali setup jaringan
# Usage: chmod +x setup.sh && ./setup.sh
# =================================================================

set -e  # stop jika ada error

CHANNEL_NAME="medchannel"
DOMAIN="example.com"  # ganti ke domain production saat migrasi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# -----------------------------------------------------------------
# 0. CEK BINARY
# -----------------------------------------------------------------
log "Memeriksa binary Fabric..."
for bin in cryptogen configtxgen peer; do
  command -v $bin >/dev/null 2>&1 || error "Binary '$bin' tidak ditemukan. Jalankan: curl -sSL https://bit.ly/2ysbOFE | bash -s -- 2.5.0 1.5.7"
done
log "Semua binary tersedia."

# -----------------------------------------------------------------
# 1. BERSIHKAN ARTEFAK LAMA
# -----------------------------------------------------------------
log "Membersihkan artefak lama..."
rm -rf crypto-config channel-artifacts data
mkdir -p channel-artifacts data/couchdb/klinik data/couchdb/akademik

# -----------------------------------------------------------------
# 2. GENERATE CRYPTO MATERIAL
# -----------------------------------------------------------------
log "Generating crypto material..."
cryptogen generate --config=./crypto-config.yaml --output=crypto-config
log "Crypto material berhasil dibuat di ./crypto-config/"

# -----------------------------------------------------------------
# 3. GENERATE GENESIS BLOCK
# -----------------------------------------------------------------
log "Generating genesis block..."
export FABRIC_CFG_PATH=$PWD
configtxgen \
  -profile TwoOrgsOrdererGenesis \
  -channelID system-channel \
  -outputBlock ./channel-artifacts/orderer.genesis.block
log "Genesis block: ./channel-artifacts/orderer.genesis.block"

# -----------------------------------------------------------------
# 4. GENERATE CHANNEL TRANSACTION
# -----------------------------------------------------------------
log "Generating channel transaction untuk '$CHANNEL_NAME'..."
configtxgen \
  -profile TwoOrgsChannel \
  -outputCreateChannelTx ./channel-artifacts/${CHANNEL_NAME}.tx \
  -channelID $CHANNEL_NAME
log "Channel tx: ./channel-artifacts/${CHANNEL_NAME}.tx"

# -----------------------------------------------------------------
# 5. GENERATE ANCHOR PEER UPDATE — KLINIK
# -----------------------------------------------------------------
log "Generating anchor peer update — KlinikMSP..."
configtxgen \
  -profile TwoOrgsChannel \
  -outputAnchorPeersUpdate ./channel-artifacts/KlinikMSPanchors.tx \
  -channelID $CHANNEL_NAME \
  -asOrg KlinikMSP
log "Anchor peer Klinik: ./channel-artifacts/KlinikMSPanchors.tx"

# -----------------------------------------------------------------
# 6. GENERATE ANCHOR PEER UPDATE — AKADEMIK
# -----------------------------------------------------------------
log "Generating anchor peer update — AkademikMSP..."
configtxgen \
  -profile TwoOrgsChannel \
  -outputAnchorPeersUpdate ./channel-artifacts/AkademikMSPanchors.tx \
  -channelID $CHANNEL_NAME \
  -asOrg AkademikMSP
log "Anchor peer Akademik: ./channel-artifacts/AkademikMSPanchors.tx"

# -----------------------------------------------------------------
# 7. START DOCKER
# -----------------------------------------------------------------
log "Menjalankan docker compose..."
docker compose up -d

log "Menunggu semua container healthy (60 detik)..."
sleep 60

# Verifikasi
RUNNING=$(docker ps --filter "status=running" --format "{{.Names}}" | wc -l)
log "$RUNNING container berjalan."

# -----------------------------------------------------------------
# 8. BUAT CHANNEL
# -----------------------------------------------------------------
log "Membuat channel '$CHANNEL_NAME'..."

ORDERER_CA="crypto-config/ordererOrganizations/${DOMAIN}/orderers/orderer.${DOMAIN}/msp/tlscacerts/tlsca.${DOMAIN}-cert.pem"
PEER0_KLINIK_CA="crypto-config/peerOrganizations/klinik.${DOMAIN}/peers/peer0.klinik.${DOMAIN}/tls/ca.crt"
PEER0_AKADEMIK_CA="crypto-config/peerOrganizations/akademik.${DOMAIN}/peers/peer0.akademik.${DOMAIN}/tls/ca.crt"

export CORE_PEER_TLS_ENABLED=true
export CORE_PEER_LOCALMSPID=KlinikMSP
export CORE_PEER_MSPCONFIGPATH="crypto-config/peerOrganizations/klinik.${DOMAIN}/users/Admin@klinik.${DOMAIN}/msp"
export CORE_PEER_ADDRESS=peer0.klinik.${DOMAIN}:7051
export CORE_PEER_TLS_ROOTCERT_FILE=$PEER0_KLINIK_CA

peer channel create \
  -o orderer.${DOMAIN}:7050 \
  --ordererTLSHostnameOverride orderer.${DOMAIN} \
  -c $CHANNEL_NAME \
  -f ./channel-artifacts/${CHANNEL_NAME}.tx \
  --outputBlock ./channel-artifacts/${CHANNEL_NAME}.block \
  --tls --cafile $ORDERER_CA
log "Channel '$CHANNEL_NAME' berhasil dibuat."

# -----------------------------------------------------------------
# 9. JOIN PEER KLINIK
# -----------------------------------------------------------------
log "Menggabungkan peer0.klinik ke channel..."
peer channel join -b ./channel-artifacts/${CHANNEL_NAME}.block
log "peer0.klinik bergabung ke channel."

# -----------------------------------------------------------------
# 10. JOIN PEER AKADEMIK
# -----------------------------------------------------------------
log "Menggabungkan peer0.akademik ke channel..."
export CORE_PEER_LOCALMSPID=AkademikMSP
export CORE_PEER_MSPCONFIGPATH="crypto-config/peerOrganizations/akademik.${DOMAIN}/users/Admin@akademik.${DOMAIN}/msp"
export CORE_PEER_ADDRESS=peer0.akademik.${DOMAIN}:9051
export CORE_PEER_TLS_ROOTCERT_FILE=$PEER0_AKADEMIK_CA

peer channel join -b ./channel-artifacts/${CHANNEL_NAME}.block
log "peer0.akademik bergabung ke channel."

# -----------------------------------------------------------------
# 11. UPDATE ANCHOR PEERS
# -----------------------------------------------------------------
log "Mengupdate anchor peer Klinik..."
export CORE_PEER_LOCALMSPID=KlinikMSP
export CORE_PEER_MSPCONFIGPATH="crypto-config/peerOrganizations/klinik.${DOMAIN}/users/Admin@klinik.${DOMAIN}/msp"
export CORE_PEER_ADDRESS=peer0.klinik.${DOMAIN}:7051
export CORE_PEER_TLS_ROOTCERT_FILE=$PEER0_KLINIK_CA

peer channel update \
  -o orderer.${DOMAIN}:7050 \
  --ordererTLSHostnameOverride orderer.${DOMAIN} \
  -c $CHANNEL_NAME \
  -f ./channel-artifacts/KlinikMSPanchors.tx \
  --tls --cafile $ORDERER_CA

log "Mengupdate anchor peer Akademik..."
export CORE_PEER_LOCALMSPID=AkademikMSP
export CORE_PEER_MSPCONFIGPATH="crypto-config/peerOrganizations/akademik.${DOMAIN}/users/Admin@akademik.${DOMAIN}/msp"
export CORE_PEER_ADDRESS=peer0.akademik.${DOMAIN}:9051
export CORE_PEER_TLS_ROOTCERT_FILE=$PEER0_AKADEMIK_CA

peer channel update \
  -o orderer.${DOMAIN}:7050 \
  --ordererTLSHostnameOverride orderer.${DOMAIN} \
  -c $CHANNEL_NAME \
  -f ./channel-artifacts/AkademikMSPanchors.tx \
  --tls --cafile $ORDERER_CA

# -----------------------------------------------------------------
# 12. VERIFIKASI AKHIR
# -----------------------------------------------------------------
log "Verifikasi channel..."
export CORE_PEER_LOCALMSPID=KlinikMSP
export CORE_PEER_MSPCONFIGPATH="crypto-config/peerOrganizations/klinik.${DOMAIN}/users/Admin@klinik.${DOMAIN}/msp"
export CORE_PEER_ADDRESS=peer0.klinik.${DOMAIN}:7051
export CORE_PEER_TLS_ROOTCERT_FILE=$PEER0_KLINIK_CA

peer channel list

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN} Setup selesai! Jaringan siap digunakan.${NC}"
echo -e "${GREEN} Channel: $CHANNEL_NAME${NC}"
echo -e "${GREEN} Langkah selanjutnya: deploy chaincode${NC}"
echo -e "${GREEN}============================================${NC}"