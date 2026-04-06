#!/bin/bash
set -e

echo "=== SETUP CHANNEL DAN JOIN PEERS ==="

# === Konfigurasi Umum ===
CHANNEL_NAME="sick-letter-channel"
PROJECT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
export FABRIC_CFG_PATH=$PROJECT_ROOT
export PATH=$PROJECT_ROOT/fabric-samples/bin:$PATH
ORDERER_CA=/opt/gopath/src/github.com/hyperledger/fabric/peer/crypto/ordererOrganizations/example.com/orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem

export PATH=$BIN_PATH:$PATH
export FABRIC_CFG_PATH=$FABRIC_CFG_PATH

# === Fungsi Validasi ===
check_success() {
  if [ $? -ne 0 ]; then
    echo "❌ ERROR: $1 gagal"
    exit 1
  fi
}

# === Fungsi Cek Peer Sudah Join ===
check_peer_joined() {
  ORG=$1
  PORT=$2
  MSP=$3

  CHANNELS=$(docker exec -e CORE_PEER_LOCALMSPID="$MSP" \
              -e CORE_PEER_MSPCONFIGPATH="/opt/gopath/src/github.com/hyperledger/fabric/peer/crypto/peerOrganizations/$ORG.example.com/users/Admin@$ORG.example.com/msp" \
              -e CORE_PEER_ADDRESS="peer0.$ORG.example.com:$PORT" \
              -e CORE_PEER_TLS_ROOTCERT_FILE="/opt/gopath/src/github.com/hyperledger/fabric/peer/crypto/peerOrganizations/$ORG.example.com/peers/peer0.$ORG.example.com/tls/ca.crt" \
              cli peer channel list)

  echo "$CHANNELS" | grep -q "$CHANNEL_NAME"
}

# === Fungsi Join Peer ===
join_peer() {
  ORG=$1
  PORT=$2
  MSP=$3

  echo "➡️ Peer $ORG join channel..."

  if check_peer_joined "$ORG" "$PORT" "$MSP"; then
    echo "ℹ️ Peer $ORG sudah join channel, skip"
  else
    docker exec -e CORE_PEER_LOCALMSPID="$MSP" \
                -e CORE_PEER_MSPCONFIGPATH="/opt/gopath/src/github.com/hyperledger/fabric/peer/crypto/peerOrganizations/$ORG.example.com/users/Admin@$ORG.example.com/msp" \
                -e CORE_PEER_ADDRESS="peer0.$ORG.example.com:$PORT" \
                -e CORE_PEER_TLS_ROOTCERT_FILE="/opt/gopath/src/github.com/hyperledger/fabric/peer/crypto/peerOrganizations/$ORG.example.com/peers/peer0.$ORG.example.com/tls/ca.crt" \
                cli peer channel join -b ./channel-artifacts/$CHANNEL_NAME.block
    check_success "Peer $ORG join channel"
  fi
}

# === Validasi File channel.tx dan genesis.block ===
if [ ! -f ./channel-artifacts/channel.tx ]; then
  echo "⚠️ File channel.tx tidak ditemukan. Membuat ulang..."
  configtxgen -profile ThreeOrgsChannel \
    -outputCreateChannelTx ./channel-artifacts/channel.tx \
    -channelID $CHANNEL_NAME
  check_success "Generate channel.tx"
fi

if [ ! -f ./channel-artifacts/orderer.genesis.block ]; then
  echo "⚠️ File orderer.genesis.block tidak ditemukan. Membuat ulang..."
  configtxgen -profile ThreeOrgsOrdererGenesis \
    -channelID system-channel \
    -outputBlock ./channel-artifacts/orderer.genesis.block
  check_success "Generate orderer.genesis.block"
fi

# === 1. Membuat Channel ===
if [ ! -f ./channel-artifacts/$CHANNEL_NAME.block ]; then
  echo "🛠️ Membuat channel $CHANNEL_NAME..."
  docker exec cli peer channel create \
    -o orderer.example.com:7050 \
    --ordererTLSHostnameOverride orderer.example.com \
    -c $CHANNEL_NAME \
    -f ./channel-artifacts/channel.tx \
    --outputBlock ./channel-artifacts/$CHANNEL_NAME.block \
    --tls --cafile $ORDERER_CA
  check_success "Channel creation"
else
  echo "ℹ️ Channel block sudah ada, skip pembuatan channel"
fi

# === 2. Join Semua Peer ===
join_peer "klinik" 7051 "KlinikMSP"
join_peer "akademik" 9051 "AkademikMSP"
join_peer "mahasiswa" 8051 "MahasiswaMSP"

echo "✅ Semua peer berhasil join channel '$CHANNEL_NAME'"
