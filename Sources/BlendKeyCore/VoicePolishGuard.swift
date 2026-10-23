/// 語音整理的保險（實驗 J）：模型只准做三件事——換成同音字（不管聲調）、刪掉贅字或重複的話、加標點。
/// 其他改動（加字、換成不同音的字、刪掉一般的字）都當模型自己編的，整句退回原文。
/// 3B 模型不加這層會把「他說他」寫成「他說」、「賭住了」寫成「壞了」。
public enum VoicePolishGuard {
    static let fillers = ["就是說", "然後", "那個", "就是", "嗯", "呃", "啊", "喔"]
    static let punctuation = Set("，。！？、：；「」…,.!?:; \n")

    public static func isSafe(original: String, polished: String, lexicon: Lexicon) -> Bool {
        let a = Array(original.filter { !punctuation.contains($0) })
        let b = Array(polished.filter { !punctuation.contains($0) })
        // reach[i][j]：原文前 i 字能不能變成整理後前 j 字
        var reach = Array(repeating: Array(repeating: false, count: b.count + 1), count: a.count + 1)
        reach[0][0] = true
        for i in 0...a.count {
            for j in 0...b.count where reach[i][j] {
                if i < a.count, j < b.count, lexicon.soundsAlike(a[i], b[j]) { reach[i + 1][j + 1] = true }
                for filler in fillers where a[i...].starts(with: filler) { reach[i + filler.count][j] = true }
                // 重複的話（「這個這個」）：跟前面一模一樣的一段可以刪
                for k in 1...4 where i >= k && i + k <= a.count && a[(i - k)..<i] == a[i..<(i + k)] {
                    reach[i + k][j] = true
                }
            }
        }
        return reach[a.count][b.count]
    }
}
