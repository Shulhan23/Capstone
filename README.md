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
7. [Troubleshooting](#troubleshooting)

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

Jika `docker compose version` error, install plugin-nya:

```bash
# Tambah repository Docker resmi
sudo apt update
sudo apt install ca-certificates curl gnupg -y
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install
sudo apt update
sudo apt install docker-ce docker-ce-cli containerd.io docker-compose-plugin -y

# Verifikasi
docker compose version    # harus muncul Docker Compose version v2.x.x
```

> **Pengguna WSL2 (Windows):**
> Gunakan Docker Desktop dan aktifkan WSL Integration:
> `Docker Desktop → Settings → Resources → WSL Integration → Enable Ubuntu`

### 2. Node.js

```bash
# Cek versi
node --version    # minimal v18

# Jika belum ada, install via nvm (direkomendasikan):
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
source ~/.bashrc
nvm install 18
nvm use 18
node --version
```

### 3. Hyperledger Fabric Binaries

```bash
# Buat folder khusus untuk tools Fabric — PISAH dari folder proyek
mkdir -p ~/fabric-tools && cd ~/fabric-tools

# Download binary Fabric 2.5
curl -sSL https://bit.ly/2ysbOFE | bash -s -- 2.5.0 1.5.7

# Tambah ke PATH secara permanen
echo 'export PATH=$PATH:$HOME/fabric-tools/fabric-samples/bin' >> ~/.bashrc
source ~/.bashrc

# Verifikasi semua binary tersedia
cryptogen version     # harus muncul versi
configtxgen version   # harus muncul versi
peer version          # harus muncul versi
```

> **Catatan:** Folder `fabric-tools/` sengaja dipisah dari folder proyek `Capstone/`.
> Ini adalah dependency eksternal — seperti `node_modules` untuk Node.js atau
> `.gradle` untuk Java. Tidak perlu di-commit ke Git.

---

## Struktur Folder

```
Capstone/
├── chaincode/                    ← Smart contract Node.js (diisi nanti)
├── channel-artifacts/            ← DIBUAT OTOMATIS oleh setup.sh
│   ├── orderer.genesis.block     ← "Akta pendirian" jaringan
│   ├── medchannel.tx             ← "Akta pendirian" channel
│   ├── KlinikMSPanchors.tx       ← Anchor peer Klinik
│   └── AkademikMSPanchors.tx     ← Anchor peer Akademik
├── crypto-config/                ← DIBUAT OTOMATIS oleh setup.sh
│   ├── ordererOrganizations/     ← Sertifikat orderer
│   └── peerOrganizations/        ← Sertifikat tiap org & peer
├── data/                         ← DIBUAT OTOMATIS, data CouchDB
├── scripts/
│   └── setup.sh                  ← Script otomasi setup jaringan
├── configtx.yaml                 ← Aturan channel & endorsement policy
├── crypto-config.yaml            ← Definisi organisasi & peer
└── docker-compose.yaml           ← Konfigurasi container Docker
```

> **Yang perlu di-commit ke Git:**
> `configtx.yaml`, `crypto-config.yaml`, `docker-compose.yaml`, `scripts/`, `chaincode/`
>
> **Jangan di-commit** (tambahkan ke `.gitignore`):
> `channel-artifacts/`, `crypto-config/`, `data/`

### Isi `.gitignore` yang Disarankan

```gitignore
# Fabric generated — dibuat ulang otomatis oleh setup.sh
channel-artifacts/
crypto-config/
data/

# Package chaincode
chaincode/**/*.tar.gz
chaincode/**/node_modules/

# Environment variables
.env
```

---

## Langkah Instalasi

### Step 1 — Clone Repository

```bash
git clone <URL_REPOSITORY> ~/Capstone
cd ~/Capstone
```

### Step 2 — Verifikasi Fabric Binaries

```bash
# Pastikan binary bisa diakses
which cryptogen    # harus tampil path
which configtxgen  # harus tampil path
which peer         # harus tampil path

# Jika tidak ada, ikuti bagian Prasyarat → Hyperledger Fabric Binaries di atas
```

### Step 3 — Beri Izin Eksekusi pada Script

```bash
chmod +x scripts/setup.sh
```

---

## Menjalankan Jaringan

### Jalankan Setup Otomatis

```bash
cd ~/Capstone
scripts/./setup.sh
```

Script ini akan otomatis melakukan semua langkah berikut:

```
Langkah yang dijalankan setup.sh:

  [1]  Periksa binary           → pastikan cryptogen, configtxgen, peer tersedia
  [2]  Bersihkan artefak lama   → hapus crypto-config/, channel-artifacts/, data/
  [3]  Generate crypto          → buat sertifikat TLS & identitas semua org
  [4]  Generate genesis block   → buat "akta pendirian" jaringan
  [5]  Generate channel tx      → buat "akta pendirian" channel medchannel
  [6]  Generate anchor peers    → buat wakil komunikasi tiap org
  [7]  Docker compose up        → start semua container
  [8]  Tunggu container sehat   → pastikan semua container healthy
  [9]  Buat channel             → buat channel medchannel via CLI container
  [10] Join peer Klinik         → peer klinik masuk channel
  [11] Join peer Akademik       → peer akademik masuk channel
  [12] Update anchor Klinik     → set anchor peer klinik
  [13] Update anchor Akademik   → set anchor peer akademik
  [14] Verifikasi               → tampilkan daftar channel yang aktif
```

Output akhir jika **berhasil:**

```
[INFO] Verifikasi channel...
Channels peers has joined:
medchannel

============================================
 Setup selesai! Jaringan siap digunakan.
 Channel: medchannel
 Langkah selanjutnya: deploy chaincode
============================================
```

### Reset dan Jalankan Ulang dari Awal

Gunakan ini jika ada error atau ingin mulai bersih:

```bash
# 1. Hentikan dan hapus semua container + volume Docker
docker compose down -v

# 2. Hapus data CouchDB (perlu sudo karena dibuat oleh container)
sudo rm -rf data/

# 3. Jalankan ulang
scripts/./setup.sh
```

---

## Verifikasi Jaringan

Setelah setup selesai, gunakan perintah berikut untuk memastikan semua berjalan normal.

### Cek Status Container

```bash
docker ps
```

Output yang diharapkan — semua container harus `Up`:

```
NAMES                           STATUS
orderer.example.com             Up X minutes (healthy)
peer0.klinik.example.com        Up X minutes (healthy)
peer0.akademik.example.com      Up X minutes (healthy)
couchdb.klinik                  Up X minutes (healthy)
couchdb.akademik                Up X minutes (healthy)
cli                             Up X minutes
```

### Cek Channel Aktif

```bash
docker exec cli peer channel list
```

Output yang diharapkan:

```
Channels peers has joined:
medchannel
```

### Cek Info Detail Channel

```bash
docker exec cli peer channel getinfo -c medchannel
```

### Akses CouchDB via Browser (opsional)

```
Klinik   → http://localhost:5984/_utils  (user: admin | pass: adminpw)
Akademik → http://localhost:6984/_utils  (user: admin | pass: adminpw)
```

---

## Troubleshooting

### Container unhealthy / tidak mau start

```bash
# Lihat log container yang bermasalah
docker logs orderer.example.com 2>&1 | tail -30
docker logs peer0.klinik.example.com 2>&1 | tail -30
docker logs peer0.akademik.example.com 2>&1 | tail -30

# Solusi: reset total
docker compose down -v
sudo rm -rf data/
scripts/./setup.sh
```

### Permission denied saat hapus folder data/

```bash
# File CouchDB dibuat oleh container sebagai root
# Gunakan sudo untuk menghapusnya
sudo rm -rf data/
```

### Error: Config File "core" Not Found

Terjadi jika `FABRIC_CFG_PATH` salah atau binary belum di-install.

```bash
# Verifikasi file core.yaml ada di sini
ls ~/fabric-tools/fabric-samples/config/core.yaml

# Jika tidak ada, download ulang fabric binaries
cd ~/fabric-tools
curl -sSL https://bit.ly/2ysbOFE | bash -s -- 2.5.0 1.5.7
```

### Error: no such host

Terjadi jika perintah `peer` dijalankan langsung dari terminal, bukan dari dalam container.

```bash
# SALAH — dijalankan dari terminal host
peer channel list

# BENAR — dijalankan dari dalam container CLI
docker exec cli peer channel list
```

Nama seperti `orderer.example.com` hanya dikenal di dalam Docker network `fabric_network`.
Container CLI sudah berada di dalam network tersebut sehingga bisa resolve nama tersebut.

### Error: docker compose not found

```bash
# Cek versi yang tersedia
docker-compose version    # v1, sudah deprecated
docker compose version    # v2, yang dipakai script ini

# Jika hanya v1 yang ada, install v2 (lihat bagian Prasyarat)
```

---

## Referensi Port

| Container | Port | Fungsi |
|---|---|---|
| orderer.example.com | 7050 | gRPC komunikasi peer |
| orderer.example.com | 7053 | Admin channel management |
| orderer.example.com | 8443 | Health check & metrics |
| peer0.klinik | 7051 | gRPC peer |
| peer0.klinik | 7052 | Chaincode |
| peer0.klinik | 9443 | Operations |
| peer0.akademik | 9051 | gRPC peer |
| peer0.akademik | 9052 | Chaincode |
| peer0.akademik | 10443 | Operations |
| couchdb.klinik | 5984 | CouchDB UI & API |
| couchdb.akademik | 6984 | CouchDB UI & API |

---

## Informasi Tim

| Peran | Tanggung Jawab |
|---|---|
| Blockchain Engineer | Setup jaringan, konfigurasi, deployment infrastruktur |
| Blockchain Developer | Chaincode Node.js, REST API, integrasi Fabric Gateway SDK |
| Web Developer | Dashboard klinik, form rekam medis, halaman verifikasi |
| Mobile Developer | Aplikasi dokter/pasien, fitur scan QR code |
