(function () {
    'use strict';

    try {
    if (window.__max2iMessageInstalled) return;
    window.__max2iMessageInstallError = null;

    const OPCODE_NOTIF_MESSAGE = 128;
    const OPCODE_NOTIF_CHAT = 135;
    const OPCODE_NOTIF_CONTACT = 131;
    const OPCODE_AUTH_SNAPSHOT = 19;
    const OPCODE_CONFIG = 22;
    const OPCODE_NOTIF_CONFIG = 134;

    const chatTypes = {};
    const chatTitles = {};
    const chatMuteUntil = {};
    let sessionReady = false;
    let everSynced = false;
    let myUserId = null;
    let lastIndexedDbScanAt = 0;
    const userNames = {};

    function touchPacket() {
        window.__max2iMessageLastPacketAt = Date.now();
        window.__max2iMessagePacketCount = (window.__max2iMessagePacketCount || 0) + 1;
    }

    function touchMessage() {
        window.__max2iMessageLastMessageAt = Date.now();
        window.__max2iMessageMessageCount = (window.__max2iMessageMessageCount || 0) + 1;
    }

    function publishState() {
        window.__max2iMessageSessionReady = sessionReady;
        window.__max2iMessageEverSynced = everSynced;
    }

    function keepPageAwake() {
        try {
            Object.defineProperty(document, 'visibilityState', {
                get: function () { return 'visible'; },
                configurable: true
            });
            Object.defineProperty(document, 'hidden', {
                get: function () { return false; },
                configurable: true
            });
        } catch (_) {}
    }

    function post(type, payload) {
        try {
            window.webkit.messageHandlers.maxBridge.postMessage({ type: type, payload: payload });
        } catch (e) {
            console.warn('[Max2iMessage] bridge error', e);
        }
    }

    function isVerboseLogging() {
        return window.__max2iMessageVerboseLogging === true;
    }

    function isMuteProbeLogging() {
        return window.__max2iMessageMuteProbeLogging === true;
    }

    const MUTE_PROBE_KEY_RE = /dontdisturb|mute|dnd|notif|disturb|sound|push|silent|suppress|notify/i;

    function postMuteProbe(entry) {
        if (!isMuteProbeLogging()) return;
        post('mute_probe', entry);
    }

    function findNotificationHints(obj, path, depth, out) {
        path = path || '';
        depth = depth || 0;
        out = out || [];
        if (!obj || typeof obj !== 'object' || depth > 12 || out.length > 60) return out;

        if (Array.isArray(obj)) {
            obj.forEach(function (item, index) {
                findNotificationHints(item, path + '[' + index + ']', depth + 1, out);
            });
            return out;
        }

        Object.keys(obj).forEach(function (key) {
            const fullPath = path ? path + '.' + key : key;
            const val = obj[key];
            if (MUTE_PROBE_KEY_RE.test(key) && val !== undefined && val !== null && typeof val !== 'object') {
                out.push({ path: fullPath, key: key, value: val });
            }
            if (val && typeof val === 'object') {
                findNotificationHints(val, fullPath, depth + 1, out);
            }
        });
        return out;
    }

    function summarizeSettingsChats(settings) {
        if (!settings || !settings.chats || typeof settings.chats !== 'object' || Array.isArray(settings.chats)) {
            return null;
        }
        const muted = {};
        const sample = {};
        Object.keys(settings.chats).forEach(function (chatId) {
            const entry = settings.chats[chatId];
            if (!entry) return;
            const dnd = entry.dontDisturbUntil;
            if (dnd !== undefined && dnd !== null && Number(dnd) !== 0) {
                muted[chatId] = dnd;
            }
            if (Object.keys(sample).length < 5) {
                sample[chatId] = collectMuteFields(entry) || { dontDisturbUntil: dnd };
            }
        });
        return {
            total: Object.keys(settings.chats).length,
            mutedCount: Object.keys(muted).length,
            muted: muted,
            sample: sample
        };
    }

    function summarizeMutedCache() {
        const out = {};
        Object.keys(chatMuteUntil).forEach(function (chatId) {
            const value = chatMuteUntil[chatId];
            if (value !== 0 && value !== null && value !== undefined) {
                out[chatId] = value;
            }
        });
        return out;
    }

    function probePacket(packet, source) {
        if (!isMuteProbeLogging() || !packet) return;
        const payload = packet.payload || {};
        const hints = findNotificationHints(packet);
        const settingsSummary = summarizeSettingsChats(payload.settings) || summarizeSettingsChats(payload.config);
        const chatId = safeString(
            (payload.chat && payload.chat.id) ||
            payload.chatId ||
            (payload.message && payload.message.chatId)
        );
        const entry = {
            source: source || 'ws_in',
            opcode: packet.opcode,
            cmd: packet.cmd,
            chatId: chatId,
            hints: hints.slice(0, 40),
            hintCount: hints.length,
            muteFields: collectMuteFields(payload) || (payload.chat ? collectMuteFields(payload.chat) : null),
            settingsChats: settingsSummary,
            mutedInCache: summarizeMutedCache()
        };
        if (hints.length || settingsSummary || entry.muteFields || packet.opcode === 22 || packet.opcode === 61 || packet.opcode === 134) {
            postMuteProbe(entry);
        }
    }

    function probeOutgoingPacket(packet) {
        if (!isMuteProbeLogging() || !packet) return;
        const payload = packet.payload || {};
        const settingsSummary = summarizeSettingsChats(payload.settings) || summarizeSettingsChats(payload.config);
        const hints = findNotificationHints(packet);
        postMuteProbe({
            source: 'ws_out',
            opcode: packet.opcode,
            cmd: packet.cmd,
            hints: hints.slice(0, 40),
            hintCount: hints.length,
            muteFields: collectMuteFields(payload),
            settingsChats: settingsSummary
        });
    }

    function probeOutgoingWS(data) {
        if (data instanceof Blob) {
            data.text().then(function (text) {
                const packet = parsePacket(text);
                if (packet) probeOutgoingPacket(packet);
            }).catch(function () {});
            return;
        }
        const packet = parsePacket(data);
        if (packet) probeOutgoingPacket(packet);
    }

    function scanStorageArea(storage, areaName, source) {
        const matches = [];
        try {
            for (let i = 0; i < storage.length; i++) {
                const key = storage.key(i);
                if (!key) continue;
                try {
                    const raw = storage.getItem(key);
                    if (!raw) continue;
                    const parsed = JSON.parse(raw);
                    const hints = findNotificationHints(parsed);
                    const settingsSummary = summarizeSettingsChats(parsed.settings || parsed);
                    if (hints.length || settingsSummary) {
                        matches.push({
                            key: key,
                            hints: hints.slice(0, 20),
                            settingsChats: settingsSummary
                        });
                    }
                    ingestMuteFromUnknownStructure(parsed, source + ':' + areaName + ':' + key);
                } catch (_) {}
            }
        } catch (_) {}
        if (matches.length) {
            postMuteProbe({
                source: source + '_' + areaName,
                matchCount: matches.length,
                matches: matches.slice(0, 15)
            });
        }
        return matches.length;
    }

    function runMuteProbeScan(source) {
        if (!isMuteProbeLogging()) return;
        const src = source || 'manual';
        scanStorageArea(localStorage, 'localStorage', src);
        scanStorageArea(sessionStorage, 'sessionStorage', src);
        ingestSettingsFromIndexedDB('mute_probe_' + src);
        postMuteProbe({
            source: src + '_cache_snapshot',
            mutedInCache: summarizeMutedCache(),
            muteCacheSize: Object.keys(chatMuteUntil).length
        });
    }

    window.__max2iMessageRunMuteProbeScan = runMuteProbeScan;

    function hookNetworkForMuteProbe() {
        if (window.__max2iMessageNetworkHooked || !isMuteProbeLogging()) return;
        window.__max2iMessageNetworkHooked = true;

        const inspectResponse = function (url, bodyText) {
            if (!bodyText || bodyText.length > 500000) return;
            try {
                const parsed = JSON.parse(bodyText);
                const hints = findNotificationHints(parsed);
                const settingsSummary = summarizeSettingsChats(parsed.settings || parsed);
                if (hints.length || settingsSummary) {
                    postMuteProbe({
                        source: 'http_response',
                        url: String(url || '').slice(0, 200),
                        hints: hints.slice(0, 30),
                        settingsChats: settingsSummary
                    });
                    ingestMuteFromUnknownStructure(parsed, 'http:' + String(url || '').slice(0, 80));
                }
            } catch (_) {}
        };

        if (window.fetch) {
            const nativeFetch = window.fetch.bind(window);
            window.fetch = function () {
                const args = arguments;
                const url = args[0];
                return nativeFetch.apply(window, args).then(function (response) {
                    try {
                        const clone = response.clone();
                        clone.text().then(function (text) {
                            inspectResponse(url, text);
                        }).catch(function () {});
                    } catch (_) {}
                    return response;
                });
            };
        }

        if (window.XMLHttpRequest) {
            const NativeXHR = window.XMLHttpRequest;
            function WrappedXHR() {
                const xhr = new NativeXHR();
                xhr.addEventListener('load', function () {
                    try {
                        inspectResponse(xhr.responseURL, xhr.responseText);
                    } catch (_) {}
                });
                return xhr;
            }
            WrappedXHR.prototype = NativeXHR.prototype;
            window.XMLHttpRequest = WrappedXHR;
        }
    }

    const CHAT_RAW_MUTE_KEYS = [
        'dontDisturbUntil', 'muteUntil', 'mutedUntil', 'muted', 'isMuted',
        'notificationsDisabled', 'notify', 'soundEnabled', 'pushEnabled', 'dnd'
    ];

    function sanitizeForLog(value, depth) {
        depth = depth || 0;
        if (depth > 8) return '[max_depth]';
        if (value === null || value === undefined) return value;
        if (typeof value === 'bigint') return value.toString();
        if (typeof value !== 'object') return value;
        if (Array.isArray(value)) {
            return value.map(function (item) { return sanitizeForLog(item, depth + 1); });
        }
        const out = {};
        Object.keys(value).forEach(function (key) {
            const nested = value[key];
            if (key === 'participants' && nested && typeof nested === 'object' && !Array.isArray(nested)) {
                out[key] = { _count: Object.keys(nested).length };
                return;
            }
            out[key] = sanitizeForLog(nested, depth + 1);
        });
        return out;
    }

    function collectMuteFields(obj, depth) {
        depth = depth || 0;
        if (!obj || typeof obj !== 'object' || depth > 5) return null;
        const out = {};
        Object.keys(obj).forEach(function (key) {
            const val = obj[key];
            if (CHAT_RAW_MUTE_KEYS.indexOf(key) >= 0 && val !== undefined && val !== null) {
                out[key] = val;
            }
        });
        if (obj.settings && typeof obj.settings === 'object') {
            const nested = collectMuteFields(obj.settings, depth + 1);
            if (nested && Object.keys(nested).length) out.settings = nested;
        }
        if (obj.chats && typeof obj.chats === 'object' && !Array.isArray(obj.chats)) {
            const mutedEntries = {};
            Object.keys(obj.chats).forEach(function (chatId) {
                const cs = obj.chats[chatId];
                if (cs && cs.dontDisturbUntil !== undefined && cs.dontDisturbUntil !== null) {
                    mutedEntries[chatId] = { dontDisturbUntil: cs.dontDisturbUntil };
                }
            });
            if (Object.keys(mutedEntries).length) out.settingsChats = mutedEntries;
        }
        if (obj.config && obj.config.chats && typeof obj.config.chats === 'object') {
            const configEntries = {};
            Object.keys(obj.config.chats).forEach(function (chatId) {
                const cs = obj.config.chats[chatId];
                if (cs && cs.dontDisturbUntil !== undefined && cs.dontDisturbUntil !== null) {
                    configEntries[chatId] = { dontDisturbUntil: cs.dontDisturbUntil, sound: cs.sound };
                }
            });
            if (Object.keys(configEntries).length) out.configChats = configEntries;
        }
        return Object.keys(out).length ? out : null;
    }

    function postChatRaw(entry) {
        if (!isVerboseLogging()) return;
        post('chat_raw', entry);
    }

    function logChatPacket(source, packet, extra) {
        const payload = packet.payload || {};
        const chat = payload.chat || null;
        const chatId = safeString(
            (extra && extra.chatId) ||
            (chat && chat.id) ||
            payload.chatId ||
            (payload.message && payload.message.chatId)
        );
        postChatRaw({
            source: source,
            opcode: packet.opcode,
            cmd: packet.cmd,
            chatId: chatId,
            chatTitle: chat ? (extractContactName(chat) || (chat.title ? String(chat.title).trim() : '')) : '',
            chatType: chat && chat.type ? String(chat.type) : '',
            muteFields: collectMuteFields(payload) || (chat ? collectMuteFields(chat) : null),
            cache: {
                chatMuteUntil: chatId ? chatMuteUntil[chatId] : undefined,
                chatType: chatId ? chatTypes[chatId] : undefined,
                isMuted: chatId ? isChatIdMuted(chatId) : undefined,
                muteKnown: chatId ? isChatMuteKnown(chatId) : undefined
            },
            payload: sanitizeForLog(payload),
            rawPacket: sanitizeForLog(packet)
        });
    }

    function logAuthSnapshotChats(packet) {
        const payload = packet.payload || {};
        logChatPacket('auth_snapshot', packet);

        if (payload.settings && payload.settings.chats) {
            postChatRaw({
                source: 'auth_snapshot_settings_chats',
                opcode: packet.opcode,
                cmd: packet.cmd,
                muteFields: collectMuteFields(payload.settings),
                settingsChats: sanitizeForLog(payload.settings.chats)
            });
        }

        if (!Array.isArray(payload.chats)) return;
        payload.chats.forEach(function (chat, index) {
            const chatId = safeString(chat.id);
            const settingsEntry = payload.settings &&
                payload.settings.chats &&
                (payload.settings.chats[chatId] || payload.settings.chats[chat.id]);
            postChatRaw({
                source: 'auth_snapshot_chat',
                opcode: packet.opcode,
                cmd: packet.cmd,
                chatIndex: index,
                chatId: chatId,
                chatTitle: extractContactName(chat) || (chat.title ? String(chat.title).trim() : ''),
                chatType: chat.type ? String(chat.type) : '',
                muteFields: collectMuteFields(chat) || (settingsEntry ? collectMuteFields(settingsEntry) : null),
                settingsEntry: settingsEntry ? sanitizeForLog(settingsEntry) : null,
                chat: sanitizeForLog(chat)
            });
        });
    }

    function shouldLogMessageChatEnvelope(payload, parsed) {
        if (payload.chat) return true;
        if (parsed && parsed.msg && parsed.msg.chat) return true;
        if (collectMuteFields(payload)) return true;
        if (parsed && parsed.msg && collectMuteFields(parsed.msg)) return true;
        return false;
    }

    function safeString(value) {
        if (value === null || value === undefined) return '';
        if (typeof value === 'bigint') return value.toString();
        if (typeof value === 'object' && value !== null && 'toString' in value) return value.toString();
        return String(value);
    }

    function readMyUserIdFromStorage() {
        try {
            const authRaw = localStorage.getItem('__oneme_auth');
            if (!authRaw) return null;
            const auth = JSON.parse(authRaw);
            return safeString(auth.profile?.id || auth.userId || auth.id);
        } catch (_) {
            return null;
        }
    }

    function extractContactName(entity) {
        if (!entity || typeof entity !== 'object') return '';
        if (entity.name) return String(entity.name).trim();
        if (Array.isArray(entity.names) && entity.names.length > 0) {
            const item = entity.names[0];
            if (item.name) return String(item.name).trim();
            const full = [item.firstName, item.lastName].filter(Boolean).join(' ').trim();
            if (full) return full;
        }
        const composed = [entity.firstName, entity.lastName].filter(Boolean).join(' ').trim();
        if (composed) return composed;
        if (entity.title) return String(entity.title).trim();
        return '';
    }

    function ingestContact(contact) {
        if (!contact || typeof contact !== 'object') return;
        const id = safeString(contact.id || contact.userId || contact.contactId || contact.sender);
        const name = extractContactName(contact);
        if (id && name) userNames[id] = name;
    }

    function ingestContactsList(contacts) {
        if (!Array.isArray(contacts)) return;
        contacts.forEach(ingestContact);
    }

    function ingestChatType(chat) {
        const chatId = safeString(chat && chat.id);
        if (!chatId) return;
        if (chat.type) {
            chatTypes[chatId] = chat.type;
            return;
        }
        if (chat.participants && typeof chat.participants === 'object') {
            const count = Object.keys(chat.participants).length;
            if (count > 2) chatTypes[chatId] = 'GROUP';
            else if (count === 2) chatTypes[chatId] = 'DIALOG';
        }
    }

    function isChatTypeKnown(chatId) {
        return !!chatId && Object.prototype.hasOwnProperty.call(chatTypes, chatId);
    }

    function isChatMuteKnown(chatId) {
        return !!chatId && Object.prototype.hasOwnProperty.call(chatMuteUntil, chatId);
    }

    function ingestChatsMeta(chats) {
        if (!Array.isArray(chats)) return;
        chats.forEach(function (chat) {
            const chatId = safeString(chat.id);
            const title = extractContactName(chat) || (chat.title ? String(chat.title).trim() : '');
            if (chatId && title) chatTitles[chatId] = title;
            ingestChatType(chat);
            ingestChatMute(chat, chat);
        });
    }

    function resolveSenderName(parsed, payload) {
        const fromCache = userNames[parsed.senderId];
        if (fromCache) return fromCache;

        const fromMessage = extractContactName(parsed.msg)
            || (parsed.msg.senderName ? String(parsed.msg.senderName).trim() : '');
        if (fromMessage) return fromMessage;

        const fromPayload = extractContactName(payload.contact)
            || extractContactName(payload.sender)
            || extractContactName(payload.user);
        if (fromPayload) return fromPayload;

        return chatTitles[parsed.chatId] || '';
    }

    function parsePacket(raw) {
        try {
            if (typeof raw === 'string') return JSON.parse(raw);
            if (raw instanceof ArrayBuffer) return JSON.parse(new TextDecoder().decode(raw));
            if (ArrayBuffer.isView(raw)) return JSON.parse(new TextDecoder().decode(raw));
        } catch (_) {}
        return null;
    }

    function isChatMuted(dontDisturbUntil) {
        if (dontDisturbUntil === null || dontDisturbUntil === undefined) return false;
        const value = Number(dontDisturbUntil);
        if (Number.isNaN(value)) return false;
        if (value === -1) return true;
        if (value === 0) return false;
        const nowMs = Date.now();
        const untilMs = value > 1e12 ? value : value * 1000;
        return untilMs > nowMs;
    }

    function extractDontDisturbUntil(chat, payload) {
        const chatId = safeString(chat && chat.id);
        const configEntry = chatId &&
            payload &&
            payload.config &&
            payload.config.chats &&
            payload.config.chats[chatId];
        const settingsEntry = chatId &&
            payload &&
            payload.settings &&
            payload.settings.chats &&
            payload.settings.chats[chatId];

        const candidates = [
            chat && chat.dontDisturbUntil,
            chat && chat.settings && chat.settings.dontDisturbUntil,
            configEntry && configEntry.dontDisturbUntil,
            settingsEntry && settingsEntry.dontDisturbUntil,
            payload && payload.dontDisturbUntil,
            chat && chat.muteUntil,
            chat && chat.mutedUntil
        ];
        for (let i = 0; i < candidates.length; i++) {
            if (candidates[i] !== null && candidates[i] !== undefined) {
                return candidates[i];
            }
        }
        return null;
    }

    function updateChatMuteState(chatId, dontDisturbUntil, source) {
        if (!chatId) return;
        if (dontDisturbUntil === null || dontDisturbUntil === undefined) return;
        const previous = chatMuteUntil[chatId];
        chatMuteUntil[chatId] = dontDisturbUntil;
        if (previous !== dontDisturbUntil) {
            postMuteProbe({
                source: source || 'mute_cache_update',
                chatId: safeString(chatId),
                previous: previous,
                dontDisturbUntil: dontDisturbUntil,
                isMuted: isChatMuted(dontDisturbUntil),
                isMutedNow: isChatIdMuted(chatId)
            });
            postChatRaw({
                source: source || 'mute_cache_update',
                chatId: safeString(chatId),
                previous: previous,
                dontDisturbUntil: dontDisturbUntil,
                isMuted: isChatMuted(dontDisturbUntil),
                isMutedNow: isChatIdMuted(chatId)
            });
        }
    }

    function isChatIdMuted(chatId) {
        if (!chatId) return false;
        return isChatMuted(chatMuteUntil[chatId]);
    }

    function ingestSettingsDeep(obj, source, depth) {
        ingestMuteFromUnknownStructure(obj, source, depth);
    }

    function ingestMuteFromUnknownStructure(obj, source, depth) {
        depth = depth || 0;
        if (!obj || typeof obj !== 'object' || depth > 10) return;

        if (obj.chats && typeof obj.chats === 'object' && !Array.isArray(obj.chats)) {
            Object.keys(obj.chats).forEach(function (chatId) {
                const chatSettings = obj.chats[chatId];
                if (chatSettings && chatSettings.dontDisturbUntil !== undefined) {
                    updateChatMuteState(safeString(chatId), chatSettings.dontDisturbUntil, source);
                }
            });
        }

        if (Array.isArray(obj)) {
            obj.forEach(function (item) {
                ingestMuteFromUnknownStructure(item, source, depth + 1);
            });
            return;
        }

        Object.keys(obj).forEach(function (key) {
            if (/^-?\d{5,}$/.test(key) && obj[key] && typeof obj[key] === 'object') {
                const entry = obj[key];
                if (entry.dontDisturbUntil !== undefined) {
                    updateChatMuteState(safeString(key), entry.dontDisturbUntil, source);
                }
            }
        });

        if (obj.settings) ingestMuteFromUnknownStructure(obj.settings, source, depth + 1);
        if (obj.config) ingestMuteFromUnknownStructure(obj.config, source, depth + 1);

        Object.keys(obj).forEach(function (key) {
            if (key === 'settings' || key === 'config' || key === 'chats' || key === 'participants' || key === 'lastMessage' || key === 'previewData' || key === 'attaches') {
                return;
            }
            ingestMuteFromUnknownStructure(obj[key], source, depth + 1);
        });
    }

    function scanIndexedDBObjectStore(db, storeName, source) {
        return new Promise(function (resolve) {
            let tx;
            try {
                tx = db.transaction(storeName, 'readonly');
            } catch (_) {
                resolve(0);
                return;
            }
            const store = tx.objectStore(storeName);
            const req = store.openCursor();
            let count = 0;
            req.onsuccess = function (event) {
                const cursor = event.target.result;
                if (!cursor) return;
                count += 1;
                try {
                    ingestMuteFromUnknownStructure(cursor.value, source);
                } catch (_) {}
                cursor.continue();
            };
            tx.oncomplete = function () { resolve(count); };
            tx.onerror = function () { resolve(count); };
        });
    }

    function ingestSettingsFromIndexedDB(source) {
        if (!window.indexedDB) return Promise.resolve();
        const now = Date.now();
        if (source === 'heartbeat' && now - lastIndexedDbScanAt < 5 * 60 * 1000) {
            return Promise.resolve();
        }
        lastIndexedDbScanAt = now;

        return new Promise(function (resolve) {
            const finish = function (summary) {
                if (summary.length) {
                    postChatRaw({
                        source: source + '_indexeddb',
                        scanned: summary,
                        muteCache: sanitizeForLog(chatMuteUntil)
                    });
                }
                if (isMuteProbeLogging()) {
                    postMuteProbe({
                        source: source + '_indexeddb',
                        scanned: summary,
                        mutedInCache: summarizeMutedCache()
                    });
                }
                resolve();
            };

            const openDatabase = function (dbName) {
                return new Promise(function (resolveDb) {
                    const req = indexedDB.open(dbName);
                    req.onsuccess = function () { resolveDb(req.result); };
                    req.onerror = function () { resolveDb(null); };
                    req.onblocked = function () { resolveDb(null); };
                });
            };

            const scanDatabase = async function (dbName) {
                const db = await openDatabase(dbName);
                if (!db) return [];
                const entries = [];
                const stores = Array.from(db.objectStoreNames || []);
                for (let i = 0; i < stores.length; i++) {
                    const storeName = stores[i];
                    const count = await scanIndexedDBObjectStore(
                        db,
                        storeName,
                        source + ':idb:' + dbName + '/' + storeName
                    );
                    if (count) entries.push(dbName + '/' + storeName + ':' + count);
                }
                db.close();
                return entries;
            };

            const run = async function () {
                let dbNames = [];
                try {
                    if (indexedDB.databases) {
                        const dbs = await indexedDB.databases();
                        dbNames = dbs.map(function (d) { return d.name; }).filter(Boolean);
                    }
                } catch (_) {}
                if (!dbNames.length) {
                    dbNames = ['oneme', 'max', 'OneMe', 'MAX', 'keyval-store'];
                }
                const summary = [];
                for (let i = 0; i < dbNames.length; i++) {
                    const entries = await scanDatabase(dbNames[i]);
                    summary.push.apply(summary, entries);
                }
                finish(summary);
            };

            run().catch(function () { finish([]); });
        });
    }

    function ingestSettingsFromLocalStorage(source) {
        let matchedKeys = [];
        try {
            for (let i = 0; i < localStorage.length; i++) {
                const key = localStorage.key(i);
                if (!key) continue;
                const lower = key.toLowerCase();
                if (lower.indexOf('oneme') === -1 && lower.indexOf('max') === -1 && lower.indexOf('setting') === -1) {
                    continue;
                }
                try {
                    const raw = localStorage.getItem(key);
                    if (!raw) continue;
                    const parsed = JSON.parse(raw);
                    const before = Object.keys(chatMuteUntil).length;
                    ingestSettingsDeep(parsed, source + ':' + key);
                    if (Object.keys(chatMuteUntil).length > before) {
                        matchedKeys.push(key);
                    }
                } catch (_) {}
            }
        } catch (_) {}
        if (matchedKeys.length) {
            postChatRaw({
                source: source + '_local_storage',
                matchedKeys: matchedKeys,
                muteCache: sanitizeForLog(chatMuteUntil)
            });
        }
        if (isMuteProbeLogging()) {
            scanStorageArea(localStorage, 'localStorage', source);
        }
    }

    function ingestSettingsChats(settings) {
        if (!settings) return;
        ingestSettingsDeep(settings, 'ingest_settings_chats');
    }

    function ingestChatConfig(config, source) {
        if (!config) return;
        ingestMuteFromUnknownStructure(config, source || 'ingest_chat_config');
    }

    function ingestChatMute(chat, payload) {
        const chatId = safeString((chat && chat.id) || (payload && payload.chatId));
        if (!chatId) return;
        const muteUntil = extractDontDisturbUntil(chat, payload);
        if (muteUntil !== null && muteUntil !== undefined) {
            updateChatMuteState(chatId, muteUntil, 'ingest_chat_mute');
        }
    }

    function parseMessageBody(payload) {
        const msg = payload.message || payload.msg || payload;
        const chatId = safeString(payload.chatId || msg.chatId || payload.cid);
        const messageId = safeString(msg.id || msg.messageId || msg.mid);
        const senderId = safeString(msg.sender || msg.senderId || msg.from || msg.userId);
        const text = msg.text || msg.body || msg.message || '';
        const attaches = msg.attaches || msg.attachments || [];
        const chatObj = payload.chat || msg.chat || null;

        if (chatObj && chatId) {
            ingestChatType(Object.assign({ id: chatId }, chatObj));
            ingestChatMute(Object.assign({ id: chatId }, chatObj), payload);
            const title = extractContactName(chatObj) || (chatObj.title ? String(chatObj.title).trim() : '');
            if (title) chatTitles[chatId] = title;
        }

        const chatType = chatTypes[chatId]
            || (chatObj && chatObj.type ? String(chatObj.type) : '')
            || (payload.chatType ? String(payload.chatType) : '');

        if (chatId && chatType) chatTypes[chatId] = chatType;

        return { chatId, messageId, senderId, text, attaches, chatType, msg };
    }

    function handlePacket(packet) {
        if (!packet || typeof packet !== 'object') return;
        touchPacket();
        if (isMuteProbeLogging()) {
            probePacket(packet, 'ws_in');
        }

        const opcode = packet.opcode;
        const payload = packet.payload || {};

        if (opcode === OPCODE_AUTH_SNAPSHOT && packet.cmd === 1) {
            const profile = payload.profile || {};
            myUserId = safeString(profile.id) || readMyUserIdFromStorage();
            if (profile.name) userNames[myUserId] = profile.name;
            ingestChatsMeta(payload.chats);
            ingestContactsList(payload.contacts);
            ingestContact(payload.contact);
            ingestSettingsChats(payload.settings);
            ingestChatConfig(payload.config, 'auth_snapshot_config');
            if (isVerboseLogging()) {
                ingestSettingsFromLocalStorage('auth_snapshot');
                ingestSettingsFromIndexedDB('auth_snapshot');
                logAuthSnapshotChats(packet);
            }
            if (isMuteProbeLogging()) {
                postMuteProbe({
                    source: 'auth_snapshot',
                    opcode: packet.opcode,
                    cmd: packet.cmd,
                    hasSettings: !!payload.settings,
                    hasConfig: !!payload.config,
                    settingsChats: summarizeSettingsChats(payload.settings),
                    configChats: summarizeSettingsChats(payload.config),
                    hints: findNotificationHints(packet).slice(0, 40),
                    chatCount: Array.isArray(payload.chats) ? payload.chats.length : 0
                });
                runMuteProbeScan('auth_snapshot');
                hookNetworkForMuteProbe();
            }
            sessionReady = true;
            everSynced = true;
            publishState();
            post('auth_ready', { userId: myUserId, userName: profile.name || '' });
            post('chats_synced', {
                chatCount: Array.isArray(payload.chats) ? payload.chats.length : 0
            });
            return;
        }

        if (opcode === OPCODE_NOTIF_CONTACT) {
            ingestContact(payload.contact || payload);
            ingestContactsList(payload.contacts);
            return;
        }

        if (opcode === OPCODE_CONFIG || opcode === OPCODE_NOTIF_CONFIG) {
            logChatPacket(opcode === OPCODE_CONFIG ? 'opcode_config' : 'opcode_notif_config', packet);
            ingestSettingsChats(payload.settings);
            ingestChatConfig(payload.config, opcode === OPCODE_CONFIG ? 'opcode_config' : 'opcode_notif_config');
            if (payload.chat) ingestChatMute(payload.chat, payload);
            return;
        }

        if (opcode === 61) {
            logChatPacket('chat_personal_config', packet);
            ingestSettingsChats(payload.settings);
            ingestChatConfig(payload.config, 'chat_personal_config');
            ingestChatMute(payload.chat || payload, payload);
            if (payload.chatId !== undefined && payload.chatId !== null) {
                ingestChatMute({ id: payload.chatId }, payload);
            }
            return;
        }

        if (opcode === OPCODE_NOTIF_CHAT) {
            logChatPacket('notif_chat', packet);
            const chat = payload.chat || payload;
            const chatId = safeString(chat.id || payload.chatId);
            const title = extractContactName(chat) || (chat.title ? String(chat.title).trim() : '');
            ingestChatType(chat);
            if (chatId && title) chatTitles[chatId] = title;
            ingestChatMute(chat, payload);
            return;
        }

        if (opcode === OPCODE_NOTIF_MESSAGE) {
            touchMessage();

            const parsed = parseMessageBody(payload);
            if (!parsed.messageId || !parsed.chatId) {
                if (isVerboseLogging()) {
                    post('debug_packet', { opcode: opcode, reason: 'missing_ids', payload: payload });
                }
                return;
            }

            if (!sessionReady) {
                post('message_traffic', {
                    reason: 'session_not_ready',
                    messageCount: window.__max2iMessageMessageCount || 0
                });
            }

            const muteFromMessage = extractDontDisturbUntil(parsed.msg, payload);
            if (muteFromMessage !== null && muteFromMessage !== undefined) {
                updateChatMuteState(parsed.chatId, muteFromMessage, 'notif_message');
            }

            if (shouldLogMessageChatEnvelope(payload, parsed)) {
                logChatPacket('notif_message_chat_envelope', packet, { chatId: parsed.chatId });
            }

            const senderName = resolveSenderName(parsed, payload);
            if (parsed.senderId && senderName) userNames[parsed.senderId] = senderName;

            post('message_observed', {
                chatId: parsed.chatId,
                messageId: parsed.messageId,
                sessionReady: sessionReady
            });

            post('new_message', {
                chatId: parsed.chatId,
                messageId: parsed.messageId,
                senderId: parsed.senderId,
                senderName: senderName,
                chatTitle: chatTitles[parsed.chatId] || '',
                text: parsed.text,
                timestamp: safeString(parsed.msg.time || parsed.msg.timestamp),
                chatType: parsed.chatType,
                isMutedChat: isChatIdMuted(parsed.chatId),
                chatTypeKnown: isChatTypeKnown(parsed.chatId) || !!parsed.chatType,
                chatMuteKnown: isChatMuteKnown(parsed.chatId),
                hasAttachment: Array.isArray(parsed.attaches) && parsed.attaches.length > 0,
                myUserId: myUserId || readMyUserIdFromStorage()
            });
        }
    }

    function processRawMessageData(data) {
        if (data instanceof Blob) {
            data.text().then(function (text) {
                const packet = parsePacket(text);
                if (packet) handlePacket(packet);
            }).catch(function () {});
            return;
        }
        const packet = parsePacket(data);
        if (packet) handlePacket(packet);
    }

    function hookWebSocket() {
        const NativeWS = window.WebSocket;
        if (!NativeWS || NativeWS.__max2iMessageHooked) return;

        function WrappedWebSocket(url, protocols) {
            const ws = protocols !== undefined
                ? new NativeWS(url, protocols)
                : new NativeWS(url);

            ws.addEventListener('message', function (event) {
                processRawMessageData(event.data);
            });

            const nativeSend = ws.send.bind(ws);
            ws.send = function (data) {
                try {
                    if (isMuteProbeLogging()) {
                        probeOutgoingWS(data);
                    }
                } catch (_) {}
                return nativeSend(data);
            };

            ws.addEventListener('close', function (event) {
                sessionReady = false;
                publishState();
                post('ws_closed', {
                    url: safeString(url),
                    code: event.code,
                    reason: event.reason ? String(event.reason) : '',
                    wasClean: event.wasClean
                });
            });

            ws.addEventListener('open', function () {
                sessionReady = everSynced;
                publishState();
                post('ws_open', { url: safeString(url), resumed: everSynced });
            });

            return ws;
        }

        try {
            WrappedWebSocket.prototype = NativeWS.prototype;
        } catch (_) {}

        ['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED'].forEach(function (key) {
            if (key in NativeWS) {
                try { WrappedWebSocket[key] = NativeWS[key]; } catch (_) {}
            }
        });

        WrappedWebSocket.__max2iMessageHooked = true;
        try {
            window.WebSocket = WrappedWebSocket;
        } catch (e) {
            throw new Error('assign WebSocket: ' + (e && e.message ? e.message : e));
        }
    }

    function checkAuth() {
        try {
            const token = localStorage.getItem('__oneme_auth');
            myUserId = myUserId || readMyUserIdFromStorage();
            post('auth_check', { hasToken: !!token, userId: myUserId || '' });
        } catch (_) {
            post('auth_check', { hasToken: false });
        }
    }

    function setupDOMFallback() {
        const observer = new MutationObserver(function () {
            const badges = document.querySelectorAll('[class*="unread"], [class*="badge"], [data-testid*="unread"]');
            if (badges.length > 0) {
                post('dom_activity', { badgeCount: badges.length });
            }
        });

        const startObserver = function () {
            if (!document.body) return;
            observer.observe(document.body, { childList: true, subtree: true, attributes: true });
        };

        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', startObserver);
        } else {
            startObserver();
        }
    }

    function sendHeartbeat() {
        keepPageAwake();
        hookWebSocket();
        publishState();
        if (isVerboseLogging()) {
            ingestSettingsFromLocalStorage('heartbeat');
            ingestSettingsFromIndexedDB('heartbeat');
        }
        if (isMuteProbeLogging()) {
            runMuteProbeScan('heartbeat');
        }
        post('heartbeat', {
            lastPacketAt: window.__max2iMessageLastPacketAt || 0,
            lastMessageAt: window.__max2iMessageLastMessageAt || 0,
            packetCount: window.__max2iMessagePacketCount || 0,
            messageCount: window.__max2iMessageMessageCount || 0,
            sessionReady: sessionReady,
            everSynced: everSynced
        });
    }

    window.__max2iMessageNativePing = function () {
        keepPageAwake();
        hookWebSocket();
        publishState();
        return {
            lastPacketAt: window.__max2iMessageLastPacketAt || 0,
            lastMessageAt: window.__max2iMessageLastMessageAt || 0,
            packetCount: window.__max2iMessagePacketCount || 0,
            messageCount: window.__max2iMessageMessageCount || 0,
            sessionReady: sessionReady,
            everSynced: everSynced,
            now: Date.now()
        };
    };

    window.__max2iMessageInstallStep = 'hookWebSocket';
    hookWebSocket();
    window.__max2iMessageInstallStep = 'keepPageAwake';
    keepPageAwake();
    window.__max2iMessageInstallStep = 'setupDOMFallback';
    setupDOMFallback();
    myUserId = readMyUserIdFromStorage();
    publishState();

    if (isMuteProbeLogging()) {
        hookNetworkForMuteProbe();
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', checkAuth);
    } else {
        checkAuth();
    }

    setInterval(checkAuth, 5 * 60 * 1000);
    setInterval(sendHeartbeat, 60 * 1000);
    setInterval(keepPageAwake, 30 * 1000);

    window.__max2iMessageInstalled = true;
    window.__max2iMessageInstallStep = 'ready';
    post('monitor_ready', {});
    sendHeartbeat();
    } catch (e) {
        window.__max2iMessageInstalled = false;
        window.__max2iMessageInstallError = String(
            (window.__max2iMessageInstallStep || 'unknown') + ': ' + (e && e.message ? e.message : e)
        );
        console.error('[Max2iMessage] monitor install failed', e);
    }
})();
