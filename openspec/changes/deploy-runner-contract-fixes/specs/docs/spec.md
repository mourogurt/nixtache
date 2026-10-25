# Spec Delta

## MODIFIED Requirements

### Requirement: CI log shows every test suite

`ci.yml` MUST print the reports (ok/FAIL tables) of every `checks.<system>`
suite that `nix flake check` builds — not only runner. Test headers MUST
describe current behavior and MUST NOT claim intentional failure or missing
modules for implemented functionality.

#### Scenario: Each suite's report is visible in the log

- **WHEN** the CI job finishes
- **THEN** the log contains a separate report block for every suite registered
  in `checks.<system>`

#### Scenario: A failing suite does not suppress later reports

- **WHEN** validation or one suite fails while other suites can still be built
- **THEN** CI continues through the remaining suites, prints every obtainable
  report, and exits non-zero only after recording the collected failures
