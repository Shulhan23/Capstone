#!/bin/bash
# =================================================================
# setup.sh — Generate artefak & setup channel medchannel
# Jalankan sekali saat pertama kali setup jaringan
# Usage: chmod +x setup.sh && ./setup.sh
# =================================================================

set -e  # stop jika ada error

# Simpan direktori proyek — semua path crypto relatif ke sini
PROJECT_DIR=$PWD

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
rm -rf crypto-config channel-artifacts
  sudo rm -rf data
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
# configtxgen: gunakan -configPath untuk baca configtx.yaml dari project dir
# peer: butuh FABRIC_CFG_PATH ke fabric-samples/config untuk baca core.yaml
export PATH=$PATH:$HOME/fabric-tools/fabric-samples/bin
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
# Deteksi versi docker compose yang tersedia
if docker compose version &>/dev/null; then
  COMPOSE_CMD="docker compose"
elif docker-compose version &>/dev/null; then
  COMPOSE_CMD="docker-compose"
else
  error "Docker Compose tidak ditemukan. Install dengan: sudo apt install docker-compose-plugin"
fi
log "Menggunakan: $COMPOSE_CMD"
$COMPOSE_CMD up -d

log "Menunggu semua container healthy (60 detik)..."
sleep 120

# Verifikasi
RUNNING=$(docker ps --filter "status=running" --format "{{.Names}}" | wc -l)
log "$RUNNING container berjalan."

# -----------------------------------------------------------------
# 8. BUAT CHANNEL (via CLI container — resolve DNS otomatis)
# -----------------------------------------------------------------
log "Membuat channel '$CHANNEL_NAME' via CLI container..."

# Path di dalam CLI container (sesuai volume mount di docker-compose)
CLI_CRYPTO="/etc/hyperledger/fabric/crypto"
CLI_ARTIFACTS="/etc/hyperledger/fabric/channel-artifacts"
ORDERER_CA_CLI="${CLI_CRYPTO}/ordererOrganizations/${DOMAIN}/orderers/orderer.${DOMAIN}/msp/tlscacerts/tlsca.${DOMAIN}-cert.pem"
PEER0_KLINIK_CA_CLI="${CLI_CRYPTO}/peerOrganizations/klinik.${DOMAIN}/peers/peer0.klinik.${DOMAIN}/tls/ca.crt"
PEER0_AKADEMIK_CA_CLI="${CLI_CRYPTO}/peerOrganizations/akademik.${DOMAIN}/peers/peer0.akademik.${DOMAIN}/tls/ca.crt"

docker exec cli peer channel create \
  -o orderer.${DOMAIN}:7050 \
  --ordererTLSHostnameOverride orderer.${DOMAIN} \
  -c $CHANNEL_NAME \
  -f ${CLI_ARTIFACTS}/${CHANNEL_NAME}.tx \
  --outputBlock ${CLI_ARTIFACTS}/${CHANNEL_NAME}.block \
  --tls --cafile $ORDERER_CA_CLI
log "Channel '$CHANNEL_NAME' berhasil dibuat."

# -----------------------------------------------------------------
# 9. JOIN PEER KLINIK
# -----------------------------------------------------------------
log "Menggabungkan peer0.klinik ke channel..."
docker exec cli peer channel join -b ${CLI_ARTIFACTS}/${CHANNEL_NAME}.block
log "peer0.klinik bergabung ke channel."

# -----------------------------------------------------------------
# 10. JOIN PEER AKADEMIK
# -----------------------------------------------------------------
log "Menggabungkan peer0.akademik ke channel..."
docker exec -e CORE_PEER_LOCALMSPID=AkademikMSP \
  -e CORE_PEER_ADDRESS=peer0.akademik.${DOMAIN}:9051 \
  -e CORE_PEER_MSPCONFIGPATH=${CLI_CRYPTO}/peerOrganizations/akademik.${DOMAIN}/users/Admin@akademik.${DOMAIN}/msp \
  -e CORE_PEER_TLS_ROOTCERT_FILE=$PEER0_AKADEMIK_CA_CLI \
  cli peer channel join -b ${CLI_ARTIFACTS}/${CHANNEL_NAME}.block
log "peer0.akademik bergabung ke channel."

# -----------------------------------------------------------------
# 11. UPDATE ANCHOR PEERS
# -----------------------------------------------------------------
log "Mengupdate anchor peer Klinik..."
docker exec cli peer channel update \
  -o orderer.${DOMAIN}:7050 \
  --ordererTLSHostnameOverride orderer.${DOMAIN} \
  -c $CHANNEL_NAME \
  -f ${CLI_ARTIFACTS}/KlinikMSPanchors.tx \
  --tls --cafile $ORDERER_CA_CLI

log "Mengupdate anchor peer Akademik..."
docker exec -e CORE_PEER_LOCALMSPID=AkademikMSP \
  -e CORE_PEER_ADDRESS=peer0.akademik.${DOMAIN}:9051 \
  -e CORE_PEER_MSPCONFIGPATH=${CLI_CRYPTO}/peerOrganizations/akademik.${DOMAIN}/users/Admin@akademik.${DOMAIN}/msp \
  -e CORE_PEER_TLS_ROOTCERT_FILE=$PEER0_AKADEMIK_CA_CLI \
  cli peer channel update \
  -o orderer.${DOMAIN}:7050 \
  --ordererTLSHostnameOverride orderer.${DOMAIN} \
  -c $CHANNEL_NAME \
  -f ${CLI_ARTIFACTS}/AkademikMSPanchors.tx \
  --tls --cafile $ORDERER_CA_CLI

# -----------------------------------------------------------------
# 12. VERIFIKASI AKHIR
# -----------------------------------------------------------------
log "Verifikasi channel..."
docker exec cli peer channel list

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN} Setup selesai! Jaringan siap digunakan.${NC}"
echo -e "${GREEN} Channel: $CHANNEL_NAME${NC}"
echo -e "${GREEN} Langkah selanjutnya: deploy chaincode${NC}"
echo -e "${GREEN}============================================${NC}"