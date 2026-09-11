type
  TOwnerProbe = class(TThread)
    Task: TScheduledTask;
    Rejected: Integer;
    procedure Execute; override;
  end;

  TProducer = class(TThread)
    Scheduler: TFiberScheduler;
    Accepted: Integer;
    procedure Execute; override;
  end;

var
  Log: string;
  Parked: TScheduledTask;
  Calls, Reentries, Posted: Integer;

procedure Empty(T: TScheduledTask; Data: Pointer);
begin
  if Data <> nil then
    Inc(PInteger(Data)^);
end;

procedure Counter(Data: Pointer);
begin
  Inc(PInteger(Data)^);
end;

procedure PostedFault(Data: Pointer);
begin
  raise EConvertError.Create('post fault');
end;

procedure ObjectPostFault(Data: Pointer);
begin
  raise TObject.Create;
end;

procedure Reenter(Data: Pointer);
var
  R: Boolean;
begin
  R := False;
  try
    S.RunUntil(10000);
  except
    on EFiberUsage do
      R := True;
  end;
  if R then
    Inc(Reentries);
  R := False;
  try
    S.Stop(10000);
  except
    on EFiberUsage do
      R := True;
  end;
  if R then
    Inc(Reentries);
  R := False;
  try
    S.Free;
  except
    on EFiberUsage do
      R := True;
  end;
  if R then
    Inc(Reentries);
  R := False;
  try
    S.StopTask(Parked, 100);
  except
    on EFiberUsage do
      R := True;
  end;
  if R then
    Inc(Reentries);
end;

procedure Fair(T: TScheduledTask; Data: Pointer);
var
  I: Integer;
begin
  for I := 1 to 3 do
  begin
    Log := Log + Chr(PtrUInt(Data));
    T.Yield;
  end;
end;

procedure EarlyWake(T: TScheduledTask; Data: Pointer);
begin
  S.WakeTask(Parked);
  S.WakeTask(Parked);
end;

procedure TimerTask(T: TScheduledTask; Data: Pointer);
begin
  T.Delay(1000);
  Check(D.Clock >= 1000, 'SCHEDULER_WAKE_RECHECKS_TIMER');
end;

procedure Parking(T: TScheduledTask; Data: Pointer);
begin
  try
    T.Park;
  finally
    Inc(Cleanups);
  end;
end;

procedure FaultTask(T: TScheduledTask; Data: Pointer);
begin
  raise EConvertError.Create('task fault');
end;

procedure UsageTask(T: TScheduledTask; Data: Pointer);
var
  R: Boolean;
begin
  Check((T.Scheduler = S) and (S.CurrentTask = T), 'SCHEDULER_TASK_IDENTITY');
  T.LocalValue := Data;
  Check(T.LocalValue = Data, 'SCHEDULER_LOCAL_VALUE');
  R := False;
  try
    Parked.Yield;
  except
    on EFiberUsage do
      R := True;
  end;
  Check(R, 'SCHEDULER_OTHER_TASK_YIELD');
  R := False;
  try
    T.Free;
  except
    on EFiberUsage do
      R := True;
  end;
  Check(R and (T.State = fsRunning), 'SCHEDULER_FREE_RUNNING');
  Reenter(nil);
  try
    raise Exception.Create('handler');
  except
    R := False;
    try
      T.Park;
    except
      on EFiberUsage do
        R := True;
    end;
    Check(R, 'SCHEDULER_HANDLER_GUARD');
  end;
  T.Yield;
end;

procedure TOwnerProbe.Execute;
var
  Trace: TSchedulerTaskTrace;
