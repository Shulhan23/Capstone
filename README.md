# Sistem Verifikasi Surat Sakit Berbasis Blockchain
### Capstone Project — Hyperledger Fabric 2.5 + Node.js Chaincode

Sistem ini menggunakan blockchain untuk memverifikasi keaslian surat sakit yang diterbitkan oleh klinik. Data pasien dan rekam medis disimpan di database MySQL (offchain), sedangkan hash surat sakit disimpan di blockchain (onchain) sebagai bukti keaslian yang tidak bisa dimanipulasi.

---

## Daftar Isi

1. [Arsitektur Sistem](#arsitektur-sistem)
2. [Prasyarat](#prasyarat)
3. [Struktur Folder](#struktur-folder)
4. [Langkah Instalasi](#langkah-instalasi)
5. [Menjalankan Jaringan](#menjalankan-jaringan)
6. [Verifikasi Jaringan](#verifikasi-jaringan)
7. [Deploy Chaincode](#deploy-chaincode)
8. [Upgrade Chaincode](#upgrade-chaincode)
9. [Perintah Berguna](#perintah-berguna)
10. [Troubleshooting](#troubleshooting)

---

## Arsitektur Sistem

```
Aktor & Peran di Blockchain:

  Mahasiswa / Pasien  →  User biasa, tidak punya peer
                          Berinteraksi lewat aplikasi web / mobile

  Klinik              →  peer0.klinik.example.com  (READ + WRITE)
                          Menerbitkan & mencabut surat sakit
                          Port: 7051

  Akademik            →  peer0.akademik.example.com  (READ ONLY)
                          Verifikasi keaslian surat sakit
                          Port: 9051

  Orderer             →  orderer.example.com
                          Memvalidasi & mengurutkan transaksi
                          Port: 7050

Alur Data:
  Dokter input data
    → Backend simpan ke MySQL           (offchain)
    → Backend generate hash SHA-256
    → Hash disimpan ke blockchain       (onchain)
    → Surat diterbitkan dengan QR code

  Verifikasi:
    Scan QR → Backend query blockchain → Cocokkan hash → Valid / Invalid
```

---

## Prasyarat

Pastikan semua software berikut sudah terinstall sebelum memulai.

### 1. Docker & Docker Compose v2

```bash
# Cek versi
docker --version          # minimal 20.10
docker compose version    # minimal v2.0
```

Jika Docker Compose v2 belum ada:

```bash
sudo apt update
sudo apt install ca-certificates curl gnupg -y
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update
sudo apt install docker-ce docker-ce-cli containerd.io docker-compose-plugin -y
docker compose version
```

> **Pengguna WSL2 (Windows):**
> Gunakan Docker Desktop dan aktifkan WSL Integration:
> `Docker Desktop → Settings → Resources → WSL Integration → Enable Ubuntu`

### 2. Node.js

```bash
# Cek versi
node --version    # minimal v18

# Install via nvm (direkomendasikan)
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
source ~/.bashrc
nvm install 18
nvm use 18
```

### 3. Hyperledger Fabric Binaries

```bash
# Buat folder khusus — PISAH dari folder proyek
mkdir -p ~/fabric-tools && cd ~/fabric-tools

# Download binary Fabric 2.5
curl -sSL https://bit.ly/2ysbOFE | bash -s -- 2.5.0 1.5.7

# Tambah ke PATH secara permanen
echo 'export PATH=$PATH:$HOME/fabric-tools/fabric-samples/bin' >> ~/.bashrc
source ~/.bashrc

# Verifikasi
cryptogen version
configtxgen version
peer version
```

> **Mengapa dipisah dari folder proyek?**
> `fabric-tools/` adalah dependency eksternal seperti `node_modules`.
> Tidak perlu di-commit ke Git.

### 4. Pull Docker Image Fabric

```bash
# Image ini dibutuhkan untuk build chaincode Node.js
docker pull hyperledger/fabric-nodeenv:2.5

# Verifikasi
docker images | grep nodeenv
```

---

## Struktur Folder

```
Capstone/
├── chaincode/                    ← Smart contract Node.js
│   └── medical/
│       ├── index.js              ← Entry point chaincode
│       ├── package.json          ← Dependencies chaincode
│       └── lib/
│           └── medicalContract.js ← Logika smart contract
├── channel-artifacts/            ← DIBUAT OTOMATIS oleh setup.sh
│   ├── orderer.genesis.block
│   ├── medchannel.tx
│   ├── KlinikMSPanchors.tx
│   └── AkademikMSPanchors.tx
├── crypto-config/                ← DIBUAT OTOMATIS oleh setup.sh
│   ├── ordererOrganizations/
│   └── peerOrganizations/
├── data/                         ← DIBUAT OTOMATIS, data CouchDB
├── scripts/
│   ├── setup.sh                  ← Setup jaringan + channel
│   ├── deploy-chaincode.sh       ← Deploy chaincode pertama kali
│   ├── approve-commit.sh         ← Lanjut dari step approve
│   └── upgrade-chaincode.sh      ← Upgrade chaincode versi baru
├── configtx.yaml                 ← Aturan channel & endorsement policy
├── crypto-config.yaml            ← Definisi organisasi & peer
└── docker-compose.yaml           ← Konfigurasi container Docker
```

> **Yang di-commit ke Git:**
> `chaincode/`, `scripts/`, `configtx.yaml`, `crypto-config.yaml`, `docker-compose.yaml`, `README.md`
>
> **Yang TIDAK di-commit** (ada di `.gitignore`):
> `channel-artifacts/`, `crypto-config/`, `data/`, `node_modules/`

---

## Langkah Instalasi

### Step 1 — Clone Repository

```bash
git clone <URL_REPOSITORY> ~/Capstone
cd ~/Capstone
```

### Step 2 — Install Chaincode Dependencies

```bash
cd ~/Capstone/chaincode/medical
npm install
cd ~/Capstone
```

### Step 3 — Beri Izin Eksekusi Script

```bash
chmod +x scripts/setup.sh
chmod +x scripts/deploy-chaincode.sh
chmod +x scripts/approve-commit.sh
chmod +x scripts/upgrade-chaincode.sh
```

---

## Menjalankan Jaringan

### Setup Otomatis (Jaringan + Channel)

```bash
cd ~/Capstone
scripts/./setup.sh
```

Script ini melakukan semua langkah berikut secara otomatis:

```
[1]  Periksa binary Fabric tersedia
[2]  Bersihkan artefak lama
[3]  Generate crypto material    → sertifikat TLS semua org
[4]  Generate genesis block      → akta pendirian jaringan
[5]  Generate channel tx         → akta pendirian channel medchannel
[6]  Generate anchor peer tx     → wakil komunikasi tiap org
[7]  Docker compose up           → start semua container
[8]  Tunggu container healthy
[9]  Buat channel medchannel     → via CLI container
[10] Join peer Klinik            → masuk channel
[11] Join peer Akademik          → masuk channel
[12] Update anchor peer Klinik
[13] Update anchor peer Akademik
[14] Verifikasi channel aktif
```

Output akhir jika berhasil:

```
============================================
 Setup selesai! Jaringan siap digunakan.
 Channel: medchannel
 Langkah selanjutnya: deploy chaincode
============================================
```

### Reset Jaringan dari Awal

```bash
docker compose down -v
sudo rm -rf data/
scripts/./setup.sh
```

---

## Verifikasi Jaringan

```bash
# Cek semua container berjalan
docker ps --format "table {{.Names}}\t{{.Status}}"

# Output yang diharapkan:
# orderer.example.com             Up X minutes (healthy)
# peer0.klinik.example.com        Up X minutes (healthy)
# peer0.akademik.example.com      Up X minutes (healthy)
# couchdb.klinik                  Up X minutes (healthy)
# couchdb.akademik                Up X minutes (healthy)
# cli                             Up X minutes

# Cek channel aktif
docker exec cli peer channel list
# Output: medchannel
```

---

## Deploy Chaincode

### Deploy Pertama Kali

```bash
scripts/./deploy-chaincode.sh
```

Script ini menjalankan lifecycle chaincode Fabric 2.x:

```
[1/6] Package    → bungkus chaincode jadi .tar.gz
[2/6] Install    → install ke peer Klinik & Akademik
[3/6] Package ID → ambil ID dari chaincode yang ter-install
[4/6] Approve    → kedua org setujui definisi chaincode
[5/6] Readiness  → cek semua org sudah approve (harus semua true)
[6/6] Commit     → daftarkan chaincode ke channel, siap dipakai
```

Output akhir jika berhasil:

```
============================================
 Chaincode berhasil di-deploy!
 Nama    : medical
 Versi   : 1.0
 Channel : medchannel
============================================
```

### Jika Gagal di Tengah Proses

Jika chaincode sudah ter-install tapi gagal saat approve:

```bash
# Cek dan fix permission CouchDB dulu
sudo chown -R 5984:5984 data/couchdb/klinik/
sudo chown -R 5984:5984 data/couchdb/akademik/
docker restart couchdb.klinik couchdb.akademik
sleep 15

# Lanjut dari step approve (tanpa install ulang)
scripts/./approve-commit.sh
```

### Verifikasi Chaincode Aktif

```bash
# Cek chaincode sudah committed
docker exec cli peer lifecycle chaincode querycommitted \
  --channelID medchannel --name medical

# Test invoke — terbitkan surat pertama
docker exec cli peer chaincode invoke \
  -o orderer.example.com:7050 \
  --ordererTLSHostnameOverride orderer.example.com \
  --tls --cafile /etc/hyperledger/fabric/crypto/ordererOrganizations/example.com/orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem \
  -C medchannel -n medical \
  --peerAddresses peer0.klinik.example.com:7051 \
  --tlsRootCertFiles /etc/hyperledger/fabric/crypto/peerOrganizations/klinik.example.com/peers/peer0.klinik.example.com/tls/ca.crt \
  -c '{"function":"IssueSuratSakit","Args":["SS-001","abc123hash","D-001","K-001","P-001","2026-04-10"]}'

# Test query — verifikasi surat
docker exec cli peer chaincode query \
  -C medchannel -n medical \
  -c '{"function":"VerifySuratSakit","Args":["SS-001","abc123hash"]}'

# Output yang diharapkan: {"valid":true,"reason":"VALID",...}
```

---

## Upgrade Chaincode

Jika ada perubahan pada kode chaincode, jalankan upgrade:

```bash
# WAJIB: edit dua angka ini di scripts/upgrade-chaincode.sh
# sebelum menjalankan
#   CHAINCODE_VERSION="2.0"   ← naik dari 1.0
#   CHAINCODE_SEQUENCE="2"    ← naik dari 1

scripts/./upgrade-chaincode.sh
```

> **Aturan upgrade:**
> Setiap perubahan kode chaincode — sekecil apapun —
> wajib menaikkan `CHAINCODE_VERSION` dan `CHAINCODE_SEQUENCE`.
> Data di ledger tidak hilang saat upgrade.

---

## Perintah Berguna

```bash
# Masuk ke CLI container
docker exec -it cli bash

# Lihat log container
docker logs orderer.example.com -f
docker logs peer0.klinik.example.com -f
docker logs peer0.akademik.example.com -f
docker logs couchdb.klinik -f

# Stop jaringan (data tetap tersimpan)
docker compose stop

# Start kembali setelah stop
docker compose start

# Reset total — hapus semua data
docker compose down -v
sudo rm -rf data/

# Cek chaincode yang ter-install di peer
docker exec cli peer lifecycle chaincode queryinstalled

# Cek chaincode yang sudah committed di channel
docker exec cli peer lifecycle chaincode querycommitted \
  --channelID medchannel
```

---

## Fungsi Chaincode

Smart contract `medical` menyimpan data berikut di blockchain:

| Field | Keterangan |
|---|---|
| `id` | Nomor unik surat sakit |
| `hash` | SHA-256 dari konten surat (dibuat di backend) |
| `dokterID` | ID dokter penerbit (referensi ke MySQL) |
| `klinikID` | ID klinik penerbit (referensi ke MySQL) |
| `pasienID` | ID pasien (referensi ke MySQL) |
| `tanggalTerbit` | Tanggal penerbitan surat |
| `status` | `ACTIVE` atau `REVOKED` |
| `revokeReason` | Alasan pencabutan (kosong jika aktif) |

Fungsi yang tersedia:

| Fungsi | Akses | Keterangan |
|---|---|---|
| `IssueSuratSakit` | Klinik | Terbitkan surat baru ke ledger |
| `VerifySuratSakit` | Semua org | Verifikasi hash + status surat |
| `RevokeSuratSakit` | Klinik | Cabut surat yang sudah terbit |
| `GetSuratSakit` | Semua org | Ambil data surat berdasarkan ID |
| `GetHistoryById` | Semua org | Riwayat perubahan surat (audit trail) |
| `QueryByKlinik` | Semua org | Semua surat dari klinik tertentu |
| `QueryByDokter` | Semua org | Semua surat dari dokter tertentu |

---

## Troubleshooting

### Container unhealthy / tidak mau start

```bash
docker logs <nama_container> 2>&1 | tail -30
docker compose down -v
sudo rm -rf data/
scripts/./setup.sh
```

### Permission denied saat hapus data/

```bash
sudo rm -rf data/
```

### CouchDB error: permission denied pada shards

```bash
sudo chown -R 5984:5984 data/couchdb/klinik/
sudo chown -R 5984:5984 data/couchdb/akademik/
docker restart couchdb.klinik couchdb.akademik
sleep 15
```

### Error: no such host

Pastikan semua perintah `peer` dijalankan via `docker exec cli`, bukan langsung dari terminal:

```bash
# SALAH
peer channel list

# BENAR
docker exec cli peer channel list
```

### Error: fabric-nodeenv image not found

```bash
docker pull hyperledger/fabric-nodeenv:2.5
```

### Chaincode gagal di approve — CouchDB internal server error

```bash
sudo chown -R 5984:5984 data/couchdb/
docker restart couchdb.klinik couchdb.akademik
sleep 15
scripts/./approve-commit.sh
```

### Upgrade chaincode gagal — sequence error

Pastikan `CHAINCODE_SEQUENCE` di `upgrade-chaincode.sh` selalu lebih besar dari sequence sebelumnya. Cek sequence saat ini:

```bash
docker exec cli peer lifecycle chaincode querycommitted \
  --channelID medchannel --name medical
```

---

## Referensi Port

| Container | Port | Fungsi |
|---|---|---|
| orderer.example.com | 7050 | gRPC komunikasi peer |
| orderer.example.com | 7053 | Admin channel management |
| orderer.example.com | 8443 | Health check |
| peer0.klinik | 7051 | gRPC peer |
| peer0.klinik | 7052 | Chaincode |
| peer0.klinik | 9443 | Operations |
| peer0.akademik | 9051 | gRPC peer |
| peer0.akademik | 9052 | Chaincode |
| peer0.akademik | 10443 | Operations |
| couchdb.klinik | 5984 | CouchDB UI → http://localhost:5984/_utils |
| couchdb.akademik | 6984 | CouchDB UI → http://localhost:6984/_utils |
