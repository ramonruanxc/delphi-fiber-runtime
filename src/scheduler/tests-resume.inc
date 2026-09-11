type
  TResumeDriver = class(TVirtualDriver)
    Jumped: Boolean;
    procedure WaitUntil(DeadlineUs: Int64); override;
  end;
procedure TResumeDriver.WaitUntil(DeadlineUs: Int64);
begin
  Inc(Waits);
  if not Jumped then begin Jumped := True; Inc(Generation); Inc(Clock, 10); end
  else Clock := DeadlineUs;
end;
procedure ResumeOrdinary(T: TScheduledTask; Data: Pointer);
begin
  T.AwaitUntil(100);
  Check(D.Clock >= 100, 'SCHEDULER_RESUME_ORDINARY_PREDICATE');
  Inc(Steps);
end;
procedure ResumeAware(T: TScheduledTask; Data: Pointer);
begin
  Check(not T.AwaitUntilOrResume(100, S.ResumeGeneration), 'SCHEDULER_RESUME_WAIT_INTERRUPTED');
  Check((S.ResumeGeneration = 1) and (S.ResumeEpochUs = 10), 'SCHEDULER_RESUME_METADATA');
  Check(not S.ClockDiscontinuity and not T.CancelRequested, 'SCHEDULER_RESUME_PRESERVES_WORKFLOW');
  Inc(Steps);
end;
function HasOneStep(Data: Pointer): Boolean;
begin Result := Steps = 1; end;
procedure TestResumeDefault;
var Ordinary: TScheduledTask; Trace: TSchedulerTaskTrace;
begin
  Steps := 0; D := TResumeDriver.Create; S := TFiberScheduler.Create(2, D);
  Ordinary := S.Spawn(ResumeOrdinary, nil); S.Spawn(ResumeAware, nil);
  Check(S.RunUntilCondition(HasOneStep, nil, 200), 'SCHEDULER_CONDITION_SETTLED');
  Check((D.Clock = 10) and (Ordinary.State = fsSuspended), 'SCHEDULER_CONDITION_RETENTION');
  Check(S.RunUntil(200) and (Steps = 2), 'SCHEDULER_RESUME_FINAL');
  Trace := Ordinary.Trace;
  Check(Trace.HasWaitDeadline and Trace.HasTimerObservation and Trace.HasReadyEnqueue and
    Trace.HasResume and (Trace.WaitDeadlineUs = 100) and (Trace.TimerObservedUs = 100) and
    (Trace.ReadyEnqueuedUs = 100) and (Trace.ResumedUs = 100) and
    (Trace.ReadyReason = rrTimer) and (Trace.ReadyGeneration = 1) and
    (Trace.ResumeGeneration = 1), 'SCHEDULER_STAGE_TRACE');
  S.Free; D.Free;
end;
procedure TraceImmediate(T: TScheduledTask; Data: Pointer);
var Trace: TSchedulerTaskTrace;
begin
  T.AwaitUntil(0); Trace := T.Trace;
  Check(Trace.HasWaitDeadline and not Trace.HasTimerObservation and
    not Trace.HasReadyEnqueue and not Trace.HasResume, 'SCHEDULER_IMMEDIATE_TRACE_UNAVAILABLE');
  Check(T.AwaitUntilOrResume(0, S.ResumeGeneration), 'SCHEDULER_RESUME_ALREADY_DUE');
end;
procedure TestTraceDuplicate;
var T: TScheduledTask; Before, After: TSchedulerTaskTrace;
begin
  D := TVirtualDriver.Create; S := TFiberScheduler.Create(2, D);
  T := S.Spawn(Empty, nil); Before := T.Trace;
  D.Clock := 7; S.WakeTask(T); S.WakeTask(T); After := T.Trace;
  Check(Before.HasReadyEnqueue and After.HasReadyEnqueue and
    (Before.ReadyEnqueuedUs = After.ReadyEnqueuedUs) and
    (After.ReadyReason = rrSpawn), 'SCHEDULER_TRACE_FIRST_ENQUEUE');
  S.Spawn(TraceImmediate, nil);
  Check(S.RunUntil(100), 'SCHEDULER_TRACE_IMMEDIATE_SETTLED');
  After := T.Trace;
  Check(After.HasResume and (After.ResumedUs = 7), 'SCHEDULER_TRACE_DISPATCH_TIMESTAMP');
  S.Free; D.Free;
end;
function ReentrantCondition(Data: Pointer): Boolean;
var R: Boolean;
begin
  Check(S.CurrentTask = nil, 'SCHEDULER_CONDITION_OWNER_CARRIER');
  R := False; try S.RunUntilCondition(ReentrantCondition, nil, 1);
  except on EFiberUsage do R := True; end;
  Check(R, 'SCHEDULER_CONDITION_REENTRY');
  R := False; try Parked.Yield; except on EFiberUsage do R := True; end;
  Check(R, 'SCHEDULER_CONDITION_NO_SUSPEND');
  Result := True;
end;
function FailingCondition(Data: Pointer): Boolean;
begin raise EConvertError.Create('condition fault'); Result := False; end;
procedure TestConditions;
var R: Boolean;
begin
  D := TVirtualDriver.Create; S := TFiberScheduler.Create(1, D);
  Parked := S.Spawn(Parking, nil);
  R := False; try S.RunUntilCondition(nil, nil, 100); except on EFiberUsage do R := True; end;
  Check(R, 'SCHEDULER_CONDITION_REQUIRED');
  Check(S.RunUntilCondition(ReentrantCondition, nil, 100), 'SCHEDULER_CONDITION_TRUE_NO_DISPATCH');
  Check(Parked.State = fsCreated, 'SCHEDULER_CONDITION_PRESERVES_WORK');
  R := False; try S.RunUntilCondition(FailingCondition, nil, 100); except on EConvertError do R := True; end;
  Check(R, 'SCHEDULER_CONDITION_PROPAGATES_FAULT');
  Check(S.Stop(100), 'SCHEDULER_CONDITION_RESETS_PUMP'); S.Free; D.Free;
end;
procedure TestResumeBackwardGeneration;
var R: Boolean;
begin
  D := TVirtualDriver.Create; D.Generation := 2;
  S := TFiberScheduler.Create(1, D); S.Spawn(Parking, nil);
  Check(not S.RunUntil(10), 'SCHEDULER_RESUME_BACKWARD_PREPARE'); D.Generation := 1;
  R := False; try S.RunUntil(20); except on EFiberUsage do R := True; end;
  Check(R and S.ClockDiscontinuity, 'SCHEDULER_RESUME_BACKWARD_FAIL_CLOSED');
  Check(S.Stop(100), 'SCHEDULER_RESUME_BACKWARD_CLEANUP'); S.Free; D.Free;
end;
