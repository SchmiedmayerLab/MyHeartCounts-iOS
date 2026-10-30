//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

// periphery:ignore:all - Debugging API
// swiftlint:disable all

import Foundation
@_spi(APISupport) // we need to access `Grove.modules`
import Grove


/// A snapshot of the dependency relationships between the `Module`s loaded into a `Grove` instance.
///
/// Grove doesn't publicly expose its modules' `@Dependency` declarations, so this type extracts them via reflection.
/// It is therefore tied to the internal property-wrapper storage layout of the currently-pinned Grove version
/// (verified against SchmiedmayerLab/Grove 0.3.0-beta.6, rev `fb13cf97`) and intended purely as a debugging aid;
/// if Grove's internals change, edges will be missing and reported via ``warnings``.
///
/// - Warning: Grove itself crashes (stack overflow in `DependencyManager.buildTypeOrder()`) at the end of any
///     `loadModules` pass whose injected module graph contains a cycle — i.e. before control ever returns to the app.
///     ``cycles`` can therefore only ever surface a cycle that isn't fully injected yet
///     (e.g. an un-injected optional back-edge that a later `Grove/loadModule(_:ownership:)` call would complete).
@MainActor
struct GroveModuleDependencyGraph {
    /// How a module declared its dependency on another module.
    enum EdgeKind: String {
        /// A non-optional `@Dependency` declaration.
        case required
        /// An optional `@Dependency` declaration.
        case optional
        /// A `@Dependency(load:)` declaration.
        case load
    }

    /// A loaded module.
    struct Node: Hashable, Sendable {
        /// Unique node identifier: the module's type name, disambiguated with `#N` if several instances of the same type are loaded.
        let id: String
        /// The name of the module's type.
        let typeName: String
    }

    /// A `@Dependency` declaration of one module pointing at another.
    struct Edge: Hashable, Sendable {
        /// The ``Node/id`` of the module declaring the dependency.
        let source: String
        /// The ``Node/id`` of the target module or, if the dependency isn't injected, the declared type name.
        let target: String
        /// How the dependency was declared.
        let kind: EdgeKind
        /// Whether a module instance is currently injected into the declaration.
        /// `false` e.g. for optional dependencies on modules that aren't loaded (yet).
        let isInjected: Bool
    }

    /// The modules loaded into the `Grove` instance.
    private(set) var nodes: [Node] = []
    /// All `@Dependency` edges declared by ``nodes``, including un-injected ones.
    private(set) var edges: [Edge] = []
    /// Diagnostic messages for `@Dependency` property wrappers whose contents couldn't be understood,
    /// e.g. because the Grove version in use has a different internal layout.
    private(set) var warnings: [String] = []

    /// Creates a snapshot of the dependency graph of all modules currently loaded into the `Grove` instance.
    init(_ grove: Grove) {
        self.init(modules: grove.modules)
    }

    /// Creates a snapshot of the dependency graph of the specified modules.
    init(modules: [any Module]) {
        var idsByInstance: [ObjectIdentifier: String] = [:]
        let instanceCountsByType = modules.reduce(into: [:]) { counts, module in
            counts["\(type(of: module))", default: 0] += 1
        }
        var seenCountsByType: [String: Int] = [:]
        for module in modules {
            let typeName = "\(type(of: module))"
            let seenCount = seenCountsByType[typeName, default: 0] + 1
            seenCountsByType[typeName] = seenCount
            let id = instanceCountsByType[typeName, default: 1] > 1 ? "\(typeName) #\(seenCount)" : typeName
            idsByInstance[ObjectIdentifier(module)] = id
            nodes.append(Node(id: id, typeName: typeName))
        }
        for module in modules {
            guard let sourceId = idsByInstance[ObjectIdentifier(module)] else {
                continue
            }
            for declaration in Self.dependencyDeclarations(of: module, warnings: &warnings) {
                let target: String
                let isInjected: Bool
                if let injected = declaration.injectedModule {
                    target = idsByInstance[ObjectIdentifier(injected)] ?? "\(type(of: injected))"
                    isInjected = true
                } else {
                    target = declaration.declaredTypeName
                    isInjected = false
                }
                edges.append(Edge(source: sourceId, target: target, kind: declaration.kind, isInjected: isInjected))
            }
        }
    }
}


// MARK: Cycle Detection

extension GroveModuleDependencyGraph {
    /// All dependency cycles, as strongly connected components of more than one module, plus self-loops.
    ///
    /// Only edges with an injected module are considered; see the type-level warning about cycles Grove crashes on itself.
    var cycles: [[String]] {
        stronglyConnectedComponents().filter { component in
            component.count > 1 || edges.contains { $0.source == component[0] && $0.target == component[0] && $0.isInjected }
        }
    }

