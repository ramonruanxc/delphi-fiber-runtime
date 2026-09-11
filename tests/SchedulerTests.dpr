program SchedulerTests;
{$mode delphi}{$H+}
uses {$ifdef unix}cthreads,{$endif} SysUtils, Classes, SyncObjs,
  FiberRuntime.Context, FiberRuntime.Scheduler, FiberRuntime.Platform;
type
  TVirtualDriver = class(TSchedulerDriver)
    Clock, Generation: Int64;
    Waits, Wakes: Integer;
    function NowUs: Int64; override;
    function ClockGeneration: Int64; override;
    procedure WaitUntil(DeadlineUs: Int64); override;
    procedure Wake; override;
  end;
var S: TFiberScheduler; D: TVirtualDriver; Steps, Cleanups: Integer;
procedure Check(V: Boolean; const N: string);
begin if not V then begin WriteLn('ASSERTION FAILED: ', N); Halt(1); end; end;
function TVirtualDriver.ClockGeneration: Int64;
begin Result := Generation; end;
function TVirtualDriver.NowUs: Int64;
begin Result := Clock; end;
procedure TVirtualDriver.WaitUntil(DeadlineUs: Int64);
begin Inc(Waits); Clock := DeadlineUs; end;
procedure TVirtualDriver.Wake;
begin Inc(Wakes); end;
procedure Awaiter(T: TScheduledTask; Data: Pointer);
begin
  try
    Check(T.Scheduler.CurrentTask = T, 'SCHEDULER_IDENTITY');
    T.AwaitUntil(1000);
    Check((Steps = 1) and (D.Clock = 1000), 'SCHEDULER_NO_EARLY_TIMER');
    Inc(Steps);
  finally Inc(Cleanups); end;
end;
procedure Runner(T: TScheduledTask; Data: Pointer);
begin Check(D.Clock = 0, 'SCHEDULER_NONBLOCKING_WAIT'); Inc(Steps); end;
procedure TestVirtual;
var A: TScheduledTask;
begin
  D := TVirtualDriver.Create; S := TFiberScheduler.Create(2, D);
  A := S.Spawn(Awaiter, nil); S.Spawn(Runner, nil);
  S.WakeTask(A); S.WakeTask(A);
  Check(S.RunUntil(2000), 'SCHEDULER_SETTLED');
  Check((Steps = 2) and (Cleanups = 1) and (D.Waits = 1), 'SCHEDULER_VIRTUAL');
  Check(A.State = fsCompleted, 'SCHEDULER_TERMINAL');
  S.Free; D.Free;
end;
{ Test helpers are split to keep every source below 500 lines. }
{$I ../src/scheduler/tests-cases.inc}
{$I ../src/scheduler/tests-stop-task.inc}
{$I ../src/scheduler/tests-resume.inc}
{$I ../src/scheduler/tests-clock-snapshot.inc}
begin
  TestVirtual; TestTimersFairness; TestUsage; TestStop; TestPost; TestNativePostRace; TestMailboxFairness; TestTargetAndInvalid; TestClockFault; TestDrainParkRace; TestDriverFailureRetention;
  TestStopTaskClock; TestStopTaskHealthy; TestStopTaskNewFault; TestPostWakeFailure;
  TestResumeDefault; TestTraceDuplicate; TestConditions; TestResumeBackwardGeneration;
  TestConsistentClockSnapshot;
  WriteLn('PASS SchedulerTests');
end.
