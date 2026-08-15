/// 大千（標準）注音鍵盤配置。
/// 鍵序可對照小麥 BPMFBase.txt 第 4 欄驗證（例：吧 ㄅㄚ˙ → 鍵序 187）。
public enum DachenLayout {

    public static func component(for key: Character) -> ZhuyinComponent? {
        table[key]
    }

    private static let table: [Character: ZhuyinComponent] = [
        // 數字列
        "1": .initial(.b), "2": .initial(.d), "3": .tone(.tone3), "4": .tone(.tone4),
        "5": .initial(.zh), "6": .tone(.tone2), "7": .tone(.tone5),
        "8": .final(.a), "9": .final(.ai), "0": .final(.an), "-": .final(.er),
        // 上排
        "q": .initial(.p), "w": .initial(.t), "e": .initial(.g), "r": .initial(.j),
        "t": .initial(.ch), "y": .initial(.z), "u": .medial(.i), "i": .final(.o),
        "o": .final(.ei), "p": .final(.en),
        // 中排
        "a": .initial(.m), "s": .initial(.n), "d": .initial(.k), "f": .initial(.q),
        "g": .initial(.sh), "h": .initial(.c), "j": .medial(.u), "k": .final(.e),
        "l": .final(.ao), ";": .final(.ang),
        // 下排
        "z": .initial(.f), "x": .initial(.l), "c": .initial(.h), "v": .initial(.x),
        "b": .initial(.r), "n": .initial(.s), "m": .medial(.yu), ",": .final(.eh),
        ".": .final(.ou), "/": .final(.eng),
        // 一聲
        " ": .tone(.tone1),
    ]
}
