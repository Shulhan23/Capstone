#!/bin/bash
# =================================================================
# SCRIPT : enroll-ca.sh
# Fungsi : Enroll semua identity via Fabric CA
# Fabric : 2.5.x
# Urutan : Jalankan SETELAH CA containers Up
# Usage  : bash scripts/enroll-ca.sh [--verbose]
# =================================================================
set -euo pipefail
IFS=$'\n\t'

export SCRIPT_NAME="enroll-ca"
export PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export DOMAIN="${DOMAIN:-medchain.id}"
export VERBOSE="${VERBOSE:-false}"

# Load env dan lib
set -a; source "${PROJECT_ROOT}/.env"; set +a
source "${PROJECT_ROOT}/scripts/lib.sh"
_init_log

# =================================================================
# HELPER: Enroll node (orderer atau peer) — MSP + TLS
# Usage: enroll_node <org_msp> <node_dir> <url> <caname> <tls_cert> <hosts>
# =================================================================
enroll_node() {
  local org_msp="$1" node_dir="$2" url="$3" caname="$4" tls_cert="$5" hosts="$6"

  mkdir -p "${node_dir}/msp" "${node_dir}/tls"

  # MSP enroll
  ca_enroll "${node_dir}/msp" "${url}" "${caname}" "${tls_cert}" \
    --csr.hosts "${hosts}"

  # TLS enroll
  ca_enroll "${node_dir}/tls" "${url}" "${caname}" "${tls_cert}" \
    --enrollment.profile tls \
    --csr.hosts "${hosts}"

  # Salin TLS artifacts ke lokasi standar
  copy_tls_artifacts "${node_dir}/tls"

  # Salin config.yaml ke node MSP
  cp "${org_msp}/config.yaml" "${node_dir}/msp/config.yaml"

  # Buat tlscacerts di node MSP (dibutuhkan configtxgen & orderer)
  mkdir -p "${node_dir}/msp/tlscacerts"
  cp "${node_dir}/tls/ca.crt" \
     "${node_dir}/msp/tlscacerts/tlsca.${DOMAIN}-cert.pem"
}

# =================================================================
# HELPER: Enroll user/admin (MSP saja, tanpa TLS)
# Usage: enroll_identity <home> <url> <caname> <tls_cert> <ou_config>
# =================================================================
enroll_identity() {
  local home="$1" url="$2" caname="$3" tls_cert="$4" ou_config="$5"
  mkdir -p "${home}"
  ca_enroll "${home}" "${url}" "${caname}" "${tls_cert}"
  cp "${ou_config}" "${home}/config.yaml"
}

# =================================================================
# ORDERER ORGANIZATION
# =================================================================
enroll_orderer_org() {
  step "Enroll Orderer Organization"

  local ORG_DIR="${ORGANIZATIONS}/ordererOrganizations/${DOMAIN}"
  local CA_CERT="${ORGANIZATIONS}/fabric-ca/orderer/tls-cert.pem"
  local CA_URL="https://${CA_ADMIN_USER}:${CA_ADMIN_PASS}@ca.orderer.${DOMAIN}:7054"
  local CA_NAME="ca-orderer"
  local ORG_MSP="${ORG_DIR}/msp"

  mkdir -p "${ORG_DIR}"/{msp,orderers,users}

  # Bootstrap MSP dengan enroll CA admin
  ca_enroll "${ORG_MSP}" "${CA_URL}" "${CA_NAME}" "${CA_CERT}"
  write_ou_config "${ORG_MSP}"
  log "MSP bootstrap selesai."

  # Enroll 3 orderer node
  local i=1
  for name in orderer1 orderer2 orderer3; do
    ca_register "${ORG_MSP}" "${CA_NAME}" "${CA_CERT}" \
      "${name}" "${name}pw" "orderer"

    enroll_node \
      "${ORG_MSP}" \
      "${ORG_DIR}/orderers/${name}.${DOMAIN}" \
      "${CA_URL}" "${CA_NAME}" "${CA_CERT}" \
      "${name}.${DOMAIN},localhost,127.0.0.1"

    log "${name}.${DOMAIN} enrolled. (${i}/3)"
    (( i++ ))
  done

  # Enroll orderer admin
  ca_register "${ORG_MSP}" "${CA_NAME}" "${CA_CERT}" \
    "ordererAdmin" "ordererAdminpw" "admin"

  enroll_identity \
    "${ORG_DIR}/users/Admin@${DOMAIN}/msp" \
    "${CA_URL}" "${CA_NAME}" "${CA_CERT}" \
    "${ORG_MSP}/config.yaml"
  log "Admin@${DOMAIN} enrolled."

  # Verifikasi OU admin
  local admin_ou
  admin_ou="$(openssl x509 -in "${ORG_DIR}/users/Admin@${DOMAIN}/msp/signcerts/cert.pem" \
    -noout -subject 2>/dev/null | grep -oP 'OU = \K\w+')"
  log "Admin OU: ${admin_ou}"
  [[ "${admin_ou}" != "admin" ]] && \
    warn "  Admin OU bukan 'admin' (${admin_ou}). Pastikan CA config sudah benar."

  # Buat admincerts di org MSP
  mkdir -p "${ORG_MSP}/admincerts"
  cp "${ORG_DIR}/users/Admin@${DOMAIN}/msp/signcerts/"*.pem \
     "${ORG_MSP}/admincerts/Admin@${DOMAIN}-cert.pem"

  # Buat tlscacerts di org MSP
  mkdir -p "${ORG_MSP}/tlscacerts"
  cp "${ORG_DIR}/orderers/orderer1.${DOMAIN}/tls/ca.crt" \
     "${ORG_MSP}/tlscacerts/tlsca.${DOMAIN}-cert.pem"

  step_ok
}

