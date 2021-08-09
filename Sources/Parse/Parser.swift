import AST
import Basic

/// The parser for Val source code.
public struct Parser {

  /// The internal state of a parser.
  fileprivate struct State {

    /// A Boolean value that indicates whether the parser encountered an error.
    var hasError = false

    /// The declaration space in which new declarations are being parsed.
    var declSpace: DeclSpace?

    /// The parser's lexer.
    var lexer: Lexer

    /// The lookahead buffer.
    var lookahead: Token?

    /// The flags of the parser's state.
    var flags = Flags.isParsingTopLevel

    /// Returns the next element in the token stream, without consuming it.
    mutating func peek() -> Token? {
      // Return the token in the lookahead buffer, if available.
      if let token = lookahead {
        return token
      }

      // Attempt to pull a new element from the lexer.
      guard let token = lexer.next() else { return nil }
      lookahead = token
      return token
    }

    /// Consumes the next element from the token stream.
    mutating func take() -> Token? {
      if let token = lookahead {
        lookahead = nil
        return token
      } else {
        return lexer.next()
      }
    }

    /// Consumes the next element from the token stream, if it has the specified kind.
    mutating func take(_ kind: Token.Kind) -> Token? {
      return peek()?.kind == kind
        ? take()
        : nil
    }

    /// Consumes the next element from the token stream, if it satisfies the specified predicate.
    mutating func take(if predicate: (Token) -> Bool) -> Token? {
      guard let token = peek() else { return nil }
      return predicate(token)
        ? take()
        : nil
    }

    /// Consumes an operator from the token stream.
    ///
    /// If the next token in the stream is an angle bracket, it is interpreter as an operator and
    /// merged with any attached operator.
    ///
    /// - Parameter includingAssign: A flag that indicates whether `=` should be consumed.
    mutating func takeOperator(includingAssign: Bool = true) -> Ident? {
      guard let head = peek() else { return nil }

      switch head.kind {
      case .oper:
        _ = take()
        return ident(head)

      case .assign where includingAssign:
        _ = take()
        return ident(head)

      case .lAngle, .rAngle:
        _ = take()

        // Merge the leading angle bracket with attached operators.
        var upper = head.range.upperBound
        while let next = peek(), next.isOperator && (upper == next.range.lowerBound) {
          upper = next.range.upperBound
        }

        let range = head.range.lowerBound ..< upper
        return Ident(name: String(lexer.source[range]), range: range)

      default:
        return nil
      }
    }

    /// Consumes the stream token as long as the specified predicate is satisfied.
    mutating func skip(while predicate: (Token) -> Bool) {
      while let token = peek(), predicate(token) {
        _ = take()
      }
    }

    /// Creates a save point to restore the state.
    func save() -> State { self }

    /// Restores the state to the specified backup.
    mutating func restore(_ backup: State) {
      self = backup
    }

    /// Creates an identifier from the specified token.
    func ident(_ token: Token) -> Ident {
      let name = lexer.source[token.range]
      return Ident(name: String(name), range: token.range)
    }

    /// Returns a source range suitable to report an error at the current stream position.
    mutating func errorRange() -> SourceRange {
      return peek()?.range ?? (lexer.source.endIndex ..< lexer.source.endIndex)
    }

  }

  /// The flags of a parser's state.
  fileprivate struct Flags {

    private var rawValue: UInt8

    static func + (lhs: Flags, rhs: Flags) -> Flags {
      return Flags(rawValue: lhs.rawValue | rhs.rawValue)
    }

    static func & (lhs: Flags, rhs: Flags) -> Bool {
      return (lhs.rawValue & rhs.rawValue) != 0
    }

    static let isParsingTopLevel  = Flags(rawValue: 1 << 0)
    static let isParsingProdBody  = Flags(rawValue: 1 << 1)
    static let isParsingViewBody  = Flags(rawValue: 1 << 2)
    static let isParsingExtnBody  = Flags(rawValue: 1 << 3)
    static let isParsingFunBody   = Flags(rawValue: 1 << 4)
    static let isParsingLoopBody  = Flags(rawValue: 1 << 5)

    static let isParsingTypeBody  = isParsingProdBody + isParsingViewBody + isParsingExtnBody

  }

  /// The AST context in which the parser operates.
  public let context: Context

  /// An alias to the context's unresolved type.
  private var unresolved: UnresolvedType { context.unresolvedType }

  /// Creates a parser.
  ///
  /// - Parameter context: The AST context in which source files will be parsed.
  public init(context: Context) {
    self.context = context
  }

  /// Parses the specified source file.
  ///
  /// - Parameters:
  ///   - source: A source file.
  ///   - context: The AST context in which the source file is parsed.
  public func parse(source: SourceFile) -> (unit: SourceUnit, hasError: Bool) {
    let unit = SourceUnit(source: source)
    var state = State(declSpace: unit, lexer: Lexer(source: source))

    while true {
      // Skip leading semicolons and exit the loop once we've reached the end of the stream
      state.skip(while: { $0.kind == .semi })
      guard state.peek() != nil else { break }

      // Parse a declaration.
      do {
        guard let decl = try parseDecl(state: &state) else {
          throw ParseError(Diagnostic("expected declaration", anchor: state.errorRange()))
        }
        unit.decls.append(decl)
      } catch let error as ParseError {
        context.report(error.diag)
        state.hasError = true
        state.skip(while: { !$0.isOf(kind: [.semi, .rBrace]) && !$0.mayBeginDecl })
      } catch {
        fatalError("unreachable")
      }
    }

    return (unit, state.hasError)
  }

  /// Parses a declaration.
  ///
  ///     decl ::= decl-modifier* (binding-decl | fun-decl | type-decl | extn-decl | oper-decl)
  private func parseDecl(state: inout State) throws -> Decl? {
    // Consume a list of declaration modifiers.
    var kinds: Set<DeclModifier.Kind> = []
    var modifiers: [DeclModifier] = []

    loop:while let token = state.peek() {
      let m: DeclModifier
      switch token.kind {
      case .pub     : m = DeclModifier(kind: .pub     , range: token.range)
      case .mod     : m = DeclModifier(kind: .mod     , range: token.range)
      case .mut     : m = DeclModifier(kind: .mut     , range: token.range)
      case .infix   : m = DeclModifier(kind: .infix   , range: token.range)
      case .prefix  : m = DeclModifier(kind: .prefix  , range: token.range)
      case .postfix : m = DeclModifier(kind: .postfix , range: token.range)
      case .volatile: m = DeclModifier(kind: .volatile, range: token.range)
      case .static  : m = DeclModifier(kind: .static  , range: token.range)
      case .moveonly: m = DeclModifier(kind: .moveonly, range: token.range)
      default       : break loop
      }
      _ = state.take()

      guard kinds.insert(m.kind).inserted else {
        context.report(
          "ignoring duplicate modifier \(m.kind)", level: .warning, anchor: token.range)
        continue
      }

      // 'pub' and 'mod' are mutually exclusive.
      guard ((m.kind != .pub) || !kinds.contains(.mod)),
            ((m.kind != .mod) || !kinds.contains(.pub))
      else {
        context.report(
          "'pub' and 'mod' modifiers are mutually exclusive", anchor: token.range)
        state.hasError = true
        continue
      }

      // 'infix', 'prefix' and 'postfix' are mutually exclusive.
      guard ((m.kind != .infix)   || !kinds.contains(.prefix) && !kinds.contains(.postfix)),
            ((m.kind != .prefix)  || !kinds.contains(.infix)  && !kinds.contains(.postfix)),
            ((m.kind != .postfix) || !kinds.contains(.infix)  && !kinds.contains(.prefix))
      else {
        context.report(
          "'infix', 'prefix' and 'postfix' modifiers are mutually exclusive", anchor: token.range)
        state.hasError = true
        continue
      }

      modifiers.append(m)
    }

    // Parse a declaration.
    let head = state.peek()
    switch head?.kind {
    case .val, .var:
      return parseBindingDecl(state: &state, rawModifiers: modifiers)

    case .fun, .new, .del:
      return parseFunDecl(state: &state, rawModifiers: modifiers)

    case .type:
      return parseTypeDecl(state: &state, rawModifiers: modifiers)

    case .view:
      if !(state.flags & .isParsingTopLevel) {
        context.report("view declarations can only appear at top level", anchor: head?.range)
        state.hasError = true
      }
      return parseTypeDecl(state: &state, rawModifiers: modifiers)

    case .extn:
      if !(state.flags & .isParsingTopLevel) {
        context.report("extensions can only appear at top level", anchor: head?.range)
        state.hasError = true
      }
      return parseTypeExtn(state: &state, rawModifiers: modifiers)

    default:
      // We must commit to a failure, unless we didn't parse any modifier.
      if let modifier = modifiers.last {
        throw ParseError(
          Diagnostic("expected declaration after \(modifier.kind)", anchor: state.errorRange()))
      } else {
        return nil
      }
    }
  }

