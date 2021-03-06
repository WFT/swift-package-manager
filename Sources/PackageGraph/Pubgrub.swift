/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2019 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import struct SPMUtility.Version
import Basic
import struct PackageModel.PackageReference

/// A term represents a statement about a package that may be true or false.
public struct Term: Equatable, Hashable {
    let package: PackageReference
    let requirement: PackageRequirement
    let isPositive: Bool

    init(package: PackageReference, requirement: PackageRequirement, isPositive: Bool) {
        self.package = package
        self.requirement = requirement
        self.isPositive = isPositive
    }

    init(_ package: PackageReference, _ requirement: PackageRequirement) {
        self.init(package: package, requirement: requirement, isPositive: true)
    }

    /// Create a new negative term.
    init(not package: PackageReference, _ requirement: PackageRequirement) {
        self.init(package: package, requirement: requirement, isPositive: false)
    }

    /// The same term with an inversed `isPositive` value.
    var inverse: Term {
        return Term(
            package: package,
            requirement: requirement,
            isPositive: !isPositive)
    }

    /// Check if this term satisfies another term, e.g. if `self` is true,
    /// `other` must also be true.
    func satisfies(_ other: Term) -> Bool {
        // TODO: This probably makes more sense as isSatisfied(by:) instead.
        guard self.package == other.package else { return false }
        return self.relation(with: other) == .subset
    }

    /// Create an intersection with another term.
    func intersect(with other: Term) -> Term? {
        guard self.package == other.package else { return nil }
        return intersect(withRequirement: other.requirement, andPolarity: other.isPositive)
    }

    /// Create an intersection with a requirement and polarity returning a new
    /// term which represents the version constraints allowed by both the current
    /// and given term.
    /// Returns `nil` if an intersection is not possible (possibly due to being
    /// constrained on branches, revisions, local, etc. or entirely different packages).
    func intersect(withRequirement requirement: PackageRequirement,
                   andPolarity otherIsPositive: Bool) -> Term? {
        // Intersections can only be calculated if both sides have version-based
        // requirements. 
        guard
            case .versionSet(let lhs) = self.requirement,
            case .versionSet(let rhs) = requirement else
        {
            return nil
        }

        let intersection: VersionSetSpecifier?
        let isPositive: Bool
        switch (self.isPositive, otherIsPositive) {
        case (false, false):
            if case .range(let lhs) = lhs, case .range(let rhs) = rhs {
                let lower = min(lhs.lowerBound, rhs.lowerBound)
                let upper = max(lhs.upperBound, rhs.upperBound)
                intersection = .range(lower..<upper)
            } else {
                intersection = lhs.intersection(rhs)
            }
            isPositive = false
        case (true, true):
            intersection = lhs.intersection(rhs)
            isPositive = true
        case (true, false):
            intersection = lhs.intersection(withInverse: rhs)
            isPositive = true
        case (false, true):
            intersection = rhs.intersection(withInverse: lhs)
            isPositive = true
        }

        guard let versionIntersection = intersection, versionIntersection != .empty else {
            return nil
        }

        return Term(package: package, requirement: .versionSet(versionIntersection), isPositive: isPositive)
    }

    func difference(with other: Term) -> Term? {
        return self.intersect(with: other.inverse)
    }

    private func with(_ requirement: PackageRequirement) -> Term {
        return Term(
            package: self.package,
            requirement: requirement,
            isPositive: self.isPositive)
    }

    /// Verify if the term fulfills all requirements to be a valid choice for
    /// making a decision in the given partial solution.
    /// - There has to exist a positive derivation for it.
    /// - There has to be no decision for it.
    /// - The package version has to match all assignments.
    func isValidDecision(for solution: PartialSolution) -> Bool {
        for assignment in solution.assignments where assignment.term.package == package {
            assert(!assignment.isDecision, "Expected assignment to be a derivation.")
            guard satisfies(assignment.term) else { return false }
        }
        return true
    }

    func relation(with other: Term) -> SetRelation {
        // From: https://github.com/dart-lang/pub/blob/master/lib/src/solver/term.dart

        if self.package != other.package {
            fatalError("attempting to compute relation between different packages \(self) \(other)")
        }

        if other.isPositive {
            if self.isPositive {
                // If the second requirement contains all the elements of
                // the first requirement, then it is a subset relation.
                if other.requirement.containsAll(self.requirement) {
                    return .subset
                }

                // If second requirement contains any requirements of
                // the first, then the relation is overlapping.
                if other.requirement.containsAny(self.requirement) {
                    return .overlap
                }

                // Otherwise it is disjoint.
                return .disjoint
            } else {
                if self.requirement.containsAll(other.requirement) {
                    return .disjoint
                }
                return .overlap
            }
        } else {
            if self.isPositive {
                if !other.requirement.containsAny(self.requirement) {
                    return .subset
                }
                if other.requirement.containsAll(self.requirement) {
                    return .disjoint
                }
                return .overlap
            } else {
                if self.requirement.containsAll(other.requirement) {
                    return .subset
                }
                return .overlap
            }
        }
    }

