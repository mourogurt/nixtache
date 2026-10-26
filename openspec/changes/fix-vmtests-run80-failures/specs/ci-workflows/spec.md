# ci-workflows Delta

## ADDED Requirements

### Requirement: vmtests suite jobs are diagnosable from concise output and a full-log artifact

Each `vmtests.yml` matrix job SHALL keep its step output limited to what
the suite itself reported, while the complete `nix build -L` transcript of
that suite is captured as a file and attached by the log upload step on
every outcome. The upload step SHALL NOT be a silent no-op: if a suite ran,
its full log exists as an artifact.

#### Scenario: passing suite

- **WHEN** a vmtests suite builds and its test script reports all checks ok
- **THEN** the job's step output contains the suite's own ok/verdict lines
  and not the raw build log, and the uploaded artifact for that suite holds
  the full `nix build -L` transcript

#### Scenario: build failure before the test

- **WHEN** a suite's build fails before any test executes
- **THEN** the job's step output states that the build never reached the
  test and shows the closing build error, and the uploaded artifact still
  holds the full transcript

### Requirement: vmtests matrix jobs are named after their suites

Each `vmtests.yml` matrix job SHALL be displayed under its bare suite name,
not prefixed with the job id.

#### Scenario: jobs are named after their suites

- **WHEN** the vmtests matrix runs
- **THEN** each job is displayed under its bare suite name (for example
  `ab-vm`), not prefixed with the job id (not `suites (ab-vm)`)

### Requirement: full-matrix vmtests dispatches bound suite concurrency

A full-matrix `vmtests` dispatch SHALL bound how many suites execute
concurrently, so a single dispatch cannot exhaust the memory or KVM capacity
of one runner host and turn unrelated suites into host-level kills
(QEMU/build processes dying with connection resets or SIGKILL).

#### Scenario: full dispatch on one KVM runner

- **WHEN** a full-matrix vmtests dispatch runs on a single `kvm`-label
  runner
- **THEN** no more than the configured number of suites execute at once,
  and the dispatch finishes without host-level kills attributable to runner
  overload