  /// Parses a pattern binding declaration.
  ///
  ///     binding-decl ::= ('val' | 'var') NAME (':' sign)? ('=' expr)
  ///
  /// The next token is expected to be 'val' or 'var'.
  private func parseBindingDecl(
    state: inout State, rawModifiers: [DeclModifier]
  ) -> PatternBindingDecl {
    let introducer = state.take(if: { $0.kind == .val || $0.kind == .var })!
    let startRange = rawModifiers.isEmpty
      ? introducer.range
      : rawModifiers[0].range.lowerBound ..< introducer.range.upperBound

    // Filter out modifiers that are not applicable in this context.
    let modifiers = rawModifiers.filter({ (modifier: DeclModifier) -> Bool in
      switch modifier.kind {
      case .pub, .mod:
        guard !(state.flags & .isParsingViewBody) else {
          context.report(
            "'\(modifier.kind)' cannot be applied to property requirement", anchor: modifier.range)
          state.hasError = true
          return false
        }
        return true

      case .static:
        guard state.flags & .isParsingTypeBody else {
          context.report(
            "'static' is only allowed inside of a type", anchor: modifier.range)
          state.hasError = true
          return false
        }
        return true

      default:
        context.report(
          "'\(modifier.kind)' cannot be applied to this declaration", anchor: modifier.range)
        state.hasError = true
        return false
      }
    })

    // Create the declaration.
    let decl = PatternBindingDecl(
      modifiers: modifiers,
      isMutable: introducer.kind == .var,
      pattern: WildcardPattern(type: unresolved, range: state.errorRange()),
      sign: nil,
      initializer: nil,
      introRange: introducer.range,
      range: startRange)
    decl.parentDeclSpace = state.declSpace

    if let pattern = parsePattern(state: &state) {
      decl.pattern = pattern
      decl.range = decl.range ..< pattern.range

      // Associate each introduced variable declaration to the new pattern binding declaration.
      for name in decl.pattern.namedPatterns {
        name.decl.isMutable = decl.isMutable
        name.decl.patternBindingDecl = decl
        decl.varDecls.append(name.decl)
      }
    } else {
      context.report("expected pattern", anchor: state.errorRange())
      state.hasError = true
    }

    if state.take(.colon) != nil {
      // We've consumed a colon, so we're committed to parse a type signature.
      if let sign = parseSign(state: &state) {
        decl.sign = sign
        decl.range = decl.range ..< sign.range
      } else {
        context.report("expected type signature after ':'", anchor: state.errorRange())
        state.hasError = true
      }
    }

    if let assign = state.take(.assign) {
      // We've consumed an assignment operator, so we're committed to parse an initializer.
      if let expr = parseExpr(state: &state) {
        decl.initializer = expr
        decl.range = decl.range ..< expr.range
      } else {
        context.report("expected expression after '='", anchor: state.errorRange())
        state.hasError = true
      }

      if state.flags & .isParsingViewBody {
        context.report("property requirement cannot have an initializer", anchor: assign.range)
        state.hasError = true
      }
    }

    return decl
  }

  /// Parses a function declaration.
  ///
  ///     fun-decl ::= 'fun' fun-ident? generic-clause? fun-interface brace-stmt?
  ///     fun-ident ::= operator | NAME
  ///     fun-interface ::= param-decl-list ('->' sign)?
  ///
  /// The next token is expected to be 'fun', 'new' or 'del'.
  private func parseFunDecl(state: inout State, rawModifiers: [DeclModifier]) -> BaseFunDecl {
    let introducer = state.take(if: { $0.kind == .fun || $0.kind == .new || $0.kind == .del })!
    let startRange = rawModifiers.isEmpty
      ? introducer.range
      : rawModifiers[0].range.lowerBound ..< introducer.range.upperBound

    // Filter out the modifiers that are not applicable in this context.
    let modifiers = rawModifiers.filter({ (modifier: DeclModifier) -> Bool in
      switch modifier.kind {
      case .pub, .mod:
        guard introducer.kind != .del else {
          context.report(
            "'\(modifier.kind)' cannot be applied to destructor", anchor: modifier.range)
          state.hasError = true
          return false
        }
        guard !(state.flags & .isParsingViewBody) else {
          context.report(
            "'\(modifier.kind)' cannot be applied to function requirement", anchor: modifier.range)
          state.hasError = true
          return false
        }
        return true

      case .mut, .infix, .prefix, .postfix:
        guard introducer.kind == .fun,
              state.flags & .isParsingTypeBody,
              !rawModifiers.contains(where: { $0.kind == .static })
        else {
          context.report(
            "'\(modifier.kind) can only be applied to non-static member functions",
            anchor: modifier.range)
          state.hasError = true
          return false
        }
        return true

      case .static where introducer.kind == .fun:
        guard state.flags & .isParsingTypeBody else {
          context.report(
            "'static' is only allowed inside of a type", anchor: modifier.range)
          state.hasError = true
          return false
        }
        return true

      case .volatile where introducer.kind == .fun:
        guard !(state.flags & .isParsingTypeBody) else {
          context.report(
            "'volatile' can only be applied to free functions", anchor: modifier.range)
          state.hasError = true
          return false
        }
        return true

      default:
        context.report(
          "'\(modifier.kind)' cannot be applied to this declaration", anchor: modifier.range)
        state.hasError = true
        return false
      }
    })

    // Create the declaration.
    let decl: BaseFunDecl
    var isOperator = false

    switch introducer.kind {
    case .fun:
      decl = FunDecl(modifiers: modifiers, type: unresolved, range: startRange)

      if state.flags & .isParsingTypeBody {
        decl.props.insert(.isMember)
      }

      // The identifier of the function can be a name, or any non-cast operator.
      if let name = state.take(.name) {
        decl.ident = state.ident(name)
      } else if let oper = state.takeOperator() {
        decl.ident = oper
        isOperator = true

        if introducer.kind != .fun
            || !(state.flags & .isParsingTypeBody)
            || modifiers.contains(where: { $0.kind == .static })
        {
          context.report(
            "operator '\(oper.name)' must be declared as a non-static member function",
            anchor: oper.range)
          state.hasError = true
        }
      }

    case .new:
      decl = CtorDecl(
        modifiers: modifiers, type: unresolved, introRange: introducer.range, range: startRange)

      if !(state.flags & .isParsingTypeBody) {
        context.report("constructors are only allowed inside of a type", anchor: introducer.range)
        state.hasError = true
      }
      if let name = state.take(.name) {
        context.report("constructors cannot have a name", anchor: name.range)
        state.hasError = true
      }

    case .del:
      fatalError("not implemented")

    default:
      fatalError("unreachable")
    }

    decl.parentDeclSpace = state.declSpace
    state.declSpace = decl
    defer { state.declSpace = decl.parentDeclSpace }

    decl.genericClause = parseGenericClause(state: &state)

    if let (opener, params, closer) = list(
        state: &state, delimiters: (.lParen, .rParen), parser: parseParamDecl(state:))
    {
      decl.params = params
      decl.range = decl.range ..< (closer?.range ?? params.last?.range ?? opener.range)

      if isOperator {
        switch params.count {
        case 0 where !modifiers.contains(where: { $0.kind == .prefix || $0.kind == .postfix }):
          context.report(
            "unary operator declaration requires 'prefix' or 'postfix' modifier",
            anchor: introducer.range)
          state.hasError = true

        case 1:
          if let m = modifiers.first(where: { $0.kind == .prefix || $0.kind == .postfix }) {
            context.report("unary operator must have 0 parameter", anchor: m.range)
            state.hasError = true
          } else if let m = modifiers.first(where: { $0.kind == .infix }) {
            context.report(
              "extraneous modifier; binary operators are always infix",
              level: .warning,
              anchor: m.range)
          }

        default:
          context.report("operators must have 0 or 1 parameters", anchor: params[1].range)
          state.hasError = true
        }
      }
    } else {
      // We're missing the opening parenthesis of the parameter list. We'll pretend the user forgot
      // to define the function's parameters and try to recover before the arrow of the return type
      // signature, or before the opening brace of the function's body.
      context.report("expected parameter list", anchor: state.errorRange())
      state.hasError = true
      state.skip(while: {
        !$0.isOf(kind: [.semi, .rBrace]) && !$0.mayBeginDecl && !$0.mayBeginCtrlStmt
      })
    }

    if state.take(.arrow) != nil {
      // We've consumed an arrow operator, so we're committed to parse a type signature.
      if let sign = parseSign(state: &state) {
        decl.retSign = sign
        decl.range = decl.range ..< sign.range
      } else {
        context.report("expected return type signature after '->'", anchor: state.errorRange())
        state.hasError = true
        state.skip(while: {
          !$0.isOf(kind: [.semi, .rBrace]) && !$0.mayBeginDecl && !$0.mayBeginCtrlStmt
        })
      }
    }

    let oldFlags = state.flags
    state.flags = .isParsingFunBody
    if let body = parseBraceStmt(state: &state) {
      decl.body = body
      decl.range = decl.range ..< body.range
    }
    state.flags = oldFlags

    // Function declarations must have a body, unless they are defined within a view.
    if decl.body == nil && !(state.flags & .isParsingViewBody) {
      context.report("expected function body", anchor: state.errorRange())
      state.hasError = true
    }

    return decl
  }