    enum SetRelation: Equatable {
        /// The sets have nothing in common.
        case disjoint
        /// The sets have elements in common but first set is not a subset of second.
        case overlap
        /// The second set contains all elements of the first set.
        case subset
    }
}

extension PackageRequirement {
    func containsAll(_ other: PackageRequirement) -> Bool {
        switch (self, other) {
        case (.versionSet(let lhs), .versionSet(let rhs)):
            return lhs.intersection(rhs) == rhs
        default:
            fatalError("unhandled \(self), \(other)")
        }
    }

    func containsAny(_ other: PackageRequirement) -> Bool {
        switch (self, other) {
        case (.versionSet(let lhs), .versionSet(let rhs)):
            return lhs.intersection(rhs) != .empty
        default:
            fatalError("unhandled \(self), \(other)")
        }
    }
}

extension Term: CustomStringConvertible {
    public var description: String {
        let pkg = "\(package)"
        var req = ""
        switch requirement {
        case .unversioned:
            req = "unversioned"
        case .revision(let rev):
            req = rev
        case .versionSet(let vs):
            switch vs {
            case .any:
                req = "*"
            case .empty:
                req = "()"
            case .exact(let v):
                req = v.description
            case .range(let range):
                req = range.description
            }
        }

        if !isPositive {
            return "¬\(pkg) \(req)"
        }
        return "\(pkg) \(req)"
    }
}

private extension Range where Bound == Version {
    func contains(_ other: Range<Version>) -> Bool {
        return contains(version: other.lowerBound) &&
            contains(version: other.upperBound)
    }
}

/// A set of terms that are incompatible with each other and can therefore not
/// all be true at the same time. In dependency resolution, these are derived
/// from version requirements and when running into unresolvable situations.
public struct Incompatibility: Equatable, Hashable {
    let terms: OrderedSet<Term>
    let cause: Cause

    init(terms: OrderedSet<Term>, cause: Cause) {
        self.terms = terms
        self.cause = cause
    }

    init(_ terms: Term..., root: PackageReference, cause: Cause = .root) {
        let termSet = OrderedSet(terms)
        self.init(termSet, root: root, cause: cause)
    }

    init(_ terms: OrderedSet<Term>, root: PackageReference, cause: Cause) {
        assert(terms.count > 0, "An incompatibility must contain at least one term.")

        // Remove the root package from generated incompatibilities, since it will
        // always be selected.
        var terms = terms
        if terms.count > 1,
            case .conflict(conflict: _, other: _) = cause,
            terms.contains(where: { $0.isPositive && $0.package == root })
        {
            terms = OrderedSet(terms.filter { !$0.isPositive || $0.package != root })
        }

        let normalizedTerms = normalize(terms: terms.contents)
        self.init(terms: OrderedSet(normalizedTerms), cause: cause)
    }
}

extension Incompatibility: CustomStringConvertible {
    public var description: String {
        let terms = self.terms
            .map(String.init)
            .joined(separator: ", ")
        return "{\(terms)}"
    }
}

extension Incompatibility {
    /// Every incompatibility has a cause to explain its presence in the
    /// derivation graph. Only the root incompatibility uses `.root`. All other
    /// incompatibilities are either obtained from dependency constraints,
    /// decided upon in decision making or derived during unit propagation or
    /// conflict resolution.
    /// Using this information we can build up a derivation graph by following
    /// the tree of causes. All leaf nodes are external dependencies and all
    /// internal nodes are derived incompatibilities.
    ///
    /// An example graph could look like this:
    /// ```
    /// ┌────────────────────────────┐ ┌────────────────────────────┐
    /// │{foo ^1.0.0, not bar ^2.0.0}│ │{bar ^2.0.0, not baz ^3.0.0}│
    /// └─────────────┬──────────────┘ └──────────────┬─────────────┘
    ///               │      ┌────────────────────────┘
    ///               ▼      ▼
    /// ┌─────────────┴──────┴───────┐ ┌────────────────────────────┐
    /// │{foo ^1.0.0, not baz ^3.0.0}│ │{root 1.0.0, not foo ^1.0.0}│
    /// └─────────────┬──────────────┘ └──────────────┬─────────────┘
    ///               │   ┌───────────────────────────┘
    ///               ▼   ▼
    ///         ┌─────┴───┴──┐
    ///         │{root 1.0.0}│
    ///         └────────────┘
    /// ```
    indirect enum Cause: Equatable, Hashable {
        /// The root incompatibility.
        case root
        /// The incompatibility represents a package's dependency on another
        /// package.
        case dependency(package: PackageReference)
        /// The incompatibility was derived from two others during conflict
        /// resolution.
        case conflict(conflict: Incompatibility, other: Incompatibility)
        /// There exists no version to fulfill the specified requirement.
        case noAvailableVersion
        // TODO: Figure out what other cases should be represented here.
        // - SDK requirements
        // - package not found

        var isConflict: Bool {
            if case .conflict = self {
                return true
            }
            return false
        }

        /// Returns whether this cause can be represented in a single line of the
        /// error output.
        var isSingleLine: Bool {
            guard case .conflict(let lhs, let rhs) = self else {
                // TODO: Sure?
                return false
            }
            if case .conflict = lhs.cause, case .conflict = rhs.cause {
                return false
            }
            return true
        }
    }
}

