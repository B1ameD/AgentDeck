import AppKit

/// 把 ASCII 标量取成 UTF-16 码元（unichar）。`UInt16` 没有 `init(ascii:)`，故用标量值转。
private func codeUnit(_ scalar: Unicode.Scalar) -> UInt16 {
    UInt16(truncatingIfNeeded: scalar.value)
}

/// 代码块语法配色（按 CodeBlockTheme 的浅/深取色）。plain（普通标识符）沿用代码块前景色，不在此列。
struct CodeSyntaxPalette: Equatable {
    let keyword: NSColor
    let type: NSColor
    let string: NSColor
    let number: NSColor
    let comment: NSColor
}

/// 轻量语法高亮：单遍扫描器，按语言识别注释 / 字符串 / 数字 / 关键字 / 类型（首字母大写启发）。
/// 纯函数、不依赖任何 UI，返回相对 code 字符串（UTF-16）的 [(范围, 颜色)]，便于测试与缓存。
/// 目标是「看起来像编辑器」，而非完整语法解析——故对个别边角（如 shell 的 `$#`）容忍轻微误染。
enum CodeSyntaxHighlighter {
    static func highlights(
        code: String,
        language: String?,
        palette: CodeSyntaxPalette
    ) -> [(range: NSRange, color: NSColor)] {
        let profile = LangProfile.resolve(language)
        let ns = code as NSString
        let length = ns.length
        var spans: [(NSRange, NSColor)] = []
        var i = 0

        while i < length {
            let c = ns.character(at: i)

            // 行注释（// 或 # 或 -- …，按语言）。
            if let tokenLength = profile.lineCommentLength(at: i, in: ns) {
                let start = i
                i += tokenLength
                while i < length, ns.character(at: i) != newline { i += 1 }
                spans.append((NSRange(location: start, length: i - start), palette.comment))
                continue
            }

            // 块注释 /* … */。
            if profile.blockComment, c == slash, i + 1 < length, ns.character(at: i + 1) == star {
                let start = i
                i += 2
                while i < length {
                    if ns.character(at: i) == star, i + 1 < length, ns.character(at: i + 1) == slash {
                        i += 2
                        break
                    }
                    i += 1
                }
                spans.append((NSRange(location: start, length: i - start), palette.comment))
                continue
            }

            // 字符串 " ' `（含三引号）。
            if c == doubleQuote || c == singleQuote || c == backtick {
                let consumed = scanStringLength(ns, from: i, quote: c, tripleQuote: profile.tripleQuote)
                spans.append((NSRange(location: i, length: consumed), palette.string))
                i += max(consumed, 1)
                continue
            }

            // 数字。
            if isDigit(c) || (c == dot && i + 1 < length && isDigit(ns.character(at: i + 1))) {
                let start = i
                i = scanNumberEnd(ns, from: i)
                spans.append((NSRange(location: start, length: i - start), palette.number))
                continue
            }

            // 标识符 → 关键字 / 类型 / 普通。
            if isIdentifierStart(c) {
                let start = i
                i += 1
                while i < length, isIdentifierChar(ns.character(at: i)) { i += 1 }
                let word = ns.substring(with: NSRange(location: start, length: i - start))
                let lookup = profile.caseInsensitive ? word.lowercased() : word
                if profile.keywords.contains(lookup) {
                    spans.append((NSRange(location: start, length: i - start), palette.keyword))
                } else if profile.highlightTypes, let first = word.first, first.isUppercase, first.isLetter {
                    spans.append((NSRange(location: start, length: i - start), palette.type))
                }
                continue
            }

            i += 1
        }

        return spans
    }

    // MARK: - 扫描

    /// 字符串长度（含两端引号）。处理 \\ 转义；三引号成对闭合；普通引号未闭合则止于行尾（避免染红整段）。
    private static func scanStringLength(_ ns: NSString, from start: Int, quote: unichar, tripleQuote: Bool) -> Int {
        let length = ns.length

        if tripleQuote, start + 2 < length,
           ns.character(at: start + 1) == quote, ns.character(at: start + 2) == quote {
            var i = start + 3
            while i < length {
                if ns.character(at: i) == backslash { i += 2; continue }
                if ns.character(at: i) == quote, i + 2 < length,
                   ns.character(at: i + 1) == quote, ns.character(at: i + 2) == quote {
                    return (i + 3) - start
                }
                i += 1
            }
            return length - start
        }

        let allowMultiline = (quote == backtick)
        var i = start + 1
        while i < length {
            let ch = ns.character(at: i)
            if ch == backslash { i += 2; continue }
            if ch == quote { return (i + 1) - start }
            if !allowMultiline, ch == newline { return i - start }
            i += 1
        }
        return length - start
    }

