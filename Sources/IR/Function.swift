import Core
import Foundation
import Utils

/// A collection of basic blocks representing a lowered function.
public struct Function {

  /// A collection of blocks with stable identities.
  public typealias Blocks = DoublyLinkedList<Block>

  /// The mangled name of the function.
  public let name: String

  /// The position in source code at which the function is anchored.
  public let anchor: SourcePosition

  /// The linkage of the function.
  public let linkage: Linkage

  /// The types of the function's parameters.
  public let inputs: [ParameterType]

  /// The type of the function's output.
  public let output: LoweredType

  /// The blocks in the function.
  public private(set) var blocks: Blocks

  /// The entry of the function.
  public var entry: Blocks.Address? { blocks.firstAddress }

  /// Accesses the basic block at `address`.
  ///
  /// - Requires: `address` must be a valid address in `self`.
  public subscript(_ address: Blocks.Address) -> Block {
    get { blocks[address] }
    _modify { yield &blocks[address] }
  }

  /// Appends to `self` a basic block accepting given `parameters` and returns its address.
  ///
  /// The new block will become the function's entry if `self` contains no block before
  /// `appendBlock` is called.
  mutating func appendBlock(taking parameters: [LoweredType]) -> Blocks.Address {
    blocks.append(Block(inputs: parameters))
  }

  /// Removes the block at `address`.
  @discardableResult
  mutating func removeBlock(_ address: Blocks.Address) -> Block {
    blocks.remove(at: address)
  }

  /// Returns the control flow graph of `self`.
  func cfg() -> ControlFlowGraph {
    var result = ControlFlowGraph()
    for source in blocks.indices {
      guard let s = blocks[source.address].instructions.last as? Terminator else { continue }
      for target in s.successors {
        result.define(source.address, predecessorOf: target.address)
      }
    }

    return result
  }

}

extension Function: CustomStringConvertible {

  public var description: String { "@\(name)" }

}

extension Function {

  /// The global identity of an IR function.
  public struct ID: Hashable {

    /// The value of a function IR identity.
    public enum Value: Hashable {

      /// A lowered Val function, initializer, or method variant.
      case lowered(AnyDeclID)

      /// An initializer's constructor form.
      case constructor(InitializerDecl.ID)

      /// The accessor of a global binding.
      case globalAccessor(VarDecl.ID)

      /// The initializer of a global binding declaration.
      case globalInitializer(BindingDecl.ID)

      /// A requirement synthesized for some type.
      ///
      /// The payload is a pair (D, U) where D is the declaration of a requirement and T is a type
      /// conforming to the trait defining D.
      case synthesized(AnyDeclID, for: AnyType)

    }

    /// The value of this identity.
    public let value: Value

    /// Creates the identity of the lowered form of `f`.
    public init(_ f: FunctionDecl.ID) {
      self.value = .lowered(AnyDeclID(f))
    }

    /// Creates the identity of the lowered form of `f` used as an initializer.
    public init(initializer f: InitializerDecl.ID) {
      self.value = .lowered(AnyDeclID(f))
    }

    /// Creates the identity of the lowered form of `f` used as a constructor.
    public init(constructor f: InitializerDecl.ID) {
      self.value = .constructor(f)
    }

    /// Creates the identity the global binding accessor of `d`.
    public init(globalAccessor d: VarDecl.ID) {
      self.value = .globalAccessor(d)
    }

    /// Creates the identity of a global pattern binding initializer.
    public init(globalInitializerOf d: BindingDecl.ID) {
      self.value = .globalInitializer(d)
    }

    /// Creates the identity of synthesized requirement `r` for type `t`.
    public init<T: DeclID>(synthesized r: T, for t: AnyType) {
      self.value = .synthesized(AnyDeclID(r), for: t)
    }

  }

}

extension Function.ID: CustomStringConvertible {

  public var description: String {
    switch value {
    case .lowered(let d):
      return "\(d).lowered"
    case .constructor(let d):
      return "\(d).constructor"
    case .globalAccessor(let d):
      return "\(d).accessor"
    case .globalInitializer(let d):
      return "\(d).initializer"
    case .synthesized(let r, let t):
      return "\"synthesized \(r) for \(t)\""
    }
  }

}
