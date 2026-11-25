# Remaining work of the rework

This note hands the unfinished part of the rework of Test::Mutation to the next agent.
It records where the work stands on 2026-11-25, the rules that the work follows, and every slice that remains.
The last slice of the rework deletes this note together with `t/open-findings.tsv`.

The approved plan lives outside the repository, in Japanese, at `/Users/yasunobu/.claude/plans/perl-mutation-testing-atomic-liskov-of-a4b783db-c99d-4834-9953-ac445c1bac57.md`.
This note restates every part of the plan that the remaining slices need.

## Where the work stands

All work stays on this machine, apart from the first slice, which the draft pull request #20 holds.
Nobody pushed another branch or merged a pull request.

The finished work forms one linear stack of 65 commits on `main`, with its tip at `b008bcb` on the branch `stack/paused-tip`.
`mise run check` passes there.
The branch `docs/remaining-work-of-the-rework` adds this note on top of that tip, for issue #40.

Slice 1 made every gate count and reject, with its fixtures and the repair of weak gates, under the issues #19, #21, #22, and #23.
Slices 2 to 6 built the five harnesses under the issues #24 to #28: contract, mutant quality, engine, shim experiments, and real distributions.
Slice 7 brought the typed errors with the message catalog, the exit table, and the signals, under #32.
Slice 8 brought the status catalog under #37, and slice 9 the settings table under #38.
Slice 11 typed the analysis under #29, and slice 12 built the validity boundary of the generator under #30.
Issue #31 repaired a readline that the parser read as two comparisons.
Slice 20 brought the reader of test output, the processor count, the pool loop, and the work counters, under #33, #34, and #39.

Two branches wait outside the stack, and both start at `bfd1470`, an older point of the stack.
The branch `feat/suppression-grammar` at `3b1a1f5` holds slice 13, for issue #36.
The branch `feat/operator-precedence` at `d4f9b97` holds slice 14, the first half of #35.
Nobody started slice 10, slice 15, slices 16 to 19, or slices 21 to 35.
Slice 15 shares issue #35, and the other slices have no issue yet.

The precedence branch removes the 162 lines of `the new mutators and the declined table of the census`.
The suppression branch removes 20 of the 22 lines of `the suppression grammar`, and the first steps below remove the other two.

The suppression branch passes `mise run check`, and its self-mutation detected 141 of 141 mutants.
It still needs `mise run discover`, `mise run discover-mutants`, and `mise run realworld`.

The precedence branch holds two commits that nobody verified in full.
It still needs a complete `mise run check`, a complete self-mutation run with every survivor killed, and `mise run discover-mutants`.
The drafts for slice 15 were in `/tmp`, which no longer exists.

The worktrees under `.claude/worktrees/` belong to finished agents and hold no uncommitted change.
Remove them once their branches are on the stack.

## First steps

First, put `feat/operator-precedence` on the tip with `git cherry-pick`, resolve the conflicts, and verify it.
Its commit `d4f9b97` also repairs `_example` in `t/lib/Oracle.pm`.
Without that repair, `t/discovery/oracles.t` fails the unmodified run of the tool inside a deep work directory, so take the branch first.

Second, put `feat/suppression-grammar` on the result and verify it.
The settings table now exists, so add `suppress-require-names` and `suppress-require-reason` to it and wire them into `Test::Mutation::Suppression`.
That change removes the two `suppression-settings` lines and the two `contract-plan-settings` lines about those settings.

Third, rerun the self-mutation of the pool slice and the settings slice over every test.
Both ran with `t/discovery` left out because of the `_example` defect.

Fourth, settle the two instabilities of the real-world run that the next section describes.

## Known problems

The score of `TOML-Tiny` in `mise run realworld` falls on either side of its band: 69.9 or 70.1, with a floor of 70.
The order of the tests of a mutant follows their measured times, so a mutant flips between `Killed` and `Timeout` from run to run.
Make the order deterministic, or state the band from repeated runs, and record the decision.

With the settings table on the stack, the shard of `Moo` gave two timeouts in four runs where the stack without it gave one.
The settings slice changed only names in `Runner.pm`, and nobody found the cause.

