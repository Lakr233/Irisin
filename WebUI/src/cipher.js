// The page's own cryptography: SHA-256, HMAC-SHA256, HKDF-SHA256 (RFC 5869)
// and ChaCha20-Poly1305 (RFC 8439), because a page served over plain HTTP is
// not a secure context and is offered no WebCrypto. It carries its own UTF-8
// and base64 too, so the same file runs in JavaScriptCore on the Mac, where
// Packages/IrisinWeb/Tests/IrisinWebTests/CipherTests.swift loads it as a
// plain script and checks it against the RFCs' vectors and byte for byte
// against CryptoKit; the page imports it as a module (cipher.d.ts).
// Documentation/WebManagement.md says what it protects and what it does not.
var IrisinCipher = (function () {
    "use strict";

    // MARK: SHA-256

    var K = new Uint32Array([
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]);
    var INITIAL = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
    var W = new Uint32Array(64);

    function rotr(x, n) {
        return (x >>> n) | (x << (32 - n));
    }

    // One 64-byte block at `offset` into `state` (8 words).
    function compress(state, bytes, offset) {
        for (var i = 0; i < 16; i++) {
            var at = offset + i * 4;
            W[i] = (bytes[at] << 24) | (bytes[at + 1] << 16) | (bytes[at + 2] << 8) | bytes[at + 3];
        }
        for (i = 16; i < 64; i++) {
            var w15 = W[i - 15];
            var w2 = W[i - 2];
            var s0 = rotr(w15, 7) ^ rotr(w15, 18) ^ (w15 >>> 3);
            var s1 = rotr(w2, 17) ^ rotr(w2, 19) ^ (w2 >>> 10);
            W[i] = (W[i - 16] + s0 + W[i - 7] + s1) | 0;
        }
        var a = state[0], b = state[1], c = state[2], d = state[3];
        var e = state[4], f = state[5], g = state[6], h = state[7];
        for (i = 0; i < 64; i++) {
            var t1 = (h + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + K[i] + W[i]) | 0;
            var t2 = ((rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c))) | 0;
            h = g;
            g = f;
            f = e;
            e = (d + t1) | 0;
            d = c;
            c = b;
            b = a;
            a = (t1 + t2) | 0;
        }
        state[0] = (state[0] + a) | 0;
        state[1] = (state[1] + b) | 0;
        state[2] = (state[2] + c) | 0;
        state[3] = (state[3] + d) | 0;
        state[4] = (state[4] + e) | 0;
        state[5] = (state[5] + f) | 0;
        state[6] = (state[6] + g) | 0;
        state[7] = (state[7] + h) | 0;
    }

    function digestOf(state) {
        var out = new Uint8Array(32);
        for (var i = 0; i < 8; i++) {
            out[i * 4] = state[i] >>> 24;
            out[i * 4 + 1] = state[i] >>> 16;
            out[i * 4 + 2] = state[i] >>> 8;
            out[i * 4 + 3] = state[i];
        }
        return out;
    }

    function sha256(message) {
        var state = new Int32Array(INITIAL);
        var length = message.length;
        var total = ((length + 9 + 63) >> 6) << 6;
        var padded = new Uint8Array(total);
        padded.set(message);
        padded[length] = 0x80;
        var bits = length * 8;
        var high = Math.floor(bits / 0x100000000);
        padded[total - 8] = high >>> 24;
        padded[total - 7] = high >>> 16;
        padded[total - 6] = high >>> 8;
        padded[total - 5] = high;
        padded[total - 4] = bits >>> 24;
        padded[total - 3] = bits >>> 16;
        padded[total - 2] = bits >>> 8;
        padded[total - 1] = bits;
        for (var offset = 0; offset < total; offset += 64) {
            compress(state, padded, offset);
        }
        return digestOf(state);
    }

    // MARK: HMAC-SHA256 and HKDF

    function concatenated(first, second) {
        var out = new Uint8Array(first.length + second.length);
        out.set(first);
        out.set(second, first.length);
        return out;
    }

    function hmacSHA256(key, message) {
        if (key.length > 64) {
            key = sha256(key);
        }
        var inner = new Uint8Array(64);
        var outer = new Uint8Array(64);
        for (var i = 0; i < 64; i++) {
            var byte = i < key.length ? key[i] : 0;
            inner[i] = byte ^ 0x36;
            outer[i] = byte ^ 0x5c;
        }
        return sha256(concatenated(outer, sha256(concatenated(inner, message))));
    }

    // HKDF-SHA256 (RFC 5869): the six-digit code stretched to a key's
    // length, nothing more.
    function hkdfSHA256(inputKeyMaterial, salt, info, length) {
        var pseudoRandomKey = hmacSHA256(salt, inputKeyMaterial);
        var out = new Uint8Array(length);
        var previous = new Uint8Array(0);
        for (var counter = 1, filled = 0; filled < length; counter++) {
            var message = new Uint8Array(previous.length + info.length + 1);
            message.set(previous);
            message.set(info, previous.length);
            message[message.length - 1] = counter;
            previous = hmacSHA256(pseudoRandomKey, message);
            var take = Math.min(32, length - filled);
            out.set(previous.subarray(0, take), filled);
            filled += take;
        }
        return out;
    }

    // MARK: ChaCha20-Poly1305

    function rotl(x, n) {
        return (x << n) | (x >>> (32 - n));
    }

    function word(bytes, at) {
        return bytes[at] | (bytes[at + 1] << 8) | (bytes[at + 2] << 16) | (bytes[at + 3] << 24);
    }

    // One 64-byte keystream block (RFC 8439 2.3).
    function chachaBlock(key, counter, nonce) {
        var state = new Int32Array(16);
        state[0] = 0x61707865;
        state[1] = 0x3320646e;
        state[2] = 0x79622d32;
        state[3] = 0x6b206574;
        for (var i = 0; i < 8; i++) {
            state[4 + i] = word(key, i * 4);
        }
        state[12] = counter;
        state[13] = word(nonce, 0);
        state[14] = word(nonce, 4);
        state[15] = word(nonce, 8);
        var x = state.slice();
        function quarter(a, b, c, d) {
            x[a] = (x[a] + x[b]) | 0;
            x[d] = rotl(x[d] ^ x[a], 16);
            x[c] = (x[c] + x[d]) | 0;
            x[b] = rotl(x[b] ^ x[c], 12);
            x[a] = (x[a] + x[b]) | 0;
            x[d] = rotl(x[d] ^ x[a], 8);
            x[c] = (x[c] + x[d]) | 0;
            x[b] = rotl(x[b] ^ x[c], 7);
        }
        for (i = 0; i < 10; i++) {
            quarter(0, 4, 8, 12);
            quarter(1, 5, 9, 13);
            quarter(2, 6, 10, 14);
            quarter(3, 7, 11, 15);
            quarter(0, 5, 10, 15);
            quarter(1, 6, 11, 12);
            quarter(2, 7, 8, 13);
            quarter(3, 4, 9, 14);
        }
        var out = new Uint8Array(64);
        for (i = 0; i < 16; i++) {
            var v = (x[i] + state[i]) | 0;
            out[i * 4] = v;
            out[i * 4 + 1] = v >>> 8;
            out[i * 4 + 2] = v >>> 16;
            out[i * 4 + 3] = v >>> 24;
        }
        return out;
    }

    function chacha20(key, nonce, counter, input) {
        var output = new Uint8Array(input.length);
        for (var offset = 0; offset < input.length; offset += 64, counter++) {
            var stream = chachaBlock(key, counter, nonce);
            var end = Math.min(64, input.length - offset);
            for (var i = 0; i < end; i++) {
                output[offset + i] = input[offset + i] ^ stream[i];
            }
        }
        return output;
    }

    function littleEndianNumber(bytes, start, end) {
        var hex = "";
        for (var i = end - 1; i >= start; i--) {
            hex += (bytes[i] < 16 ? "0" : "") + bytes[i].toString(16);
        }
        return BigInt("0x" + (hex || "0"));
    }

    var P1305 = (BigInt(1) << BigInt(130)) - BigInt(5);
    var CLAMP = BigInt("0x0ffffffc0ffffffc0ffffffc0fffffff");
    var BLOCK_HIGH_BIT = BigInt(1) << BigInt(128);
    var MASK_128 = (BigInt(1) << BigInt(128)) - BigInt(1);

    // Poly1305 over a message whose length is a multiple of 16, which the
    // AEAD's padding guarantees (RFC 8439 2.5, 2.8).
    function poly1305(oneTimeKey, message) {
        var r = littleEndianNumber(oneTimeKey, 0, 16) & CLAMP;
        var s = littleEndianNumber(oneTimeKey, 16, 32);
        var accumulator = BigInt(0);
        for (var offset = 0; offset < message.length; offset += 16) {
            accumulator = ((accumulator + littleEndianNumber(message, offset, offset + 16) + BLOCK_HIGH_BIT) * r) % P1305;
        }
        var tag = (accumulator + s) & MASK_128;
        var out = new Uint8Array(16);
        for (var i = 0; i < 16; i++) {
            out[i] = Number(tag & BigInt(0xff));
            tag >>= BigInt(8);
        }
        return out;
    }

    function padded16(length) {
        return (length + 15) & ~15;
    }

    function macData(aad, ciphertext) {
        var aadLength = padded16(aad.length);
        var textLength = padded16(ciphertext.length);
        var data = new Uint8Array(aadLength + textLength + 16);
        data.set(aad, 0);
        data.set(ciphertext, aadLength);
        var lengths = [aad.length, ciphertext.length];
        for (var n = 0; n < 2; n++) {
            var value = lengths[n];
            for (var i = 0; i < 8; i++) {
                data[aadLength + textLength + n * 8 + i] = value % 256;
                value = Math.floor(value / 256);
            }
        }
        return data;
    }

    // The ciphertext with its 16-byte tag after it, as CryptoKit's
    // `ChaChaPoly.SealedBox` holds them.
    function seal(key, nonce, plaintext, aad) {
        var oneTimeKey = chachaBlock(key, 0, nonce).subarray(0, 32);
        var ciphertext = chacha20(key, nonce, 1, plaintext);
        var tag = poly1305(oneTimeKey, macData(aad, ciphertext));
        var out = new Uint8Array(ciphertext.length + 16);
        out.set(ciphertext);
        out.set(tag, ciphertext.length);
        return out;
    }

    // The plaintext, or null when the tag does not match.
    function open(key, nonce, sealed, aad) {
        if (sealed.length < 16) {
            return null;
        }
        var ciphertext = sealed.subarray(0, sealed.length - 16);
        var oneTimeKey = chachaBlock(key, 0, nonce).subarray(0, 32);
        var expected = poly1305(oneTimeKey, macData(aad, ciphertext));
        var difference = 0;
        for (var i = 0; i < 16; i++) {
            difference |= expected[i] ^ sealed[sealed.length - 16 + i];
        }
        return difference === 0 ? chacha20(key, nonce, 1, ciphertext) : null;
    }

    // MARK: UTF-8 and base64

    function utf8Encode(text) {
        var bytes = [];
        for (var i = 0; i < text.length; i++) {
            var code = text.codePointAt(i);
            if (code > 0xffff) {
                i++;
            }
            if (code < 0x80) {
                bytes.push(code);
            } else if (code < 0x800) {
                bytes.push(0xc0 | (code >> 6), 0x80 | (code & 63));
            } else if (code < 0x10000) {
                bytes.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 63), 0x80 | (code & 63));
            } else {
                bytes.push(0xf0 | (code >> 18), 0x80 | ((code >> 12) & 63), 0x80 | ((code >> 6) & 63), 0x80 | (code & 63));
            }
        }
        return new Uint8Array(bytes);
    }

    function utf8Decode(bytes) {
        var text = "";
        for (var i = 0; i < bytes.length; ) {
            var byte = bytes[i];
            var code;
            if (byte < 0x80) {
                code = byte;
                i += 1;
            } else if (byte < 0xe0) {
                code = ((byte & 31) << 6) | (bytes[i + 1] & 63);
                i += 2;
            } else if (byte < 0xf0) {
                code = ((byte & 15) << 12) | ((bytes[i + 1] & 63) << 6) | (bytes[i + 2] & 63);
                i += 3;
            } else {
                code = ((byte & 7) << 18) | ((bytes[i + 1] & 63) << 12) | ((bytes[i + 2] & 63) << 6) | (bytes[i + 3] & 63);
                i += 4;
            }
            text += String.fromCodePoint(code);
        }
        return text;
    }

    var ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    function base64Encode(bytes) {
        var text = "";
        for (var i = 0; i < bytes.length; i += 3) {
            var chunk = (bytes[i] << 16) | ((bytes[i + 1] || 0) << 8) | (bytes[i + 2] || 0);
            text += ALPHABET[(chunk >> 18) & 63] + ALPHABET[(chunk >> 12) & 63];
            text += i + 1 < bytes.length ? ALPHABET[(chunk >> 6) & 63] : "=";
            text += i + 2 < bytes.length ? ALPHABET[chunk & 63] : "=";
        }
        return text;
    }

    function base64Decode(text) {
        var clean = text.replace(/=+$/, "");
        var bytes = new Uint8Array(Math.floor((clean.length * 3) / 4));
        var buffer = 0;
        var bits = 0;
        var at = 0;
        for (var i = 0; i < clean.length; i++) {
            var value = ALPHABET.indexOf(clean[i]);
            if (value < 0) {
                return null;
            }
            buffer = (buffer << 6) | value;
            bits += 6;
            if (bits >= 8) {
                bits -= 8;
                bytes[at++] = (buffer >> bits) & 0xff;
            }
        }
        return bytes;
    }

    return {
        sha256: sha256,
        hmacSHA256: hmacSHA256,
        hkdfSHA256: hkdfSHA256,
        seal: seal,
        open: open,
        utf8Encode: utf8Encode,
        utf8Decode: utf8Decode,
        base64Encode: base64Encode,
        base64Decode: base64Decode,
    };
})();

if (typeof module !== "undefined" && module.exports) {
    module.exports = IrisinCipher;
}
