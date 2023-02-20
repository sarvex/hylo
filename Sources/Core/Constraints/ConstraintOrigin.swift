/// The site from which a constraint originates and the reason why it was formed.
public struct ConstraintOrigin: Hashable {

  /// The reason why a constraint was formed.
  public enum Kind: Hashable {

    /// The constraint is caused by a type annotation.
    case annotation

    /// The constraint is caused by an expression being passed as an argument.
    case argument

    /// The constraint is caused by a binding reference.
    case binding

    /// The constraint is caused by a conditional expression.
    case branchMerge

    /// The constraint is caused by an expression being used as a callee.
    case callee

    /// The constraint is caused by a cast expression.
    case cast

    /// The constraint is caused by an initialization or assignment.
    case initializationOrAssignment

    /// The constraint is caused by a binding initialization with a type hint.
    case initializationWithHint

    /// The constraint is caused by a binding initialization with a pattern.
    case initializationWithPattern

    /// The constraint is caused by the evaluation of a literal expression.
    case literal

    /// The constraint is caused by a member binding reference.
    case member

    /// The constraint is caused by some structural property of the AST.
    case structural

    /// The constraint is caused by another constraint.
    indirect case subordinate(parent: ConstraintOrigin, id: Int)

    /// The constraint is caused by a return statement.
    case `return`

    /// The constraint is caused by a yield statement.
    case `yield`

  }

  /// The reason of the constraint.
  public let kind: Kind

  /// The site from which the constraint originates.
  public let site: SourceRange

  /// Creates a new instance with the given properties.
  public init(_ kind: Kind, at site: SourceRange) {
    self.kind = kind
    self.site = site
  }

  /// Returns the parent of this instance if it has kind `.subordinate`.
  public var parent: ConstraintOrigin? {
    if case .subordinate(let p, _) = kind {
      return p
    } else {
      return nil
    }
  }

  /// Returns a subordinate of this instance with given `id`.
  public func subordinate(_ id: Int) -> ConstraintOrigin {
    ConstraintOrigin(.subordinate(parent: self, id: id), at: site)
  }

}

extension ConstraintOrigin: CustomStringConvertible {

  public var description: String { .init(describing: kind) }

}
