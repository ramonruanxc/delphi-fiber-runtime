procedure TestStopTaskClock;
var Mode: Integer; R: Boolean;
begin
  for Mode := 0 to 1 do
  begin
    Cleanups := 0; D := TVirtualDriver.Create; D.Clock := 100;
    S := TFiberScheduler.Create(2, D); Parked := S.Spawn(Parking, nil);
    Check(not S.RunUntil(200), 'SCHEDULER_STOP_TASK_PARK');
    if Mode = 0 then D.Clock := 199 else Inc(D.Generation);
    R := False; try S.RunUntil(300); except on EFiberUsage do R := True; end;
    Check(R and S.ClockDiscontinuity, 'SCHEDULER_STOP_TASK_CLOCK_FAULT');
    R := False; try R := S.StopTask(Parked, 1000); except on EFiberUsage do R := False; end;
    Check(R and (Cleanups = 1) and (Parked.State = fsCancelled),
      'SCHEDULER_STOP_TASK_CLOCK_CLEANUP');
    Check(S.StopTask(Parked, 0), 'SCHEDULER_STOP_TASK_TERMINAL_FASTPATH');
    S.Free; D.Free;
  end;
end;
procedure TestStopTaskHealthy;
var Other: TScheduledTask; R: Boolean;
begin
  Cleanups := 0; D := TVirtualDriver.Create; S := TFiberScheduler.Create(3, D);
  Parked := S.Spawn(Parking, nil); Other := S.Spawn(Parking, nil);
  Check(not S.RunUntil(10), 'SCHEDULER_STOP_TASK_HEALTHY_PARK');
  R := False; try S.StopTask(Parked, -1); except on EFiberUsage do R := True; end;
  Check(R and not Parked.CancelRequested, 'SCHEDULER_STOP_TASK_INVALID_TIMEOUT');
  R := False; try S.StopTask(nil, 100); except on EFiberUsage do R := True; end;
  Check(R, 'SCHEDULER_STOP_TASK_INVALID_TARGET');
  Check(not S.StopTask(Parked, 0), 'SCHEDULER_STOP_TASK_TIMEOUT');
  Check((Cleanups = 0) and (Parked.State = fsSuspended), 'SCHEDULER_STOP_TASK_RETAINS_STACK');
  Check(S.StopTask(Parked, 1000), 'SCHEDULER_STOP_TASK_HEALTHY_CLEANUP');
  Check((Cleanups = 1) and (Other.State = fsSuspended) and not Other.CancelRequested,
    'SCHEDULER_STOP_TASK_PRESERVES_OTHERS');
  Check(S.Post(Counter, @Calls), 'SCHEDULER_STOP_TASK_PRESERVES_ADMISSION');
  S.Spawn(Empty, nil);
  Check(S.Stop(1000), 'SCHEDULER_STOP_TASK_FINAL_CLEANUP'); S.Free; D.Free;
end;
procedure ChangeGeneration(Data: Pointer);
begin Inc(D.Generation); end;
procedure TestStopTaskNewFault;
var Other: TScheduledTask;
begin
  Cleanups := 0; D := TVirtualDriver.Create; S := TFiberScheduler.Create(2, D);
  Parked := S.Spawn(Parking, nil); Other := S.Spawn(Parking, nil);
  Check(not S.RunUntil(10), 'SCHEDULER_STOP_TASK_NEW_FAULT_PARK');
  Check(S.Post(ChangeGeneration, nil), 'SCHEDULER_STOP_TASK_NEW_FAULT_POST');
  Check(S.StopTask(Parked, 1000), 'SCHEDULER_STOP_TASK_NEW_FAULT_CLEANUP');
  Check(S.ClockDiscontinuity and Other.CancelRequested,
    'SCHEDULER_STOP_TASK_DETECTS_NEW_FAULT');
  Check(S.Stop(1000), 'SCHEDULER_STOP_TASK_NEW_FAULT_FINAL'); S.Free; D.Free;
end;
type
  TWakeFailDriver = class(TVirtualDriver)
    FailWake: Boolean;
    procedure Wake; override;
  end;
procedure TWakeFailDriver.Wake;
begin
  if FailWake then raise EConvertError.Create('injected notification failure');
  inherited;
end;
procedure TestPostWakeFailure;
var Driver: TWakeFailDriver; R, Accepted: Boolean;
begin
  Calls := 0; Driver := TWakeFailDriver.Create; S := TFiberScheduler.Create(2, Driver);
  Driver.FailWake := True; Accepted := False; R := False;
  try Accepted := S.Post(Counter, @Calls); except on EConvertError do R := True; end;
  Check(R and not Accepted, 'SCHEDULER_POST_WAKE_FAILURE_PROPAGATED');
  Driver.FailWake := False;
  Check(S.RunUntil(100), 'SCHEDULER_POST_WAKE_FAILURE_SETTLED');
  Check(Calls = 0, 'SCHEDULER_POST_WAKE_FAILURE_NO_ADMISSION');
  Check(S.Post(Counter, @Calls), 'SCHEDULER_POST_WAKE_FAILURE_FIRST');
  Driver.FailWake := True;
  try S.Post(Counter, @Calls); except on EConvertError do ; end;
  Driver.FailWake := False;
  Check(S.Post(Counter, @Calls), 'SCHEDULER_POST_WAKE_FAILURE_ROLLBACK_CAPACITY');
  Check(S.RunUntil(100) and (Calls = 2), 'SCHEDULER_POST_WAKE_FAILURE_PRESERVES_ACCEPTED');
  S.Free; Driver.Free;
end;