    /// Computes the strongly connected components of the injected-edge graph, using an iterative Tarjan's algorithm.
    private func stronglyConnectedComponents() -> [[String]] { // swiftlint:disable:this cyclomatic_complexity
        let successors: [String: [String]] = edges.reduce(into: [:]) { successors, edge in
            if edge.isInjected {
                successors[edge.source, default: []].append(edge.target)
            }
        }
        var index = 0
        var indices: [String: Int] = [:]
        var lowLinks: [String: Int] = [:]
        var stack: [String] = []
        var onStack: Set<String> = []
        var components: [[String]] = []
        for start in nodes.map(\.id) where indices[start] == nil {
            var work: [(node: String, successorIdx: Int)] = [(start, 0)]
            while let (node, successorIdx) = work.last {
                if successorIdx == 0 {
                    indices[node] = index
                    lowLinks[node] = index
                    index += 1
                    stack.append(node)
                    onStack.insert(node)
                }
                let nodeSuccessors = successors[node, default: []]
                if successorIdx < nodeSuccessors.count {
                    let successor = nodeSuccessors[successorIdx]
                    work[work.count - 1].successorIdx += 1
                    if indices[successor] == nil {
                        work.append((successor, 0))
                    } else if onStack.contains(successor), let successorIndex = indices[successor] {
                        lowLinks[node] = min(lowLinks[node, default: index], successorIndex)
                    }
                    continue
                }
                if lowLinks[node] == indices[node] {
                    var component: [String] = []
                    while let member = stack.popLast() {
                        onStack.remove(member)
                        component.append(member)
                        if member == node {
                            break
                        }
                    }
                    components.append(component)
                }
                work.removeLast()
                if let (parent, _) = work.last {
                    lowLinks[parent] = min(lowLinks[parent, default: index], lowLinks[node, default: index])
                }
            }
        }
        return components
    }
}


// MARK: Exports

