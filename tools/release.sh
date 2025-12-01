#!/bin/bash
set -euo pipefail

# Builder Release Automation Script
# Automates: version bump, build, tag, GitHub release, crates.io, homebrew

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

log() { echo -e "${BLUE}→${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}!${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1" >&2; exit 1; }

# Version files
CARGO_TOML="distribution/cratesio/Cargo.toml"
MAIN_RS="distribution/cratesio/src/main.rs"
PACKAGE_JSON="tools/vscode/builder-lang/package.json"
HOMEBREW_FORMULA="distribution/homebrew/main/bldr.rb"
BUILDER_ENTRY="source/builder_entry.d"

get_current_version() {
    grep -E '^version = "' "$CARGO_TOML" | head -1 | sed 's/version = "\(.*\)"/\1/'
}

bump_version() {
    local current="$1" part="${2:-patch}"
    IFS='.' read -r major minor patch <<< "$current"
    case "$part" in
        major) echo "$((major + 1)).0.0" ;;
        minor) echo "$major.$((minor + 1)).0" ;;
        patch) echo "$major.$minor.$((patch + 1))" ;;
        *) echo "$part" ;;  # Allow explicit version
    esac
}

validate_prereqs() {
    log "Validating prerequisites..."
    
    command -v gh &>/dev/null || error "GitHub CLI (gh) not installed"
    command -v cargo &>/dev/null || error "Cargo not installed"
    command -v dub &>/dev/null || error "Dub not installed"
    command -v curl &>/dev/null || error "curl not installed"
    
    gh auth status &>/dev/null || error "Not authenticated with GitHub CLI"
    
    [[ -f "$CARGO_TOML" ]] || error "Missing $CARGO_TOML"
    [[ -f "$MAIN_RS" ]] || error "Missing $MAIN_RS"
    [[ -f "$PACKAGE_JSON" ]] || error "Missing $PACKAGE_JSON"
    [[ -f "$HOMEBREW_FORMULA" ]] || error "Missing $HOMEBREW_FORMULA"
    [[ -f "$BUILDER_ENTRY" ]] || error "Missing $BUILDER_ENTRY"
    
    success "All prerequisites met"
}

validate_git_state() {
    log "Validating git state..."
    
    local branch
    branch=$(git branch --show-current)
    [[ "$branch" == "master" || "$branch" == "main" ]] || warn "Not on master/main branch (on $branch)"
    
    git fetch origin --quiet
    local behind
    behind=$(git rev-list HEAD..origin/"$branch" --count 2>/dev/null || echo "0")
    [[ "$behind" == "0" ]] || error "Branch is $behind commits behind origin"
    
    success "Git state valid"
}

update_version_files() {
    local old="$1" new="$2"
    log "Updating version: $old → $new"
    
    # Cargo.toml
    sed -i '' "s/^version = \"$old\"/version = \"$new\"/" "$CARGO_TOML"
    
    # main.rs
    sed -i '' "s/const VERSION: \&str = \"[^\"]*\"/const VERSION: \&str = \"$new\"/" "$MAIN_RS"
    
    # package.json
    sed -i '' "s/\"version\": \"[^\"]*\"/\"version\": \"$new\"/" "$PACKAGE_JSON"
    
    # builder_entry.d
    sed -i '' "s/bldr version [0-9]\+\.[0-9]\+\.[0-9]\+/bldr version $new/g" "$BUILDER_ENTRY"
    
    # Homebrew formula (URL and test)
    sed -i '' "s|refs/tags/v[0-9]\+\.[0-9]\+\.[0-9]\+|refs/tags/v$new|" "$HOMEBREW_FORMULA"
    sed -i '' "s/bldr version [0-9]\+\.[0-9]\+\.[0-9]\+/bldr version $new/" "$HOMEBREW_FORMULA"
    
    success "Version files updated"
}

build_release() {
    log "Building release..."
    make build
    success "Build complete"
}

create_tarball() {
    log "Creating release tarball..."
    mkdir -p dist/release
    cp bin/bldr dist/release/
    
    local arch
    arch=$(uname -m)
    [[ "$arch" == "arm64" ]] && arch="arm64" || arch="amd64"
    
    local tarball="bldr-darwin-$arch.tar.gz"
    (cd dist/release && tar -czf "$tarball" bldr)
    
    echo "dist/release/$tarball"
}

verify_build() {
    local version="$1"
    log "Verifying build..."
    
    local output
    output=$(./bin/bldr --version 2>&1 | head -1)
    [[ "$output" == *"$version"* ]] || error "Version mismatch: expected $version, got $output"
    
    success "Build verified: $output"
}

