#!/bin/bash
# =================================================================
# SCRIPT : init-ca-config.sh
# Fungsi : Buat fabric-ca-server-config awal untuk setiap CA
#          WAJIB dijalankan SEBELUM docker compose up CA
#          agar admin CA di-register dengan type=admin (bukan client)
# Usage  : bash scripts/init-ca-config.sh
# =================================================================
set -euo pipefail

export SCRIPT_NAME="init-ca-config"
export PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export DOMAIN="${DOMAIN:-medchain.id}"

# Load env
set -a; source "${PROJECT_ROOT}/.env"; set +a

# Load lib
source "${PROJECT_ROOT}/scripts/lib.sh"
_init_log

# -----------------------------------------------------------------
# Buat config untuk satu CA
# Usage: init_ca_config <org_name> <ca_name> <port>
# -----------------------------------------------------------------
init_ca_config() {
  local org_name="$1"   # orderer / klinik / akademik
  local ca_name="$2"    # ca-orderer / ca-klinik / ca-akademik /ca-dokter
  local port="$3"

  local ca_dir="${PROJECT_ROOT}/organizations/fabric-ca/${org_name}"
  mkdir -p "${ca_dir}"

  # Jika sudah ada dan sudah punya database, skip
  # (tidak mau overwrite CA yang sudah berjalan)
  if [[ -f "${ca_dir}/fabric-ca-server.db" ]]; then
    warn "  CA ${org_name} sudah diinisialisasi, skip."
    return 0
  fi

  log "  Membuat config CA untuk ${org_name}..."

  cat > "${ca_dir}/fabric-ca-server-config.yaml" <<EOF
# =================================================================
# Fabric CA Server Config — ${org_name}
# Auto-generated oleh init-ca-config.sh
# =================================================================

version: "1.5.7"

port: ${port}

tls:
  enabled: true
  certfile:
  keyfile:
  clientauth:
    type: noclientcert
    certfiles:

ca:
  name: ${ca_name}
  keyfile:
  certfile:
  chainfile:

crl:
  expiry: 24h

registry:
  # Jumlah maksimal password attempts sebelum identity dikunci
  maxenrollments: -1

  # Admin CA harus bertipe 'admin' agar bisa register identity
  # dan agar certificate yang di-issue mengandung OU=admin
  identities:
    - name: ${CA_ADMIN_USER}
      pass: ${CA_ADMIN_PASS}
      type: admin
      affiliation: ""
      maxenrollments: -1
      attrs:
        hf.Registrar.Roles: "*"
        hf.Registrar.DelegateRoles: "*"
        hf.Revoker: true
        hf.IntermediateCA: true
        hf.GenCRL: true
        hf.Registrar.Attributes: "*"
        hf.AffiliationMgr: true

db:
  type: sqlite3
  datasource: fabric-ca-server.db
  tls:
    enabled: false

ldap:
  enabled: false

affiliations:
  org1:
    - department1
    - department2
  org2:
    - department1

signing:
  default:
    usage:
      - digital signature
    expiry: 8760h
  profiles:
    ca:
      usage:
        - cert sign
        - crl sign
      expiry: 43800h
      caconstraint:
        isca: true
        maxpathlen: 0
    tls:
      usage:
        - signing
        - key encipherment
        - server auth
        - client auth
        - key agreement
      expiry: 8760h

csr:
  cn: ${ca_name}
  keyrequest:
    algo: ecdsa
    size: 256
  names:
    - C: US
      ST: "North Carolina"
      L:
      O: Hyperledger
      OU: Fabric
  hosts:
    - localhost
    - 127.0.0.1
    - ${ca_name}.${DOMAIN}
  ca:
    expiry: 131400h
    pathlength: 1

idemix:
  rhpoolsize: 1000
  nonceexpiry: 15s
  noncesweepinterval: 15m

bccsp:
  default: SW
  sw:
    hash: SHA2
    security: 256
    filekeystore:
      keystore: msp/keystore

cfg:
  identities:
    passwordattempts: 10

operations:
  listenAddress: 0.0.0.0:$(( port + 10000 ))
  tls:
    enabled: false

metrics:
  provider: prometheus
EOF

  log "  Config CA ${org_name} selesai."
}

# =================================================================
# MAIN
# =================================================================
step "Init CA configs"

init_ca_config "orderer"  "ca-orderer"  7054
init_ca_config "klinik"   "ca-klinik"   8054
init_ca_config "akademik" "ca-akademik" 9054
init_ca_config "dokter"   "ca-dokter"   10054

step_ok
log "Semua CA config siap. Lanjutkan dengan: bash scripts/setup-production.sh"