/// An assignment that is either decided upon during decision making or derived
/// from previously known incompatibilities during unit propagation.
///
/// All assignments store a term (a package identifier and a version
/// requirement) and a decision level, which represents the number of decisions
/// at or before it in the partial solution that caused it to be derived. This
/// is later used during conflict resolution to figure out how far back to jump
/// when a conflict is found.
public struct Assignment: Equatable {
    let term: Term
    let decisionLevel: Int
    let cause: Incompatibility?
    let isDecision: Bool

    private init(
        term: Term,
        decisionLevel: Int,
        cause: Incompatibility?,
        isDecision: Bool
    ) {
        self.term = term
        self.decisionLevel = decisionLevel
        self.cause = cause
        self.isDecision = isDecision
    }

    /// An assignment made during decision making.
    static func decision(_ term: Term, decisionLevel: Int) -> Assignment {
        assert(term.requirement.isExact, "Cannot create a decision assignment with a non-exact version selection.")

        return self.init(
            term: term,
            decisionLevel: decisionLevel,
            cause: nil,
            isDecision: true)
    }

    /// An assignment derived from previously known incompatibilities during
    /// unit propagation.
    static func derivation(
        _ term: Term,
        cause: Incompatibility,
        decisionLevel: Int) -> Assignment {
        return self.init(
            term: term,
            decisionLevel: decisionLevel,
            cause: cause,
            isDecision: false)
    }
}

extension Assignment: CustomStringConvertible {
    public var description: String {
        switch self.isDecision {
        case true:
            return "[Decision \(decisionLevel): \(term)]"
        case false:
            return "[Derivation: \(term) ← \(cause?.description ?? "-")]"
        }
    }
}

/// The partial solution is a constantly updated solution used throughout the
/// dependency resolution process, tracking know assignments.
final class PartialSolution {
    var root: PackageReference?

    /// All known assigments.
    private(set) var assignments: [Assignment]

    /// All known decisions.
    private(set) var decisions: [PackageReference: Version] = [:]

    /// The intersection of all positive assignments for each package, minus any
    /// negative assignments that refer to that package.
    private(set) var _positive: OrderedDictionary<PackageReference, Term> = [:]

    /// Union of all negative assignments for a package.
    ///
    /// Only present if a package has no postive assignment.
    private(set) var _negative: [PackageReference: Term] = [:]

    /// The current decision level.
    var decisionLevel: Int {
        return decisions.count - 1
    }

    init(assignments: [Assignment] = []) {
        self.assignments = assignments
        for assignment in assignments {
            register(assignment)
        }
    }

    /// A list of all packages that have been assigned, but are not yet satisfied.
    var undecided: [Term] {
        return _positive.values.filter { !decisions.keys.contains($0.package) }
    }

    /// Create a new derivation assignment and add it to the partial solution's
    /// list of known assignments.
    func derive(_ term: Term, cause: Incompatibility) {
        let derivation = Assignment.derivation(term, cause: cause, decisionLevel: decisionLevel)
        self.assignments.append(derivation)
        register(derivation)
    }

    /// Create a new decision assignment and add it to the partial solution's
    /// list of known assignments.
    func decide(_ package: PackageReference, atExactVersion version: Version) {
        decisions[package] = version
        let term = Term(package, .versionSet(.exact(version)))
        let decision = Assignment.decision(term, decisionLevel: decisionLevel)
        self.assignments.append(decision)
        register(decision)
    }

    /// Populates the _positive and _negative poperties with the assignment.
    private func register(_ assignment: Assignment) {
        let term = assignment.term
        let pkg = term.package

        if let positive = _positive[pkg] {
            _positive[term.package] = positive.intersect(with: term)
            return
        }

        let newTerm = _negative[pkg].flatMap{ term.intersect(with: $0) } ?? term
        
        if newTerm.isPositive {
            _negative[pkg] = nil
            _positive[pkg] = newTerm
        } else {
            _negative[pkg] = newTerm
        }
    }

    /// Returns the first Assignment in this solution such that the list of
    /// assignments up to and including that entry satisfies term.
    func satisfier(for term: Term) -> Assignment {
        var assignedTerm: Term?

        for assignment in assignments {
            guard assignment.term.package == term.package else {
                continue
            }
            assignedTerm = assignedTerm.flatMap{ $0.intersect(with: assignment.term) } ?? assignment.term

            if assignedTerm!.satisfies(term) {
                return assignment
            }
        }

        fatalError("term \(term) not satisfied")
    }

    /// Backtrack to a specific decision level by dropping all assignments with
    /// a decision level which is greater.
    func backtrack(toDecisionLevel decisionLevel: Int) {
        var toBeRemoved: [(Int, Assignment)] = []

        for (idx, assignment) in zip(0..., assignments) {
            if assignment.decisionLevel > decisionLevel {
                toBeRemoved.append((idx, assignment))
            }
        }

        for (idx, remove) in toBeRemoved.reversed() {
            let assignment = assignments.remove(at: idx)
            if assignment.isDecision {
                decisions.removeValue(forKey: remove.term.package)
            }
        }

        // FIXME: We can optimize this by recomputing only the removed things.
        _negative.removeAll()
        _positive.removeAll()
        for assignment in assignments {
            register(assignment)
        }
    }

