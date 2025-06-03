#!/bin/bash

# Create PR using GitHub CLI with the comprehensive description
gh pr create \
  --title "Complete Restoration of Dieter's AlpenFlow Implementation (90.96% test coverage)" \
  --body-file PR_DESCRIPTION.md \
  --base main \
  --head fix/update-tests-for-complete-restoration \
  --assignee @me

echo "PR created successfully!" 