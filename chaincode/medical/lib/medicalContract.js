'use strict';

const { Contract } = require('fabric-contract-api');

class MedicalContract extends Contract {

    constructor() {
        super('MedicalContract');
    }

    // ===================== HELPER =====================

    _getTxTimestamp(ctx) {
        const ts = ctx.stub.getTxTimestamp();
        const seconds = ts.seconds?.low || ts.seconds || 0;
        return new Date(seconds * 1000).toISOString();
    }

    async _putState(ctx, key, data) {
        await ctx.stub.putState(key, Buffer.from(JSON.stringify(data)));
    }

    _emit(ctx, eventName, payload) {
        ctx.stub.setEvent(eventName, Buffer.from(JSON.stringify(payload)));
    }

    _validateHash(hash) {
        if (!/^[a-f0-9]{64}$/.test(hash)) {
            throw new Error('Hash tidak valid (harus SHA-256)');
        }
    }

    _requireMSP(ctx, allowedMSP) {
        const msp = ctx.clientIdentity.getMSPID();
        if (!allowedMSP.includes(msp)) {
            throw new Error(`Akses ditolak untuk MSP: ${msp}`);
        }
    }

    _validateRequired(...fields) {
        for (const f of fields) {
            if (!f) throw new Error('Input tidak lengkap');
        }
    }

    // =========================================================
    async InitLedger(ctx) {
        console.info('[InitLedger] Ledger diinisialisasi');
    }

    // =========================================================
    async IssueSuratSakit(ctx, id, hash, dokterID, klinikID, pasienID, tanggalTerbit) {

        this._requireMSP(ctx, ['KlinikMSP']);
        this._validateRequired(id, hash, dokterID, klinikID, pasienID, tanggalTerbit);
        this._validateHash(hash);

        const exists = await this.SuratSakitExists(ctx, id);
        if (exists) {
            throw new Error(`[IssueSuratSakit] ID ${id} sudah ada`);
        }

        const suratSakit = {
            docType: 'surat_sakit',
            id,
            hash,
            dokterID,
            klinikID,
            pasienID,
            tanggalTerbit,
            status: 'ACTIVE',
            revokeReason: '',
            createdAt: this._getTxTimestamp(ctx),
        };

        await this._putState(ctx, id, suratSakit);

        this._emit(ctx, 'IssueSuratSakit', {
            id,
            klinikID,
            status: 'ACTIVE'
        });

        console.info(`[IssueSuratSakit] SUCCESS ID=${id}`);
        return JSON.stringify(suratSakit);
    }

    // =========================================================
    async VerifySuratSakit(ctx, id, hash) {

        this._validateRequired(id, hash);
        this._validateHash(hash);

        const suratSakit = await this.GetSuratSakit(ctx, id);

        if (suratSakit.status === 'REVOKED') {
            return JSON.stringify({
                valid: false,
                reason: 'REVOKED',
                revokeReason: suratSakit.revokeReason,
                data: suratSakit,
            });
        }

        const hashMatch = suratSakit.hash === hash;

        return JSON.stringify({
            valid: hashMatch,
            reason: hashMatch ? 'VALID' : 'HASH_MISMATCH',
            data: suratSakit,
        });
    }

    // =========================================================
    async RevokeSuratSakit(ctx, id, reason) {

        this._requireMSP(ctx, ['KlinikMSP']);
        this._validateRequired(id, reason);

        const suratSakit = await this.GetSuratSakit(ctx, id);

        if (suratSakit.status === 'REVOKED') {
            throw new Error(`[RevokeSuratSakit] ID ${id} sudah REVOKED`);
        }

        suratSakit.status = 'REVOKED';
        suratSakit.revokeReason = reason;
        suratSakit.revokedAt = this._getTxTimestamp(ctx);

        await this._putState(ctx, id, suratSakit);

        this._emit(ctx, 'RevokeSuratSakit', {
            id,
            reason,
            status: 'REVOKED'
        });

        console.info(`[RevokeSuratSakit] SUCCESS ID=${id}`);
        return JSON.stringify(suratSakit);
    }

    // =========================================================
    async GetSuratSakit(ctx, id) {

        this._validateRequired(id);

        const suratJSON = await ctx.stub.getState(id);

        if (!suratJSON || suratJSON.length === 0) {
            throw new Error(`[GetSuratSakit] ID ${id} tidak ditemukan`);
        }

        return JSON.parse(suratJSON.toString());
    }

    // =========================================================
    async GetHistoryById(ctx, id) {

        this._validateRequired(id);

        const iterator = await ctx.stub.getHistoryForKey(id);
        const results = [];

        let res = await iterator.next();
        while (!res.done) {
            const record = {
                txId: res.value.txId,
                timestamp: (() => {
                    try {
                        const ts = res.value.timestamp;
                        if (!ts) return null;
                        const seconds = ts.seconds?.low || ts.seconds || 0;
                        return new Date(seconds * 1000).toISOString();
                    } catch {
                        return null;
                    }
                })(),
                isDelete: res.value.isDelete,
                data: res.value.isDelete
                    ? null
                    : JSON.parse(res.value.value.toString()),
            };

            results.push(record);
            res = await iterator.next();
        }

        await iterator.close();
        return JSON.stringify(results);
    }

    // =========================================================
    async QueryByKlinik(ctx, klinikID) {

        this._validateRequired(klinikID);

        const queryString = JSON.stringify({
            selector: {
                docType: 'surat_sakit',
                klinikID: klinikID,
            }
        });

        return await this._getQueryResultForQueryString(ctx, queryString);
    }

    // =========================================================
    async QueryByDokter(ctx, dokterID) {

        this._validateRequired(dokterID);

        const queryString = JSON.stringify({
            selector: {
                docType: 'surat_sakit',
                dokterID: dokterID,
            }
        });

        return await this._getQueryResultForQueryString(ctx, queryString);
    }

    // =========================================================
    async SuratSakitExists(ctx, id) {
        const suratJSON = await ctx.stub.getState(id);
        return suratJSON && suratJSON.length > 0;
    }

    // =========================================================
    async _getQueryResultForQueryString(ctx, queryString) {

        const iterator = await ctx.stub.getQueryResult(queryString);
        const results = [];

        let res = await iterator.next();
        while (!res.done) {
            results.push(JSON.parse(res.value.value.toString()));
            res = await iterator.next();
        }

        await iterator.close();
        return JSON.stringify(results);
    }
}

module.exports = MedicalContract;