    /// Returns true if the given term satisfies the partial solution.
    func satisfies(_ term: Term) -> Bool {
        return self.relation(with: term) == .subset
    }

    /// Returns the set relation of the partial solution with the given term.
    func relation(with term: Term) -> Term.SetRelation {
        let pkg = term.package
        if let positive = _positive[pkg] {
            return positive.relation(with: term)
        } else if let negative = _negative[pkg] {
            return negative.relation(with: term)
        }
        return .overlap
    }
}

/// Normalize terms so that at most one term refers to one package/polarity
/// combination. E.g. we don't want both a^1.0.0 and a^1.5.0 to be terms in the
/// same incompatibility, but have these combined by intersecting their version
/// requirements to a^1.5.0.
fileprivate func normalize(
    terms: [Term]) -> [Term] {
    let dict = terms.reduce(into: [PackageReference: (req: PackageRequirement, polarity: Bool)]()) {
        res, term in
        // Don't try to intersect if this is the first time we're seeing this package.
        guard let previous = res[term.package] else {
            res[term.package] = (term.requirement, term.isPositive)
            return
        }

        let intersection = term.intersect(withRequirement: previous.req,
                                          andPolarity: previous.polarity)
        assert(intersection != nil, """
            Attempting to create an incompatibility with terms for \(term.package) \
            intersecting versions \(previous) and \(term.requirement). These are \
            mutually exclusive and can't be intersected, making this incompatibility \
            irrelevant.
            """)
        res[term.package] = (intersection!.requirement, intersection!.isPositive)
    }
    // Sorting the values for deterministic test runs.
    let sortedKeys = dict.keys.sorted(by: { lhs, rhs in
        return String(describing: lhs) < String(describing: rhs)
    })
    return sortedKeys.map { pkg in
        let req = dict[pkg]!
        return Term(package: pkg, requirement: req.req, isPositive: req.polarity)
    }
}

/// A step the resolver takes to advance its progress, e.g. deriving a new assignment
/// or creating a new incompatibility based on a package's dependencies.
public struct GeneralTraceStep {
    /// The traced value, e.g. an incompatibility or term.
    public let value: Traceable
    /// How this value came to be.
    public let type: StepType
    /// Where this value was created.
    public let location: Location
    /// A previous step that caused this step.
    public let cause: String?
    /// The solution's current decision level.
    public let decisionLevel: Int

    /// A step can either store an incompatibility or a decided or derived
    /// assignment's term.
    public enum StepType: String {
        case incompatibility
        case decision
        case derivation
    }

    /// The location a step is created at.
    public enum Location: String {
        case topLevel = "top level"
        case unitPropagation = "unit propagation"
        case decisionMaking = "decision making"
        case conflictResolution = "conflict resolution"
    }
}

/// A step the resolver takes during conflict resolution.
public struct ConflictResolutionTraceStep {
    /// The conflicted incompatibility.
    public let incompatibility: Incompatibility
    public let term: Term
    /// The satisfying assignment.
    public let satisfier: Assignment
}

public enum TraceStep {
    case general(GeneralTraceStep)
    case conflictResolution(ConflictResolutionTraceStep)
}

public protocol Traceable: CustomStringConvertible {}
extension Incompatibility: Traceable {}
extension Term: Traceable {}

/// The solver that is able to transitively resolve a set of package constraints
/// specified by a root package.
public final class PubgrubDependencyResolver {

    /// The type of the constraints the resolver operates on.
    public typealias Constraint = PackageContainerConstraint

    /// The current best guess for a solution satisfying all requirements.
    var solution = PartialSolution()

    /// A collection of all known incompatibilities matched to the packages they
    /// refer to. This means an incompatibility can occur several times.
    var incompatibilities: [PackageReference: [Incompatibility]] = [:]

    /// Find all incompatibilities containing a positive term for a given package.
    func positiveIncompatibilities(for package: PackageReference) -> [Incompatibility]? {
        guard let all = incompatibilities[package] else {
            return nil
        }
        return all.filter {
            $0.terms.first { $0.package == package }!.isPositive
        }
    }

    /// The root package reference.
    private(set) var root: PackageReference?

    /// The container provider used to load package containers.
    let provider: PackageContainerProvider

    /// The resolver's delegate.
    let delegate: DependencyResolverDelegate?

    /// Skip updating containers while fetching them.
    private let skipUpdate: Bool

    /// Should resolver prefetch the containers.
    private let isPrefetchingEnabled: Bool

    /// Set the package root.
    func set(_ root: PackageReference) {
        self.root = root
        self.solution.root = root
    }

    func trace(
        value: Traceable,
        type: GeneralTraceStep.StepType,
        location: GeneralTraceStep.Location,
        cause: String?
    ) {
        let step = GeneralTraceStep(value: value,
                             type: type,
                             location: location,
                             cause: cause,
                             decisionLevel: solution.decisionLevel)
        delegate?.trace(.general(step))
    }