  /// Parses a parameter declaration.
  ///
  ///     param-decl ::= (label | '_')? NAME ':' sign
  private func parseParamDecl(state: inout State) -> FunParamDecl? {
    // We assume that the first token corresponds to the external label. If the following token is
    // a name, then we can use it as the internal name. Owtherwise, we can use the first token both
    // the external label and the internal name.
    guard let external = state.take(if: { $0.kind == .under || $0.isLabel }) else { return nil }

    // Create the declaration.
    let decl = FunParamDecl(
      name: "", externalName: nil, typeSign: nil, type: unresolved, range: external.range)
    decl.parentDeclSpace = state.declSpace

    if let internal_ = state.take(.name) {
      // We parsed an external label *and* an internal identifier.
      decl.name = String(state.lexer.source[internal_.range])
      decl.range = external.range ..< internal_.range

      // Further, if the token for the external label is '_', the parameter is anonymous.
      if external.kind != .under {
        decl.externalName = String(state.lexer.source[external.range])
      }

      // Warn against identical extraneous parameter names.
      if decl.name == decl.externalName {
        context.report("extraneous parameter name", level: .warning, anchor: internal_.range)
      }
    } else {
      // The next token is a colon: the external label should be used as the parameter name.
      decl.name = String(state.lexer.source[external.range])
      decl.externalName = decl.name

      // Require that the parameter name be a valid identifier.
      if external.kind != .name {
        context.report("'\(decl.name)' is not a valid parameter name", anchor: external.range)
        state.hasError = true
      }
    }

    // Parse the type signature of the parameter.
    if state.take(.colon) != nil, let sign = parseSign(state: &state) {
      decl.sign = sign
      decl.range = external.range ..< sign.range
    } else {
      context.report("expected type signature", anchor: state.errorRange())
      state.hasError = true
    }

    return decl
  }

  /// Parses a type declaration.
  ///
  /// The next token is expected to be 'type' or 'view'.
  private func parseTypeDecl(state: inout State, rawModifiers: [DeclModifier]) -> TypeDecl {
    // All type declarations but views have similar prefixes. Thus, we must parse the "head" of the
    // declaration before we can instantiate a new declaration node. Unfortunately, that means that
    // we'll have to rebind the declaration space of the generic clause.
    let head = parseTypeDeclHead(state: &state)
    let startRange = rawModifiers.isEmpty
      ? head.introducer.range
      : rawModifiers[0].range.lowerBound ..< head.introducer.range.upperBound

    // Filter out the modifiers that are not applicable in this context.
    let modifiers = rawModifiers.filter({ (modifier: DeclModifier) -> Bool in
      switch modifier.kind {
      case .pub, .mod, .moveonly:
        return true

      default:
        context.report(
          "'\(modifier.kind)' cannot be applied to this declaration", anchor: modifier.range)
        state.hasError = true
        return false
      }
    })

    // If the introducer was 'view', then we know what we're parsing already.
    if head.introducer.kind == .view {
      let decl = ViewTypeDecl(name: head.ident.name, type: unresolved, range: startRange)
      decl.parentDeclSpace = state.declSpace
      decl.inheritances = head.inheritances
      decl.type = context.viewType(decl: decl).kind

      if let clause = head.genericClause {
        context.report(
          "view type declaration cannot have a generic clause, "
            + "declare abstract type requirements instead",
          anchor: clause.range)
        state.hasError = true
      }

      // Parse the members of the declaration.
      guard state.peek()?.kind == .lBrace else {
        context.report("expected view body", anchor: state.errorRange())
        state.hasError = true
        return decl
      }

      let before = (state.flags, state.declSpace)
      state.flags = .isParsingViewBody
      state.declSpace = decl
      defer { (state.flags, state.declSpace) = before }

      let body = parseDeclBody(state: &state)
      decl.members = body.members
      if let closer = body.closer {
        decl.range = startRange ..< closer.range
      }

      for case let member as TypeDecl in decl.members where !(member is AbstractTypeDecl) {
        context.report(
          "type '\(member.name)' cannot be nested in view '\(decl.name)'", anchor: member.range)
        state.hasError = true
      }

      return decl
    }

    // If the introducer was 'type', the next token determines what we're parsing.
    switch state.peek()?.kind {
    case .lBrace:
      // We're parsing a product type declaration.
      let decl = ProductTypeDecl(name: head.ident.name, type: unresolved, range: startRange)
      decl.parentDeclSpace = state.declSpace
      decl.inheritances = head.inheritances
      decl.type = context.productType(decl: decl).kind

      // Update the parent space of all type parameters of the generic clause.
      if let clause = head.genericClause {
        decl.genericClause = clause
        for param in clause.params {
          param.parentDeclSpace = decl
        }
      }

      // Parse the members of the declaration.
      let before = (state.flags, state.declSpace)
      state.flags = .isParsingProdBody
      state.declSpace = decl
      defer { (state.flags, state.declSpace) = before }

      let body = parseDeclBody(state: &state)
      decl.members = body.members
      if let closer = body.closer {
        decl.range = startRange ..< closer.range
      }

      for case let member as AbstractTypeDecl in decl.members {
        context.report("abstract types are only allowed inside of a view", anchor: member.range)
        state.hasError = true
      }

      return decl

    case .assign:
      // We're parsing a type alias declaration.
      _ = state.take()

      let sign = parseSign(state: &state) ?< { () -> Sign in
        context.report("expected type signature", anchor: state.errorRange())
        state.hasError = true
        return ErrorSign(type: context.errorType, range: state.errorRange())
      }

      let decl = AliasTypeDecl(
        name: head.ident.name,
        aliasedSign: sign,
        type: unresolved,
        range: startRange ..< sign.range)
      decl.parentDeclSpace = state.declSpace
      decl.inheritances = head.inheritances

      // Update the parent space of all type parameters of the generic clause.
      if let clause = head.genericClause {
        decl.genericClause = clause
        for param in clause.params {
          param.parentDeclSpace = decl
        }
      }

      return decl

    default:
      // We're most likely parsing an asbtract type declaration.
      let decl = AbstractTypeDecl(name: head.ident.name, type: unresolved, range: startRange)
      decl.parentDeclSpace = state.declSpace
      decl.inheritances = head.inheritances
      decl.type = context.genericParamType(decl: decl).kind

      if let clause = head.genericClause {
        context.report(
          "abstract type declaration cannot have a generic clause",
          anchor: clause.range)
        state.hasError = true
      }

      if state.take(.where) != nil {
        // We've consumed 'where', so we're committed to parse a type requirements.
        var mustParse = false
        while let typeReq = parseTypeReq(state: &state) {
          mustParse = false
          decl.typeReqs.append(typeReq)

          // If we consume a comma, then we're committed to parse another requirement.
          if state.take(.comma) != nil {
            mustParse = true
          } else {
            break
          }
        }

        if mustParse {
          context.report("expected type requirement", anchor: state.errorRange())
          state.hasError = true
          state.skip(while: { $0.kind == .comma })
        }
      }

      return decl
    }
  }

  /// Parses the head of a type or view declaration.
  ///
  ///     type-decl-head ::= 'type' NAME generic-clause? inheritance-list?
  ///     view-decl-head ::= 'view' NAME inheritance-list?
  ///
  /// The next token is expected to be 'type' or 'view'.
  private func parseTypeDeclHead(state: inout State) -> TypeDeclHead {
    let introducer = state.take(if: { $0.isOf(kind: [.type, .view]) })!

    let ident: Ident
    if let name = state.take(.name) {
      ident = state.ident(name)
    } else {
      context.report("expected type identifier", anchor: state.errorRange())
      state.hasError = true
      ident = Ident(name: "", range: state.errorRange())
    }

    let genericClause = parseGenericClause(state: &state)

    var inheritances: [IdentSign] = []
    if state.take(.colon) != nil {
      // We've consumed a colon, so we're committed to parse an inheritance list.
      var mustParse = true
      while let sign = parseSign(state: &state) {
        mustParse = false

        // The signature must designate an identifier. We can't inherit from a structural type.
        if let identSign = sign as? IdentSign {
          inheritances.append(identSign)
        } else {
          context.report("expected type identifier", anchor: sign.range)
          state.hasError = true
        }

        // If we consume a comma, then we're committed to parse another signature.
        if state.take(.comma) != nil {
          mustParse = true
        } else {
          break
        }
      }

      if mustParse {
        context.report("expected type identifier", anchor: state.errorRange())
        state.hasError = true
        state.skip(while: { $0.kind == .comma })
      }
    }

    return TypeDeclHead(
      introducer: introducer,
      ident: ident,
      genericClause: genericClause,
      inheritances: inheritances)
  }

