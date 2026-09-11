procedure Benchmark;
var
  Runs: array of TRun;
  Keep: array of IRunnable;
  Workers: array of TWorker;
  Tasks: array of TScheduledTask;
  Pool: TWorkerPool;
  Scheduler: TFiberScheduler;
  Host: TServiceHost;
  Service: THostRun;
  Timer: TPlatformTimer;
  CompletionDeadlineUs: Int64;
  I, J, Disposed: Integer;
  Sample: TSample;
  Payload: TPayload;
  Delivery: TDelivery;
  Recipient: TFiberService;
begin
  if ParamCount < 1 then
    raise Exception.Create('First argument: fibers, workers, pool or host');
  Mode := ParamStr(1);
  if (Mode <> 'fibers') and (Mode <> 'workers') and (Mode <> 'pool') and (Mode <> 'host') then
    raise Exception.Create('Unknown comparison mode');
  Services := Option('--services', 8);
  Cycles := Option('--cycles', 200);
  ValidateAllocationProbe;
  Events := Option('--events', 0);
  Capacity := Option('--event-capacity', 256);
  PayloadBytes := Option('--payload-bytes', 64);
  CallbackUs := Option('--callback-us', 25);
  WorkerCount := Option('--workers', 4);
  WorkUs := Option('--work-us', 0);
  if (Services < 1) or (Services > 128) or (Cycles < 1) or (Cycles > 10000) or
    (Events < 0) or (Events > 1) or (Capacity < 1) or (Capacity > 65536) or
    (PayloadBytes < 1) or (PayloadBytes > 4096) or (CallbackUs < 0) or (CallbackUs > 100000) or
    (WorkerCount < 1) or (WorkerCount > 128) or (WorkUs < 0) or (WorkUs > 100000) then
    raise Exception.Create('Comparison options out of bounds');
  Timer := TPlatformTimer.Create;
  SetLength(Runs, Services);
  SetLength(Keep, Services);
  SetLength(Workers, Services);
  SetLength(Tasks, Services);
  for I := 0 to Services - 1 do
  begin
    Runs[I] := TRun.Create;
    Keep[I] := Runs[I];
    Runs[I].Source := 'service-' + IntToStr(I);
    Payload := TPayload.Create;
    Payload.Text := StringOfChar('x', PayloadBytes);
    Runs[I].Payload := Payload;
    Delivery := TDelivery.Create;
    Delivery.Payload := Runs[I].Payload;
    Runs[I].Delivery := Delivery;
  end;
  Receiver := TReceiver.Create;
  Recipient := nil;
  { Process-wide hook installed before reference worker/dispatcher creation;
    restored only after joins: includes executor startup and shutdown allocation. }
  StartAllocationProbe;
  Pool := nil;
  Scheduler := nil;
  Host := nil;
  if Mode = 'pool' then
    Pool := TWorkerPool.Create(WorkerCount, Services);
  if Mode = 'fibers' then
    Scheduler := TFiberScheduler.Create(Services + 1);
  if Mode = 'host' then
    Host := TServiceHost.Create(nil, Capacity);
  if Events <> 0 then
  begin
    if Mode = 'pool' then
      EventPool := TWorkerPool.Create(1, Capacity)
    else if Mode = 'fibers' then
    begin
      Hub := TFiberEventHub.Create(Scheduler, Capacity, 1);
      Recipient := TFiberService.Create(Scheduler, 1000, DormantTick, nil);
      Hub.Subscribe(Hub.Attach(Recipient), FiberEvent, nil);
      for I := 0 to Services - 1 do
      begin
        Runs[I].Owner := TFiberService.Create(Scheduler, 1000, DormantTick, nil);
        Runs[I].Endpoint := Hub.Attach(Runs[I].Owner);
      end;
    end
    else
    begin
      if Mode = 'host' then
        Bus := Host.Bus
      else
        Bus := TEventBus.Create(Capacity);
      Bus.Subscribe(Receiver.OnEvent, saBackground);
    end;
  end;
  { All modes use a declared 50ms startup window before the common epoch. }
  EpochUs := Timer.NowUs + 50000;
  EndUs := EpochUs + (Int64(Cycles) + 1) * 1000;
  for I := 0 to Services - 1 do
  begin
    if Mode = 'workers' then
    begin
      Workers[I] := TWorker.Create(Keep[I]);
      Workers[I].Start;
    end
    else if Mode = 'pool' then
    begin
      if Pool.Submit(Keep[I]) <> qwOK then
        raise Exception.Create('Reference pool rejected admission');
    end
    else if Mode = 'fibers' then
      Tasks[I] := Scheduler.Spawn(FiberEntry, Runs[I])
    else
    begin
      Service := THostRun.Create('service-' + IntToStr(I), 1);
      Service.Data := Runs[I];
      Host.Register(Service);
    end;
  end;
  if Mode = 'host' then
  begin
    Host.StartAll;
    Timer.WaitUntil(EndUs);
    if not Host.StopAll(5000) then
      raise Exception.Create('Reference host stop timeout');
  end;
  if Mode = 'host' then
    for I := 0 to Services - 1 do
      if Host.FaultCountOf('service-' + IntToStr(I)) <> 0 then
      begin
        {$IFDEF REFERENCE_PROVE_HOST_FAULT}
        WriteLn('ASSERTION FAILED: REFERENCE_HOST_FAULT');
        Halt(1);
        {$ELSE}
        raise Exception.Create('Reference host callback fault');
        {$ENDIF}
      end;
  if Mode = 'workers' then
    for I := 0 to Services - 1 do
    begin
      if not Workers[I].WaitFor(5000) then
        raise Exception.Create('Reference worker timeout');
      if Workers[I].State = wsFaulted then
        raise Exception.Create('Reference worker fault');
    end;
  if Mode = 'pool' then
  begin
    if not Pool.Shutdown(5000) then
      raise Exception.Create('Reference pool shutdown timeout');
    if (Pool.Completed <> Services) or (Pool.Faulted <> 0) or (Pool.Dropped <> 0) then
      raise Exception.Create('Reference pool accounting failed');
  end;
  if Mode = 'fibers' then
  begin
    {$IFDEF REFERENCE_TEST_COMPLETION_GRACE}
    { Model owner preemption after measured work but before producers can
      resume and observe the end of their measurement window. }
    Scheduler.RunUntil(EndUs - 2000);
    Timer.WaitUntil(EndUs + 20000);
    {$ENDIF}
    { EndUs still bounds measured work. Give every producer one shared budget
      to resume and exit; a persistent subscriber must not consume that budget
      after the producers have completed. }
    CompletionDeadlineUs := EndUs + 1000000;
    for I := 0 to Services - 1 do
    begin
      if not Scheduler.RunTaskUntil(Tasks[I], CompletionDeadlineUs) then
        raise Exception.CreateFmt(
          'Fiber comparison completion timeout: task=%d state=%d ErrorClass=%s ErrorMessage=%s',
          [I, Ord(Tasks[I].State), Tasks[I].ErrorClass, Tasks[I].ErrorMessage]);
      if Tasks[I].State <> fsCompleted then
        raise Exception.CreateFmt(
          'Fiber comparison callback failed: task=%d state=%d ErrorClass=%s ErrorMessage=%s',
          [I, Ord(Tasks[I].State), Tasks[I].ErrorClass, Tasks[I].ErrorMessage]);
    end;
    if Events <> 0 then
    begin
      for I := 0 to Services - 1 do
        if not Runs[I].Owner.Stop(1000000) then
          raise Exception.Create('Publisher stop failed');
      if not Recipient.Stop(1000000) then
        raise Exception.Create('Recipient stop failed');
    end;
    if not Scheduler.Stop(1000000) then
      raise Exception.Create('Fiber stop failed');
  end;
  Disposed := 0;
  if Events <> 0 then
  begin
    if Mode = 'pool' then
    begin
      if not EventPool.Shutdown(5000) then
        raise Exception.Create('Event pool drain timeout');
      if (EventPool.Completed <> Accepted) or (EventPool.Faulted <> 0) or
        (EventPool.Dropped <> 0) then
        raise Exception.Create('Event pool accounting failed');
    end
    else if Mode = 'fibers' then
      Disposed := Hub.DiscardedCount
    else
    begin
      if not Bus.WaitDrained(5000) then
        raise Exception.Create('Reference event bus drain timeout');
      Disposed := Bus.Discarded;
    end;
  end;
  { No receiver or payload is released until all executing delivery threads join. }
  Host.Free;
  Host := nil;
  if (Mode = 'workers') and (Bus <> nil) then
    Bus.Free;
  Bus := nil;
  EventPool.Free;
  EventPool := nil;
  Pool.Free;
  Pool := nil;
  for I := 0 to Services - 1 do
  begin
    Workers[I].Free;
    Workers[I] := nil;
  end;
  { WaitDrained and finite Worker.WaitFor exclude native thread tails. The
    destructors above perform actual joins before final counters/MM restore. }
  if Events <> 0 then
    if (Accepted <> Receiver.Delivered + Disposed) or (Receiver.Faults <> 0) then
      raise Exception.Create('Accepted event delivery/disposal mismatch');
  StopAllocationProbe;
  Write('{"format":"reference-bench-v1","mode":"', Mode,
    '","services":', Services, ',"workers":', WorkerCount,
    ',"period_us":1000,"planned_cycles":', Cycles, ',"warmup_us":50000,',
    '"work_us":', WorkUs, ',"allocation_api_calls":', ProbeMeasuredCalls,
    ',"allocation_window":"executor creation through joined shutdown"');
  if Events <> 0 then
    Write(',"events":{"enabled":true,"payload_bytes":', PayloadBytes,
      ',"fanout":1,"capacity":', Capacity, ',"callback_us":', CallbackUs,
      ',"attempted":', Accepted + Rejected, ',"accepted":', Accepted,
      ',"delivered":', Receiver.Delivered, ',"disposed":', Disposed,
      ',"rejected":', Rejected, ',"handler_faults":', Receiver.Faults, '}');
  Write(',"runs":[');
  for I := 0 to Services - 1 do
  begin
    if I > 0 then
      Write(',');
    Write('{"epoch_us":', EpochUs, ',"samples":[');
    for J := 0 to Runs[I].Count - 1 do
    begin
      if J > 0 then
        Write(',');
      Sample := Runs[I].Samples[J];
      Write('{"index":', Sample.Index, ',"deadline_us":', Sample.DueUs,
        ',"start_us":', Sample.StartUs, ',"work_start_us":', Sample.WorkStartUs,
        ',"finish_us":', Sample.FinishUs, '}');
    end;
    Write(']}');
  end;
  WriteLn(']}');
  for I := 0 to Services - 1 do
    Runs[I].Owner.Free;
  Recipient.Free;
  Hub.Free;
  Hub := nil;
  Scheduler.Free;
  Receiver.Free;
  for I := 0 to Services - 1 do
    Keep[I] := nil;
  Timer.Free;
end;
