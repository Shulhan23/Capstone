'use strict';

const { Contract } = require('fabric-contract-api');

class MedicalContract extends Contract {

    constructor() {
        // Namespace contract — pola resmi dari fabric-chaincode-node
        super('MedicalContract');
    }

    // =========================================================
    // InitLedger — inisialisasi ledger saat pertama deploy
    // Dipanggil otomatis saat chaincode di-instantiate
    // =========================================================
    async InitLedger(ctx) {
        console.info('============= MedicalContract: InitLedger ===========');
        // Tidak ada data awal — ledger dimulai kosong
        // Surat sakit dibuat saat dokter menerbitkannya lewat IssueSuratSakit
        console.info('Ledger berhasil diinisialisasi');
    }

    // =========================================================
    // IssueSuratSakit — terbitkan surat sakit baru ke ledger
    //
    // Dipanggil oleh: Backend Klinik (via Fabric Gateway SDK)
    // Args:
    //   id           — ID unik surat sakit (contoh: "SS-001")
    //   hash         — SHA-256 dari konten surat (dibuat di backend)
    //   dokterID     — ID dokter penerbit (referensi ke MySQL)
    //   klinikID     — ID klinik penerbit (referensi ke MySQL)
    //   pasienID     — ID pasien (referensi ke MySQL)
    //   tanggalTerbit — tanggal penerbitan (format: "2026-04-10")
    // =========================================================
    async IssueSuratSakit(ctx, id, hash, dokterID, klinikID, pasienID, tanggalTerbit) {

        // Cek apakah surat dengan ID ini sudah ada
        const exists = await this.SuratSakitExists(ctx, id);
        if (exists) {
            throw new Error(`Surat sakit dengan ID ${id} sudah ada di ledger`);
        }

        // Buat objek surat sakit
        // Pola dari asset-transfer-basic: data disimpan sebagai JSON string
        const suratSakit = {
            id,
            hash,
            dokterID,
            klinikID,
            pasienID,
            tanggalTerbit,
            status: 'ACTIVE',
            revokeReason: '',
            // Timestamp dari blockchain — bukan dari input user
            // Pola resmi: gunakan ctx.stub.getTxTimestamp()
            createdAt: new Date(ctx.stub.getTxTimestamp().seconds.low * 1000).toISOString(),
        };

        // Simpan ke world state (ledger)
        // Pola resmi: PutState(key, Buffer.from(JSON.stringify(data)))
        await ctx.stub.putState(id, Buffer.from(JSON.stringify(suratSakit)));

        // Emit event — pola resmi dari fabric-samples/asset-transfer-events
        ctx.stub.setEvent('IssueSuratSakit', Buffer.from(JSON.stringify({ id, klinikID, status: 'ACTIVE' })));

        console.info(`Surat sakit ${id} berhasil diterbitkan`);
        return JSON.stringify(suratSakit);
    }

    // =========================================================
    // VerifySuratSakit — verifikasi keaslian surat sakit
    //
    // Dipanggil oleh: Backend Akademik atau Klinik
    // Args:
    //   id   — ID surat sakit yang akan diverifikasi
    //   hash — hash yang akan dicocokkan (dari QR code / form)
    // Returns: { valid: boolean, status: string, data: object }
    // =========================================================
    async VerifySuratSakit(ctx, id, hash) {

        const suratSakit = await this.GetSuratSakit(ctx, id);

        // Surat sudah dicabut
        if (suratSakit.status === 'REVOKED') {
            return JSON.stringify({
                valid: false,
                reason: 'REVOKED',
                revokeReason: suratSakit.revokeReason,
                data: suratSakit,
            });
        }

        // Cocokkan hash
        const hashMatch = suratSakit.hash === hash;

        return JSON.stringify({
            valid: hashMatch,
            reason: hashMatch ? 'VALID' : 'HASH_MISMATCH',
            data: suratSakit,
        });
    }