  /// Parses the body of a product type or view declaration.
  ///
  ///     decl-body ::= '{' (decl ';'*)* ';'* '}'
  ///
  /// The next token is expected to be '{'. The caller is expected to set the appropriate
  /// parser flags (e.g., `isParsingProdBody`).
  private func parseDeclBody(state: inout State) -> (members: [Decl], closer: Token?) {
    _ = state.take(.lBrace)!

    var members: [Decl] = []
    while state.peek() != nil {
      // Skip leading semicolons and exit the loop once we've found a closing brace.
      state.skip(while: { $0.kind == .semi })
      if let closer = state.take(.rBrace) {
        return (members, closer)
      }

      // Parse a member.
      do {
        guard let member = try parseDecl(state: &state) else {
          throw ParseError(Diagnostic("expected declaration", anchor: state.errorRange()))
        }
        members.append(member)
      } catch let error as ParseError {
        context.report(error.diag)
        state.hasError = true
        state.skip(while: { !$0.isOf(kind: [.semi, .rBrace]) && !$0.mayBeginDecl })
      } catch {
        fatalError("unreachable")
      }
    }

    return (members, nil)
  }

  /// Parses a type extension.
  ///
  ///     type-extn-decl ::= 'extn' compound-ident-sign decl-body
  ///
  /// The next token is expected to be 'extn'.
  private func parseTypeExtn(state: inout State, rawModifiers: [DeclModifier]) -> TypeExtnDecl {
    let introducer = state.take(.extn)!
    let startRange = rawModifiers.isEmpty
      ? introducer.range
      : rawModifiers[0].range.lowerBound ..< introducer.range.upperBound

    for modifier in rawModifiers {
      context.report(
        "'\(modifier.kind)' cannot be applied to this declaration", anchor: modifier.range)
      state.hasError = true
    }

    let identSign: IdentSign
    switch parseSign(state: &state) {
    case let i as IdentSign:
      identSign = i

    case .some(let sign):
      identSign = BareIdentSign(ident: Ident(name: "", range: sign.range), type: context.errorType)

    case nil:
      context.report("expected type identifier", anchor: state.errorRange())
      state.hasError = true
      identSign = BareIdentSign(
        ident: Ident(name: "", range: state.errorRange()),
        type: context.errorType)
    }

    // Create the declaration.
    let decl = TypeExtnDecl(extendedIdent: identSign, members: [], range: startRange)
    decl.parentDeclSpace = state.declSpace

    // Parse the members of the declaration.
    let before = (state.flags, state.declSpace)
    state.flags = .isParsingExtnBody
    state.declSpace = decl
    defer { (state.flags, state.declSpace) = before }

    let body = parseDeclBody(state: &state)
    decl.members = body.members
    if let closer = body.closer {
      decl.range = startRange ..< closer.range
    }

    return decl
  }

  /// Parses a generic clause.
  ///
  ///     generic-clause ::= '<' generic-param-list type-req-clause? '>'
  ///     generic-param-list ::= NAME (',' NAME)* ','?
  ///     type-req-clause ::= 'where' type-req (',' type-req)* ','?
  private func parseGenericClause(state: inout State) -> GenericClause? {
    guard let opener = state.take(.lAngle) else { return nil }

    let clause = GenericClause(params: [], typeReqs: [], range: opener.range)

    // Parse a list of generic parameter names.
    while let token = state.take(.name) {
      let decl = GenericParamDecl(
        name: String(state.lexer.source[token.range]),
        type: unresolved,
        range: token.range)
      decl.parentDeclSpace = state.declSpace
      decl.type = context.genericParamType(decl: decl).kind
      clause.params.append(decl)

      guard state.take(.comma) != nil else { break }
    }

    // Parse a type requirement clause.
    if state.take(.where) != nil {
      while let typeReq = parseTypeReq(state: &state) {
        clause.typeReqs.append(typeReq)
        guard state.take(.comma) != nil else { break }
      }
    }

    let closer = state.take(.rAngle)
    if closer == nil {
      context.report("expected '>' delimiter", anchor: state.errorRange())
      state.hasError = true
    }

    let endRange = closer?.range
      ?? clause.typeReqs.last?.range
      ?? clause.params.last?.range
      ?? opener.range
    clause.range = opener.range ..< endRange
    return clause
  }

  /// Parses a type requirement.
  ///
  ///     type-req ::= same-req | conf-req
  ///     same-req ::= compound-ident-sign '==' sign
  ///     conf-req ::= compound-ident-sign ':' sign
  private func parseTypeReq(state: inout State) -> TypeReq? {
    guard let lhs = parseCompoundIdentSign(state: &state) else { return nil }

    // Handle failures to parse a type identifier.
    let identSign = (lhs as? IdentSign) ?? BareIdentSign(
      ident: Ident(name: "", range: lhs.range),
      type: context.errorType)

    // Identify the type of requirement we're parsing.
    let kind: TypeReq.Kind

    let oper = state.peek()
    switch oper?.kind {
    case .oper where state.lexer.source[oper!.range] == "==":
      _ = state.take()
      kind = .equality

    case .colon:
      _ = state.take()
      kind = .conformance

    default:
      context.report(
        "expected '==' or ':' to specify a type requirement", anchor: state.errorRange())
      state.hasError = true
      kind = .equality
    }

    // Parse the right operand of the requirement.
    let rhs = parseSign(state: &state) ?< { () -> Sign in
      context.report("expected type signature", anchor: state.errorRange())
      state.hasError = true
      return ErrorSign(type: context.errorType, range: state.errorRange())
    }

    return TypeReq(kind: kind, lhs: identSign, rhs: rhs, range: lhs.range ..< rhs.range)
  }

  /// Parses a control statement.
  private func parseCtrlStmt(state: inout State) -> Stmt? {
    switch state.peek()?.kind {
    case .break:
      return parseBreakStmt(state: &state)
    case .continue:
      return parseContinueStmt(state: &state)
    case .ret:
      return parseRetStmt(state: &state)
    case .for:
      fatalError("not implemented")
    case .while:
      fatalError("not implemented")
    case .lBrace:
      return parseBraceStmt(state: &state)
    default:
      return nil
    }
  }

  /// Parses a break statement.
  ///
  ///     break-stmt ::= 'break' NAME?
  private func parseBreakStmt(state: inout State) -> /*Break*/Stmt? {
    guard let opener = state.take(.break) else { return nil }

    if !(state.flags & .isParsingLoopBody) {
      context.report("'break' is only allowed inside of a loop", anchor: opener.range)
      state.hasError = true
    }

    fatalError("not implemented")
  }

  /// Parses a continue statement.
  ///
  ///     break-stmt ::= 'continue' NAME?
  private func parseContinueStmt(state: inout State) -> /*Continue*/Stmt? {
    guard let opener = state.take(.continue) else { return nil }

    if !(state.flags & .isParsingLoopBody) {
      context.report("'continue' is only allowed inside of a loop", anchor: opener.range)
      state.hasError = true
    }

    fatalError("not implemented")
  }

  /// Parses a return statement.
  ///
  ///     ret-stmt ::= 'ret' expr?
  private func parseRetStmt(state: inout State) -> RetStmt? {
    guard let opener = state.take(.ret) else { return nil }
    let stmt = RetStmt(value: nil, range: opener.range)

    if let expr = parseExpr(state: &state) {
      stmt.value = expr
      stmt.range = stmt.range ..< expr.range
    }

    if state.flags & .isParsingFunBody {
      stmt.funDecl = state.declSpace?.spacesUpToRoot.first(as: BaseFunDecl.self)
    } else {
      context.report("'return' is only allowed inside of a function", anchor: opener.range)
      state.hasError = true
    }

    return stmt
  }

  /// Parses a brace statement.
  ///
  ///     brace-stmt ::= '{' (stmt ';'*)* ';'* '}'
  private func parseBraceStmt(state: inout State) -> BraceStmt? {
    guard let opener = state.take(.lBrace) else { return nil }

    let scope = BraceStmt(statements: [], range: opener.range)
    scope.parentDeclSpace = state.declSpace
    state.declSpace = scope
    defer { state.declSpace = scope.parentDeclSpace }

    loop:while true {
      // Skip leading semicolons and exit the loop once we've found a closing brace.
      state.skip(while: { $0.kind == .semi })
      if let closer = state.take(.rBrace) {
        scope.range = opener.range ..< closer.range
        return scope
      }

      guard let head = state.peek() else {
        context.report("expected '}' delimiter", anchor: state.errorRange())
        state.hasError = true
        return scope
      }

      do {
        if head.mayBeginDecl {
          guard let decl = try parseDecl(state: &state) else {
            throw ParseError(Diagnostic("expected declaration", anchor: state.errorRange()))
          }
          scope.stmts.append(decl)
        } else if head.mayBeginCtrlStmt {
          guard let stmt = parseCtrlStmt(state: &state) else {
            throw ParseError(Diagnostic("expected statement", anchor: state.errorRange()))
          }
          scope.stmts.append(stmt)
        } else {
          guard let expr = parseExpr(state: &state) else {
            throw ParseError(Diagnostic("expected expression", anchor: state.errorRange()))
          }
          scope.stmts.append(expr)

          // If a match or conditional expression is parsed at the top-level of a brace statement,
          // then it should be considered as a statement rather than an expression.
          if let match = expr as? MatchExpr {
            match.isSubexpr = false
          }
        }
      } catch let error as ParseError {
        context.report(error.diag)
        state.hasError = true
        state.skip(while: {
          !$0.isOf(kind: [.semi, .rBrace]) && !$0.mayBeginDecl && !$0.mayBeginCtrlStmt
        })
      } catch {
        fatalError("unreachable")
      }
    }
  }