Slice 20 replaced the gates that read the clock with counts.
A gate that still changes its answer under load is a defect of the gate.

## How the work proceeds

Each slice has one issue and one branch, and the branches form one linear stack.
Before an implementation edit, run `pr-workflow start --repo P4suta/Test-Mutation --issue N --path PATH...` and list every path that the slice touches.
In a worktree, `pr-workflow start` refuses while the untracked `local` link exists: remove the link, run the command, and put the link back.

The development is test first.
The first failing test of a slice is the removal of its lines from `t/open-findings.tsv`, which makes the gate report the finding as new.
Watch each test fail for the right reason before the code.
Fix a defect at one authority, such as a table, a typed shape, or one boundary function, and sweep the whole family of the defect.

`t/open-findings.tsv` lists every known violation, one per line: the gate, the finding, and the work that removes it.
`Gate::findings` fails when a gate finds a violation outside the list, and when a listed line no longer reproduces.
Remove exactly the lines that the slice resolves, and never weaken an assertion to make a line pass.
A finding that the slice exposes outside its own work goes into the list with the work that removes it.
When two branches meet in a cherry-pick, the list takes the union of both sides minus the lines that either side removed.
A product change can move a line of the census of the mutant harness.
A token of a new class in `lib/` is a key of the census that needs a mutator or a stated reason.

Every gate under `xt/` calls `Gate::checked` with a count and a floor, and holds a subtest that feeds the gate a broken input.
A gate never takes its broken input from a defect of the product.
The harnesses judge the tool with independent oracles: `perl` itself, `prove`, `TAP::Parser`, the report schema, known-answer projects, and real distributions.

Every failure goes through `Test::Mutation::Error::raise` with an identifier of the catalog `Test::Mutation::Message`, and every warning through `Test::Mutation::Message::warning`.
`Test::Mutation::Try::attempt` is the only `eval` of the driver.
`xt/literals.t` refuses a literal message, and `t/contract/messages.t` requires a case that produces every identifier.
Every public subroutine has a `signature_for`, every attribute an `isa` with a shape, and every Moo class composes `Test::Mutation::Value`.
`lib/Test/Mutation/Shim.pm` stays on Perl 5.10 and core modules.
No slice adds a runtime dependency.

A consequential decision gets an architecture decision record under `docs/adr/<decision>.md`.
A record holds 200 words at most, the front matter `status` and `date`, and the sections Context, Decision, Alternatives, Consequences, and Confirmation.

## Checks

Before each commit of a slice, run `mise run fmt` twice, since one pass can leave a line that the second pass changes.
Then run `mise run check`, the fast gate of unit, shim, contract, fast discovery, structural, end-to-end, audit, and secret checks.
After a change of the engine, run `mise run discover`, the full engine harness.
After a change of the analysis, the generator, or the mutators, run `mise run discover-mutants`, the long tier of the mutant harness, which takes about 15 minutes.
After a change of what the tool prints, run `mise run realworld`, eleven runs of real distributions in an OrbStack container, which take about 5 minutes.
Last, run `mise run mutation -- --since <base> --format terminal` to measure the changed lines with the tool itself, and repeat until no survivor and no timeout remain.

A slice never runs `mise run mutation` without arguments, since the full run takes over 20 minutes and belongs to slice 33.
Run `mise trust` after every change of `mise.toml`.
The comment checker `ocomment` reads Perl with its own parser.
The parser rejects `EXPR //= VALUE for LIST` and a division right after a call such as `length($x) / 4`, so write those forms another way.

Commit messages follow Conventional Commits in English, one sentence per line, without attribution lines.
Push, pull requests, and merges follow the instruction of the user, and the instruction so far was to finish the work locally first.

## Decisions already taken

The user approved the plan, and that approval is the acceptance of the decision records that the plan names.
`mutation exec` ends with 125 when it fails itself, 126 when the command exists and fails to start, and 127 when the command is missing.
A signal ends a command with 128 plus its number at any time, during the plan included.
The warnings of a run are messages of the catalog with the kind `warning`.
`root` and `config` stay out of the configuration file, since both settings decide where the file is.
The reader of test output decodes the lines after `TAP version 13` as UTF-8, as `prove` does for a process.
The mutant harness measures equivalent mutants as a rate of each mutator and compares the rate with the bound of 2 percent of appendix J.
The judge of the real-world run accepts one final line of the tool that starts with `mutation: ` after a failed run.
The declined table of the census may name a construct of slice 15 with a provisional reason, and the census fails once a mutator covers that construct.

