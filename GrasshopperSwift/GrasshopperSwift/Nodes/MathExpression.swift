import Foundation

/// A small arithmetic-expression parser/evaluator backing the Expression node.
///
/// Every single letter in the expression is treated as its own variable
/// (implicit multiplication between adjacent letters/numbers/parens, e.g.
/// "2x(y+1)" == 2*x*(y+1)) — except the reserved words "e" and "pi"
/// (case-insensitive), which resolve to Euler's number and Pi instead of
/// becoming variables.
enum MathExpression {
    /// Distinct variable letters referenced by `text`, in order of first
    /// appearance, excluding the reserved constants "e" and "pi".
    static func variables(in text: String) -> [String] {
        var seen = Set<String>()
        var order: [String] = []
        for token in tokenize(text) {
            if case .variable(let name) = token, !seen.contains(name) {
                seen.insert(name)
                order.append(name)
            }
        }
        return order
    }

    /// Evaluates `text` with the given variable bindings (missing variables
    /// default to 0). Returns `nil` if the expression can't be parsed.
    static func evaluate(_ text: String, variables values: [String: Double]) -> Double? {
        guard let ast = try? parse(text) else { return nil }
        return evaluate(ast, variables: values)
    }

    // MARK: - AST

    private indirect enum ExprNode {
        case number(Double)
        case constant(Double)
        case variable(String)
        case negate(ExprNode)
        case add(ExprNode, ExprNode)
        case subtract(ExprNode, ExprNode)
        case multiply(ExprNode, ExprNode)
        case divide(ExprNode, ExprNode)
        case power(ExprNode, ExprNode)
    }

    private enum ExpressionError: Error {
        case syntax
    }

    // MARK: - Lexer

    private enum Token: Equatable {
        case number(Double)
        case variable(String)
        case constantPi
        case constantE
        case plus, minus, star, slash, caret
        case lparen, rparen
    }

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace {
                i += 1
                continue
            }
            if c.isNumber || c == "." {
                var j = i
                while j < chars.count, chars[j].isNumber || chars[j] == "." { j += 1 }
                if let v = Double(String(chars[i..<j])) { tokens.append(.number(v)) }
                i = j
                continue
            }
            if c.isLetter {
                // Greedily match the reserved two-letter constant "pi" before
                // falling back to single-letter variables — this is what
                // keeps "pi" from becoming two input ports (p, i).
                if i + 1 < chars.count, String([c, chars[i + 1]]).lowercased() == "pi" {
                    tokens.append(.constantPi)
                    i += 2
                    continue
                }
                if c.lowercased() == "e" {
                    tokens.append(.constantE)
                    i += 1
                    continue
                }
                tokens.append(.variable(String(c)))
                i += 1
                continue
            }
            switch c {
            case "+": tokens.append(.plus)
            case "-": tokens.append(.minus)
            case "*", "×": tokens.append(.star)
            case "/", "÷": tokens.append(.slash)
            case "^": tokens.append(.caret)
            case "(": tokens.append(.lparen)
            case ")": tokens.append(.rparen)
            default: break // ignore stray punctuation (commas, etc.)
            }
            i += 1
        }
        return tokens
    }

    // MARK: - Parser (recursive descent, right-assoc power, implicit multiplication)

    private static func parse(_ text: String) throws -> ExprNode {
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { throw ExpressionError.syntax }
        var pos = 0

        func peek() -> Token? { pos < tokens.count ? tokens[pos] : nil }

        func startsImplicitFactor(_ t: Token?) -> Bool {
            switch t {
            case .number, .variable, .constantPi, .constantE, .lparen: return true
            default: return false
            }
        }

        func parsePrimary() throws -> ExprNode {
            guard pos < tokens.count else { throw ExpressionError.syntax }
            let t = tokens[pos]
            pos += 1
            switch t {
            case .number(let v): return .number(v)
            case .variable(let name): return .variable(name)
            case .constantPi: return .constant(.pi)
            case .constantE: return .constant(M_E)
            case .lparen:
                let inner = try parseExpr()
                guard pos < tokens.count, tokens[pos] == .rparen else { throw ExpressionError.syntax }
                pos += 1
                return inner
            default:
                throw ExpressionError.syntax
            }
        }

        func parsePower() throws -> ExprNode {
            let base = try parsePrimary()
            if peek() == .caret {
                pos += 1
                let exponent = try parseUnary() // right-associative
                return .power(base, exponent)
            }
            return base
        }

        func parseUnary() throws -> ExprNode {
            if peek() == .minus {
                pos += 1
                return .negate(try parseUnary())
            }
            if peek() == .plus {
                pos += 1
                return try parseUnary()
            }
            return try parsePower()
        }

        func parseTerm() throws -> ExprNode {
            var node = try parseUnary()
            while true {
                if peek() == .star {
                    pos += 1
                    node = .multiply(node, try parseUnary())
                } else if peek() == .slash {
                    pos += 1
                    node = .divide(node, try parseUnary())
                } else if startsImplicitFactor(peek()) {
                    node = .multiply(node, try parseUnary())
                } else {
                    break
                }
            }
            return node
        }

        func parseExpr() throws -> ExprNode {
            var node = try parseTerm()
            while true {
                if peek() == .plus {
                    pos += 1
                    node = .add(node, try parseTerm())
                } else if peek() == .minus {
                    pos += 1
                    node = .subtract(node, try parseTerm())
                } else {
                    break
                }
            }
            return node
        }

        let result = try parseExpr()
        guard pos == tokens.count else { throw ExpressionError.syntax }
        return result
    }

    private static func evaluate(_ node: ExprNode, variables: [String: Double]) -> Double? {
        switch node {
        case .number(let v): return v
        case .constant(let v): return v
        case .variable(let name): return variables[name] ?? 0
        case .negate(let a):
            return evaluate(a, variables: variables).map { -$0 }
        case .add(let a, let b):
            guard let av = evaluate(a, variables: variables), let bv = evaluate(b, variables: variables) else { return nil }
            return av + bv
        case .subtract(let a, let b):
            guard let av = evaluate(a, variables: variables), let bv = evaluate(b, variables: variables) else { return nil }
            return av - bv
        case .multiply(let a, let b):
            guard let av = evaluate(a, variables: variables), let bv = evaluate(b, variables: variables) else { return nil }
            return av * bv
        case .divide(let a, let b):
            guard let av = evaluate(a, variables: variables), let bv = evaluate(b, variables: variables), bv != 0 else { return nil }
            return av / bv
        case .power(let a, let b):
            guard let av = evaluate(a, variables: variables), let bv = evaluate(b, variables: variables) else { return nil }
            return pow(av, bv)
        }
    }
}