  /// Parses an expression.
  ///
  ///     expr ::= prefix-expr binary*
  ///     binary ::= (operator | NAME) prefix-expr
  private func parseExpr(state: inout State) -> Expr? {
    guard var head = parsePrefixExpr(state: &state) else { return nil }
    var tree = InfixTree.leaf(.expr(head))

    // Parse a sequence of binary suffixes.
    var upperRange = head.range.upperBound
    while true {
      let oper: Ident
      let group: PrecedenceGroup?

      if let ident = state.takeOperator() {
        // The operator is a standard non-cast infix operator,.
        oper = ident
        group = PrecedenceGroup(for: ident.name) ?< {
          context.report("unknown infix operator '\(oper.name)'", anchor: oper.range)
          return nil
        }
      } else if let name = state.peek(), name.kind == .name {
        // The next token might be an infix identifier. However, we require that it be on the same
        // line as the left operand, to to avoid any ambiguity with statements that may begin with
        // a name on the next line.
        let gap = state.lexer.source[upperRange ..< name.range.lowerBound]
        guard !gap.contains(where: { $0.isNewline }) else { break }

        _ = state.take()
        oper = state.ident(name)
        group = .identifier
      } else if let token = state.take(.cast) {
        // The right operand of a cast operator is a type signature, not an expression.
        guard let rhs = parseSign(state: &state) else {
          context.report("expected type signature", anchor: state.errorRange())
          state.hasError = true
          return ErrorExpr(type: context.errorType, range: head.range)
        }

        // Append the new operator/operand to the tree.
        upperRange = rhs.range.upperBound
        tree.append(oper: state.ident(token), group: .casting, rhs: .sign(rhs))
        continue
      } else {
        // No binary suffix; we're done.
        break
      }

      // Parse the right operand.
      guard let rhs = parsePrefixExpr(state: &state) else {
        context.report("expected right operand", anchor: state.errorRange())
        state.hasError = true
        return ErrorExpr(type: context.errorType, range: head.range)
      }

      // Check that spacing around the operator is consistent.
      let lGap = upperRange < oper.range.lowerBound
      let rGap = upperRange < oper.range.lowerBound
      if lGap != rGap {
        context.report("inconsistent spacing around infix operator", anchor: oper.range)
        state.hasError = true
      }

      // Append the new operator/operand to the tree.
      if let group = group {
        upperRange = rhs.range.upperBound
        tree.append(oper: oper, group: group, rhs: .expr(rhs))
      } else {
        head = ErrorExpr(type: context.errorType, range: head.range ..< rhs.range)
        tree = InfixTree.leaf(.expr(head))
      }
    }

    return tree.flattened()
  }

  /// Parses compound expression, optionally preceeded by a prefix operator.
  ///
  ///     prefix-expr ::= prefix-oper? compound-expr
  private func parsePrefixExpr(state: inout State) -> Expr? {
    // Assign and cast operators are never infix.
    guard let oper = state.takeOperator(includingAssign: false) else {
      // No prefix operator; just parse a compound expression.
      return parseCompoundExpr(state: &state)
    }

    // Parse the operand.
    guard let value = parseCompoundExpr(state: &state) else {
      context.report("expected operand expression", anchor: state.errorRange())
      state.hasError = true
      return ErrorExpr(type: context.errorType, range: oper.range)
    }

    // Prefix operators cannot be separated from their operand.
    if oper.range.upperBound != value.range.lowerBound {
      context.report("prefix operator cannot be separated from its operand", anchor: oper.range)
      state.hasError = true
      return ErrorExpr(type: context.errorType, range: oper.range ..< value.range)
    }

    // If the operator is '&', then return an AddrOfExpr; otherwise, return a prefix call.
    if oper.name == "&" {
      return AddrOfExpr(value: value, type: unresolved, range: oper.range ..< value.range)
    } else {
      let fun = UnresolvedMemberExpr(base: value, ident: oper, type: unresolved, range: oper.range)
      return CallExpr.prefix(fun: fun, type: unresolved, range: oper.range ..< value.range)
    }
  }

  /// Parses a compound expression.
  ///
  ///     compound-expr ::= primary-expr (call-args | subscript | member)*
  ///     call-args ::= list['(', call-arg, ')']
  ///     subscript ::= list['[', call-arg, ']']
  ///     member ::= '.' (label | oper | INTEGER)
  private func parseCompoundExpr(state: inout State) -> Expr? {
    guard var base = parsePrimaryExpr(state: &state) else { return nil }

    // Parse a sequence of primary suffixes.
    while let token = state.peek() {
      switch token.kind {
      case .lParen:
        // We require call suffixes to start on the same line, to avoid any ambiguity with
        // statements that may begin with a left parenthesis on the next line.
        let gap = state.lexer.source[base.range.upperBound ..< token.range.lowerBound]
        guard !gap.contains(where: { $0.isNewline }) else { return base }

        // Parse an argument list.
        let (opener, elems, closer) = list(
          state: &state, delimiters: (.lParen, .rParen), parser: parseTupleExprElem(state:))!

        // Create a call expression.
        let range = base.range ..< (closer?.range ?? elems.last?.range ?? opener.range)
        base = CallExpr(
          fun: base, args: elems, notation: .standard, type: unresolved, range: range)

      case .lBrack:
        fatalError("not implemented")

      case .dot:
        // Consume the dot token.
        _ = state.take()

        // Parse the member identifier or index.
        if let name = state.take(if: { $0.isLabel }) {
          let ident = state.ident(name)
          base = UnresolvedMemberExpr(
            base: base, ident: ident, type: unresolved, range: base.range ..< ident.range)
          continue
        } else if let oper = state.takeOperator() {
          base = UnresolvedMemberExpr(
            base: base, ident: oper, type: unresolved, range: base.range ..< oper.range)
        } else if let index = state.take(.int) {
          let value = state.lexer.source[index.range]

          guard !value.contains(where: { !$0.isDigit }), let i = Int(value) else {
            context.report("'\(value)' is not a valid tuple index", anchor: index.range)
            state.hasError = true
            return ErrorExpr(type: context.errorType, range: base.range ..< index.range)
          }

          base = TupleMemberExpr(
            base: base, memberIndex: i, type: unresolved, range: base.range ..< index.range)
        } else {
          context.report("expected member identifier", anchor: state.errorRange())
          state.hasError = true
          return ErrorExpr(type: context.errorType, range: base.range ..< token.range)
        }

      case _ where token.isOperator:
        // Attempt to consume a postfix.
        let backup = state.save()
        guard let oper = state.takeOperator(includingAssign: false) else {
          return base
        }

        // Postfix operators must be attached to the expression, and followed by a whitespace.
        let lGap = base.range.upperBound != oper.range.lowerBound
        let rGap = (oper.range.upperBound == state.lexer.source.endIndex)
          || state.lexer.source[oper.range.upperBound].isWhitespace
        guard !lGap && rGap else {
          state.restore(backup)
          return base
        }

        let fun = UnresolvedMemberExpr(
          base: base, ident: oper, type: unresolved, range: oper.range)
        base = CallExpr.postfix(fun: fun, type: unresolved, range: base.range ..< oper.range)

      default:
        return base
      }
    }

    return base
  }

  /// Parses a primary expression.
  private func parsePrimaryExpr(state: inout State) -> Expr? {
    switch state.peek()?.kind {
    case .bool:
      return parseBoolLiteral(state: &state)
    case .int:
      return parseIntLiteral(state: &state)
    case .float:
      return parseFloatLiteral(state: &state)
    case .string:
      return parseStringLiteral(state: &state)
    case .name:
      return parseDeclRefExpr(state: &state)
    case .dot:
      fatalError("not implemented")
    case .async:
      return parseAsyncExpr(state: &state)
    case .await:
      return parseAwaitExpr(state: &state)
    case .if:
      fatalError("not implemented")
    case .match:
      return parseMatchExpr(state: &state)
    case .lParen:
      return parseTupleExpr(state: &state)
    case .under:
      return parseWildcardExpr(state: &state)
    default:
      return nil
    }
  }

