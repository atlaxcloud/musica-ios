// AXS1, the Atlax screen stream: the Swift twin of agent/src/mirror_proto.zig
// (read that header for the whole protocol). Same bytes on the wire, checked in
// CI against vectors computed by the Zig side (Tests/wire_check.swift).
import CryptoKit
import Foundation

enum Wire {
    static let magic = Data("AXS1".utf8)
    static let helloLen = 36
    static let tag = 16
    static let maxRecord = 4 << 20
    static let version: UInt16 = 1

    enum T: UInt8 {
        case hello = 0x01, config = 0x02, frame = 0x03, bye = 0x04, ping = 0x05
        case ack = 0x81, key = 0x82, pong = 0x83
    }

    /// One direction of the record layer (nonce = 0^4 || u64 BE seq).
    struct Dir {
        let key: SymmetricKey
        var seq: UInt64 = 0

        private func nonce() -> ChaChaPoly.Nonce {
            var n = Data(count: 4)
            n.append(be(seq))
            return try! ChaChaPoly.Nonce(data: n)
        }

        /// u32 BE n || ciphertext(type || payload) || tag, ad = the 4 length bytes.
        mutating func seal(_ t: T, _ payload: Data) -> Data? {
            let n = 1 + payload.count + Wire.tag
            if n > Wire.maxRecord { return nil }
            let head = be(UInt32(n))
            var pt = Data([t.rawValue])
            pt.append(payload)
            guard let box = try? ChaChaPoly.seal(pt, using: key, nonce: nonce(), authenticating: head) else { return nil }
            seq += 1
            var out = head
            out.append(box.ciphertext)
            out.append(box.tag)
            return out
        }

        /// rec = one whole record (length header included).
        mutating func open(_ rec: Data) -> (UInt8, Data)? {
            let rec = Data(rec)
            if rec.count < 4 + 1 + Wire.tag { return nil }
            let head = rec.prefix(4)
            let ct = rec.subdata(in: 4..<(rec.count - Wire.tag))
            let tg = rec.suffix(Wire.tag)
            guard let box = try? ChaChaPoly.SealedBox(nonce: nonce(), ciphertext: ct, tag: tg),
                  let pt = try? ChaChaPoly.open(box, using: key, authenticating: head), !pt.isEmpty else { return nil }
            seq += 1
            let p = Data(pt)
            return (p[0], p.subdata(in: 1..<p.count))
        }
    }

    struct Keys { var up: Dir; var down: Dir }

    /// "AXS1" || ephemeral X25519 public key.
    static func hello(_ k: Curve25519.KeyAgreement.PrivateKey) -> Data {
        var b = magic
        b.append(k.publicKey.rawRepresentation)
        return b
    }

    static func peerKey(_ h: Data) -> Data? {
        let h = Data(h)
        if h.count < helloLen || h.prefix(4) != magic { return nil }
        return h.subdata(in: 4..<36)
    }

    /// okm = HKDF-SHA256(salt psk, ikm X25519, info "atlax-screen v1" || pk_phone || pk_receiver, 64)
    static func derive(psk: Data, mine: Curve25519.KeyAgreement.PrivateKey, receiverPk: Data) -> Keys? {
        guard let other = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: receiverPk),
              let shared = try? mine.sharedSecretFromKeyAgreement(with: other) else { return nil }
        var info = Data("atlax-screen v1".utf8)
        info.append(mine.publicKey.rawRepresentation)
        info.append(receiverPk)
        let okm = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: psk, sharedInfo: info, outputByteCount: 64)
        let b = okm.withUnsafeBytes { Data($0) }
        return Keys(up: Dir(key: SymmetricKey(data: b.prefix(32))), down: Dir(key: SymmetricKey(data: b.suffix(32))))
    }

    static func helloPayload(w: Int, h: Int, fps: Int, name: String) -> Data {
        var b = be(version)
        b.append(be(UInt16(clamping: w)))
        b.append(be(UInt16(clamping: h)))
        b.append(UInt8(clamping: fps))
        b.append(Data(name.utf8).prefix(64))
        return b
    }

    /// avcC from SPS / PPS (4-byte NAL lengths), as mirror_mp4.avcc.
    static func avcc(sps: Data, pps: Data) -> Data? {
        let s = Data(sps), p = Data(pps)
        if s.count < 4 { return nil }
        var b = Data([1, s[1], s[2], s[3], 0xff, 0xe1])
        b.append(be(UInt16(s.count)))
        b.append(s)
        b.append(1)
        b.append(be(UInt16(p.count)))
        b.append(p)
        return b
    }

    /// FRAME payload head: u64 pts (us) | u8 flags; AVCC NALs follow.
    static func frameHead(ptsUs: UInt64, key: Bool) -> Data {
        var b = be(ptsUs)
        b.append(key ? 1 : 0)
        return b
    }
}

/// A pairing from atlax-screen://pair?h=<ip:port>&k=<psk b64url>&id=<id>&n=<name>
struct Pairing: Codable, Equatable {
    var host: String
    var port: UInt16
    var psk: Data
    var id: String
    var name: String

    init?(uri: String) {
        guard let c = URLComponents(string: uri), c.scheme == "atlax-screen" else { return nil }
        func q(_ k: String) -> String? { c.queryItems?.first { $0.name == k }?.value }
        guard let hp = q("h"), let k = q("k"), let colon = hp.lastIndex(of: ":"),
              let port = UInt16(hp[hp.index(after: colon)...]) else { return nil }
        var b64 = k.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let psk = Data(base64Encoded: b64), psk.count == 32 else { return nil }
        host = String(hp[..<colon])
        self.port = port
        self.psk = psk
        id = q("id") ?? ""
        name = q("n") ?? "Atlax"
    }
}

func be<I: FixedWidthInteger>(_ v: I) -> Data {
    var x = v.bigEndian
    return withUnsafeBytes(of: &x) { Data($0) }
}