# =================================================================
# PEER ORGANIZATION (generik — Klinik & Akademik)
# Usage: enroll_peer_org <org_name> <ca_port>
# =================================================================
enroll_peer_org() {
  local org_name="$1"
  local ca_port="$2"

  step "Enroll ${org_name^} Organization"

  local ORG_FQDN="${org_name}.${DOMAIN}"
  local ORG_DIR="${ORGANIZATIONS}/peerOrganizations/${ORG_FQDN}"
  local CA_CERT="${ORGANIZATIONS}/fabric-ca/${org_name}/tls-cert.pem"
  local CA_URL="https://${CA_ADMIN_USER}:${CA_ADMIN_PASS}@ca.${ORG_FQDN}:${ca_port}"
  local CA_NAME="ca-${org_name}"
  local ORG_MSP="${ORG_DIR}/msp"

  mkdir -p "${ORG_DIR}"/{msp,peers,users}

  # Bootstrap MSP
  ca_enroll "${ORG_MSP}" "${CA_URL}" "${CA_NAME}" "${CA_CERT}"
  write_ou_config "${ORG_MSP}"
  log "MSP bootstrap selesai."

  # ---------------------------------------------------------------
  # Register + enroll peer0
  # ---------------------------------------------------------------
  ca_register "${ORG_MSP}" "${CA_NAME}" "${CA_CERT}" \
    "peer0${org_name}" "peer0${org_name}pw" "peer"

  local PEER0_URL="https://peer0${org_name}:peer0${org_name}pw@ca.${ORG_FQDN}:${ca_port}"

  enroll_node \
    "${ORG_MSP}" \
    "${ORG_DIR}/peers/peer0.${ORG_FQDN}" \
    "${PEER0_URL}" "${CA_NAME}" "${CA_CERT}" \
    "peer0.${ORG_FQDN},localhost,127.0.0.1"
  log "peer0.${ORG_FQDN} enrolled."

  # ---------------------------------------------------------------
  # Register + enroll peer1
  # ---------------------------------------------------------------
  ca_register "${ORG_MSP}" "${CA_NAME}" "${CA_CERT}" \
    "peer1${org_name}" "peer1${org_name}pw" "peer"

  local PEER1_URL="https://peer1${org_name}:peer1${org_name}pw@ca.${ORG_FQDN}:${ca_port}"

  enroll_node \
    "${ORG_MSP}" \
    "${ORG_DIR}/peers/peer1.${ORG_FQDN}" \
    "${PEER1_URL}" "${CA_NAME}" "${CA_CERT}" \
    "peer1.${ORG_FQDN},localhost,127.0.0.1"
  log "peer1.${ORG_FQDN} enrolled."

  # ---------------------------------------------------------------
  # Register + enroll user
  # ---------------------------------------------------------------
  ca_register "${ORG_MSP}" "${CA_NAME}" "${CA_CERT}" \
    "user${org_name^}1" "user${org_name^}1pw" "client"

  local USER1_URL="https://user${org_name^}1:user${org_name^}1pw@ca.${ORG_FQDN}:${ca_port}"

  enroll_identity \
    "${ORG_DIR}/users/User1@${ORG_FQDN}/msp" \
    "${USER1_URL}" "${CA_NAME}" "${CA_CERT}" \
    "${ORG_MSP}/config.yaml"
  log "User1@${ORG_FQDN} enrolled."

  # ---------------------------------------------------------------
  # Register + enroll admin
  # ---------------------------------------------------------------
  ca_register "${ORG_MSP}" "${CA_NAME}" "${CA_CERT}" \
    "admin${org_name^}" "admin${org_name^}pw" "admin"

  local ADMIN_URL="https://admin${org_name^}:admin${org_name^}pw@ca.${ORG_FQDN}:${ca_port}"

  enroll_identity \
    "${ORG_DIR}/users/Admin@${ORG_FQDN}/msp" \
    "${ADMIN_URL}" "${CA_NAME}" "${CA_CERT}" \
    "${ORG_MSP}/config.yaml"
  log "Admin@${ORG_FQDN} enrolled."

  # Verifikasi OU
  local admin_ou
  admin_ou="$(openssl x509 -in "${ORG_DIR}/users/Admin@${ORG_FQDN}/msp/signcerts/cert.pem" \
    -noout -subject 2>/dev/null | grep -oP 'OU = \K\w+')"
  log "Admin OU: ${admin_ou}"

  # admincerts
  mkdir -p "${ORG_MSP}/admincerts"
  cp "${ORG_DIR}/users/Admin@${ORG_FQDN}/msp/signcerts/"*.pem \
     "${ORG_MSP}/admincerts/Admin@${ORG_FQDN}-cert.pem"

  # tlscacerts
  mkdir -p "${ORG_MSP}/tlscacerts"
  cp "${ORG_DIR}/peers/peer0.${ORG_FQDN}/tls/ca.crt" \
     "${ORG_MSP}/tlscacerts/ca.crt"

  step_ok
}

# =================================================================
# MAIN
# =================================================================
log "Memulai enrollment semua organisasi..."
log "Log: ${LOG_FILE}"

enroll_orderer_org
enroll_peer_org "klinik"   8054
enroll_peer_org "akademik" 9054
enroll_peer_org "dokter"   10054

# Untuk menambah org baru: enroll_peer_org "namaorg" <port>

print_summary
log "Semua organisasi berhasil di-enroll."
log "Langkah selanjutnya: bash scripts/setup-channel.sh"
exit 0