  /// Parses a Boolean literal.
  private func parseBoolLiteral(state: inout State) -> Expr? {
    guard let token = state.take(.bool) else { return nil }
    let value = state.lexer.source[token.range] == "true"
    return BoolLiteralExpr(value: value, type: unresolved, range: token.range)
  }

  /// Parses an integer number literal.
  private func parseIntLiteral(state: inout State) -> Expr? {
    guard let token = state.take(.int) else { return nil }

    let literal = state.lexer.source[token.range]
    guard let value = Int(literal) else {
      context.report("invalid integer literal '\(literal)'", anchor: token.range)
      state.hasError = true
      return ErrorExpr(type: context.errorType, range: token.range)
    }

    return IntLiteralExpr(value: value, type: unresolved, range: token.range)
  }

  /// Parses a floating-point number literal.
  private func parseFloatLiteral(state: inout State) -> Expr? {
    guard let token = state.take(.float) else { return nil }

    let literal = state.lexer.source[token.range]
    guard let value = Double(literal) else {
      context.report("invalid floating point literal '\(literal)'", anchor: token.range)
      state.hasError = true
      return ErrorExpr(type: context.errorType, range: token.range)
    }

    return FloatLiteralExpr(value: value, type: unresolved, range: token.range)
  }

  /// Parses a string literal.
  ///
  ///     string-literal ::= STRING+
  private func parseStringLiteral(state: inout State) -> Expr? {
    guard let first = state.take(.string) else { return nil }

    var tokens = [first]
    while let token = state.take(.string) {
      tokens.append(token)
    }

    if tokens.isEmpty {
      let value = String(state.lexer.source[tokens[0].range])
      return StringLiteralExpr(value: value, type: unresolved, range: tokens[0].range)
    } else {
      let value = tokens.reduce(into: "", { $0 += String(state.lexer.source[$1.range]) })
      return StringLiteralExpr(
        value: value, type: unresolved, range: tokens.first!.range ..< tokens.last!.range)
    }
  }

  /// Parses a declaration reference.
  private func parseDeclRefExpr(state: inout State) -> Expr? {
    // We first attempt to parse a sequence of unqualified type identifiers. We stop on failure, or
    // if the parsed identifier is not followed by '::'. At each iteration, we must save potential
    // diagnostics until we decide to commit. After the list, we parse a single identifier.
    let tmpConsumer = DiagSaver()
    var oldConsumer = context.diagnosticConsumer
    context.diagnosticConsumer = tmpConsumer

    var comps: [IdentCompSign] = []
    var backup = state.save()
    while let sign = parseIdentCompSign(state: &state) {
      // We succeeded to parse a type identifier. It's part of the namespace if the next token is
      // '::'; otherwise, we backtrack.
      if state.take(.twoColons) != nil {
        comps.append(sign)
        backup = state.save()

        // Now that we've committed, we can emit the potential diagnostics we emitted while we
        // parsed the type signature.
        for diag in tmpConsumer.diags {
          oldConsumer?.consume(diag)
        }
        tmpConsumer.diags.removeAll()
      } else if let bare = sign as? BareIdentSign {
        // Little shortcut: if the signature we parsed is a bare type identifier, we can simply
        // transform it as a bare unqualified declaration reference and avoid backtracking.
        assert(tmpConsumer.diags.isEmpty)
        context.diagnosticConsumer = oldConsumer

        if comps.isEmpty {
          return UnresolvedDeclRefExpr(ident: bare.ident, type: unresolved, range: bare.range)
        } else {
          let space = CompoundIdentSign.create(comps)
          let range = space.range ..< bare.range
          return UnresolvedQualDeclRefExpr(
            namespace: space, ident: bare.ident, type: unresolved, range: range)
        }
      } else {
        state.restore(backup)
        context.diagnosticConsumer = oldConsumer
        break
      }
    }

    // Either we've just failed to parse a type signature, or we've backtracked the beginning of a
    // a sequence that could have been interpreter as a type signature. Either way, we're expecting
    // a declaration reference now. If the namespace is empty, we're expecting an identifier. If it
    // isn't, we may also parse an operator.
    if comps.isEmpty {
      guard let name = state.take(.name) else { return nil }
      return UnresolvedDeclRefExpr(ident: state.ident(name), type: unresolved, range: name.range)
    }

    let space = CompoundIdentSign.create(comps)

    if let name = state.take(.name) {
      let ident = state.ident(name)
      return UnresolvedQualDeclRefExpr(
        namespace: space, ident: ident, type: unresolved, range: space.range ..< ident.range)
    } else if let ident = state.takeOperator() {
      return UnresolvedQualDeclRefExpr(
        namespace: space, ident: ident, type: unresolved, range: space.range ..< ident.range)
    } else {
      context.report("expected identifier", anchor: state.errorRange())
      state.hasError = true
      return ErrorExpr(type: context.errorType, range: space.range)
    }
  }

  /// Parses an async expression.
  ///
  ///     async-expr ::= 'async' expr
  private func parseAsyncExpr(state: inout State) -> Expr? {
    guard let introducer = state.take(.async) else { return nil }

    guard let value = parseExpr(state: &state) else {
      context.report("expected expression", anchor: state.errorRange())
      state.hasError = true
      return ErrorExpr(type: context.errorType, range: introducer.range)
    }

    return AsyncExpr(value: value, type: unresolved, range: introducer.range ..< value.range)
  }

  /// Parses an await expression.
  ///
  ///     await-expr ::= 'await' expr
  private func parseAwaitExpr(state: inout State) -> Expr? {
    guard let introducer = state.take(.await) else { return nil }

    guard let value = parseExpr(state: &state) else {
      context.report("expected expression", anchor: state.errorRange())
      state.hasError = true
      return ErrorExpr(type: context.errorType, range: introducer.range)
    }

    return AwaitExpr(
      value: value, type: unresolved, range: introducer.range ..< value.range)
  }

  /// Parses a match expression.
  ///
  ///     match-expr ::= 'match' expr '{' match-case* '}'
  private func parseMatchExpr(state: inout State) -> Expr? {
    guard let introducer = state.take(.match) else { return nil }

    let subject = parseExpr(state: &state) ?< { () -> Expr in
      context.report("expected expression", anchor: state.errorRange())
      state.hasError = true
      return ErrorExpr(type: context.errorType, range: state.errorRange())
    }

    let expr = MatchExpr(
      isSubExpr: true, subject: subject, cases: [], type: unresolved, range: introducer.range)

    guard state.take(.lBrace) != nil else {
      context.report("expected '{' after match subject expression", anchor: state.errorRange())
      state.hasError = true
      return expr
    }
    while let case_ = parseMatchCase(state: &state) {
      expr.cases.append(case_)
    }
    if state.take(.rBrace) == nil {
      context.report("expected '}' delimiter", anchor: state.errorRange())
      state.hasError = true
    }

    return expr
  }

  /// Parses a case in a match expression.
  ///
  ///     match-case ::= 'case' pattern ('where' expr)? brace-stmt
  private func parseMatchCase(state: inout State) -> MatchCaseStmt? {
    guard let introducer = state.take(.case) else { return nil }

    let pattern = parsePattern(state: &state) ?< { () -> Pattern in
      context.report("expected pattern", anchor: state.errorRange())
      state.hasError = true
      return WildcardPattern(type: context.errorType, range: state.errorRange())
    }

    let condition: Expr?
    if state.take(.where) != nil {
      condition = parseExpr(state: &state) ?< {
        context.report("expected condition", anchor: state.errorRange())
        state.hasError = true
        return nil
      }
    } else {
      condition = nil
    }

    let body = parseBraceStmt(state: &state) ?< { () -> BraceStmt in
      context.report("expected '{' after case pattern", anchor: state.errorRange())
      state.hasError = true
      return BraceStmt(statements: [], range: state.errorRange())
    }

    let stmt = MatchCaseStmt(
      pattern: pattern, condition: condition, body: body, range: introducer.range ..< body.range)
    stmt.parentDeclSpace = state.declSpace
    body.parentDeclSpace = stmt
    return stmt
  }

  /// Parses a tuple expression.
  ///
  ///     tuple-expr ::= list['(', tuple-expr-elem, ')']
  private func parseTupleExpr(state: inout State) -> Expr? {
    guard let (opener, elems, closer) = list(
            state: &state, delimiters: (.lParen, .rParen), parser: parseTupleExprElem(state:))
    else { return nil }

    let range = opener.range ..< (closer?.range ?? elems.last?.range ?? opener.range)
    return TupleExpr(elems: elems, type: unresolved, range: range)
  }

