# Getting started

This guide builds the complete [QuickStart](../demo/QuickStart.dpr) console
program: a service publishes an immutable message every 50 ms, suspends for 5 ms,
and a subscription receives the message on the same carrier thread. After a
275 ms run window, the owner stops the services, checks faults and frees them.

Use **Free Pascal 3.2.2** and Python 3.12. Windows x86/x64, Linux x64 and macOS
x64/ARM64 have integrated runtime evidence in the
[support matrix](support-matrix.md). Delphi and other FPC versions require a
different context adapter; these instructions do not claim they can build the
integrated example. Linux needs FCL and a C toolchain (`build-essential` on
Ubuntu); macOS needs Apple command-line tools.

## Install with Boss

Use your consumer project directory with Boss installed. If the project does
not have `boss.json` yet, run `boss init` before installing the dependency:

```sh
boss install github.com/ramonruanxc/delphi-fiber-runtime
```

To select the documented release explicitly, add or update this entry in your
consumer's `boss.json` `dependencies` object. Merge it with existing dependencies
and retain all other consumer fields; do not replace the entire file with this
fragment:

```json
{
  "dependencies": {
    "github.com/ramonruanxc/delphi-fiber-runtime": "0.3.1-prototype.1"
  }
}
```

Then install from the manifest:

```sh
boss install
```

Use this manifest form for the prerelease version. Boss 3.0.17's command-line
version parser does not accept the full `@v0.3.1-prototype.1` tag syntax and may
finish without adding the dependency.

Boss 3.0.17 uses this layout:

```text
consumer/
  boss.json
  modules/
    github_com_ramonruanxc_delphi-fiber-runtime/
      src/
      native/context/
      demo/QuickStart.dpr
      scripts/build_example.py
```

Run the installed example from the consumer directory:

```sh
python modules/github_com_ramonruanxc_delphi-fiber-runtime/scripts/build_example.py --library modules/github_com_ramonruanxc_delphi-fiber-runtime --out build/quickstart
```

The build helper compiles and runs QuickStart against that library directory.
On Unix it also builds the bundled native helper for the host architecture.
Boss retrieves source and metadata; it does not run that native build for you.
For your own program, add the installed `src/` to the compiler unit search path
and preserve the included backend directories. Unix consumers also need the
native archive and `cthreads` first, as described below.

## Build QuickStart

For a manual installation, clone the repository and run from its root:

```sh
git clone https://github.com/ramonruanxc/delphi-fiber-runtime.git
cd delphi-fiber-runtime
python scripts/build_example.py
```

This is the same example and compiler boundary as the Boss installation. No
sibling library, external Boost installation or C++ runtime is needed.

For a direct Windows FPC build in PowerShell:

```powershell
New-Item -ItemType Directory -Force build/quickstart | Out-Null
fpc -B -Mdelphi -Sa -Fusrc -FUbuild/quickstart -FEbuild/quickstart demo/QuickStart.dpr
if ($LASTEXITCODE -eq 0) { & ./build/quickstart/QuickStart.exe }
```

The Pascal Windows backend uses native fibers. The explicit `in '../src/...'`
paths in the demo aid IDE source navigation, while FPC builds supply `-Fusrc`.
They do not make this an executable Delphi IDE example.

For a direct Unix build, first produce the native archive, then link it through
FPC's library path:

```sh
python scripts/context_build.py --out build/native
mkdir -p build/quickstart
fpc -B -Mdelphi -Sa -Fusrc -Flbuild/native -FUbuild/quickstart -FEbuild/quickstart demo/QuickStart.dpr
./build/quickstart/QuickStart
```

`context_build.py` selects the shipped Linux x64 or macOS x64/ARM64 assembly and
runs its native tests. The Pascal context unit links `fr_context`, C, math and
pthread libraries. QuickStart already includes `cthreads` first on Unix. Use a
matching compiler/CPU and keep native objects separate between targets.

