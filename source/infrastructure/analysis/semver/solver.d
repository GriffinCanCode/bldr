module infrastructure.analysis.semver.solver;

import std.algorithm : map, filter, any, all, sort, canFind, find, countUntil;
import std.array : array, appender;
import std.conv : to;
import infrastructure.analysis.semver.version_;
import infrastructure.analysis.semver.constraint;
import infrastructure.analysis.semver.source;
import infrastructure.errors;

/// Term in an incompatibility - a package with version constraint
/// Positive: package MUST be in given range; Negative: package must NOT be
struct Term
{
    PackageId pkg;
    VersionConstraint constraint;
    bool positive;  // true = must satisfy, false = must not satisfy
    
    /// Create positive term (package must satisfy constraint)
    static Term must(PackageId pkg, VersionConstraint c) pure @safe
        => Term(pkg, c, true);
    
    /// Create negative term (package must NOT satisfy constraint)
    static Term mustNot(PackageId pkg, VersionConstraint c) pure @safe
        => Term(pkg, c, false);
    
    /// Negate this term
    Term negate() const pure @trusted
        => Term(pkg, cast(VersionConstraint) constraint, !positive);
    
    /// Check if term is satisfied by assignment
    bool satisfiedBy(SemVer v) const pure @trusted
        => positive ? (cast(VersionConstraint) constraint).allows(v) : !(cast(VersionConstraint) constraint).allows(v);
    
    /// Check if terms are compatible (can both be true)
    bool compatible(Term other) const pure @trusted
    {
        if (pkg != other.pkg) return true;
        
        auto c = cast(VersionConstraint) constraint;
        auto oc = cast(VersionConstraint) other.constraint;
        
        if (positive && other.positive)
            return c.allowsAny(oc);
        if (!positive && !other.positive)
            return true;  // Both negative, always compatible
        
        // One positive, one negative
        auto pos = positive ? c : oc;
        auto neg = positive ? oc : c;
        return !neg.allowsAll(pos);
    }
    
    /// Intersect with another term for same package
    Term intersect(Term other) const pure @trusted
    {
        assert(pkg == other.pkg);
        
        auto c = cast(VersionConstraint) constraint;
        auto oc = cast(VersionConstraint) other.constraint;
        
        if (positive && other.positive)
            return Term(pkg, c.intersect(oc), true);
        if (!positive && !other.positive)
            return Term(pkg, c.unite(oc), false);
        
        // Mixed: positive intersected with negation
        auto pos = positive ? c : oc;
        auto neg = positive ? oc : c;
        return Term(pkg, pos.intersect(neg.negate()), true);
    }
    
    string toString() const pure @safe
        => (positive ? "" : "not ") ~ pkg.toString() ~ " " ~ constraint.toString();
}

/// Incompatibility - a clause that describes an impossible combination
/// If all terms are satisfied, the solution is invalid
struct Incompatibility
{
    Term[] terms;
    IncompatibilityCause cause;
    
    /// Create from dependency: if A@v then B must satisfy constraint
    static Incompatibility fromDependency(PackageVersion pkg, PackageId dep, VersionConstraint c) pure @safe
    {
        return Incompatibility(
            [Term.must(pkg.pkg, VersionConstraint.exact(pkg.ver)),
             Term.mustNot(dep, c)],
            IncompatibilityCause.Dependency
        );
    }
    
    /// Create root requirement
    static Incompatibility fromRoot(PackageId pkg, VersionConstraint c) pure @safe
    {
        return Incompatibility(
            [Term.mustNot(pkg, c)],
            IncompatibilityCause.Root
        );
    }
    
    /// Create no-versions-available
    static Incompatibility noVersions(PackageId pkg, VersionConstraint c) pure @safe
    {
        return Incompatibility(
            [Term.must(pkg, c)],
            IncompatibilityCause.NoVersions
        );
    }
    
