constructor TFiberScheduler.Create(AMaxTasks: Integer; ADriver: TSchedulerDriver);
begin
  inherited Create;
  FOwner := GetCurrentThreadID;
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
  Enqueue(Result);
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
    FDriver.Wake;
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
var Generation: Int64;
begin
  if Cleanup then
  begin
    try Result := FDriver.NowUs;
    except on EClockDiscontinuity do Result := FLastNow; end;
    Exit;
  end;
  try
    Generation := FDriver.ClockGeneration;
    Result := FDriver.NowUs;
    if FClockFault or (FClockSeen and (Result < FLastNow)) or
      (FGenerationSeen and (Generation <> FGeneration)) then
      raise EClockDiscontinuity.Create('Scheduler clock discontinuity');
    FGeneration := Generation; FGenerationSeen := True;
    FLastNow := Result; FClockSeen := True;
  except
    on E: EClockDiscontinuity do
    begin
      FClockFault := True; RequestStop;
      raise EFiberUsage.Create('Scheduler clock discontinuity: ' + E.Message);
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

