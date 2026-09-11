constructor TFiberScheduler.Create(AMaxTasks: Integer; ADriver: TSchedulerDriver;
  AResumePolicy: TResumePolicy);
begin
  inherited Create;
  FOwner := GetCurrentThreadID; FResumePolicy := AResumePolicy;
  if AMaxTasks <= 0 then raise EFiberUsage.Create('Capacity must be positive');
  InitCriticalSection(FLock); FLockReady := True;
  SetLength(FTasks, AMaxTasks); SetLength(FReady, AMaxTasks);
  SetLength(FPosts, AMaxTasks);
  FDriver := ADriver;
  if FDriver = nil then begin FDriver := TNativeSchedulerDriver.Create; FOwnDriver := True; end;
  FRuntime := TFiberRuntime.Create;
end;
procedure TFiberScheduler.CheckOwner;
begin
  if GetCurrentThreadID <> FOwner then raise EFiberUsage.Create('Scheduler belongs to its creating thread');
end;
procedure TFiberScheduler.RequireCarrier;
begin
  CheckOwner;
  if FPumping then raise EFiberUsage.Create('Scheduler pump cannot be reentered');
  if RaiseList <> nil then raise EFiberUsage.Create('Scheduler pump during exception handling is prohibited');
end;
procedure TFiberScheduler.BeforeDestruction;
begin
  RequireCarrier;
  EnterCriticalSection(FLock);
  try
    if not Settled then raise EFiberUsage.Create('Scheduler retains unfinished work');
    FStopping := True;
  finally LeaveCriticalSection(FLock); end;
  inherited;
end;
destructor TFiberScheduler.Destroy;
var I: Integer;
begin
  for I := 0 to FCount - 1 do begin FTasks[I].FRelease := True; FTasks[I].Free; end;
  FRuntime.Free;
  if FOwnDriver then FDriver.Free;
  if FLockReady then DoneCriticalSection(FLock);
  inherited;
end;
function TFiberScheduler.Spawn(AProc: TScheduledProc; AData: Pointer): TScheduledTask;
begin
  CheckOwner;
  if not Assigned(AProc) then raise EFiberUsage.Create('Task callback is required');
  EnterCriticalSection(FLock);
  try
    if FStopping or FClockFault then raise EFiberUsage.Create('Scheduler is stopping');
    if FCount = Length(FTasks) then raise EFiberUsage.Create('Scheduler task capacity exhausted');
    Result := TScheduledTask.Create(Self, AProc, AData);
    FTasks[FCount] := Result; Inc(FCount);
  finally LeaveCriticalSection(FLock); end;
  Enqueue(Result, rrSpawn);
end;
function TFiberScheduler.Post(AProc: TCarrierProc; AData: Pointer): Boolean;
var Index: Integer;
begin
  Result := False;
  if not Assigned(AProc) then Exit;
  EnterCriticalSection(FLock);
  try
    if FStopping or (FPostCount = Length(FPosts)) then Exit;
    Index := (FPostHead + FPostCount) mod Length(FPosts);
    FPosts[Index].Proc := AProc; FPosts[Index].Data := AData;
    Inc(FPostCount);
    { Wake under this short lock: destruction cannot overtake accepted publication. }
    try FDriver.Wake;
    except
      { No carrier can consume while this lock is held. Failed notification
        must not transfer callback responsibility to the scheduler. }
      Dec(FPostCount); FPosts[Index].Proc := nil; FPosts[Index].Data := nil;
      raise;
    end;
    Result := True;
  finally LeaveCriticalSection(FLock); end;
end;
procedure TFiberScheduler.RequestStop;
begin
  EnterCriticalSection(FLock);
  try
    FStopping := True;
    FDriver.Wake;
  finally LeaveCriticalSection(FLock); end;
end;
function TFiberScheduler.IsStopping: Boolean;
begin
  EnterCriticalSection(FLock);
  try Result := FStopping;
  finally LeaveCriticalSection(FLock); end;
