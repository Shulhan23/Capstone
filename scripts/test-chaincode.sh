#!/bin/bash

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
PASS=0; FAIL=0

log()  { echo -e "${GREEN}[TEST]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; ((FAIL++)); }
pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS++)); }

DOMAIN="medchain.id"
CLI_CRYPTO="/etc/hyperledger/fabric/crypto"
ORDERER_CA="${CLI_CRYPTO}/ordererOrganizations/${DOMAIN}/orderers/orderer1.${DOMAIN}/msp/tlscacerts/tlsca.${DOMAIN}-cert.pem"
PEER_CA="${CLI_CRYPTO}/peerOrganizations/klinik.${DOMAIN}/peers/peer0.klinik.${DOMAIN}/tls/ca.crt"

invoke() {
  docker exec cli peer chaincode invoke \
    -o orderer1.${DOMAIN}:7050 \
    --ordererTLSHostnameOverride orderer1.${DOMAIN} \
    --tls --cafile $ORDERER_CA \
    -C medchannel -n medical \
    --peerAddresses peer0.klinik.${DOMAIN}:7051 \
    --tlsRootCertFiles $PEER_CA \
    -c "$1" 2>&1
}

query() {
  docker exec cli peer chaincode query \
    -C medchannel -n medical \
    -c "$1" 2>&1
}

echo ""
echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}   TEST CHAINCODE MEDICAL               ${NC}"
echo -e "${YELLOW}========================================${NC}"
echo ""

# Tambahkan di atas bagian TEST 1
TEST_HASH="a665a45920422f9d417e4867efdc4fb8a04a1f3fff1fa07e998e86f7f7a27ae3"

# TEST 1 — Issue surat baru
log "Test 1: IssueSuratSakit..."
RESULT=$(invoke "{\"function\":\"IssueSuratSakit\",\"Args\":[\"TEST-001\",\"${TEST_HASH}\",\"D-001\",\"K-001\",\"P-001\",\"2026-04-10\"]}")
if echo "$RESULT" | grep -q "TEST-001"; then
  pass "IssueSuratSakit berhasil"
else
  fail "IssueSuratSakit gagal: $RESULT"
fi

sleep 2  # tunggu transaksi committed

# TEST 2 — Verifikasi hash benar
log "Test 2: VerifySuratSakit (hash benar)..."
RESULT=$(query "{\"function\":\"VerifySuratSakit\",\"Args\":[\"TEST-001\",\"${TEST_HASH}\"]}")
if echo "$RESULT" | grep -q '"valid":true'; then
  pass "Verifikasi hash benar: valid=true"
else
  fail "Verifikasi hash benar gagal: $RESULT"
fi

# TEST 3 — Verifikasi hash salah
log "Test 3: VerifySuratSakit (hash salah)..."
RESULT=$(query "{\"function\":\"VerifySuratSakit\",\"Args\":[\"TEST-001\",\"${WRONG_HASH}\"]}")
if echo "$RESULT" | grep -q '"valid":false'; then
  pass "Verifikasi hash salah: valid=false"
else
  fail "Verifikasi hash salah gagal: $RESULT"
fi

# TEST 4 — Get surat
log "Test 4: GetSuratSakit..."
RESULT=$(query '{"function":"GetSuratSakit","Args":["TEST-001"]}')
if echo "$RESULT" | grep -q '"status":"ACTIVE"'; then
  pass "GetSuratSakit: status ACTIVE"
else
  fail "GetSuratSakit gagal: $RESULT"
fi

# TEST 5 — Revoke surat
log "Test 5: RevokeSuratSakit..."
RESULT=$(invoke '{"function":"RevokeSuratSakit","Args":["TEST-001","Test pencabutan"]}')
if echo "$RESULT" | grep -q "REVOKED"; then
  pass "RevokeSuratSakit berhasil"
else
  fail "RevokeSuratSakit gagal: $RESULT"
fi

sleep 2

# TEST 6 — Verifikasi setelah revoke
log "Test 6: VerifySuratSakit setelah revoke..."
RESULT=$(query "{\"function\":\"VerifySuratSakit\",\"Args\":[\"TEST-001\",\"${TEST_HASH}\"]}")
if echo "$RESULT" | grep -q '"reason":"REVOKED"'; then
  pass "Verifikasi setelah revoke: reason=REVOKED"
else
  fail "Verifikasi setelah revoke gagal: $RESULT"
fi

# TEST 7 — ID tidak ada
log "Test 7: GetSuratSakit ID tidak ada..."
RESULT=$(query '{"function":"GetSuratSakit","Args":["TIDAK-ADA-999"]}')
if echo "$RESULT" | grep -qi "error\|tidak ditemukan"; then
  pass "ID tidak ada: error ditangani dengan benar"
else
  fail "ID tidak ada: seharusnya error tapi dapat: $RESULT"
fi

# TEST 8 — Duplikat ID
log "Test 8: IssueSuratSakit duplikat ID..."
RESULT=$(invoke "{\"function\":\"IssueSuratSakit\",\"Args\":[\"TEST-001\",\"${TEST_HASH}\",\"D-001\",\"K-001\",\"P-001\",\"2026-04-10\"]}")
if echo "$RESULT" | grep -qi "error\|sudah ada"; then
  pass "Duplikat ID: error ditangani dengan benar"
else
  fail "Duplikat ID: seharusnya error tapi dapat: $RESULT"
fi

# TEST 9 — History
log "Test 9: GetHistoryById..."
RESULT=$(query '{"function":"GetHistoryById","Args":["TEST-001"]}')
if echo "$RESULT" | grep -q "txId"; then
  pass "GetHistoryById: riwayat tersimpan"
else
  fail "GetHistoryById gagal: $RESULT"
fi

# HASIL AKHIR
echo ""
echo -e "${YELLOW}========================================${NC}"
echo -e "${GREEN} PASS: $PASS${NC}"
echo -e "${RED} FAIL: $FAIL${NC}"
echo -e "${YELLOW}========================================${NC}"

if [ $FAIL -eq 0 ]; then
  echo -e "${GREEN} Semua test berhasil!${NC}"
else
  echo -e "${RED} Ada $FAIL test yang gagal.${NC}"
  exit 1
fi