## Remaining slices

Each slice removes the lines of `t/open-findings.tsv` whose third column names its work.
The counts hold on `b008bcb`.

### Slice 10 describes every command in one table

One table describes each command with its operands and its settings: `run`, `baseline`, `list`, `show`, `exec`, `merge`, `mutators`, `settings`, and `help`.
`help` and `settings` print from the tables, an unknown command names the nearest one, and stray operands are a usage error.
The `commands` attribute that the settings slice put on `Setting` moves to the commands table.
The slice removes the 6 lines of `the commands table`.

### Slice 15 adds the remaining mutators and the profile rule

Add `three-way`, `early-exit`, `filter-negation`, and `call-removal`.
Split `comparison` and `string-comparison` into `comparison-boundary` and `comparison-negation`, and rename `sort-order` to `list-order` with `reverse X` to `X`.
Make `number-literal` cover every numeric class of the parser library `PPI` and keep the base of a literal.
Add `regex-class`, `regex-flag` for `i m s` and the `g` of `s///`, and `literal-collection`.
Accept the group names `@regex`, `@literal`, and `@removal` in `enable` and `disable`.
A mutator belongs to the default profile when the mutant harness measures no invalid mutant and no unresolved call for it.
The default profile also requires structural equivalence at 2 percent or below and load failures in the real-world corpus at 10 percent or below.
Record the measured rates and the decision in the record `place-a-mutator-in-the-default-profile-by-measured-rates`.
The slice removes the 2 lines of `the profile rule of the mutators, which places a mutator by its measured rates` and the line of `the number-literal mutator that keeps the base of a literal`.

### A follow-up closes the findings of slices 11 and 12

The follow-up removes the 17 lines of `the validity boundary of the generator`, the 2 lines of `the import resolution of the validity boundary`, and the 4 lines of `the typed analysis with its count of dropped sites`.
The validity lines name invalid mutants that the harness still finds and a final value that some mutators lose.
They also name refusals that perl accepts, such as `JSON::PP::true` to `JSON::PP::false`, and a declaration rule wider than the real scope.

### Slice 16 closes the vocabulary of the records

The shim writes the records `begin`, `seen`, `blind`, `hit`, `lines`, `around`, `outside`, `error`, and `end`, and an unknown kind is an error.
`Test::Mutation::Evidence` turns the records of a task into evidence, and a task without `begin` is an anomaly.
`xt/records.t` checks that the shim, the record table, and the evidence name one set.
The slice removes the 5 lines of `the closed record vocabulary and its evidence` and the 3 lines of `the records without a pattern over the path of a project`.

### Slice 17 builds the workspace

All temporary files of a run live in one workspace outside the project: `$TMPDIR/mutation-XXXXXX/` with `owner` as a lock, `tree/`, `slot/<n>/`, and `work/`.
The phases of a run are data, `resolve analyze plan acquire build baseline mutants conclude release`, and each phase emits events.
The signature of the tree includes the change time and the inode.
The signature compares an entry that changed within two seconds of the snapshot by its digest.
The next start reclaims a workspace whose lock is free.
The slice removes the 2 lines of `the workspace that owns every resource of a run`, the 2 lines of `the workspace outside the project`, and the 2 lines of `the tree signature of the workspace`.

### Slice 18 resolves the selection before the first write

`Select::resolve` checks its inputs in this order before any write: root, configuration, types and interactions, mutator names, the interpreter, and globs.
It goes on with the revision and its diff, paths, the analysis and the suppression names, prefixes of mutant identifiers, the shard, and the right to write the report directory.
A selector that matches nothing is a usage error.
After the copy, the run compares the analyzed sources with their digests.
The slice removes the 18 lines of `the selection resolved before the first write`.