    private static func scanNumberEnd(_ ns: NSString, from start: Int) -> Int {
        let length = ns.length
        var i = start

        // 0x / 0b / 0o 前缀。
        if i + 1 < length, ns.character(at: i) == zero {
            let p = ns.character(at: i + 1)
            if p == codeUnit("x") || p == codeUnit("X")
                || p == codeUnit("b") || p == codeUnit("B")
                || p == codeUnit("o") || p == codeUnit("O") {
                i += 2
                while i < length, isHexDigitOrSeparator(ns.character(at: i)) { i += 1 }
                return i
            }
        }

        while i < length {
            let c = ns.character(at: i)
            if isDigit(c) || c == dot || c == underscore {
                i += 1
            } else if c == codeUnit("e") || c == codeUnit("E") {
                i += 1
                if i < length, ns.character(at: i) == plus || ns.character(at: i) == minus { i += 1 }
            } else {
                break
            }
        }
        // 数字后缀字母（f/F d/D l/L u/U）。
        while i < length, isNumericSuffix(ns.character(at: i)) { i += 1 }
        return max(i, start + 1)
    }

    // MARK: - unichar 判定

    private static let newline = codeUnit("\n")
    private static let slash = codeUnit("/")
    private static let star = codeUnit("*")
    private static let dot = codeUnit(".")
    private static let underscore = codeUnit("_")
    private static let zero = codeUnit("0")
    private static let plus = codeUnit("+")
    private static let minus = codeUnit("-")
    private static let backslash = codeUnit("\\")
    private static let doubleQuote = codeUnit("\"")
    private static let singleQuote = codeUnit("'")
    private static let backtick = codeUnit("`")

    private static func isDigit(_ c: unichar) -> Bool {
        c >= codeUnit("0") && c <= codeUnit("9")
    }

    private static func isHexDigitOrSeparator(_ c: unichar) -> Bool {
        isDigit(c) || c == underscore || c == dot
            || (c >= codeUnit("a") && c <= codeUnit("f"))
            || (c >= codeUnit("A") && c <= codeUnit("F"))
    }

    private static func isNumericSuffix(_ c: unichar) -> Bool {
        switch c {
        case codeUnit("f"), codeUnit("F"),
             codeUnit("d"), codeUnit("D"),
             codeUnit("l"), codeUnit("L"),
             codeUnit("u"), codeUnit("U"):
            return true
        default:
            return false
        }
    }

    private static func isIdentifierStart(_ c: unichar) -> Bool {
        (c >= codeUnit("a") && c <= codeUnit("z"))
            || (c >= codeUnit("A") && c <= codeUnit("Z"))
            || c == underscore || c == codeUnit("$") || c > 0x7F
    }

    private static func isIdentifierChar(_ c: unichar) -> Bool {
        isIdentifierStart(c) || isDigit(c)
    }
}

/// 每种语言的注释/关键字配置。`resolve(_:)` 把围栏语言串（含常见别名）映射到一份配置。
private struct LangProfile {
    let keywords: Set<String>
    let lineComments: [String]
    let blockComment: Bool
    let tripleQuote: Bool
    let highlightTypes: Bool
    let caseInsensitive: Bool

    init(
        keywords: Set<String>,
        lineComments: [String] = ["//"],
        blockComment: Bool = true,
        tripleQuote: Bool = false,
        highlightTypes: Bool = true,
        caseInsensitive: Bool = false
    ) {
        self.keywords = keywords
        self.lineComments = lineComments
        self.blockComment = blockComment
        self.tripleQuote = tripleQuote
        self.highlightTypes = highlightTypes
        self.caseInsensitive = caseInsensitive
    }

    func lineCommentLength(at index: Int, in ns: NSString) -> Int? {
        for token in lineComments where Self.matches(ns, at: index, token: token) {
            return token.utf16.count
        }
        return nil
    }

    private static func matches(_ ns: NSString, at index: Int, token: String) -> Bool {
        let units = Array(token.utf16)
        guard index + units.count <= ns.length else { return false }
        for (offset, unit) in units.enumerated() where ns.character(at: index + offset) != unit {
            return false
        }
        return true
    }

