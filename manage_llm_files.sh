#!/usr/bin/env bash
set -euo pipefail

# Script to manage LLM working files
# Usage: ./manage_llm_files.sh [add-to-gitignore|remove-files|list]

LLM_FILES=(
    "PROMPT_FOR_TEST_RUNNING.md"
    "TEST_RUNNING_INSTRUCTIONS.md"
    "FLOW_TEST_PERSISTENCE_SOLUTION.md"
    "TidalProtocol_TestPlan.md"
    "TestSuiteComparison.md"
    "CadenceTestingPatterns.md"
    "TestsOverview.md"
    "TidalMilestones.md"
    "PUSH_SUMMARY.md"
    "TestingCompletionSummary.md"
    "IntensiveTestAnalysis.md"
    "CadenceTestingBestPractices.md"
    "FutureFeatures.md"
    "LLM_FILES_MANAGEMENT.md"
    "AUTO_BORROWING_GUIDE.md"
    "AUTO_BORROWING_PROPOSAL.md"
    "PR_COMMENT_RESPONSES.md"
    "TODO_AND_MISSING_TESTS_SUMMARY.md"
)

case "${1:-list}" in
    "add-to-gitignore")
        echo "# LLM working files (development context)" >> .gitignore
        for file in "${LLM_FILES[@]}"; do
            echo "$file" >> .gitignore
        done
        echo "✅ Added LLM files to .gitignore"
        ;;
    
    "remove-files")
        echo "⚠️  This will permanently delete LLM working files. Are you sure? (y/N)"
        read -r response
        if [[ "$response" == "y" || "$response" == "Y" ]]; then
            for file in "${LLM_FILES[@]}"; do
                if [[ -f "$file" ]]; then
                    rm "$file"
                    echo "🗑️  Removed: $file"
                fi
            done
            echo "✅ LLM files removed"
        else
            echo "❌ Operation cancelled"
        fi
        ;;
    
    "list")
        echo "📄 LLM working files in the repository:"
        for file in "${LLM_FILES[@]}"; do
            if [[ -f "$file" ]]; then
                echo "  ✓ $file"
            fi
        done
        ;;
    
    *)
        echo "Usage: $0 [add-to-gitignore|remove-files|list]"
        echo "  add-to-gitignore - Add LLM files to .gitignore"
        echo "  remove-files     - Remove LLM files from filesystem"
        echo "  list            - List existing LLM files"
        exit 1
        ;;
esac 