### Slice 19 launches a test as prove does

`Launch::test_command` builds every command, the compile included.
The libraries of the `lib` setting are absolute, and the launch normalizes `-I foo`, `-Ifoo`, and `-Mlib=foo`.
Without taint, `PERL5LIB` holds the libraries, the inherited value, and the shim, so a child perl inherits them.
With taint, as prove reads it, the arguments are `perl SWITCHES -T -I<each lib> -I<each entry of PERL5LIB> <each word of PERL5OPT> test`.
The environment holds `HARNESS_ACTIVE`, `HARNESS_VERSION`, `PERL_DL_NONLAZY` for a build, a `TMPDIR` per task, and `PWD`.
A `.proverc` of the project gives defaults, and the run refuses `--exec` with its reason.
The slice removes the 17 lines of `the launch of a test command`.

### Slice 21 places each mutant in the copy and adds the verdict rule

The run writes each mutant into the copy of its job.
A script started by `system`, an absolute path, a tainted child, and a copy under `blib` then all load the mutant.
A test decides `Killed` only after it passed unmodified in the same run, and appendix D of the plan gives the order of the checks.
`mutation exec` runs inside a copy.
`--in-place` keeps the hook and states the limits of its observation for each run.
The slice removes the 18 lines of `the placement of a mutant in the copy`, the line of `the placement of each mutant in the copy of its job`, and the 2 lines of `the unmodified pass rule of the verdict`.
It also removes the line of `the exec command inside a copy of the project` and the 7 lines of `the limits that a run in the project states for itself`.

### Slice 22 adds the witness

Each target in its copy gets one `UNITCHECK` line at the start of its last top-level statement.
The line records the load of the file without changing the line count.
The shim experiments settled the text: the capture goes through the keys of a hash and the mode is `>>:raw`.
The first text of the plan broke under `use re 'taint'` and under `use open`.
A test that reads a source as text measures a slot without the witness.
The slice removes the 9 lines of `the witness that a target writes for itself`.

### Slice 23 takes scripts as sources

The default `source` covers `lib/**/*.pm` and the Perl scripts of `bin/` and `script/`.
A filter in the main program, installed from the `import` of the shim, traces the lines of a script.
The experiments confirmed the filter from Perl 5.10 to 5.44.
The run finds `blib/script` copies by content.
The slice removes the line of `the Perl scripts of a project as sources of a run`.

### Slice 24 detects the shape of a project and builds in the copy

A project with `.xs` files, objects under `blib/arch`, configured `blib` libraries, or `-b` in `.proverc` is a build project.
The run builds in the copy with `perl Makefile.PL` and `make`, or with `Build.PL`.
A failed build ends with status 5, the command, and the end of its output.
`Makefile.PL` must look older than `Makefile`, or `make` reruns it and removes the build, and the experiments list the other pitfalls of a moved build.
The slice removes the 3 lines of `the build of a distribution in the copy`.

### Slice 25 adds exclusive tests and the recheck

A failure or a timeout that overlapped another run of the same test runs again alone.
A pass then gives the test a lock and the warning `conflicting-test`.
A test that fails in parallel and passes alone runs again in parallel in separate slots.
The run honors `testrules.yml`.
The slice removes the 7 lines of `the recheck of a failure beside another run of the same test`.

### Slice 26 does each piece of work once

Each mutant walks the tree once, a mutant without tests takes no slot and asks the cache first, and each source compiles once.
The compile has a time limit of ten times the measured compile of the original, at least ten seconds.
The equivalence check ignores the addresses that `B::Deparse` prints.
The slice removes the line of `the comparison of compiled code without the addresses that B::Deparse prints`.

### Slice 27 adds the kinds of compile error

`CompileError` has the kinds `parse`, `compile-phase`, and `standalone`.
`parse` marks a defect of the tool, `compile-phase` marks a behavior such as a mutant in a `BEGIN` block that dies, and `standalone` marks an original that fails to compile alone.
The shim checks at load time that a mutant introduces no unresolved name, and the reports list the compile errors with their kinds.
The slice removes the 4 lines of the three works that start with `the kinds of compile error`.

### Slice 28 builds the store and its key