end;
function TFiberScheduler.GetCurrentTask: TScheduledTask;
begin CheckOwner; Result := FCurrent; end;
function TFiberScheduler.GetPostFaultCount: Int64;
begin CheckOwner; Result := FPostFaultCount; end;
function TFiberScheduler.GetMaxTasks: Integer;
begin CheckOwner; Result := Length(FTasks); end;
function TFiberScheduler.GetClockDiscontinuity: Boolean;
begin CheckOwner; Result := FClockFault; end;
function TFiberScheduler.ClockNow(Cleanup: Boolean): Int64;
var Generation, GenerationAfter: Int64; I, Attempt: Integer; Resumed: Boolean;
begin
  if Cleanup and FClockFault then
  begin
    try Result := FDriver.NowUs;
    except on EClockDiscontinuity do Result := FLastNow; end;
    Exit;
  end;
  try
    for Attempt := 1 to 3 do begin
      Generation := FDriver.ClockGeneration;
      Result := FDriver.NowUs;
      GenerationAfter := FDriver.ClockGeneration;
      if GenerationAfter < Generation then
        raise EClockDiscontinuity.Create('Scheduler clock generation moved backward');
      if Generation = GenerationAfter then Break;
    end;
    if Generation <> GenerationAfter then
      raise EClockDiscontinuity.Create('Scheduler clock sample did not stabilize');
    Resumed := FGenerationSeen and (Generation > FGeneration);
    if FClockFault or (Result < 0) or (Generation < 0) or
      (FClockSeen and (Result < FLastNow)) or
      (FGenerationSeen and (Generation < FGeneration)) or
      (Resumed and (FResumePolicy = rpStop)) then
      raise EClockDiscontinuity.Create('Scheduler clock discontinuity');
    if Resumed or not FGenerationSeen then FResumeEpochUs := Result;
    FGeneration := Generation; FGenerationSeen := True;
    FLastNow := Result; FClockSeen := True;
    if Resumed then
      for I := 0 to FCount - 1 do
        if (FTasks[I].FWait = swTimer) and (FTasks[I] <> FCurrent) then
          Enqueue(FTasks[I], rrResume);
  except
    on E: EClockDiscontinuity do
    begin
      FClockFault := True; RequestStop;
      if Cleanup then
      begin
        try Result := FDriver.NowUs;
        except on EClockDiscontinuity do Result := FLastNow; end;
      end
      else raise EFiberUsage.Create('Scheduler clock discontinuity: ' + E.Message);
    end;
  end;
end;
function TFiberScheduler.NowUs: Int64;
begin CheckOwner; Result := ClockNow(FInCleanup); end;
function TFiberScheduler.Stop(ATimeoutUs: Int64): Boolean;
var Deadline: Int64;
begin
  RequireCarrier;
  Deadline := AddDuration(ClockNow(True), ATimeoutUs);
  RequestStop;
  Result := Pump(Deadline, nil, True);
end;
function TFiberScheduler.RunUntil(ADeadlineUs: Int64): Boolean;
begin RequireCarrier; Result := Pump(ADeadlineUs, nil, False); end;
function TFiberScheduler.RunTaskUntil(ATask: TScheduledTask; ADeadlineUs: Int64): Boolean;
begin
  RequireCarrier;
  if (ATask = nil) or (ATask.FOwner <> Self) then raise EFiberUsage.Create('Task belongs to another scheduler');
  Result := Pump(ADeadlineUs, ATask, False);
end;
function TFiberScheduler.StopTask(ATask: TScheduledTask; ATimeoutUs: Int64): Boolean;
var Deadline: Int64;
begin
  RequireCarrier;
  if (ATask = nil) or (ATask.FOwner <> Self) then
    raise EFiberUsage.Create('Task belongs to another scheduler');
  if ATimeoutUs < 0 then raise EFiberUsage.Create('Duration must be nonnegative');
  if Terminal(ATask) then Exit(True);
  Deadline := AddDuration(ClockNow(True), ATimeoutUs);
  ATask.Cancel;
  Result := Pump(Deadline, ATask, True);
end;
function TFiberScheduler.GetResumeGeneration: Int64;
begin CheckOwner; Result := FGeneration; end;
function TFiberScheduler.GetResumeEpochUs: Int64;
begin CheckOwner; Result := FResumeEpochUs; end;
function TFiberScheduler.CleanupNowUs: Int64;
begin CheckOwner; Result := ClockNow(True); end;
function TFiberScheduler.RunUntilCondition(ACondition: TCarrierCondition;
  AData: Pointer; ADeadlineUs: Int64): Boolean;
begin
  RequireCarrier;
  if not Assigned(ACondition) then raise EFiberUsage.Create('Condition callback is required');
  Result := Pump(ADeadlineUs, nil, True, ACondition, AData);
end;
