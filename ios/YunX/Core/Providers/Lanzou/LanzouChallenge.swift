//
//  LanzouChallenge.swift
//  YunX
//
//  蓝奏云 acw_sc__v2 人机校验 Cookie 纯本地置换异或算法（零脚本执行，与 Android LanzouApi.acwScV2 逐字节一致）。
//

import Foundation

public enum LanzouChallenge {
    private static let pos: [Int] = [
        15, 35, 29, 24, 33, 16, 1, 38, 10, 9, 19, 31, 40, 27, 22, 23, 25, 13, 6, 11,
        39, 18, 20, 8, 14, 21, 32, 26, 2, 30, 7, 4, 17, 5, 3, 28, 34, 37, 12, 36
    ]
    private static let mask = "3000176000856006061501533003690027800375"

    /// 根据 HTML 中 40 位十六进制 arg1 计算 acw_sc__v2 Cookie 值
    public static func computeAcwScV2(arg1: String) -> String {
        let chars = Array(arg1)
        var rearranged = [Character](repeating: "0", count: pos.count)
        for x in 0..<chars.count {
            for z in 0..<pos.count where pos[z] == x + 1 {
                rearranged[z] = chars[x]
            }
        }
        let u = String(rearranged)
        let uChars = Array(u)
        let mChars = Array(mask)
        var out = ""
        out.reserveCapacity(40)
        var i = 0
        while i + 2 <= uChars.count && i + 2 <= mChars.count {
            let a = Int(String(uChars[i..<(i + 2)]), radix: 16) ?? 0
            let b = Int(String(mChars[i..<(i + 2)]), radix: 16) ?? 0
            out += String(format: "%02x", a ^ b)
            i += 2
        }
        return out
    }

    /// 若 HTML 为 acw_sc__v2 挑战页，提取 arg1 并返回应设置的 Cookie 值
    public static func extractChallengeCookie(from html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\barg1\s*=\s*'([0-9A-Fa-f]{40})'"#) else {
            return nil
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: range),
              match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return computeAcwScV2(arg1: String(html[r]))
    }
}