    // =========================================================
    // RevokeSuratSakit — cabut surat sakit yang sudah terbit
    //
    // Dipanggil oleh: Backend Klinik saja
    // Args:
    //   id     — ID surat sakit yang akan dicabut
    //   reason — alasan pencabutan
    // =========================================================
    async RevokeSuratSakit(ctx, id, reason) {

        const suratSakit = await this.GetSuratSakit(ctx, id);

        if (suratSakit.status === 'REVOKED') {
            throw new Error(`Surat sakit ${id} sudah dalam status REVOKED`);
        }

        // Update status
        suratSakit.status = 'REVOKED';
        suratSakit.revokeReason = reason;
        suratSakit.revokedAt = new Date(ctx.stub.getTxTimestamp().seconds.low * 1000).toISOString();

        await ctx.stub.putState(id, Buffer.from(JSON.stringify(suratSakit)));

        // Emit event
        ctx.stub.setEvent('RevokeSuratSakit', Buffer.from(JSON.stringify({ id, reason, status: 'REVOKED' })));

        console.info(`Surat sakit ${id} berhasil dicabut`);
        return JSON.stringify(suratSakit);
    }

    // =========================================================
    // GetSuratSakit — ambil data surat dari ledger
    //
    // Dipanggil oleh: Backend Klinik & Akademik
    // Args:
    //   id — ID surat sakit
    // =========================================================
    async GetSuratSakit(ctx, id) {

        // Pola resmi: GetState(key) mengembalikan Buffer atau null
        const suratJSON = await ctx.stub.getState(id);

        if (!suratJSON || suratJSON.length === 0) {
            throw new Error(`Surat sakit dengan ID ${id} tidak ditemukan di ledger`);
        }

        return JSON.parse(suratJSON.toString());
    }

    // =========================================================
    // GetHistoryById — riwayat perubahan surat di ledger
    //
    // Berguna untuk audit trail — siapa mengubah apa dan kapan
    // Args:
    //   id — ID surat sakit
    // =========================================================
    async GetHistoryById(ctx, id) {

        // Pola resmi: getHistoryForKey dari fabric-samples/asset-transfer-ledger-queries
        const resultsIterator = await ctx.stub.getHistoryForKey(id);
        const results = [];

        let res = await resultsIterator.next();
        while (!res.done) {
            const record = {
                txId: res.value.txId,
                timestamp: new Date(res.value.timestamp.seconds.low * 1000).toISOString(),
                isDelete: res.value.isDelete,
                data: res.value.isDelete ? null : JSON.parse(res.value.value.toString()),
            };
            results.push(record);
            res = await resultsIterator.next();
        }

        await resultsIterator.close();
        return JSON.stringify(results);
    }

    // =========================================================
    // QueryByKlinik — rich query semua surat dari klinik tertentu
    //
    // Membutuhkan CouchDB (sudah dikonfigurasi di docker-compose)
    // Pola dari: fabric-samples/asset-transfer-ledger-queries
    // Args:
    //   klinikID — ID klinik yang ingin di-query
    // =========================================================
    async QueryByKlinik(ctx, klinikID) {

        // Rich query dengan CouchDB selector
        // Pola resmi: getQueryResult dari fabric-samples
        const queryString = JSON.stringify({
            selector: {
                klinikID: klinikID,
            },
            sort: [{ createdAt: 'desc' }],
        });

        return await this._getQueryResultForQueryString(ctx, queryString);
    }

    // =========================================================
    // QueryByDokter — rich query semua surat dari dokter tertentu
    // Args:
    //   dokterID — ID dokter
    // =========================================================
    async QueryByDokter(ctx, dokterID) {

        const queryString = JSON.stringify({
            selector: {
                dokterID: dokterID,
            },
            sort: [{ createdAt: 'desc' }],
        });

        return await this._getQueryResultForQueryString(ctx, queryString);
    }

    // =========================================================
    // SuratSakitExists — cek apakah surat sudah ada di ledger
    // Helper function — tidak bisa dipanggil langsung dari client
    // Diawali underscore = private (konvensi komunitas Fabric)
    // =========================================================
    async SuratSakitExists(ctx, id) {
        const suratJSON = await ctx.stub.getState(id);
        return suratJSON && suratJSON.length > 0;
    }

    // =========================================================
    // _getQueryResultForQueryString — helper untuk rich query
    // Private function (diawali underscore = konvensi komunitas)
    // Pola resmi dari: fabric-samples/asset-transfer-ledger-queries
    // =========================================================
    async _getQueryResultForQueryString(ctx, queryString) {

        const resultsIterator = await ctx.stub.getQueryResult(queryString);
        const results = [];

        let res = await resultsIterator.next();
        while (!res.done) {
            results.push(JSON.parse(res.value.value.toString()));
            res = await resultsIterator.next();
        }

        await resultsIterator.close();
        return JSON.stringify(results);
    }
}

module.exports = MedicalContract;