    /// Check if this incompatibility is satisfied (conflict!)
    bool isSatisfied(const Assignment[PackageId] assignments) const pure @safe
    {
        foreach (ref term; terms)
        {
            if (auto a = term.pkg in assignments)
            {
                if (!term.satisfiedBy(a.version_))
                    return false;
            }
            else if (term.positive)
                return false;  // Unassigned positive term can't be satisfied
        }
        return true;
    }
    
    /// Get the single term that makes this almost-satisfied
    /// Returns null if not exactly one term is undecided/unsatisfied
    const(Term)* unitTerm(const Assignment[PackageId] assignments) const pure @trusted
    {
        const(Term)* unit;
        size_t unsatisfied;
        
        foreach (ref term; terms)
        {
            if (auto a = term.pkg in assignments)
            {
                if (!term.satisfiedBy(a.version_))
                    return null;  // Term falsified, incompatibility won't trigger
            }
            else
            {
                unsatisfied++;
                unit = &term;
                if (unsatisfied > 1)
                    return null;
            }
        }
        
        return unsatisfied == 1 ? unit : null;
    }
    
    string toString() const pure @safe
    {
        if (terms.length == 0) return "impossible";
        
        string[] parts;
        foreach (ref t; terms)
            parts ~= t.toString();
        
        import std.array : join;
        return "{" ~ parts.join(", ") ~ "}";
    }
}

/// Cause of incompatibility (for error messages)
enum IncompatibilityCause
{
    Root,           // User requested this constraint
    Dependency,     // Package declares this dependency
    NoVersions,     // No versions satisfy constraint
    Conflict,       // Derived from conflict resolution
    PackageNotFound // Package doesn't exist
}

/// Assignment in partial solution
struct Assignment
{
    PackageId pkg;
    SemVer version_;
    size_t level;       // Decision level (for backtracking)
    bool isDecision;    // true = decision, false = derivation
    const(Incompatibility)* cause;  // What caused this derivation
    
    string toString() const pure @safe
        => pkg.toString() ~ "@" ~ version_.toString() ~ 
           (isDecision ? " [decision]" : " [derived]");
}

/// Resolution result
struct Resolution
{
    PackageVersion[] packages;  // Resolved packages with exact versions
    Incompatibility[] trace;    // For debugging: incompatibilities found
}

/// PubGrub version solver
/// Implements the PubGrub algorithm for dependency resolution
/// Reference: https://github.com/dart-lang/pub/blob/master/doc/solver.md
final class PubGrubSolver
{
    private IPackageSource source;
    private Incompatibility[] incompatibilities;
    private Assignment[PackageId] solution;
    private PackageId root;
    private size_t decisionLevel;
    
    this(IPackageSource source) @safe
    {
        this.source = source;
    }
    
    /// Solve dependencies starting from root package
    BuildResult!Resolution solve(PackageId rootPkg, VersionConstraint rootConstraint) @system
    {
        root = rootPkg;
        decisionLevel = 0;
        incompatibilities = [];
        solution.clear();
        
        // Add root incompatibility
        incompatibilities ~= Incompatibility.fromRoot(rootPkg, rootConstraint);
        
        // Main solving loop
        PackageId next = rootPkg;
        
        while (true)
        {
            // Unit propagation
            auto propResult = propagate(next);
            if (propResult.isErr)
                return Err!(Resolution, BuildError)(propResult.unwrapErr());
            
            auto conflict = propResult.unwrap();
            if (conflict !is null)
            {
                // Conflict resolution
                auto resolveResult = resolveConflict(*conflict);
                if (resolveResult.isErr)
                    return Err!(Resolution, BuildError)(resolveResult.unwrapErr());
                next = resolveResult.unwrap();
            }
            else
            {
                // Try to make a decision
                auto decisionResult = makeDecision();
                if (decisionResult.isErr)
                    return Err!(Resolution, BuildError)(decisionResult.unwrapErr());
                
                auto decision = decisionResult.unwrap();
                if (decision.pkg.name.length == 0)
                {
                    // No more decisions needed - solved!
                    return Ok!(Resolution, BuildError)(buildResolution());
                }
                next = decision.pkg;
            }
        }
    }
    
private:
    /// Unit propagation - derive assignments from incompatibilities
    BuildResult!(Incompatibility*) propagate(PackageId pkg) @system
    {
        PackageId[] changed = [pkg];
        
        while (changed.length > 0)
        {
            auto current = changed[0];
            changed = changed[1 .. $];
            
            // Check all incompatibilities involving this package
            foreach (ref incompat; incompatibilities)
            {
                if (!incompat.terms.any!(t => t.pkg == current))
                    continue;
                
                // Check for unit propagation
                auto unit = incompat.unitTerm(solution);
                if (unit !is null)
                {
                    // Derive new assignment
                    auto deriveResult = derive(*unit, &incompat);
                    if (deriveResult.isErr)
                        return Err!(Incompatibility*, BuildError)(deriveResult.unwrapErr());
                    
                    if (deriveResult.unwrap())
                        changed ~= unit.pkg;
                }
                
                // Check for conflict
                if (incompat.isSatisfied(solution))
                    return Ok!(Incompatibility*, BuildError)(&incompat);
            }
        }
        
        return Ok!(Incompatibility*, BuildError)(null);
    }
    