The cache is on by default, and its key holds every input that the engine can name, K1 to K9 in appendix C of the plan.
The inputs are the tool, the interpreter, the libraries outside the project, the launch settings, and the environment.
They also are the other copied files, the test, the targets that the test compiled, and the mutant.
Each run measures a sample of the reused verdicts again, one in fifty and at least three, and a mismatch discards the store and ends with status 4.
`Store.pm` and `Store/Key.pm` replace `Cache.pm`, and a successor supersedes the record `key-a-cached-result-by-the-files-it-depends-on`.
The slice removes the 11 lines of `the cache key over every input of a result`.

### Slice 29 reuses the unmodified run

A test whose inputs stay unchanged reuses its unmodified result, and `neutral` marks a test that decides nothing.
The plan phase ends early when nothing needs a run, and the command `baseline` records the unmodified run.

### Slice 30 states one outcome of a run

`Outcome::of( result, min_score )` is the only decision, and `Exit::code` the only number.
The outcomes in order are `interrupted` with 128 plus the signal and `baseline-failed` with status 3.
Next comes `inconclusive` with status 4, for a `NoVerdict` or `Pending`, an unanalyzed source, or a run without a valid mutant and with a timeout.
`measured` gives 0, or 1 below the gate.
`nothing` gives 0 for a run narrowed by `since`, a path, `mutant`, or `shard`, and 4 under a gate for the whole project.
A shard defers the gate to `merge`, and `mutation_score_ok` uses the same decision.
A narrowed rerun updates the report that the previous run of the same set of mutants wrote.
The slice removes the 11 lines of `the single outcome of a run`.

### Slice 31 rebuilds the progress and the encoding of the output

Progress goes to standard error as lines per phase with the elapsed and the remaining time.
Color follows `--color` unless the environment holds `NO_COLOR`.
The progress counts every status, including `Ignored` and `Pending`.
`main` sets the UTF-8 layer on the output handles once.
The slice removes the 6 lines of `the progress display` and the 3 lines of `the encoding of the output`.

### Slice 32 rebuilds the reports

The terminal report holds a result line, a table per file, a section per file with `ID  place  mutator  description`, and the next step.
`show`, `list`, and the GitHub summary follow the same facts, and the annotations stay at ten per level.
`t/e2e/journeys.t` asserts the whole output of the journeys A, B, and C of the plan: a first run, the repair of one survivor, and a pull request gate.
The slice removes the 2 lines of `the terminal report and the summary of GitHub`.

### Slice 33 gates a release on the run of the tool on itself

Run the tool on itself in full and remove every survivor and timeout, and use appendix F of the plan for the survivors of the last full run by place.
The release gate requires score 100, no `NoVerdict`, no unanalyzed file, no invalid mutant, and no timeout.
It also requires every suppression to carry its names and a reason, and it runs the mutants of `Shim.pm` on Perl 5.10, 5.14, and 5.18 too.
The slice removes the 2 lines of `the release gate for the run of the tool on itself`.

### Slice 34 fixes the expectations of the real distributions

Fix the bands of each distribution from repeated runs, and reduce every defect found there to a fixture under `t/fixtures/realworld` or `t/corpus/findings`.
The slice removes the line of the work that starts with `the expectations of the real distributions`.

### Slice 35 generates the manual and ends the rework

`bin/mutation` holds the manual for `perldoc mutation`.
Its sections `COMMANDS`, `SETTINGS`, `STATUSES`, `EXIT STATUS`, `ENVIRONMENT`, `DIAGNOSTICS`, and `MUTATORS` come from the tables between `=for generated NAME` markers.
`mise run manual` rewrites those sections, and a gate compares them.
The examples of the manual run, and an environment table describes every variable that the tool reads.
Every decision record agrees with the code, and `Changes` describes the release.
The workflows run the fast gate on `pull_request` and `merge_group`, and the heavy checks with macOS in a `workflow_dispatch` release gate.
The slice ends when `t/open-findings.tsv` is empty, and it then deletes the list, the support for it in `t/lib/Gate.pm`, and this note.
The slice removes the 11 lines of `the manual that the tables generate`.