commit_and_tag() {
    local version="$1"
    log "Committing and tagging v$version..."
    
    git add -A
    git commit -m "release: v$version"
    git tag "v$version"
    
    success "Committed and tagged"
}

push_to_remote() {
    local version="$1"
    log "Pushing to remote..."
    
    git push
    git push --tags
    
    success "Pushed to remote"
}

create_github_release() {
    local version="$1" tarball="$2"
    log "Creating GitHub release v$version..."
    
    gh release create "v$version" "$tarball" \
        --title "v$version" \
        --notes "Release v$version" \
        --latest
    
    success "GitHub release created"
}

wait_for_release_propagation() {
    local version="$1"
    log "Waiting for release to propagate..."
    
    local url="https://github.com/GriffinCanCode/bldr/releases/download/v$version/bldr-darwin-arm64.tar.gz"
    local attempts=0
    
    while [[ $attempts -lt 30 ]]; do
        if curl -fsSL -I "$url" 2>/dev/null | grep -q "302"; then
            success "Release available"
            return 0
        fi
        sleep 2
        attempts=$((attempts + 1))
    done
    
    error "Release not available after 60 seconds"
}

update_homebrew_sha() {
    local version="$1"
    log "Updating Homebrew formula SHA256..."
    
    local sha256
    sha256=$(curl -sL "https://github.com/GriffinCanCode/bldr/archive/refs/tags/v$version.tar.gz" | shasum -a 256 | cut -d' ' -f1)
    
    sed -i '' "s/sha256 \"[a-f0-9]*\"/sha256 \"$sha256\"/" "$HOMEBREW_FORMULA"
    
    git add "$HOMEBREW_FORMULA"
    git commit -m "fix: update homebrew sha256 for v$version"
    git push
    
    success "Homebrew SHA256 updated: $sha256"
}

publish_crates() {
    log "Publishing to crates.io..."
    
    (cd distribution/cratesio && cargo publish)
    
    success "Published to crates.io"
}

verify_crates_install() {
    local version="$1"
    log "Verifying crates.io installation..."
    
    rm -rf ~/Library/Caches/bldr 2>/dev/null || true
    
    local output
    if command -v bldr &>/dev/null; then
        output=$(bldr --version 2>&1 | head -1)
        [[ "$output" == *"$version"* ]] && success "Crates.io install verified" && return 0
    fi
    
    warn "Could not verify crates.io install (may need: cargo install bldr --force)"
}

print_summary() {
    local version="$1"
    echo
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Release v$version Complete!${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo
    echo "  • Git tag:        v$version"
    echo "  • GitHub Release: https://github.com/GriffinCanCode/bldr/releases/tag/v$version"
    echo "  • Crates.io:      cargo install bldr"
    echo "  • Homebrew:       brew tap GriffinCanCode/bldr && brew install bldr"
    echo
}

main() {
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║           Builder Release Automation Script               ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo
    
    local bump_type="${1:-patch}"
    local current_version new_version
    
    current_version=$(get_current_version)
    new_version=$(bump_version "$current_version" "$bump_type")
    
    echo "Current version: $current_version"
    echo "New version:     $new_version"
    echo
    
    if [[ "${2:-}" != "-y" && "${2:-}" != "--yes" ]]; then
        read -rp "Proceed with release v$new_version? [y/N] " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
    fi
    echo
    
    validate_prereqs
    validate_git_state
    update_version_files "$current_version" "$new_version"
    build_release
    verify_build "$new_version"
    
    local tarball
    tarball=$(create_tarball)
    
    commit_and_tag "$new_version"
    push_to_remote "$new_version"
    create_github_release "$new_version" "$tarball"
    wait_for_release_propagation "$new_version"
    update_homebrew_sha "$new_version"
    publish_crates
    verify_crates_install "$new_version"
    
    print_summary "$new_version"
}

# Usage
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "Usage: $0 [version_bump] [-y|--yes]"
    echo
    echo "Version bump options:"
    echo "  patch   - Bump patch version (default): 2.0.3 → 2.0.4"
    echo "  minor   - Bump minor version: 2.0.3 → 2.1.0"
    echo "  major   - Bump major version: 2.0.3 → 3.0.0"
    echo "  X.Y.Z   - Set explicit version"
    echo
    echo "Flags:"
    echo "  -y, --yes   Skip confirmation prompt"
    echo
    echo "Examples:"
    echo "  $0              # Patch bump with confirmation"
    echo "  $0 minor        # Minor bump"
    echo "  $0 2.1.0 -y     # Set to 2.1.0, skip confirmation"
    exit 0
fi

main "$@"