    /// Derive an assignment from unit propagation
    BuildResult!bool derive(ref const Term term, const(Incompatibility)* cause) @system
    {
        // Find best version satisfying negated term
        auto termConstraint = cast(VersionConstraint) term.constraint;
        auto constraint = term.positive ? termConstraint.negate() : termConstraint;
        auto pkg = cast(PackageId) term.pkg;
        
        auto versionsResult = source.versions(pkg);
        if (versionsResult.isErr)
            return Err!(bool, BuildError)(versionsResult.unwrapErr());
        
        auto versions = versionsResult.unwrap();
        SemVer best;
        bool found;
        
        foreach (v; versions)
        {
            if (constraint.allows(v))
            {
                if (!found || v > best)
                {
                    best = v;
                    found = true;
                }
            }
        }
        
        if (!found)
        {
            // No valid version - add incompatibility
            incompatibilities ~= Incompatibility.noVersions(pkg, constraint);
            return Ok!(bool, BuildError)(false);
        }
        
        // Check if already assigned
        if (pkg in solution)
            return Ok!(bool, BuildError)(false);
        
        // Add assignment
        solution[pkg] = Assignment(pkg, best, decisionLevel, false, cause);
        
        // Add incompatibilities from dependencies
        auto depsResult = source.dependencies(PackageVersion(term.pkg, best));
        if (depsResult.isErr)
            return Err!(bool, BuildError)(depsResult.unwrapErr());
        
        foreach (dep; depsResult.unwrap())
            incompatibilities ~= Incompatibility.fromDependency(
                PackageVersion(term.pkg, best), dep.pkg, dep.constraint);
        
        return Ok!(bool, BuildError)(true);
    }
    
    /// Resolve a conflict by backtracking and learning
    BuildResult!PackageId resolveConflict(ref Incompatibility conflict) @system
    {
        while (true)
        {
            // Find the most recent decision that contributed to this conflict
            auto backtrackResult = findBacktrackLevel(conflict);
            if (backtrackResult.isErr)
                return Err!(PackageId, BuildError)(backtrackResult.unwrapErr());
            
            auto btAssign = backtrackResult.unwrap();
            
            if (btAssign.level == 0)
            {
                // Can't backtrack - unsolvable
                return Err!(PackageId, BuildError)(
                    new AnalysisError("", "Dependency conflict: " ~ conflict.toString(), Analysis.VersionConflict));
            }
            
            // Learn new incompatibility from conflict
            auto learned = learnFromConflict(conflict, btAssign.pkg);
            incompatibilities ~= learned;
            
            // Backtrack
            doBacktrack(btAssign.level - 1);
            
            return Ok!(PackageId, BuildError)(btAssign.pkg);
        }
    }
    