begin
  try
    Trace := Task.Trace;
    Check(not Trace.HasResume, 'FOREIGN_TRACE');
  except
    on EFiberUsage do
      Inc(Rejected);
  end;
  try
    Task.AwaitUntilOrResume(1, 0);
  except
    on EFiberUsage do
      Inc(Rejected);
  end;
  try
    Task.Yield;
  except
    on EFiberUsage do
      Inc(Rejected);
  end;
  try
    Task.Park;
  except
    on EFiberUsage do
      Inc(Rejected);
  end;
  try
    Task.Delay(1);
  except
    on EFiberUsage do
      Inc(Rejected);
  end;
  try
    Task.AwaitUntil(1);
  except
    on EFiberUsage do
      Inc(Rejected);
  end;
  try
    Task.Cancel;
  except
    on EFiberUsage do
      Inc(Rejected);
  end;
  try
    Task.CheckCancelled;
  except
    on EFiberUsage do
      Inc(Rejected);
  end;
  try
    Task.Free;
  except
    on EFiberUsage do
      Inc(Rejected);
  end;
  try
    Check(Task.State = fsCreated, 'FOREIGN_STATE');
  except
    on EFiberUsage do
      Inc(Rejected);
  end;
  try
    Check(not Task.CancelRequested, 'FOREIGN_CANCEL');
  except
    on EFiberUsage do
      Inc(Rejected);
  end;
  try
    Check(Task.ErrorClass = '', 'FOREIGN_ERROR');
  except
    on EFiberUsage do
      Inc(Rejected);
  end;
  try
    Check(Task.ErrorMessage = '', 'FOREIGN_MESSAGE');
  except
    on EFiberUsage do
      Inc(Rejected);
  end;
  try
    Check(Task.Scheduler = S, 'FOREIGN_SCHEDULER');
  except
    on EFiberUsage do
      Inc(Rejected);
  end;
  try
    Check(Task.LocalValue = nil, 'FOREIGN_LOCAL');
  except
    on EFiberUsage do
      Inc(Rejected);
  end;
  try
    Task.LocalValue := Self;
  except
    on EFiberUsage do
      Inc(Rejected);
  end;
  try
    S.Free;
  except
    on EFiberUsage do
      Inc(Rejected);
  end;
  try
    S.Spawn(Empty, nil);
  except
    on EFiberUsage do
      Inc(Rejected);
  end;
  try
    S.RunUntil(1);
  except
    on EFiberUsage do
      Inc(Rejected);
  end;
  try
    S.RunTaskUntil(Task, 1);
  except
    on EFiberUsage do
      Inc(Rejected);
  end;
  try
    S.StopTask(Task, 1);
  except
    on EFiberUsage do
      Inc(Rejected);
  end;
  try
    S.Stop(1);
  except
    on EFiberUsage do
      Inc(Rejected);
  end;
  try
    S.WakeTask(Task);
  except
    on EFiberUsage do
      Inc(Rejected);
  end;
  try
    S.RunUntilCondition(nil, nil, 1);
  except
    on EFiberUsage do
      Inc(Rejected);
  end;
  try
    S.CleanupNowUs;
  except
    on EFiberUsage do
      Inc(Rejected);
  end;
  try
    Check(S.ResumeGeneration >= 0, 'FOREIGN_RESUME_GEN');
  except
    on EFiberUsage do
      Inc(Rejected);
  end;
  try
    Check(S.ResumeEpochUs >= 0, 'FOREIGN_RESUME_EPOCH');
  except
    on EFiberUsage do
      Inc(Rejected);
  end;
  try
    S.CheckOwner;
  except
    on EFiberUsage do
      Inc(Rejected);
  end;
  try
    Check(S.NowUs = 0, 'FOREIGN_NOW');
  except
    on EFiberUsage do
      Inc(Rejected);
  end;
  try
    Check(S.CurrentTask = nil, 'FOREIGN_CURRENT');
  except
    on EFiberUsage do
      Inc(Rejected);
  end;
  try
    Check(S.PostFaultCount = 0, 'FOREIGN_FAULT_COUNT');
  except
    on EFiberUsage do
      Inc(Rejected);
  end;
  try
    Check(S.MaxTasks > 0, 'FOREIGN_CAPACITY');
  except
    on EFiberUsage do
      Inc(Rejected);
  end;
  try
    Check(not S.ClockDiscontinuity, 'FOREIGN_CLOCK');
  except
    on EFiberUsage do
      Inc(Rejected);
  end;
end;

{$I tests-behavior.inc}