    /// Trace a conflict resolution step.
    func trace(
        incompatibility: Incompatibility,
        term: Term,
        satisfier: Assignment
        ) {
        let step = ConflictResolutionTraceStep(incompatibility: incompatibility,
                                               term: term,
                                               satisfier: satisfier)
        delegate?.trace(.conflictResolution(step))
    }

    func decide(_ package: PackageReference, version: Version, location: GeneralTraceStep.Location) {
        let term = Term(package, .versionSet(.exact(version)))
        // FIXME: Shouldn't we check this _before_ making a decision?
        assert(term.isValidDecision(for: solution))

        trace(value: term, type: .decision, location: location, cause: nil)
        solution.decide(package, atExactVersion: version)
    }

    func derive(_ term: Term, cause: Incompatibility, location: GeneralTraceStep.Location) {
        trace(value: term, type: .derivation, location: location, cause: nil)
        solution.derive(term, cause: cause)
    }

    public init(
        _ provider: PackageContainerProvider,
        _ delegate: DependencyResolverDelegate? = nil,
        isPrefetchingEnabled: Bool = false,
        skipUpdate: Bool = false
        ) {
        self.provider = provider
        self.delegate = delegate
        self.isPrefetchingEnabled = isPrefetchingEnabled
        self.skipUpdate = skipUpdate
    }

    /// Add a new incompatibility to the list of known incompatibilities.
    func add(_ incompatibility: Incompatibility, location: GeneralTraceStep.Location) {
        trace(value: incompatibility, type: .incompatibility, location: location, cause: nil)
        for package in incompatibility.terms.map({ $0.package }) {
            if incompatibilities[package] != nil {
                if !incompatibilities[package]!.contains(incompatibility) {
                    incompatibilities[package]!.append(incompatibility)
                }
            } else {
                incompatibilities[package] = [incompatibility]
            }
        }
    }

    public typealias Result = DependencyResolver.Result

    // TODO: This should be the actual (and probably only) entrypoint to version solving.
    /// Run the resolution algorithm on a root package finding a valid assignment of versions.
    public func solve(root: PackageReference, pins: [Constraint]) -> Result {
        // Prefetch the pins.
        if isPrefetchingEnabled {
            prefetch(containers: pins.map({ $0.identifier }))
        }

        self.set(root)
        do {
            return try .success(solve(constraints: [], pins: pins))
        } catch {
            return .error(error)
        }
    }

    /// Execute the resolution algorithm to find a valid assignment of versions.
    public func solve(dependencies: [Constraint], pins: [Constraint]) -> Result {
        guard let root = dependencies.first?.identifier else {
            fatalError("expected a root package")
        }
        self.root = root
        return solve(root: root, pins: pins)
    }

    public enum PubgrubError: Swift.Error, Equatable {
        case unresolvable(Incompatibility)
    }

    /// Find a set of dependencies that fit the given constraints. If dependency
    /// resolution is unable to provide a result, an error is thrown.
    /// - Warning: It is expected that the root package reference has been set
    ///            before this is called.
    public func solve(
        constraints: [Constraint], pins: [Constraint]
    ) throws -> [(container: PackageReference, binding: BoundVersion)] {
        // TODO: Handle pins
        guard let root = self.root else {
            fatalError("Expected resolver root reference to be set.")
        }

        // Handle root, e.g. add dependencies and root decision.
        //
        // We add the dependencies before deciding on a version for root
        // to avoid inserting the wrong decision level.
        let rootContainer = try getContainer(for: self.root!)
        for dependency in try rootContainer.getUnversionedDependencies() {
            let incompatibility = Incompatibility(
                Term(root, .versionSet(.exact("1.0.0"))),
                Term(not: dependency.identifier, dependency.requirement),
                root: root, cause: .root)
            add(incompatibility, location: .topLevel)
        }
        decide(root, version: "1.0.0", location: .topLevel)

        do {
            try run()
        } catch PubgrubError.unresolvable(let conflict) {
            throw PubgrubError.unresolvable(conflict)
        } catch {
            assertionFailure("Unexpected error \(error)")
            throw error
        }

        let decisions = solution.assignments.filter { $0.isDecision }
        let finalAssignments: [(container: PackageReference, binding: BoundVersion)] = decisions.map { assignment in
            var boundVersion: BoundVersion
            switch assignment.term.requirement {
            case .versionSet(.exact(let version)):
                boundVersion = .version(version)
            case .revision(let rev):
                boundVersion = .revision(rev)
            case .versionSet(.range(_)):
                // FIXME: A new requirement type that makes having a range here impossible feels like the correct thing to do.
                fatalError("Solution should not contain version ranges.")
            case .unversioned, .versionSet(.any):
                boundVersion = .unversioned
            case .versionSet(.empty):
                fatalError("Solution should not contain empty versionSet requirement.")
            }

            return (assignment.term.package, boundVersion)
        }

        return finalAssignments.filter { $0.container != root }
    }

