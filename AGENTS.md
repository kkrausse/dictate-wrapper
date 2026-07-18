# Agent Instructions

## Build Verification

- For general changes and development, run only the focused tests and the minimum debug build needed to compile and run the affected CLI or app.
- Do not run a release build unless the user explicitly requests one or the change specifically affects release-only optimization, packaging, signing, or distribution behavior.
- Avoid rebuilding unaffected targets when a focused test or debug build already provides sufficient verification.
