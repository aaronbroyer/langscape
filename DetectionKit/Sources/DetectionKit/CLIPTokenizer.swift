import Foundation

// Minimal CLIP BPE tokenizer backed by vocab and merges files.
// Looks up resources: clip-vocab.json and clip-merges.txt in the module bundle.
struct CLIPTokenizer {
    let contextLength = 77
    private let encoder: [String: Int]
    private let decoder: [Int: String]
    private let bpeRanks: [BytePair: Int]

    init?(bundle: Bundle) {
        guard let vocabURL = bundle.url(forResource: "clip-vocab", withExtension: "json"),
              let mergesURL = bundle.url(forResource: "clip-merges", withExtension: "txt") else { return nil }
        do {
            let data = try Data(contentsOf: vocabURL)
            let vocab = try JSONDecoder().decode([String: Int].self, from: data)
            self.encoder = vocab
            var inv: [Int: String] = [:]
            for (k, v) in vocab { inv[v] = k }
            self.decoder = inv
            let mergesText = try String(contentsOf: mergesURL)
            var ranks: [BytePair: Int] = [:]
            let lines = mergesText.split(separator: "\n").map(String.init)
            for (i, line) in lines.enumerated() {
                if i == 0 { continue }
                let comps = line.split(separator: " ").map(String.init)
                if comps.count == 2 { ranks[BytePair(comps[0], comps[1])] = i - 1 }
            }
            self.bpeRanks = ranks
        } catch { return nil }
    }

    func encodeFull(_ text: String) -> [Int] {
        // Encode with BOS/EOS and pad to context length
        let ids = encode(text)
        var full = Array(repeating: 0, count: contextLength)
        if let bos = encoder["<|startoftext|>"] { full[0] = bos }
        let copyCount = min(ids.count, contextLength - 2)
        for i in 0..<copyCount { full[i+1] = ids[i] }
        if let eos = encoder["<|endoftext|>"] { full[copyCount + 1] = eos }
        return full
    }

    private func encode(_ text: String) -> [Int] {
        let tokens = tokenize(text.lowercased()).flatMap { bpe($0).split(separator: " ").map(String.init) }
        return tokens.compactMap { encoder[$0] }
    }

    private func tokenize(_ text: String) -> [String] {
        let pattern = "<\\|startoftext\\|>|<\\|endoftext\\|>|'s|'t|'re|'ve|'m|'ll|'d|[\\p{L}]+|[\\p{N}]|[^\\s\\p{L}\\p{N}]+"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        let toks = matches.map { ns.substring(with: $0.range) }
        // byte-level BPE pre-tokenization
        return toks.map { tok in
            tok.utf8.map { byteEncoder[$0]! }.joined()
        }
    }

    private func getPairs(_ word: [String]) -> Set<BytePair> {
        var s = Set<BytePair>()
        for i in 0..<(word.count - 1) { s.insert(BytePair(word[i], word[i+1])) }
        return s
    }

    private func bpe(_ token: String) -> String {
        if token.count <= 1 { return token + "</w>" }
        var word = token.map { String($0) }
        let last = (word.last ?? "") + "</w>"
        word.removeLast(); word.append(last)
        var pairs = Array(getPairs(word))
        if pairs.isEmpty { return token + "</w>" }
        while true {
            let candidates = pairs.compactMap { (bp) -> (BytePair, Int)? in
                guard let r = bpeRanks[bp] else { return nil }
                return (bp, r)
            }
            guard let best = candidates.min(by: { $0.1 < $1.1 })?.0 else { break }
            let first = best.a, second = best.b
            var newWord: [String] = []
            var i = 0
            while i < word.count {
                if let j = word[i...].firstIndex(of: first) {
                    newWord.append(contentsOf: word[i..<j])
                    i = j
                } else {
                    newWord.append(contentsOf: word[i..<word.count])
                    break
                }
                if i < word.count - 1 && word[i] == first && word[i+1] == second {
                    newWord.append(first + second)
                    i += 2
                } else {
                    newWord.append(word[i]); i += 1
                }
            }
            word = newWord
            if word.count == 1 { break }
            pairs = Array(getPairs(word))
        }
        return word.joined(separator: " ")
    }
}

// Helpers
struct BytePair: Hashable { let a: String; let b: String; init(_ a: String, _ b: String) { self.a = a; self.b = b } }

// Byte encoder/decoder tables from GPT‑2/CLIP
let byteEncoder: [UInt8: String] = {
    // Build GPT‑2/CLIP byte encoder table
    var bs: [Int] = Array(33...126) + Array(161...172) + Array(174...255)
    var cs: [String] = bs.compactMap { UnicodeScalar(UInt32($0)).map { String($0) } }
    var n = 0
    for b in 0...255 where !bs.contains(b) {
        bs.append(b)
        if let scalar = UnicodeScalar(UInt32(256 + n)) { cs.append(String(scalar)) }
        n += 1
    }
    var dict: [UInt8: String] = [:]
    for (b, c) in zip(bs, cs) { dict[UInt8(b)] = c }
    return dict
}()
