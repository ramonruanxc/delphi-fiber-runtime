procedure ScheduledEntry(Context: TFiberTask; Data: Pointer);
var
  Task: TScheduledTask;
begin
  Task := TScheduledTask(Data);
  Task.FProc(Task, Task.FData);
end;

constructor TScheduledTask.Create(AOwner: TFiberScheduler; AProc: TScheduledProc; AData: Pointer);
begin
  inherited Create;
  FOwner := AOwner;
  FProc := AProc;
  FData := AData;
  FContext := FOwner.FRuntime.CreateTask(ScheduledEntry, Self);
end;

procedure TScheduledTask.BeforeDestruction;
begin
  FOwner.CheckOwner;
  if not FRelease then
    raise EFiberUsage.Create('Task handles are owned by the scheduler');
  inherited;
end;

destructor TScheduledTask.Destroy;
begin
  FContext.Free;
  inherited;
end;

procedure TScheduledTask.RequireCurrent;
begin
  FOwner.CheckOwner;
  if FOwner.FCurrent <> Self then
    raise EFiberUsage.Create('Wait belongs to the current task');
  if ContextExceptionActive then
    raise EFiberUsage.Create('Wait during exception handling is prohibited');
end;

procedure TScheduledTask.Suspend(AWait: TTaskWait; ADeadline: Int64);
begin
  RequireCurrent;
  CheckCancelled;
  FWait := AWait;
  FDeadline := ADeadline;
  try
    FContext.Yield;
  finally
    FWait := swReady;
  end;
  CheckCancelled;
end;

procedure TScheduledTask.Yield;
begin
  Suspend(swReady, 0);
end;

procedure TScheduledTask.Delay(ADurationUs: Int64);
begin
  RequireCurrent;
  AwaitUntil(AddDuration(FOwner.NowUs, ADurationUs));
end;

procedure TScheduledTask.AwaitUntil(ADeadlineUs: Int64);
begin
  RequireCurrent;
  CheckCancelled;
  BeginTimedWait(ADeadlineUs);
  while FOwner.NowUs < ADeadlineUs do
    Suspend(swTimer, ADeadlineUs);
end;

procedure TScheduledTask.Park;
begin
  Suspend(swParked, 0);
end;

procedure TScheduledTask.Cancel;
begin
  FOwner.CheckOwner;
  FContext.Cancel;
  if FContext.State = fsSuspended then
    FOwner.Enqueue(Self, rrCancel);
end;

procedure TScheduledTask.CheckCancelled;
begin
  FOwner.CheckOwner;
  FContext.CheckCancelled;
end;

function TScheduledTask.GetState: TFiberState;
begin
  FOwner.CheckOwner;
  Result := FContext.State;
end;

function TScheduledTask.GetCancelRequested: Boolean;
begin
  FOwner.CheckOwner;
  Result := FContext.CancelRequested;
end;

function TScheduledTask.GetErrorClass: string;
begin
  FOwner.CheckOwner;
  Result := FContext.ErrorClass;
end;

function TScheduledTask.GetErrorMessage: string;
begin
  FOwner.CheckOwner;
  Result := FContext.ErrorMessage;
end;

function TScheduledTask.GetScheduler: TFiberScheduler;
begin
  FOwner.CheckOwner;
  Result := FOwner;
end;

function TScheduledTask.GetLocalValue: Pointer;
begin
  FOwner.CheckOwner;
  Result := FContext.LocalValue;
end;

procedure TScheduledTask.SetLocalValue(Value: Pointer);
begin
  FOwner.CheckOwner;
  FContext.LocalValue := Value;
end;

procedure TScheduledTask.BeginTimedWait(ADeadline: Int64);
begin
  FTrace.HasWaitDeadline := True;
  FTrace.WaitDeadlineUs := ADeadline;
  FTrace.HasTimerObservation := False;
  FTrace.HasReadyEnqueue := False;
  FTrace.HasResume := False;
end;

function TScheduledTask.GetTrace: TSchedulerTaskTrace;
begin
  FOwner.CheckOwner;
  Result := FTrace;
end;

function TScheduledTask.AwaitUntilOrResume(ADeadlineUs, AExpectedGeneration: Int64): Boolean;
var
  Now: Int64;
begin
  RequireCurrent;
  CheckCancelled;
  BeginTimedWait(ADeadlineUs);
  while True do
  begin
    Now := FOwner.NowUs;
    if FOwner.ResumeGeneration <> AExpectedGeneration then
      Exit(False);
    if Now >= ADeadlineUs then
      Exit(True);
    Suspend(swTimer, ADeadlineUs);
  end;
end;
