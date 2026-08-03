// Pure Swift RIPEMD-160 implementation (no external dependencies).
// Follows the RIPEMD-160 specification: https://homes.esat.kuleuven.be/~bosselae/ripemd160.html

import Foundation

enum RIPEMD160 {
    static func hash(_ data: some DataProtocol) -> [UInt8] {
        var ctx = Context()
        ctx.update(data)
        return ctx.finalize()
    }

    struct Context {
        private var h: (UInt32, UInt32, UInt32, UInt32, UInt32) =
            (0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0)
        private var buffer = [UInt8]()
        private var totalBytes: UInt64 = 0

        mutating func update(_ data: some DataProtocol) {
            for byte in data {
                buffer.append(byte)
                totalBytes += 1
                if buffer.count == 64 { processBlock(); buffer.removeAll(keepingCapacity: true) }
            }
        }

        mutating func finalize() -> [UInt8] {
            var padded = buffer
            padded.append(0x80)
            while padded.count % 64 != 56 { padded.append(0x00) }
            let bitLen = totalBytes &* 8
            for i in 0..<8 { padded.append(UInt8((bitLen >> (i * 8)) & 0xFF)) }
            var ctx = self
            ctx.buffer = []
            for i in stride(from: 0, to: padded.count, by: 64) {
                ctx.buffer = Array(padded[i..<i+64])
                ctx.processBlock()
                ctx.buffer = []
            }
            var out = [UInt8](repeating: 0, count: 20)
            for (i, word) in [ctx.h.0, ctx.h.1, ctx.h.2, ctx.h.3, ctx.h.4].enumerated() {
                out[i*4]   = UInt8(word & 0xFF)
                out[i*4+1] = UInt8((word >> 8) & 0xFF)
                out[i*4+2] = UInt8((word >> 16) & 0xFF)
                out[i*4+3] = UInt8((word >> 24) & 0xFF)
            }
            return out
        }

        private mutating func processBlock() {
            var X = [UInt32](repeating: 0, count: 16)
            for i in 0..<16 {
                X[i] = UInt32(buffer[i*4]) | (UInt32(buffer[i*4+1]) << 8)
                     | (UInt32(buffer[i*4+2]) << 16) | (UInt32(buffer[i*4+3]) << 24)
            }
            var (al, bl, cl, dl, el) = h
            var (ar, br, cr, dr, er) = h

            func rol(_ x: UInt32, _ n: Int) -> UInt32 { (x << n) | (x >> (32 - n)) }
            func f(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { x ^ y ^ z }
            func g(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { (x & y) | (~x & z) }
            func h_(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { (x | ~y) ^ z }
            func i_(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { (x & z) | (y & ~z) }
            func j_(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { x ^ (y | ~z) }

            let KL: [UInt32] = [0x00000000, 0x5A827999, 0x6ED9EBA1, 0x8F1BBCDC, 0xA953FD4E]
            let KR: [UInt32] = [0x50A28BE6, 0x5C4DD124, 0x6D703EF3, 0x7A6D76E9, 0x00000000]

            let RL = [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,
                      7,4,13,1,10,6,15,3,12,0,9,5,2,14,11,8,
                      3,10,14,4,9,15,8,1,2,7,0,6,13,11,5,12,
                      1,9,11,10,0,8,12,4,13,3,7,15,14,5,6,2,
                      4,0,5,9,7,12,2,10,14,1,3,8,11,6,15,13]

            let RR = [5,14,7,0,9,2,11,4,13,6,15,8,1,10,3,12,
                      6,11,3,7,0,13,5,10,14,15,8,12,4,9,1,2,
                      15,5,1,3,7,14,6,9,11,8,12,2,10,0,4,13,
                      8,6,4,1,3,11,15,0,5,12,2,13,9,7,10,14,
                      12,15,10,4,1,5,8,7,6,2,13,14,0,3,9,11]

            let SL = [11,14,15,12,5,8,7,9,11,13,14,15,6,7,9,8,
                      7,6,8,13,11,9,7,15,7,12,15,9,11,7,13,12,
                      11,13,6,7,14,9,13,15,14,8,13,6,5,12,7,5,
                      11,12,14,15,14,15,9,8,9,14,5,6,8,6,5,12,
                      9,15,5,11,6,8,13,12,5,12,13,14,11,8,5,6]

            let SR = [8,9,9,11,13,15,15,5,7,7,8,11,14,14,12,6,
                      9,13,15,7,12,8,9,11,7,7,12,7,6,15,13,11,
                      9,7,15,11,8,6,6,14,12,13,5,14,13,13,7,5,
                      15,5,8,11,14,14,6,14,6,9,12,9,12,5,15,8,
                      8,5,12,9,12,5,14,6,8,13,6,5,15,13,11,11]

            for j in 0..<80 {
                let round = j / 16
                var tl: UInt32
                switch round {
                case 0: tl = rol(al &+ f(bl, cl, dl) &+ X[RL[j]] &+ KL[0], SL[j]) &+ el
                case 1: tl = rol(al &+ g(bl, cl, dl) &+ X[RL[j]] &+ KL[1], SL[j]) &+ el
                case 2: tl = rol(al &+ h_(bl, cl, dl) &+ X[RL[j]] &+ KL[2], SL[j]) &+ el
                case 3: tl = rol(al &+ i_(bl, cl, dl) &+ X[RL[j]] &+ KL[3], SL[j]) &+ el
                default: tl = rol(al &+ j_(bl, cl, dl) &+ X[RL[j]] &+ KL[4], SL[j]) &+ el
                }
                al = el; el = dl; dl = rol(cl, 10); cl = bl; bl = tl

                var tr: UInt32
                switch round {
                case 0: tr = rol(ar &+ j_(br, cr, dr) &+ X[RR[j]] &+ KR[0], SR[j]) &+ er
                case 1: tr = rol(ar &+ i_(br, cr, dr) &+ X[RR[j]] &+ KR[1], SR[j]) &+ er
                case 2: tr = rol(ar &+ h_(br, cr, dr) &+ X[RR[j]] &+ KR[2], SR[j]) &+ er
                case 3: tr = rol(ar &+ g(br, cr, dr) &+ X[RR[j]] &+ KR[3], SR[j]) &+ er
                default: tr = rol(ar &+ f(br, cr, dr) &+ X[RR[j]] &+ KR[4], SR[j]) &+ er
                }
                ar = er; er = dr; dr = rol(cr, 10); cr = br; br = tr
            }

            let t = h.1 &+ cl &+ dr
            h.1 = h.2 &+ dl &+ er
            h.2 = h.3 &+ el &+ ar
            h.3 = h.4 &+ al &+ br
            h.4 = h.0 &+ bl &+ cr
            h.0 = t
        }
    }
}