  /// Parses a single element in a tuple expression.
  ///
  ///     tuple-expr-elem ::= (label ':')? expr
  private func parseTupleExprElem(state: inout State) -> TupleElem? {
    guard let opener = state.peek() else { return nil }
    let backup = state.save()
    let label: String?

    // Attempt to consume a label.
    if let labelToken = state.take(if: { $0.isLabel }), state.take(.colon) != nil {
      // We successfully parsed a label; we must parse an expression.
      label = String(state.lexer.source[labelToken.range])
    } else {
      // We failed to parse a label; backtrack.
      state.restore(backup)
      label = nil
    }

    let value: Expr
    if let expr = parseExpr(state: &state) {
      value = expr
    } else if label != nil {
      context.report("expected expression", anchor: state.errorRange())
      state.hasError = true
      value = ErrorExpr(type: context.errorType, range: state.errorRange())
    } else {
      // We don't have to commit to a failure, since we didn't consume anything.
      return nil
    }

    return TupleElem(label: label, value: value, range: opener.range ..< value.range)
  }

  /// Parses a wildcard expression.
  private func parseWildcardExpr(state: inout State) -> Expr? {
    guard let token = state.take(.under) else { return nil }
    return WildcardExpr(type: unresolved, range: token.range)
  }

  /// Parses a pattern.
  private func parsePattern(state: inout State) -> Pattern? {
    switch state.peek()?.kind {
    case .name:
      return parseNamedPattern(state: &state)
    case .var, .val:
      return parseBindingPattern(state: &state)
    case .lParen:
      return parseTuplePattern(state: &state)
    case .under:
      return parseWildcardPattern(state: &state)
    default:
      return nil
    }
  }

  /// Parses a named pattern.
  private func parseNamedPattern(state: inout State) -> Pattern? {
    guard let token = state.take(.name) else { return nil }

    // Create a variable declaration for the pattern.
    let decl = VarDecl(ident: state.ident(token), type: unresolved, range: token.range)
    decl.parentDeclSpace = state.declSpace

    // Create the pattern.
    return NamedPattern(decl: decl, type: unresolved, range: token.range)
  }

  /// Parses a binding pattern.
  ///
  ///     binding-pattern ::= ('val' | 'var') pattern (':' sign)?
  private func parseBindingPattern(state: inout State) -> Pattern? {
    guard let introducer = state.take(if: { $0.isOf(kind: [.val, .var]) }) else { return nil }

    // Commit to parse a pattern.
    guard let subpattern = parsePattern(state: &state) else {
      context.report("expected pattern", anchor: state.errorRange())
      state.hasError = true
      return WildcardPattern(type: unresolved, range: introducer.range)
    }

    let pattern = BindingPattern(
      isMutable: introducer.kind == .var,
      subpattern: subpattern,
      sign: nil,
      type: unresolved,
      keywordRange: introducer.range,
      range: introducer.range ..< subpattern.range)

    // Attempt to parse a type signature.
    if state.take(.colon) != nil {
      if let sign = parseSign(state: &state) {
        pattern.sign = sign
      } else {
        // We must commit to a failure.
        context.report("expected type signature", anchor: state.errorRange())
        state.hasError = true
      }
    }

    return pattern
  }

  /// Parses a tuple pattern.
  ///
  ///     tuple-pattern ::= list['(', tuple-pattern-elem, ')']
  private func parseTuplePattern(state: inout State) -> Pattern? {
    guard let (opener, elems, closer) = list(
            state: &state, delimiters: (.lParen, .rParen), parser: parseTuplePatternElem(state:))
    else { return nil }

    let range = opener.range ..< (closer?.range ?? elems.last?.range ?? opener.range)
    return TuplePattern(elems: elems, type: unresolved, range: range)
  }

  /// Parses a single element in a tuple pattern.
  ///
  ///     tuple-pattern-elem ::= (label ':')? expr
  private func parseTuplePatternElem(state: inout State) -> TuplePattern.Elem? {
    guard let opener = state.peek() else { return nil }
    let backup = state.save()
    let label: String?

    // Attempt to consume a label.
    if let labelToken = state.take(if: { $0.isLabel }), state.take(.colon) != nil {
      // We successfully parsed a label; we must parse a subpattern.
      label = String(state.lexer.source[labelToken.range])
    } else {
      // We failed to parse a label; backtrack.
      state.restore(backup)
      label = nil
    }

    let subpattern: Pattern
    if let pat = parsePattern(state: &state) {
      subpattern = pat
    } else if label != nil {
      context.report("expected expression", anchor: state.errorRange())
      state.hasError = true
      subpattern = WildcardPattern(type: context.errorType, range: state.errorRange())
    } else {
      // We don't have to commit to a failure, since we didn't consume anything.
      return nil
    }

    return TuplePattern.Elem(
      label: label, pattern: subpattern, range: opener.range ..< subpattern.range)
  }

  /// Parses a wildcard pattern.
  private func parseWildcardPattern(state: inout State) -> Pattern? {
    guard let token = state.take(.under) else { return nil }
    return WildcardPattern(type: unresolved, range: token.range)
  }

  /// Parses a type signature.
  ///
  ///     sign ::= ('mut' | 'volatile')* async-sign ('->' sign)
  private func parseSign(state: inout State) -> Sign? {
    guard let opener = state.peek() else { return nil }
    var lastModifier: Token?

    // Consume a list of type modifiers.
    var modifiers: [Token.Kind: Token] = [:]
    while let token = state.take(if: { $0.isOf(kind: [.mut, .volatile]) }) {
      if modifiers[token.kind] != nil {
        context.report(
          "ignoring duplicate modifier \(token.kind)", level: .warning, anchor: token.range)
      } else {
        modifiers[token.kind] = token
        lastModifier = token
      }
    }

    // Parse an async signture.
    guard var base = parseAsyncSign(state: &state) else {
      // We must commit to a failure, unless we didn't parse any modifier.
      if let modifier = lastModifier {
        context.report(
          "expected type signature after \(modifier.kind)", anchor: state.errorRange())
        state.hasError = true
        return ErrorSign(type: context.errorType, range: opener.range ..< modifier.range)
      } else {
        return nil
      }
    }

    // Attempt to parse a function signature.
    if let arrow = state.take(.arrow) {
      guard let retSign = parseSign(state: &state) else {
        context.report(
          "expected type signature after '->'", anchor: state.errorRange())
        state.hasError = true
        return ErrorSign(type : context.errorType, range: opener.range ..< arrow.range)
      }

      base = FunSign(
        paramSign: base,
        retSign: retSign,
        isVolatile: modifiers[.volatile] != nil,
        type: unresolved,
        range: opener.range ..< retSign.range)
    } else if let modifier = modifiers[.volatile] {
      context.report(
        "'volatile' modifier can only be applied on function signature", anchor: modifier.range)
      state.hasError = true
      return ErrorSign(type: context.errorType, range: base.range)
    }

    if let modifier = modifiers[.mut] {
      return InoutSign(
        base: base,
        type: unresolved,
        modifierRange: modifier.range,
        range: opener.range ..< base.range)
    } else {
      return base
    }
  }


  /// Parses a maxterm signature, optionally prefix by an async modifier.
  ///
  ///     async-sign ::= 'async'? maxterm-sign
  private func parseAsyncSign(state: inout State) -> Sign? {
    // Attempt to consume an asnyc modifier.
    if let modifier = state.take(.async) {
      // Commit to parse the base of the signature.
      guard let base = parseSign(state: &state) else {
        context.report("expected type signature after 'async'", anchor: state.errorRange())
        state.hasError = true
        return ErrorSign(type: context.errorType, range: modifier.range)
      }

      return AsyncSign(
        base: base,
        type: unresolved,
        modifierRange: modifier.range,
        range: modifier.range ..< base.range)
    }

    // Parse a maxterm signature.
    return parseMaxtermSign(state: &state)
  }

  /// Parses a maxterm signature, i.e., a disjunction of signatures.
  ///
  ///     maxterm-sign ::= minterm-sign ('|' minterm-sign)*
  private func parseMaxtermSign(state: inout State) -> Sign? {
    let items = parseTermSign(state: &state, oper: "|", element: parseMintermSign(state:))
    switch items.count {
    case 0:
      return nil
    case 1:
      return items[0]
    default:
      return UnionSign(
        elems: items, type: unresolved, range: items.first!.range ..< items.last!.range)
    }
  }

  /// Parses a minterm signature, i.e., a conjunction of signatures.
  ///
  ///     minterm-sign ::= primary-sign ('&' primary-sign)*
  private func parseMintermSign(state: inout State) -> Sign? {
    let items = parseTermSign(state: &state, oper: "&", element: parsePrimarySign(state:))
    switch items.count {
    case 0:
      return nil
    case 1:
      return items[0]
    default:
      return ViewCompSign(
        views: items, type: unresolved, range: items.first!.range ..< items.last!.range)
    }
  }