    /// Perform unit propagation, resolving conflicts if necessary and making
    /// decisions if nothing else is left to be done.
    /// After this method returns `solution` is either populated with a list of
    /// final version assignments or an error is thrown.
    func run() throws {
        var next: PackageReference? = root
        while let nxt = next {
            try propagate(nxt)

            // If decision making determines that no more decisions are to be
            // made, it returns nil to signal that version solving is done.
            next = try makeDecision()
        }
    }

    /// Perform unit propagation to derive new assignments based on the current
    /// partial solution.
    /// If a conflict is found, the conflicting incompatibility is returned to
    /// resolve the conflict on.
    func propagate(_ package: PackageReference) throws {
        var changed: OrderedSet<PackageReference> = [package]

        while !changed.isEmpty {
            let package = changed.removeFirst()

            // According to the experience of pub developers, conflict
            // resolution produces more general incompatibilities later on
            // making it advantageous to check those first.
            loop: for incompatibility in positiveIncompatibilities(for: package)?.reversed() ?? [] {
                // FIXME: This needs to find set relation for each term in the incompatibility since
                // that matters. For e.g., 1.1.0..<2.0.0 won't satisfy 1.0.0..<2.0.0 but they're
                // overlapping.
                let result = propagate(incompatibility: incompatibility)

                switch result {
                case .conflict:
                    let rootCause = try _resolve(conflict: incompatibility)
                    let rootCauseResult = propagate(incompatibility: rootCause)

                    guard case .almostSatisfied(let pkg) = rootCauseResult else {
                        fatalError("""
                            Expected root cause \(rootCause) to almost satisfy the \
                            current partial solution:
                            \(solution.assignments.map { " * \($0.description)" }.joined(separator: "\n"))\n
                            """)
                    }

                    changed.removeAll(keepingCapacity: false)
                    changed.append(pkg)
                    
                    break loop
                case .almostSatisfied(let package):
                    changed.append(package)
                case .none:
                    break
                }
            }
        }
    }

    func propagate(incompatibility: Incompatibility) -> PropagationResult {
        var unsatisfied: Term?

        for term in incompatibility.terms {
            let relation = solution.relation(with: term)

            if relation == .disjoint {
                return .none
            } else if relation == .overlap {
                if unsatisfied != nil {
                    return .none
                }
                unsatisfied = term
            }
        }

        // We have a conflict if all the terms of the incompatibility were satisfied.
        guard let unsatisfiedTerm = unsatisfied else {
            return .conflict
        }

        derive(unsatisfiedTerm.inverse, cause: incompatibility, location: .unitPropagation)

        return .almostSatisfied(package: unsatisfiedTerm.package)
    }

    enum PropagationResult {
        case conflict
        case almostSatisfied(package: PackageReference)
        case none
    }

    func _resolve(conflict: Incompatibility) throws -> Incompatibility {
        // Based on:
        // https://github.com/dart-lang/pub/tree/master/doc/solver.md#conflict-resolution
        // https://github.com/dart-lang/pub/blob/master/lib/src/solver/version_solver.dart#L201
        var incompatibility = conflict
        var createdIncompatibility = false

        while !isCompleteFailure(incompatibility) {
            var mostRecentTerm: Term?
            var mostRecentSatisfier: Assignment?
            var difference: Term?
            var previousSatisfierLevel = 0

            for term in incompatibility.terms {
                let satisfier = solution.satisfier(for: term)

                if let _mostRecentSatisfier = mostRecentSatisfier {
                    let mostRecentSatisfierIdx = solution.assignments.index(of: _mostRecentSatisfier)!
                    let satisfierIdx = solution.assignments.index(of: satisfier)!

                    if mostRecentSatisfierIdx < satisfierIdx {
                        previousSatisfierLevel = max(previousSatisfierLevel, _mostRecentSatisfier.decisionLevel)
                        mostRecentTerm = term
                        mostRecentSatisfier = satisfier
                        difference = nil
                    } else {
                        previousSatisfierLevel = max(previousSatisfierLevel, satisfier.decisionLevel)
                    }
                } else {
                    mostRecentTerm = term
                    mostRecentSatisfier = satisfier
                }

                if mostRecentTerm == term {
                    difference = mostRecentSatisfier?.term.difference(with: term)
                    if let difference = difference {
                        previousSatisfierLevel = max(previousSatisfierLevel, solution.satisfier(for: difference.inverse).decisionLevel)
                    }
                }
            }

            guard let _mostRecentSatisfier = mostRecentSatisfier else {
                fatalError()
            }

            if previousSatisfierLevel < _mostRecentSatisfier.decisionLevel || _mostRecentSatisfier.cause == nil {
                solution.backtrack(toDecisionLevel: previousSatisfierLevel)
                if createdIncompatibility {
                    add(incompatibility, location: .conflictResolution)
                }
                return incompatibility
            }

            let priorCause = _mostRecentSatisfier.cause!

            var newTerms = incompatibility.terms.filter{ $0 != mostRecentTerm }
            newTerms += priorCause.terms.filter({ $0.package != _mostRecentSatisfier.term.package })

            if let _difference = difference {
                newTerms.append(_difference.inverse)
            }

            incompatibility = Incompatibility(
                OrderedSet(newTerms),
                root: root!,
                cause: .conflict(conflict: incompatibility, other: priorCause))
            createdIncompatibility = true
        }

        throw PubgrubError.unresolvable(incompatibility)
    }