Output includes a last message, service and event counts, and this success marker:

```text
Last message: Hello from tick 5
period_us=50000 started=5 skipped=0
published=5 received=5 discarded=0 aborted=0
PASS: QuickStart services and managed events stopped cleanly
```

Counts can vary with scheduling load. The example requires a received event,
checks service/subscription task faults, and verifies settled event accounting.
It reports skipped cycles and discarded/aborted deliveries rather than assuming
every planned cycle must run. Exit zero and the `PASS` marker indicate that this
example completed, not that a timing tolerance was qualified.

## Adapt the example

The wiring is explicit and stays on the scheduler's creating thread:

```pascal
Scheduler := TFiberScheduler.Create(2);
Hub := TFiberEventHub.Create(Scheduler, 16, 1);
Producer := TFiberService.Create(Scheduler, 50000, PublishTick, nil);
Receiver := TFiberService.Create(Scheduler, 50000, DormantTick, nil);
Publisher := Hub.Attach(Producer);
Subscription := Hub.Subscribe(Hub.Attach(Receiver), ReceiveMessage, nil);
Producer.Start;
Scheduler.RunUntil(Scheduler.NowUs + 275000);
```

Two scheduler slots cover the producer task and the subscription dispatcher.
The receiver is a dormant service used to own that subscription. If it also
needs periodic work, reserve another slot and call its `Start` once.
Completed tasks do not replenish the scheduler's lifetime admission capacity.

Replace `TMessage` with your own `TInterfacedObject` and interface. The hub takes
interface references for accepted deliveries. Keep the shared payload immutable;
the callback's raw `Data` pointer, if used, remains borrowed. `Publish` returns
`False` when full or stopped: decide whether the application should count, retry
later or fail. Retrying must not become an unbounded queue or busy loop.

Subscriptions receive all current hub sources; inspect `Source` or payload data
for application filtering. Handlers have no implicit main-thread UI lane. They
execute wherever you created and pump the scheduler.

Compatible waits (`Delay`, `AwaitUntil`, channel waits) let another task run.
Blocking file/network libraries and CPU work that never yields keep the carrier
occupied. Move blocking work to an external native worker and return results
through the explicit mailbox/event `Post` APIs, respecting their capacity and
payload-lifetime contracts. `RunUntil` returning `False` at the run deadline is
normal while periodic services or subscriptions remain alive.

## Keep shutdown and ownership together

QuickStart's `StopAll` cancels both services, checks each service `Stop`, and
then checks scheduler `Stop`. It frees services before the hub, and the hub
before the scheduler. Endpoints, subscriptions and task handles are owned by
the runtime and must not be freed by application code.

Source stop rejects new publications, removes its queued events and waits active
handlers attributed to that source. Recipient stop closes its subscriptions and
cancels their waits. Successful stop rules out later attributed callbacks, but
queued events may have been discarded. Inspect `DeliveredCount`,
`DiscardedCount`, `AbortedCount` and task fault fields for the result of the work.

If `Stop(TimeoutUs)` returns `False`, preserve resources and callback data and
retry on the owner thread. QuickStart puts checked `StopAll` before any `Free`
in its `finally`; a repeated cleanup failure raises and skips destruction. Its
console failure path exits with code 1. A running application should retain the
same ownership while arranging another cooperative cleanup attempt.

Timeouts cannot interrupt blocking user code. Never suspend while handling an
exception, unwinding a stack or holding a native lock. See the
[runtime contract](runtime-contract.md) and [context restrictions](context-contract.md).

## Run the broader checks

From a Git clone:

```sh
python scripts/check.py
python scripts/package.py
```

Add `--references` to `check.py` for the separately fetched, pinned sibling
comparisons; it requires GitHub access. Use `--core-only` for the standalone
periodic core without context requirements. Packaging takes tracked files and
builds an extracted consumer; commit intended package inputs before generating
a release archive. The detailed gates and evidence are in
[verification](verification.md).
