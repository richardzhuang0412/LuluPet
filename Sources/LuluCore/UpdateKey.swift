import Foundation

/// The Ed25519 PUBLIC key that release zips must be signed with (raw 32 bytes, base64).
///
/// This file is rewritten by `scripts/update_signing_key.sh init`. The private key never enters the repo
/// (see README → 开发者 → 发布签名). While the value is the placeholder below, signature verification FAILS CLOSED:
/// a build with the placeholder refuses every update, and `scripts/release.sh` refuses to publish with it.
public enum UpdateKey {
    public static let publicKeyBase64 = "5A9QE/nefbjL2laE7TMwz4iPXsTVSBs05vD8lA+rWD0="
}
