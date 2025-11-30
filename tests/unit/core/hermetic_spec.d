module tests.unit.core.hermetic_spec;

import engine.runtime.hermetic.core.spec;

@safe unittest
{
    // Test basic spec validation - non-overlapping paths
    auto builder = SandboxSpecBuilder.create()
        .input("/workspace/src")
        .output("/workspace/bin")
        .temp("/tmp/build");
    
    auto result = builder.build();
    assert(result.isOk, "Non-overlapping paths should be valid");
    
    auto spec = result.unwrap();
    assert(spec.canRead("/workspace/src"), "Should allow reading input path");
    assert(spec.canWrite("/workspace/bin"), "Should allow writing output path");
    assert(!spec.canWrite("/workspace/src"), "Should not allow writing input path");
}

@safe unittest
{
    // Test hermeticity violation - overlapping input/output
    auto builder = SandboxSpecBuilder.create()
        .input("/workspace")
        .output("/workspace/bin"); // Overlaps with input
    
    auto result = builder.build();
    assert(result.isErr, "Overlapping input/output should be invalid");
}

@safe unittest
{
    // Test network policy
    auto hermetic = NetworkPolicy.hermetic();
    assert(hermetic.isHermetic, "Hermetic policy should be hermetic");
    assert(!hermetic.allowHttp, "Hermetic should not allow HTTP");
    
    auto withHosts = NetworkPolicy.allowHosts(["example.com"]);
    assert(!withHosts.isHermetic, "Policy with hosts should not be hermetic");
    assert(withHosts.allowHttp, "Should allow HTTP for specific hosts");
}

@safe unittest
{
    // Test resource limits
    auto limits = ResourceLimits.hermetic();
    assert(limits.maxMemoryBytes > 0, "Hermetic limits should have memory limit");
    assert(limits.maxCpuTimeMs > 0, "Hermetic limits should have CPU limit");
    
    auto defaults = ResourceLimits.defaults();
    assert(defaults.maxMemoryBytes == 0, "Default limits should be unlimited");
}

@safe unittest
{
    // Test PathSet operations
    PathSet set1;
    set1.add("/a");
    set1.add("/b");
    
    PathSet set2;
    set2.add("/b");
    set2.add("/c");
    
    // Test union
    auto union_ = set1.union_(set2);
    assert(union_.contains("/a"), "Union should contain /a");
    assert(union_.contains("/b"), "Union should contain /b");
    assert(union_.contains("/c"), "Union should contain /c");
    
    // Test intersection
    auto intersection = set1.intersection(set2);
    assert(intersection.paths.length == 1, "Intersection should have one element");
    assert(intersection.contains("/b"), "Intersection should contain /b");
    
    // Test disjoint
    PathSet set3;
    set3.add("/x");
    assert(set1.disjoint(set3), "Sets should be disjoint");
    assert(!set1.disjoint(set2), "Sets should not be disjoint");
}

@safe unittest
{
    // Test environment variables
    auto env = EnvSet.minimal();
    assert(env.has("LANG"), "Minimal env should have LANG");
    assert(env.get("LANG") == "C.UTF-8", "LANG should be C.UTF-8");
    
    env.set("CUSTOM", "value");
    assert(env.has("CUSTOM"), "Should be able to set custom var");
    assert(env.get("CUSTOM") == "value", "Should retrieve custom value");
}

@safe unittest
{
    // Test process policy
    auto policy = ProcessPolicy.hermetic();
    assert(policy.killOnParentExit, "Hermetic policy should kill on parent exit");
    assert(policy.maxChildren > 0, "Should have child limit");
}

@system unittest
{
    // Test HermeticSpecBuilder fluent API
    auto spec = SandboxSpecBuilder.create()
        .input("/usr/lib")
        .input("/usr/include")
        .output("/tmp/output")
        .temp("/tmp/work")
        .env("PATH", "/usr/bin:/bin")
        .env("HOME", "/tmp/home")
        .withNetwork(NetworkPolicy.hermetic())
        .withResources(ResourceLimits.hermetic())
        .build();
    
    assert(spec.isOk, "Builder should produce valid spec");
    
    auto s = spec.unwrap();
    assert(s.canRead("/usr/lib"), "Should be able to read input");
    assert(s.canWrite("/tmp/output"), "Should be able to write output");
    assert(s.hasEnv("PATH"), "Should have PATH env var");
}

