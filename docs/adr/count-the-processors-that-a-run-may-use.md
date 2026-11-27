---
status: accepted
date: 2026-11-24
---
# Count the processors that a run may use

## Context

The default number of jobs came from the processors that the platform lists.
A container with a quota of two processors on eighteen started seventeen jobs.

## Decision

`Test::Mutation::Host` takes the least of the processors online, the affinity in `/proc/self/status`, and the quota of the control group.
The quota comes from `cpu.max`, or from `cpu.cfs_quota_us` over `cpu.cfs_period_us`, rounded up.
The tool reads the group in `/proc/self/cgroup` and each group above it under `/sys/fs/cgroup`.
Pure functions read the texts, and one function reads the files.
The first line of a run names the count and its source.

## Alternatives

`/proc/self/mountinfo` names every mount point, and no recorded fixture holds one.
`nproc` follows the affinity alone.

## Consequences

A hierarchy outside `/sys/fs/cgroup` limits nothing.

## Confirmation

`t/unit/processor-limits.t` counts eight recorded containers and two constructed version 1 groups.
`t/unit/host.t` covers the formats, the ancestors, and the ties.
Reconsider when a platform mounts its groups elsewhere.
