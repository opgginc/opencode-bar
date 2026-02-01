#!/bin/bash

# Setup Git hooks for the project

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="$PROJECT_ROOT/.git/hooks"

echo "Setting up Git hooks..."

# Create hooks directory if it doesn't exist
mkdir -p "$HOOKS_DIR"

# Install pre-commit hook for SwiftLint
cat > "$HOOKS_DIR/pre-commit" << 'EOF'
#!/bin/bash

# Get list of staged Swift files
SWIFT_FILES=$(git diff --cached --name-only --diff-filter=ACMR | grep '\.swift$')

if [ -z "$SWIFT_FILES" ]; then
    echo "No Swift files to lint"
    exit 0
fi

echo "Running SwiftLint on staged files..."
echo "$SWIFT_FILES" | xargs swiftlint lint --quiet

LINT_EXIT_CODE=$?

if [ $LINT_EXIT_CODE -ne 0 ]; then
    echo ""
    echo "❌ SwiftLint found violations. Please fix them before committing."
    echo "Run 'swiftlint autocorrect' to fix some issues automatically."
    exit 1
fi

echo "✅ SwiftLint passed"
exit 0
EOF

chmod +x "$HOOKS_DIR/pre-commit"

echo "✅ Pre-commit hook installed successfully"
echo ""
echo "The following hooks have been set up:"
echo "  - pre-commit: Runs SwiftLint on staged Swift files"
echo ""
echo "To bypass hooks temporarily, use: git commit --no-verify"
