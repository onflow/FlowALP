# LLM Working Files Management

This repository contains several LLM (Large Language Model) working files that provide development context and documentation. These files are useful during development but should be excluded when open-sourcing the project.

## LLM Working Files

The following files contain LLM-generated documentation and context:
- `PROMPT_FOR_TEST_RUNNING.md` - Test running prompts
- `TEST_RUNNING_INSTRUCTIONS.md` - Detailed test execution guide
- `FLOW_TEST_PERSISTENCE_SOLUTION.md` - Flow test persistence solutions
- `TidalProtocol_TestPlan.md` - Overall test planning documentation
- `TestSuiteComparison.md` - Test suite analysis
- `CadenceTestingPatterns.md` - Cadence testing patterns and best practices
- `TestsOverview.md` - High-level test overview
- `TidalMilestones.md` - Project milestones
- `PUSH_SUMMARY.md` - Push and PR summaries
- `TestingCompletionSummary.md` - Test completion status
- `IntensiveTestAnalysis.md` - Detailed test analysis
- `CadenceTestingBestPractices.md` - Best practices guide
- `FutureFeatures.md` - Planned features documentation

## Management Script

Use `./manage_llm_files.sh` to manage these files:

```bash
# List all LLM files present in the repository
./manage_llm_files.sh list

# Add LLM files to .gitignore (for public releases)
./manage_llm_files.sh add-to-gitignore

# Remove LLM files from filesystem (use with caution!)
./manage_llm_files.sh remove-files
```

## Development vs Production Strategy

### During Development
- Keep all LLM files in the repository
- These provide valuable context for ongoing development
- Commit them to your development branches

### For Open Source Release
1. Create a release branch
2. Run `./manage_llm_files.sh add-to-gitignore` to exclude files
3. Run `./manage_llm_files.sh remove-files` to clean the repository
4. Or maintain separate branches:
   - `main` - Development branch with LLM files
   - `public` - Clean branch for open source release

### Alternative Approach
You can also use git attributes to exclude these files from releases:
```bash
# In .gitattributes
*.md export-ignore
```

This way, the files remain in the repository but are excluded from archive downloads. 