    /// Does a given incompatibility specify that version solving has entirely
    /// failed, meaning this incompatibility is either empty or only for the root
    /// package.
    private func isCompleteFailure(_ incompatibility: Incompatibility) -> Bool {
        guard !incompatibility.terms.isEmpty else { return true }
        return incompatibility.terms.count == 1 && incompatibility.terms.first?.package == root
    }

    func makeDecision() throws -> PackageReference? {
        let undecided = solution.undecided

        // If there are no more undecided terms, version solving is complete.
        guard !undecided.isEmpty else {
            return nil
        }

        // FIXME: We should choose a package with least available versions for the
        // constraints that we have so far on the package.
        let pkgTerm = undecided.first!

        // Get the best available version for this package.
        guard let version = try getBestAvailableVersion(for: pkgTerm) else {
            add(Incompatibility(pkgTerm, root: root!, cause: .noAvailableVersion), location: .decisionMaking)
            return pkgTerm.package
        }

        // Add all of this version's dependencies as incompatibilities.
        let depIncompatibilities = try incompatibilites(for: pkgTerm.package, at: version)

        var haveConflict = false
        for incompatibility in depIncompatibilities {
            // Add the incompatibility to our partial solution.
            add(incompatibility, location: .decisionMaking)

            // Check if this incompatibility will statisfy the solution.
            haveConflict = haveConflict || incompatibility.terms.allSatisfy {
                // We only need to check if the terms other than this package
                // are satisfied because we _know_ that the terms matching
                // this package will be satisfied if we make this version
                // as a decision.
                $0.package == pkgTerm.package || solution.satisfies($0)
            }
        }

        // Decide this version if there was no conflict with its dependencies.
        if !haveConflict {
            decide(pkgTerm.package, version: version, location: .decisionMaking)
        }

        return pkgTerm.package
    }

    // MARK: - Error Reporting

    private var derivations: [Incompatibility: Int] = [:]

    func reportError(for incompatibility: Incompatibility) -> String {
        /// Populate `derivations`.
        func countDerivations(_ i: Incompatibility) {
            derivations[i, default: 0] += 1
            if case .conflict(let lhs, let rhs) = i.cause {
                countDerivations(lhs)
                countDerivations(rhs)
            }
        }

        countDerivations(incompatibility)

        let stream = BufferedOutputByteStream()
        visit(incompatibility, stream)

        return stream.bytes.description
    }

    private func visit(
        _ incompatibility: Incompatibility,
        _ stream: BufferedOutputByteStream,
        isConclusion: Bool = false
    ) {

        let isNumbered = isConclusion || derivations[incompatibility]! > 1

        guard case .conflict(let lhs, let rhs) = incompatibility.cause else {
            // TODO: Do nothing else here?
            return
        }

        switch (lhs.cause, rhs.cause) {
        case (.conflict, .conflict):
            let lhsLine = lineNumbers[lhs]
            let rhsLine = lineNumbers[rhs]

            switch (lhsLine, rhsLine) {
            case (.some(let lhsLine), .some(let rhsLine)):
                write(incompatibility,
                      message: "Because \(lhs) (\(lhsLine)) and \(rhs) (\(rhsLine), \(incompatibility).",
                      isNumbered: isNumbered,
                      toStream: stream)
            case (.some(let lhsLine), .none):
                visit(incompatibility, stream)
                write(incompatibility,
                      message: "And because \(lhs) (\(lhsLine)), \(incompatibility).",
                      isNumbered: isNumbered,
                      toStream: stream)
            case (.none, .some(let rhsLine)):
                visit(incompatibility, stream)
                write(incompatibility,
                      message: "And because \(rhs) (\(rhsLine)), \(incompatibility).",
                      isNumbered: isNumbered,
                      toStream: stream)
            case (.none, .none):
                let singleLineConflict = lhs.cause.isSingleLine
                let singleLineOther = rhs.cause.isSingleLine

                if singleLineOther || singleLineConflict {
                    let simple = singleLineOther ? lhs : rhs
                    let complex = singleLineOther ? rhs : lhs
                    visit(simple, stream)
                    visit(complex, stream)
                    write(incompatibility,
                        message: "Thus, \(incompatibility)",
                        isNumbered: isNumbered,
                        toStream: stream)
                } else {
                    visit(lhs, stream, isConclusion: true)
                    write(incompatibility,
                        message: "\n",
                        isNumbered: isNumbered,
                        toStream: stream)

                    visit(rhs, stream)
                    // TODO: lhsLine will always be nil here...
                    write(incompatibility,
                        message: "And because \(lhs) (\(lhsLine ?? -1)), \(incompatibility).",
                        isNumbered: isNumbered,
                        toStream: stream)
                }

            }
        case (.conflict, _), (_, .conflict):
            var derived: Incompatibility
            var external: Incompatibility
            if case .conflict = lhs.cause {
                derived = lhs
                external = rhs
            } else {
                derived = rhs
                external = lhs
            }

            if let derivedLine = lineNumbers[derived] {
                write(incompatibility,
                    message: "Because \(external) and \(derived) (\(derivedLine)), \(incompatibility).",
                    isNumbered: isNumbered,
                    toStream: stream)
            } else if derivations[incompatibility]! <= 1 {
                guard case .conflict(let lhs, let rhs) = derived.cause else {
                    // FIXME
                    fatalError("unexpected non-conflict")
                }
                let collapsedDerived = lhs.cause.isConflict ? rhs : lhs
                let collapsedExternal = lhs.cause.isConflict ? rhs : lhs
                visit(collapsedDerived, stream)
                write(incompatibility,
                    message: "And because \(collapsedExternal) and \(external), \(incompatibility).",
                    isNumbered: isNumbered,
                    toStream: stream)
            } else {
                visit(derived, stream)
                write(incompatibility,
                    message: "And because \(external), \(incompatibility).",
                    isNumbered: isNumbered,
                    toStream: stream)
            }
        default:
            write(incompatibility,
                message: "Because \(lhs) and \(rhs), \(incompatibility).",
                isNumbered: isNumbered,
                toStream: stream)
        }
    }