    static func resolve(_ language: String?) -> LangProfile {
        let key = (language ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        switch key {
        case "swift":
            return LangProfile(keywords: set(swift), tripleQuote: true)
        case "js", "javascript", "jsx", "mjs", "cjs", "node",
             "ts", "typescript", "tsx":
            return LangProfile(keywords: set(javascript))
        case "py", "python", "python3":
            return LangProfile(keywords: set(python), lineComments: ["#"], blockComment: false, tripleQuote: true)
        case "go", "golang":
            return LangProfile(keywords: set(go), tripleQuote: false)
        case "rust", "rs":
            return LangProfile(keywords: set(rust))
        case "java", "kt", "kotlin", "scala", "groovy":
            return LangProfile(keywords: set(jvm))
        case "c", "h", "cpp", "c++", "cc", "cxx", "hpp", "hh",
             "objc", "objective-c", "m", "mm", "cs", "csharp":
            return LangProfile(keywords: set(clike))
        case "rb", "ruby":
            return LangProfile(keywords: set(ruby), lineComments: ["#"], blockComment: false)
        case "sh", "bash", "zsh", "shell", "shellscript", "console", "fish", "ksh":
            return LangProfile(keywords: set(shell), lineComments: ["#"], blockComment: false, highlightTypes: false)
        case "php":
            return LangProfile(keywords: set(php), lineComments: ["//", "#"])
        case "json", "jsonc", "json5":
            return LangProfile(keywords: set("true false null"), lineComments: ["//"], highlightTypes: false)
        case "yaml", "yml", "toml", "ini", "conf", "cfg", "properties",
             "dockerfile", "makefile", "make", "env", "gitignore":
            return LangProfile(keywords: set("true false null yes no on off"), lineComments: ["#"], blockComment: false, highlightTypes: false)
        case "sql", "mysql", "postgres", "postgresql", "sqlite", "plsql":
            return LangProfile(keywords: set(sql), lineComments: ["--"], highlightTypes: false, caseInsensitive: true)
        case "css", "scss", "sass", "less":
            return LangProfile(keywords: set(""), lineComments: ["//"], highlightTypes: false)
        case "html", "xml", "svg", "vue", "svelte", "xhtml", "plist":
            return LangProfile(keywords: set(""), lineComments: [], blockComment: false, highlightTypes: false)
        default:
            // 未知语言：保守地用 // 行注释 + 块注释 + 一份通用关键字并集，避免把 `#include` 误当注释。
            return LangProfile(keywords: set(generic))
        }
    }

    private static func set(_ words: String) -> Set<String> {
        Set(words.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))
    }

    // MARK: - 关键字表（够用即可，不追求穷尽）

    private static let swift = """
    associatedtype class deinit enum extension fileprivate func import init inout internal let open operator
    private precedencegroup protocol public rethrows static struct subscript typealias var actor
    break case continue default defer do else fallthrough for guard if in repeat return switch where while
    as catch dynamicType is rethrows super throw throws try await async
    Any false nil self Self true _ some any weak unowned mutating nonmutating override final lazy convenience required
    """

    private static let javascript = """
    abstract any as async await boolean break case catch class const continue debugger declare default delete do
    else enum export extends false finally for from function get if implements import in instanceof interface let
    namespace new null number of package private protected public readonly return set static string super switch this
    throw true try type typeof undefined var void while with yield keyof never unknown infer satisfies as
    """

    private static let python = """
    False None True and as assert async await break class continue def del elif else except finally for from global
    if import in is lambda nonlocal not or pass raise return try while with yield match case self cls
    """

    private static let go = """
    break case chan const continue default defer else fallthrough for func go goto if import interface map package
    range return select struct switch type var nil true false iota append cap close complex copy delete len make new
    """

    private static let rust = """
    as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move
    mut pub ref return self Self static struct super trait true type unsafe use where while box union
    """

    private static let jvm = """
    abstract assert boolean break byte case catch char class const continue default do double else enum extends final
    finally float for if implements import instanceof int interface long native new package private protected public
    return short static strictfp super switch synchronized this throw throws transient try void volatile while var val
    fun when object companion data sealed null true false override open lateinit suspend inline reified internal
    """

    private static let clike = """
    alignas alignof auto bool break case catch char class const constexpr continue decltype default delete do double
    else enum explicit export extern false float for friend goto if inline int long mutable namespace new noexcept
    nullptr operator private protected public register return short signed sizeof static struct switch template this
    throw true try typedef typename union unsigned using virtual void volatile while string var let async await foreach
    """

    private static let ruby = """
    alias and begin break case class def defined do else elsif end ensure false for if in module next nil not or redo
    rescue retry return self super then true undef unless until when while yield require require_relative attr_accessor
    attr_reader attr_writer lambda proc puts
    """

    private static let shell = """
    if then else elif fi case esac for while until do done in function select time echo cd export local return read
    set unset trap source alias eval exec exit shift test printf declare typeset
    """

    private static let php = """
    abstract and array as break callable case catch class clone const continue declare default do echo else elseif
    empty enddeclare endfor endforeach endif endswitch endwhile extends final finally fn for foreach function global
    goto if implements include include_once instanceof insteadof interface isset list match namespace new or print
    private protected public require require_once return static switch throw trait try unset use var while yield true
    false null self parent
    """

    private static let sql = """
    select from where insert update delete create table drop alter join inner left right outer full on group by order
    having limit offset as and or not null is in like between values into set distinct union all index view primary
    key foreign references default constraint unique check cascade begin commit rollback transaction case when then
    else end exists with returning
    """

    private static let generic = """
    if else for while do switch case default break continue return function func def class struct enum interface
    import export from package namespace public private protected static const let var new delete try catch finally
    throw true false null nil none void int float double bool string char this self super async await yield type
    """
}