    /// Find the decision level to backtrack to
    BuildResult!Assignment findBacktrackLevel(ref Incompatibility incompat) @system
    {
        Assignment result;
        size_t highestLevel;
        
        foreach (ref term; incompat.terms)
        {
            if (auto a = term.pkg in solution)
            {
                if (a.level > highestLevel)
                {
                    highestLevel = a.level;
                    result = *a;
                }
            }
        }
        
        if (highestLevel == 0)
            return Err!(Assignment, BuildError)(
                new AnalysisError("", "Root conflict - no solution exists", Analysis.VersionConflict));
        
        return Ok!(Assignment, BuildError)(result);
    }
    
    /// Learn a new incompatibility from conflict
    Incompatibility learnFromConflict(ref Incompatibility conflict, PackageId pivot) pure @safe
    {
        // Resolution: combine terms excluding pivot
        Term[] newTerms;
        foreach (ref t; conflict.terms)
            if (t.pkg != pivot)
                newTerms ~= t;
        
        return Incompatibility(newTerms, IncompatibilityCause.Conflict);
    }
    
    /// Backtrack to given level
    void doBacktrack(size_t level) pure
    {
        PackageId[] toRemove;
        foreach (pkg, a; solution)
            if (a.level > level)
                toRemove ~= pkg;
        
        foreach (pkg; toRemove)
            solution.remove(pkg);
        
        decisionLevel = level;
    }
    
    /// Make a decision (choose next package/version to try)
    BuildResult!Assignment makeDecision() @system
    {
        // Find package that appears in incompatibilities but isn't assigned
        PackageId candidate;
        VersionConstraint constraint = VersionConstraint.any();
        
        foreach (ref incompat; incompatibilities)
        {
            foreach (ref term; incompat.terms)
            {
                if (term.pkg !in solution && term.positive)
                {
                    candidate = term.pkg;
                    constraint = constraint.intersect(term.constraint);
                    break;
                }
            }
            if (candidate.name.length > 0)
                break;
        }
        
        if (candidate.name.length == 0)
            return Ok!(Assignment, BuildError)(Assignment.init);  // Done!
        
        // Get available versions
        auto versionsResult = source.versions(candidate);
        if (versionsResult.isErr)
            return Err!(Assignment, BuildError)(versionsResult.unwrapErr());
        
        auto versions = versionsResult.unwrap();
        
        // Find best version satisfying constraint
        SemVer best;
        bool found;
        foreach (v; versions)
        {
            if (constraint.allows(v) && (!found || v > best))
            {
                best = v;
                found = true;
            }
        }
        
        if (!found)
        {
            incompatibilities ~= Incompatibility.noVersions(candidate, constraint);
            return makeDecision();  // Try again with new incompatibility
        }
        
        // Make decision
        decisionLevel++;
        auto decision = Assignment(candidate, best, decisionLevel, true, null);
        solution[candidate] = decision;
        
        // Add dependencies as incompatibilities
        auto depsResult = source.dependencies(PackageVersion(candidate, best));
        if (depsResult.isErr)
            return Err!(Assignment, BuildError)(depsResult.unwrapErr());
        
        foreach (dep; depsResult.unwrap())
            incompatibilities ~= Incompatibility.fromDependency(
                PackageVersion(candidate, best), dep.pkg, dep.constraint);
        
        return Ok!(Assignment, BuildError)(decision);
    }
    
    /// Build final resolution from solution
    Resolution buildResolution() const pure @trusted
    {
        Resolution res;
        foreach (pkg, a; solution)
            res.packages ~= PackageVersion(pkg, a.version_);
        
        res.packages.sort!((a, b) => a.pkg.name < b.pkg.name);
        res.trace = (cast(Incompatibility[]) incompatibilities).dup;
        return res;
    }
}

/// Convenience function for one-shot solving
BuildResult!Resolution solve(IPackageSource source, string rootName, string constraint) @system
{
    auto solver = new PubGrubSolver(source);
    
    auto constraintResult = VersionConstraint.parse(constraint);
    if (constraintResult.isErr)
        return Err!(Resolution, BuildError)(constraintResult.unwrapErr());
    
    return solver.solve(PackageId(rootName, ""), constraintResult.unwrap());
}