    private var lineNumbers: [Incompatibility: Int] = [:]

    /// Write a given output message to a stream. The message should describe
    /// the incompatibility and how it as derived. If `isNumbered` is true, a
    /// line number will be assigned to this incompatibility so that it can be
    /// referred to again.
    private func write(
        _ i: Incompatibility,
        message: String,
        isNumbered: Bool,
        toStream stream: BufferedOutputByteStream
    ) {
        if isNumbered {
            let number = lineNumbers.count + 1
            lineNumbers[i] = number
            // TODO: Handle `number`
            stream <<< message
        } else {
            stream <<< message
        }
    }

    // MARK: - Container Management

    /// Condition for container management structures.
    private let fetchCondition = Condition()

    /// The list of fetched containers.
    private var _fetchedContainers: [PackageReference: Basic.Result<PackageContainer, AnyError>] = [:]

    /// The set of containers requested so far.
    private var _prefetchingContainers: Set<PackageReference> = []

    /// Get the container for the given identifier, loading it if necessary.
    fileprivate func getContainer(for identifier: PackageReference) throws -> PackageContainer {
        return try fetchCondition.whileLocked {
            // Return the cached container, if available.
            if let container = _fetchedContainers[identifier] {
                return try container.dematerialize()
            }

            // If this container is being prefetched, wait for that to complete.
            while _prefetchingContainers.contains(identifier) {
                fetchCondition.wait()
            }

            // The container may now be available in our cache if it was prefetched.
            if let container = _fetchedContainers[identifier] {
                return try container.dematerialize()
            }

            // Otherwise, fetch the container synchronously.
            let container = try await { provider.getContainer(for: identifier, skipUpdate: skipUpdate, completion: $0) }
            self._fetchedContainers[identifier] = Basic.Result(container)
            return container
        }
    }

    /// Returns the best available version for a given term.
    func getBestAvailableVersion(for term: Term) throws -> Version? {
        assert(term.isPositive, "Expected term to be positive")
        let container = try getContainer(for: term.package)

        switch term.requirement {
        case .versionSet(let versionSet):
            let availableVersions = container.versions(filter: { versionSet.contains($0) } )
            return availableVersions.first{ _ in true }
        case .revision:
            fatalError()
        case .unversioned:
            fatalError()
        }
    }

    /// Returns the incompatibilities of a package at the given version.
    func incompatibilites(
        for package: PackageReference,
        at version: Version
    ) throws -> [Incompatibility] {
        let container = try getContainer(for: package)
        return try container.getDependencies(at: version).map { dep -> Incompatibility in
            var terms: OrderedSet<Term> = []

            // FIXME:
            //
            // If the selected version is the latest version, Pubgrub
            // represents the term as having an unbounded upper range.
            // We can't represent that here (currently), so we're
            // pretending that it goes to the next nonexistent major
            // version.
            let nextMajor = Version(version.major + 1, 0, 0)
            terms.append(Term(container.identifier, .versionSet(.range(version..<nextMajor))))
            terms.append(Term(not: dep.identifier, dep.requirement))
            return Incompatibility(terms, root: root!, cause: .dependency(package: container.identifier))
        }
    }

    /// Starts prefetching the given containers.
    private func prefetch(containers identifiers: [PackageReference]) {
        fetchCondition.whileLocked {
            // Process each container.
            for identifier in identifiers {
                // Skip if we're already have this container or are pre-fetching it.
                guard _fetchedContainers[identifier] == nil,
                    !_prefetchingContainers.contains(identifier) else {
                        continue
                }

                // Otherwise, record that we're prefetching this container.
                _prefetchingContainers.insert(identifier)

                provider.getContainer(for: identifier, skipUpdate: skipUpdate) { container in
                    self.fetchCondition.whileLocked {
                        // Update the structures and signal any thread waiting
                        // on prefetching to finish.
                        self._fetchedContainers[identifier] = container
                        self._prefetchingContainers.remove(identifier)
                        self.fetchCondition.signal()
                    }
                }
            }
        }
    }
}
