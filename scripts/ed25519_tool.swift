// Tiny Ed25519 helper for scripts/update_signing_key.sh (compiled with swiftc on demand; CryptoKit, same
// primitive the app verifies with). Keys are raw 32-byte values, base64.
//   gen                      -> prints a new private key (base64 seed)
//   pub  <privB64>           -> prints the matching public key (base64)
//   sign <privB64> <file>    -> prints the base64 signature of the file's exact bytes
//   verify <pubB64> <file> <sigB64> -> exit 0 if valid, 1 otherwise
import CryptoKit
import Foundation

func fail(_ m: String) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(2) }
let a = CommandLine.arguments
guard a.count >= 2 else { fail("usage: gen | pub <priv> | sign <priv> <file> | verify <pub> <file> <sig>") }

func priv(_ s: String) -> Curve25519.Signing.PrivateKey {
    guard let d = Data(base64Encoded: s.trimmingCharacters(in: .whitespacesAndNewlines)),
          let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: d) else { fail("bad private key") }
    return k
}
func readFile(_ p: String) -> Data {
    guard let d = FileManager.default.contents(atPath: p) else { fail("cannot read \(p)") }
    return d
}

switch a[1] {
case "gen":
    print(Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString())
case "pub" where a.count == 3:
    print(priv(a[2]).publicKey.rawRepresentation.base64EncodedString())
case "sign" where a.count == 4:
    guard let sig = try? priv(a[2]).signature(for: readFile(a[3])) else { fail("signing failed") }
    print(sig.base64EncodedString())
case "verify" where a.count == 5:
    guard let pd = Data(base64Encoded: a[2]), let pk = try? Curve25519.Signing.PublicKey(rawRepresentation: pd),
          let sd = Data(base64Encoded: a[4].trimmingCharacters(in: .whitespacesAndNewlines)) else { exit(1) }
    exit(pk.isValidSignature(sd, for: readFile(a[3])) ? 0 : 1)
default:
    fail("bad arguments")
}
