// The page's own cryptography (cipher.js): see there.
declare const IrisinCipher: {
  sha256(message: Uint8Array): Uint8Array;
  hmacSHA256(key: Uint8Array, message: Uint8Array): Uint8Array;
  hkdfSHA256(inputKeyMaterial: Uint8Array, salt: Uint8Array, info: Uint8Array, length: number): Uint8Array;
  seal(key: Uint8Array, nonce: Uint8Array, plaintext: Uint8Array, aad: Uint8Array): Uint8Array;
  open(key: Uint8Array, nonce: Uint8Array, sealed: Uint8Array, aad: Uint8Array): Uint8Array | null;
  utf8Encode(text: string): Uint8Array;
  utf8Decode(bytes: Uint8Array): string;
  base64Encode(bytes: Uint8Array): string;
  base64Decode(text: string): Uint8Array | null;
};
export default IrisinCipher;