extension GroveModuleDependencyGraph {
    /// A Graphviz DOT representation of the dependency graph.
    ///
    /// Required dependencies are drawn as solid edges, optional ones dashed, `load` ones with a label;
    /// un-injected dependencies are gray, and any edges participating in a cycle are highlighted in red.
    /// Render e.g. via `dot -Tpdf graph.dot -o graph.pdf`, or by pasting into an online Graphviz viewer.
    var dotDescription: String {
        var cycleComponentById: [String: Int] = [:]
        for (componentIdx, component) in cycles.enumerated() {
            for member in component {
                cycleComponentById[member] = componentIdx
            }
        }
        var lines = [
            "digraph GroveModuleDependencies {",
            "    rankdir=LR",
            "    node [shape=box, fontname=\"Helvetica\"]"
        ]
        for node in nodes.sorted(using: KeyPathComparator(\.id)) {
            lines.append("    \(Self.quoted(node.id))")
        }
        for ghost in Set(edges.filter { !$0.isInjected }.map(\.target)).subtracting(nodes.map(\.id)).sorted() {
            lines.append("    \(Self.quoted(ghost)) [color=gray, fontcolor=gray, style=dashed]")
        }
        for edge in edges.sorted(using: [KeyPathComparator(\.source), KeyPathComparator(\.target)]) {
            var attributes: [String] = []
            if edge.kind == .optional {
                attributes.append("style=dashed")
            }
            if edge.kind == .load {
                attributes.append("label=\"load\"")
            }
            if !edge.isInjected {
                attributes.append("color=gray")
            } else if let component = cycleComponentById[edge.source], cycleComponentById[edge.target] == component {
                attributes.append("color=red")
                attributes.append("penwidth=2")
            }
            let suffix = attributes.isEmpty ? "" : " [\(attributes.joined(separator: ", "))]"
            lines.append("    \(Self.quoted(edge.source)) -> \(Self.quoted(edge.target))\(suffix)")
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    /// An indented, human-readable tree representation of the dependency graph, starting at the modules nothing depends on.
    ///
    /// Every module's dependency subtree is expanded only once; further occurrences are marked with `↩`.
    var treeDescription: String {
        struct WorkItem {
            let id: String
            let depth: Int
            /// The kind of the edge we arrived at this module through.
            let kind: EdgeKind?
        }
        let hasIncomingEdge = Set(edges.filter(\.isInjected).map(\.target))
        let roots = nodes.filter { !hasIncomingEdge.contains($0.id) }.map(\.id)
        var lines: [String] = []
        var expanded: Set<String> = []
        var work: [WorkItem] = (roots.isEmpty ? nodes.map(\.id) : roots)
            .sorted()
            .reversed()
            .map { WorkItem(id: $0, depth: 0, kind: nil) }
        while let item = work.popLast() {
            let indent = String(repeating: "    ", count: item.depth)
            let kindSuffix = item.kind.map { $0 == .required ? "" : " (\($0.rawValue))" } ?? ""
            let isFirstExpansion = expanded.insert(item.id).inserted
            let outgoing = edges.filter { $0.source == item.id }
            lines.append("\(indent)\(item.id)\(kindSuffix)\(isFirstExpansion || outgoing.isEmpty ? "" : " ↩")")
            guard isFirstExpansion else {
                continue
            }
            for edge in outgoing.sorted(using: KeyPathComparator(\.target)).reversed() {
                if edge.isInjected {
                    work.append(WorkItem(id: edge.target, depth: item.depth + 1, kind: edge.kind))
                } else {
                    lines.append("\(indent)    \(edge.target) (\(edge.kind.rawValue), not injected)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func quoted(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}


// MARK: Reflection-based Edge Extraction

extension GroveModuleDependencyGraph {
    private struct ExtractedDeclaration {
        let declaredTypeName: String
        let kind: EdgeKind
        let injectedModule: (any Module)?
    }

    /// Extracts all `@Dependency` declarations of a module, by mirroring into Grove's
    /// `_DependencyPropertyWrapper` → `DependencyCollection` → `DependencyContext<M>` storage.
    private static func dependencyDeclarations(of module: any Module, warnings: inout [String]) -> [ExtractedDeclaration] {
        var declarations: [ExtractedDeclaration] = []
        for child in Mirror(reflecting: module).children {
            guard "\(type(of: child.value))".hasPrefix("_DependencyPropertyWrapper<") else {
                continue
            }
            let property = "\(type(of: module)).\(child.label ?? "?")"
            guard let collection = Mirror(reflecting: child.value).descendant("dependencies") else {
                warnings.append("\(property): no 'dependencies' collection; did Grove's internal layout change?")
                continue
            }
            guard let entries = Mirror(reflecting: collection).descendant("entries") else {
                warnings.append("\(property): no 'entries' in DependencyCollection; did Grove's internal layout change?")
                continue
            }
            for entry in Mirror(reflecting: entries).children.map(\.value) {
                if let declaration = extractDeclaration(from: entry) {
                    declarations.append(declaration)
                } else {
                    warnings.append("\(property): unable to decode entry of type \(type(of: entry))")
                }
            }
        }
        return declarations
    }

    /// Decodes a single Grove `DependencyContext<M>` instance.
    private static func extractDeclaration(from entry: Any) -> ExtractedDeclaration? {
        // "DependencyContext<SomeModule>" → "SomeModule"
        let entryTypeName = "\(type(of: entry))"
        guard entryTypeName.hasPrefix("DependencyContext<"), entryTypeName.hasSuffix(">"),
              let kindValue = Mirror(reflecting: entry).descendant("type") else {
            return nil
        }
        let declaredTypeName = String(entryTypeName.dropFirst("DependencyContext<".count).dropLast())
        let kind = EdgeKind(rawValue: "\(kindValue)") ?? .required
        var injected: (any Module)?
        if let injectedValue = Mirror(reflecting: entry).descendant("injectedDependency"),
           let reference = flattenedOptional(injectedValue) {
            injected = moduleFromDynamicReference(reference)
        }
        return ExtractedDeclaration(declaredTypeName: declaredTypeName, kind: kind, injectedModule: injected)
    }

    /// Resolves Grove's `DynamicReference<M>` enum (`.element(M)` / `.weakElement(WeaklyStoredElement)`) to the referenced module.
    private static func moduleFromDynamicReference(_ reference: Any) -> (any Module)? {
        guard let payload = Mirror(reflecting: reference).children.first?.value else {
            return nil
        }
        if let module = payload as? any Module {
            return module
        }
        // .weakElement stores a WeaklyStoredElement struct wrapping a weak optional reference
        guard let wrappedReference = Mirror(reflecting: payload).children.first?.value,
              let element = flattenedOptional(wrappedReference) else {
            return nil
        }
        return element as? any Module
    }

    private static func flattenedOptional(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else {
            return value
        }
        guard let wrapped = mirror.children.first?.value else {
            return nil
        }
        return flattenedOptional(wrapped)
    }
}


extension Grove {
    /// Computes a snapshot of the dependency graph between all currently loaded modules.
    @MainActor var moduleDependencyGraph: GroveModuleDependencyGraph {
        GroveModuleDependencyGraph(self)
    }
}
