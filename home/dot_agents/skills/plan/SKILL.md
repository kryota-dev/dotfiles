---
name: plan
description: "Plan how to implement the specified work item. Spec-Driven Developmentの第2ステップ。"
argument-hint: "[implementation-details]"
disable-model-invocation: true
---

Plan how to implement the specified work item.

This is the second step in the Spec-Driven Development lifecycle.

Given the implementation details provided as an argument, do this:

1. Run `~/.claude/scripts/setup-plan.sh --json` from the repo root and parse JSON for BRANCH_SPEC, IMPL_PLAN, SPECS_DIR, BRANCH. All future file paths must be absolute.
2. Read and analyze the specification to understand:
   - The requirements and user stories
   - Functional and non-functional requirements
   - Success criteria and acceptance criteria
   - Any technical constraints or dependencies mentioned

3. Read the constitution at `~/.claude/memory/constitution.md` to understand constitutional requirements.

4. Execute the implementation plan template:
   - Load `~/.claude/templates/plan-template.md` (already copied to IMPL_PLAN path)
   - Set Input path to BRANCH_SPEC
   - Run the Execution Flow (main) function steps 1-10
   - The template is self-contained and executable
   - Follow error handling and gate checks as specified
   - Let the template guide artifact generation in $SPECS_DIR:
     * Phase 0 generates research.md
     * Phase 1 generates data-model.md, contracts/, quickstart.md
     * Phase 2 generates tasks.md
   - Incorporate user-provided details from arguments into Technical Context: $ARGUMENTS
   - Update Progress Tracking as you complete each phase

5. Verify execution completed:
   - Check Progress Tracking shows all phases complete
   - Ensure all required artifacts were generated
   - Confirm no ERROR states in execution

6. Report results with branch name, file paths, and generated artifacts.

Use absolute paths with the repository root for all file operations to avoid path issues.