  /// Parses a a minterm or a maxterm signature.
  private func parseTermSign(
    state: inout State,
    oper: String,
    element: (inout State) -> Sign?
  ) -> [Sign] {
    guard let first = element(&state) else { return [] }
    var items = [first]

    // Attempt to parse an operator and its operand.
    while let token = state.peek(),
          (token.kind == .oper) && (state.lexer.source[token.range] == oper)
    {
      _ = state.take()

      guard let sign = element(&state) else {
        context.report("expected type signature", anchor: state.errorRange())
        state.hasError = true
        items = [ErrorSign(type: context.errorType, range: items[0].range ..< items.last!.range)]
        continue
      }

      items.append(sign)
    }

    return items
  }

  /// Parses a primary signature.
  ///
  ///     primary-sign ::= compound-ident-sign | tuple-sign
  private func parsePrimarySign(state: inout State) -> Sign? {
    switch state.peek()?.kind {
    case .name:
      return parseCompoundIdentSign(state: &state)
    case .lParen:
      return parseTupleSign(state: &state)
    default:
      return nil
    }
  }

  /// Parses a compound type identifier.
  ///
  ///     compound-ident-sign ::= ident-comp-sign ('::' ident-comp-sign)*
  private func parseCompoundIdentSign(state: inout State) -> Sign? {
    guard let first = parseIdentCompSign(state: &state) else { return nil }
    var comps = [first]

    while let sep = state.peek(), sep.kind == .twoColons {
      _ = state.take()
      guard let sign = parseIdentCompSign(state: &state) else {
        context.report("expected type identifier", anchor: state.errorRange())
        state.hasError = true
        return ErrorSign(type: context.errorType, range: comps[0].range ..< comps.last!.range)
      }
      comps.append(sign)
    }

    return CompoundIdentSign.create(comps)
  }

  /// Parses an unqualified type identifier.
  ///
  ///     ident-comp-sign ::= NAME generic-args?
  ///     generic-args ::= list['<', sign, '>']
  private func parseIdentCompSign(state: inout State) -> IdentCompSign? {
    guard let token = state.take(.name) else { return nil }
    let ident = state.ident(token)

    // Attempt to parse a list of generic arguments.
    if let (opener, args, closer) = list(
        state: &state, delimiters: (.lAngle, .rAngle), parser: parseSign(state:))
    {
      // Return a specialized identifier.
      let range = opener.range ..< (closer?.range ?? args.last?.range ?? opener.range)
      return SpecializedIdentSign(ident: ident, args: args, type : unresolved, range: range)
    }

    // Return a bare identifier.
    return BareIdentSign(ident: ident, type : unresolved)
  }

  /// Parses a tuple signature.
  ///
  ///     tuple-sign ::= list['(', tuple-sign-elem, ')']
  private func parseTupleSign(state: inout State) -> Sign? {
    guard let (opener, elems, closer) = list(
            state: &state, delimiters: (.lParen, .rParen), parser: tupleSignElem(state:))
    else { return nil }

    let range = opener.range ..< (closer?.range ?? elems.last?.range ?? opener.range)
    return TupleSign(elems: elems, type: unresolved, range: range)
  }

  /// Parses a single element in a tuple signature.
  ///
  ///     tuple-sign-elem ::= (label ':')? sign
  private func tupleSignElem(state: inout State) -> TupleSignElem? {
    guard let opener = state.peek() else { return nil }
    let backup = state.save()
    let label: String?

    // Attempt to consume a label.
    if let labelToken = state.take(if: { $0.isLabel }), state.take(.colon) != nil {
      // We successfully parsed a label; we must parse a signature.
      label = String(state.lexer.source[labelToken.range])
    } else {
      // We failed to parse a label; backtrack.
      state.restore(backup)
      label = nil
    }

    let sign: Sign
    if let s = parseSign(state: &state) {
      sign = s
    } else {
      // We must commit to a failure, unless we didn't parse a label.
      if label != nil {
        context.report("expected expression", anchor: state.errorRange())
        state.hasError = true
        sign = ErrorSign(type: context.errorType, range: state.errorRange())
      } else {
        return nil
      }
    }

    return TupleSignElem(label: label, sign: sign, range: opener.range ..< sign.range)
  }

  /// Parses a comma-separated list of elements, delimited by the specified tokens.
  ///
  /// - Parameters:
  ///   - state: The parser's state.
  ///   - delimiters: The kind of the opening and closing delimiter tokens.
  ///   - parser: A closure that accepts the parser's state and parses a single element.
  private func list<T>(
    state: inout State,
    delimiters: (left: Token.Kind, right: Token.Kind),
    parser: (inout State) -> T?
  ) -> (opener: Token, elems: [T], closer: Token?)? {
    // Consume the left delimiter.
    guard let opener = state.take(delimiters.left) else { return nil }

    // Consume the list's elements.
    var elems: [T] = []
    while let elem = parser(&state) {
      elems.append(elem)
      guard state.take(.comma) != nil else { break }
    }

    // Consume the right delimiter.
    var closer = state.take(delimiters.right)
    if closer == nil {
      if let token = state.take(.comma) {
        context.report("unexpected ',' separator", anchor: token.range)
        state.hasError = true
      } else {
        context.report("expected '\(delimiters.right)' delimiter", anchor: state.errorRange())
        state.hasError = true
      }

      // Recover at a delimiter.
      state.skip(while: { !$0.isOf(kind: [delimiters.right, .rBrace, .semi]) })
      closer = state.take(delimiters.right)
    }

    return (opener, elems, closer)
  }

}

/// The head of a type declaration.
fileprivate struct TypeDeclHead {

  /// The token introducing the declation.
  let introducer: Token

  /// The declaration's identifier.
  let ident: Ident

  /// The generic clause of the declaration.
  let genericClause: GenericClause?

  /// The inheritances of the declaration.
  let inheritances: [Sign]

}

/// A helper data structure to parse infix expressions.
///
/// Infix expressions are parsed as a sequence of operators and operands. This data structure is
/// used to insert every element of the sequence in a tree that encodes operator precedrence and
/// associativity.
fileprivate enum InfixTree {

  /// An expression or a type signature operand.
  enum Operand {
    case expr(Expr)
    case sign(Sign)
  }

  /// A single expression.
  case leaf(Operand)

  /// An infix call.
  indirect case node(oper: Ident, group: PrecedenceGroup, left: InfixTree, right: InfixTree)

  /// Appends the specified operator and operand to the tree.
  mutating func append(oper: Ident, group: PrecedenceGroup, rhs: Operand) {
    switch self {
    case .leaf:
      self = .node(oper: oper, group: group, left: self, right: .leaf(rhs))

    case .node(let loper, let lgroup, let left, var right):
      if (lgroup.weight < group.weight)
          || (lgroup.weight == group.weight && group.associativity == .right)
      {
        // Either the new operator binds more strongly, or it has the same weight and it is
        // right-associative.
        right.append(oper: oper, group: group, rhs: rhs)
        self = .node(oper: loper, group: lgroup, left: left, right: right)
      } else {
        // Either the new operator binds more weakly, or it has the same weight and it is
        // left-associative.
        self = .node(oper: oper, group: group, left: self, right: .leaf(rhs))
      }
    }
  }

  /// Flattens the tree as a single expression, transforming each node into an infix call.
  func flattened() -> Expr {
    switch self {
    case .leaf(.expr(let expr)):
      return expr

    case .node(let oper, _, let left, let right):
      let lhs = left.flattened()
      let unresolved = lhs.type.context.unresolvedType

      switch oper.name {
      case "=":
        let rhs = right.flattened()
        return AssignExpr(lvalue: lhs, rvalue: rhs, range: lhs.range ..< rhs.range)

      case "as?":
        guard case .leaf(.sign(let rhs)) = right else { fatalError("unreachable") }
        return DynCastExpr(
          value: lhs, sign: rhs, type: unresolved, range: lhs.range ..< rhs.range)

      case "as!":
        guard case .leaf(.sign(let rhs)) = right else { fatalError("unreachable") }
        return UnsafeCastExpr(
          value: lhs, sign: rhs, type: unresolved, range: lhs.range ..< rhs.range)

      default:
        let rhs = right.flattened()
        return CallExpr.infix(
          fun: UnresolvedMemberExpr(base: lhs, ident: oper, type: unresolved, range: oper.range),
          operand: rhs,
          type: unresolved,
          range: lhs.range ..< rhs.range)
      }

    case .leaf(.sign):
      preconditionFailure("cannot convert type signature to expression")
    }
  }

}

/// A parse error.
public struct ParseError: Error {

  public init(_ diag: Diagnostic) {
    self.diag = diag
  }

  public let diag: Diagnostic

}

/// A diagnostic consumer that saves all diagnostics.
final class DiagSaver: DiagnosticConsumer {

  var diags: [Diagnostic] = []

  func consume(_ diagnostic: Diagnostic) {
    diags.append(diagnostic)
  }

}

fileprivate func ..< (lhs: SourceRange, rhs: SourceRange) -> SourceRange {
  return lhs.lowerBound ..< rhs.upperBound
}
