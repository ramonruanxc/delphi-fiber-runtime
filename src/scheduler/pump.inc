function TFiberScheduler.TraceNow(out Value: Int64): Boolean;
begin
  { Diagnostic reads must never alter task admission or notification semantics.
    A failed read is explicitly unavailable; dispatch clock checks remain strict. }
  try
    Value := FDriver.NowUs;
    Result := True;
  except
    Value := 0;
    Result := False;
  end;
end;

procedure TFiberScheduler.Enqueue(T: TScheduledTask; Reason: TReadyReason);
begin
  {$IFNDEF CONTEXT_PROVE_READY}
  if T.FQueued then
    Exit;
  {$ENDIF}
  { Negative mutation is detected before a duplicate could transfer control. }
  if T.FQueued then
  begin
    WriteLn('ASSERTION FAILED: SCHEDULER_READY_ONCE');
    Halt(1);
  end;
  if Terminal(T) then
    Exit;
  if FReadyCount = Length(FReady) then
    raise EFiberUsage.Create('Ready queue invariant violated');
  FReady[(FReadyHead + FReadyCount) mod Length(FReady)] := T;
  Inc(FReadyCount);
  T.FQueued := True;
  T.FTrace.HasReadyEnqueue := TraceNow(T.FTrace.ReadyEnqueuedUs);
  T.FTrace.ReadyReason := Reason;
  T.FTrace.ReadyGeneration := FGeneration;
end;

procedure TFiberScheduler.WakeTask(ATask: TScheduledTask);
begin
  CheckOwner;
  if (ATask = nil) or (ATask.FOwner <> Self) then
    raise EFiberUsage.Create('Task belongs to another scheduler');
  if ATask = FCurrent then
    Exit;
  Enqueue(ATask);
end;

function TFiberScheduler.PopReady: TScheduledTask;
begin
  Result := nil;
  if FReadyCount = 0 then
    Exit;
  Result := FReady[FReadyHead];
  FReady[FReadyHead] := nil;
  FReadyHead := (FReadyHead + 1) mod Length(FReady);
  Dec(FReadyCount);
  Result.FQueued := False;
end;

function TFiberScheduler.TakePost(out Work: TCarrierWork): Boolean;
begin
  EnterCriticalSection(FLock);
  try
    Result := FPostCount <> 0;
    if not Result then
      Exit;
    Work := FPosts[FPostHead];
    FPosts[FPostHead].Proc := nil;
    FPosts[FPostHead].Data := nil;
    FPostHead := (FPostHead + 1) mod Length(FPosts);
    Dec(FPostCount);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TFiberScheduler.Settled: Boolean;
var
  I: Integer;
begin
  Result := False;
  EnterCriticalSection(FLock);
  try
    if FPostCount <> 0 then
      Exit;
  finally
    LeaveCriticalSection(FLock);
  end;
  for I := 0 to FCount - 1 do
    if not Terminal(FTasks[I]) then
      Exit;
  Result := True;
end;

procedure TFiberScheduler.Maintain(Now: Int64; out Nearest: Int64);
var
  I: Integer;
  T: TScheduledTask;
  Stopping: Boolean;
begin
  Nearest := High(Int64);
  Stopping := IsStopping;
  for I := 0 to FCount - 1 do
  begin
    T := FTasks[I];
    if Terminal(T) then
      Continue;
    if Stopping then
      T.Cancel;
    if Terminal(T) then
      Continue;
    if T.FWait = swTimer then
      if Now >= T.FDeadline then
      begin
        if not T.FTrace.HasTimerObservation then
        begin
          T.FTrace.TimerObservedUs := Now;
          T.FTrace.HasTimerObservation := True;
        end;
        Enqueue(T, rrTimer);
      end
      else if not T.FQueued and (T.FDeadline < Nearest) then
        Nearest := T.FDeadline;
  end;
end;

function TFiberScheduler.Pump(Deadline: Int64; Target: TScheduledTask; Cleanup: Boolean;
  Condition: TCarrierCondition; Data: Pointer): Boolean;
var
  N, Nearest: Int64;
  T: TScheduledTask;
  Work: TCarrierWork;
  HadPost: Boolean;
  WallStart, WallBudget: UInt64;
begin
  FPumping := True;
  FInCleanup := Cleanup;
  HadPost := False;
  try
    WallStart := GetTickCount64;
    WallBudget := High(UInt64);
    if Cleanup then
    begin
      N := ClockNow(True);
      if Deadline <= N then
        WallBudget := 0
      else
        WallBudget := UInt64((Deadline - N) div 1000) + 1;
    end;
    while True do
    begin
      N := ClockNow(Cleanup);
      Maintain(N, Nearest);
      if Assigned(Condition) then
        Result := Condition(Data)
      else if Target <> nil then
        Result := Terminal(Target)
      else
        Result := Settled;
      if Result then
        Exit;
      if (N >= Deadline) or (Cleanup and (GetTickCount64 - WallStart >= WallBudget)) then
        Exit(False);
      { One mailbox item and one FIFO turn bound timer/mailbox service latency. }
      if (not HadPost or (FReadyCount = 0)) and TakePost(Work) then
      begin
        HadPost := True;
        try
          Work.Proc(Work.Data);
        except
          Inc(FPostFaultCount);
        end;
        Continue;
      end;
      HadPost := False;
      T := PopReady;
      if T <> nil then
      begin
        if not Terminal(T) then
        begin
          T.FTrace.HasResume := TraceNow(T.FTrace.ResumedUs);
          T.FTrace.ResumeGeneration := FGeneration;
          FCurrent := T;
          try
            T.FContext.Resume;
          finally
            FCurrent := nil;
          end;
          if not Terminal(T) and (T.FWait = swReady) then
            Enqueue(T, rrYield);
        end;
        Continue;
      end;
      if Nearest > Deadline then
        Nearest := Deadline;
      FDriver.WaitUntil(Nearest);
    end;
  finally
    FInCleanup := False;
    FPumping := False;
  end;
end;
