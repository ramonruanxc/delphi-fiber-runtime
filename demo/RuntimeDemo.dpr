program RuntimeDemo;

{$IFDEF FPC}
{$MODE DELPHI}
{$H+}
{$ENDIF}
{$APPTYPE CONSOLE}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  SysUtils,
  FiberRuntime.Context in '../src/FiberRuntime.Context.pas',
  FiberRuntime.Schedule in '../src/FiberRuntime.Schedule.pas',
  FiberRuntime.Platform in '../src/FiberRuntime.Platform.pas',
  FiberRuntime.Scheduler in '../src/FiberRuntime.Scheduler.pas',
  FiberRuntime.ServiceHooks in '../src/FiberRuntime.ServiceHooks.pas',
  FiberRuntime.Service in '../src/FiberRuntime.Service.pas',
  FiberRuntime.EventHub in '../src/FiberRuntime.EventHub.pas';

type
  TSample = record
    Index, DeadlineUs, StartUs, FinishUs, EpochUs, Generation, FinishGeneration, Segment: Int64;
    Trace: TSchedulerTaskTrace;
  end;

  IBenchmarkPayload = interface
    ['{E506AC05-FF2A-4E13-BC5F-65F396387640}']
    function Size: Integer;
  end;

  TPayload = class(TInterfacedObject, IBenchmarkPayload)
    Text: string;
    function Size: Integer;
  end;

  TRun = class
    Service: TFiberService;
    Endpoint: TServiceEndpoint;
    Payload: IBenchmarkPayload;
    Samples: array of TSample;
    Count: Integer;
  end;

var
  Scheduler: TFiberScheduler;
  Hub: TFiberEventHub;
  Runs: array of TRun;
  Services, Cycles, WorkUs, AwaitUs, Capacity, PayloadBytes, CallbackUs: Integer;
  Sent, Received, Rejected, Disposed, HandlerFaults: Int64;

  {$I AllocationProbe.inc}

function TPayload.Size: Integer;
begin
  Result := Length(Text);
end;

function Option(const Name: string; Default: Integer): Integer;
var
  I: Integer;
begin
  Result := Default;
  for I := 1 to ParamCount do
    if ParamStr(I) = Name then
    begin
      if I = ParamCount then
        raise Exception.Create('Missing option value');
      Result := StrToInt(ParamStr(I + 1));
    end;
end;

procedure Tick(Task: TScheduledTask; const Value: TPeriodicTick; Data: Pointer);
var
  R: TRun;
  Started: Int64;
  Slot: Integer;
begin
  R := TRun(Data);
  if (Value.Index > Cycles) or (R.Count >= Cycles) then
  begin
    Task.Cancel;
    Task.CheckCancelled;
  end;
  Slot := R.Count;
  R.Samples[Slot].Index := Value.Index;
  R.Samples[Slot].Segment := Value.Segment;
  R.Samples[Slot].DeadlineUs := Value.DeadlineUs;
  R.Samples[Slot].StartUs := Value.StartedUs;
  R.Samples[Slot].Trace := Task.Trace;
  R.Samples[Slot].EpochUs := R.Service.EpochUs;
  R.Samples[Slot].Generation := Scheduler.ResumeGeneration;
  Inc(R.Count);
  if R.Endpoint.Publish(R.Payload) then
    Inc(Sent)
  else
    Inc(Rejected);
  Started := Scheduler.NowUs;
  try
    if WorkUs > 0 then
      while Scheduler.NowUs - Started < WorkUs do ;
    if AwaitUs > 0 then
      Task.Delay(AwaitUs);
  finally
    R.Samples[Slot].FinishUs := Scheduler.NowUs;
    R.Samples[Slot].FinishGeneration := Scheduler.ResumeGeneration;
  end;
end;

procedure ReceiveEvent(Task: TScheduledTask; Source: TServiceEndpoint;
  const Payload: IInterface; Data: Pointer);
var
  Started: Int64;
begin
  Started := Scheduler.NowUs;
  if (Payload = nil) or ((Payload as IBenchmarkPayload).Size <> PayloadBytes) then
  begin
    Inc(HandlerFaults);
    Exit;
  end;
  if CallbackUs > 0 then
    while Scheduler.NowUs - Started < CallbackUs do ;
  Inc(Received);
end;

procedure DormantTick(Task: TScheduledTask; const Tick: TPeriodicTick; Data: Pointer);
begin
end;

procedure Nullable(Value: Int64; Present: Boolean);
begin
  if Present then
    Write(Value)
  else
    Write('null');
end;

procedure WriteTrace(const S: TSample);
const
  Reasons: array[TReadyReason] of string = ('spawn', 'yield', 'wake', 'timer', 'cancel', 'resume');
begin
  Write(',"segment":', S.Segment, ',"epoch_us":', S.EpochUs, ',"generation":', S.Generation,
    ',"finish_generation":', S.FinishGeneration, ',"wait_deadline_us":');
  Nullable(S.Trace.WaitDeadlineUs, S.Trace.HasWaitDeadline);
  Write(',"timer_observed_us":');
  Nullable(S.Trace.TimerObservedUs, S.Trace.HasTimerObservation);
  Write(',"ready_enqueued_us":');
  Nullable(S.Trace.ReadyEnqueuedUs, S.Trace.HasReadyEnqueue);
  Write(',"resumed_us":');
  Nullable(S.Trace.ResumedUs, S.Trace.HasResume);
  Write(',"resume_generation":');
  Nullable(S.Trace.ResumeGeneration, S.Trace.HasResume);
  Write(',"ready_reason":"');
  if S.Trace.HasReadyEnqueue then
    Write(Reasons[S.Trace.ReadyReason])
  else
    Write('inline');
  Write('","ready_generation":');
  if S.Trace.HasReadyEnqueue then
    Write(S.Trace.ReadyGeneration)
  else
    Write(S.Generation);
end;

procedure WriteSegment(const S: TPeriodicSegment);
begin
  if S.Generation < 0 then
  begin
    Write('null');
    Exit;
  end;
  Write('{"generation":', S.Generation, ',"epoch_us":', S.EpochUs,
    ',"ended_us":', S.EndedUs, ',"started":', S.StartedCount,
    ',"skipped":', S.SkippedCount, '}');
end;

procedure Run;
var
  I, J: Integer;
  EndUs, Candidate: Int64;
  Receiver: TFiberService;
  Payload: TPayload;
  Timer: TPlatformTimer;
  S: TSample;
begin
  ValidateAllocationProbe;
  Services := Option('--services', 8);
  Cycles := Option('--cycles', 200);
  Capacity := Option('--event-capacity', 256);
  PayloadBytes := Option('--payload-bytes', 64);
  CallbackUs := Option('--callback-us', 25);
  WorkUs := Option('--work-us', 0);
  AwaitUs := Option('--await-us', 0);
  if (Services < 1) or (Services > 128) or (Cycles < 1) or (Cycles > 10000) or
    (Capacity < 1) or (Capacity > 65536) or (PayloadBytes < 1) or (PayloadBytes > 4096) or
    (CallbackUs < 0) or (CallbackUs > 100000) or (WorkUs < 0) or (WorkUs > 100000) or
    (AwaitUs < 0) or (AwaitUs > 100000) then
    raise Exception.Create('Options outside demo bounds');
  Scheduler := TFiberScheduler.Create(Services + 1);
  Hub := TFiberEventHub.Create(Scheduler, Capacity, 1);
  Receiver := TFiberService.Create(Scheduler, 1000, DormantTick, nil);
  Hub.Subscribe(Hub.Attach(Receiver), ReceiveEvent, nil);
  SetLength(Runs, Services);
  for I := 0 to Services - 1 do
  begin
    Runs[I] := TRun.Create;
    SetLength(Runs[I].Samples, Cycles);
    Payload := TPayload.Create;
    Payload.Text := StringOfChar('x', PayloadBytes);
    Runs[I].Payload := Payload;
    Runs[I].Service := TFiberService.Create(Scheduler, 1000, Tick, Runs[I]);
    Runs[I].Endpoint := Hub.Attach(Runs[I].Service);
  end;
  { Separate native warmup before service epochs and measurement. }
  Timer := TPlatformTimer.Create;
  Timer.WaitUntil(Timer.NowUs + 10000);
  Timer.Free;
  EndUs := High(Int64);
  for I := 0 to Services - 1 do
  begin
    Runs[I].Service.Start;
    Candidate := Runs[I].Service.EpochUs + (Int64(Cycles) + 1) * 1000;
    if Candidate < EndUs then
      EndUs := Candidate;
  end;
  StartAllocationProbe;
  try
    Scheduler.RunUntil(EndUs);
  finally
    StopAllocationProbe;
  end;
  for I := 0 to Services - 1 do
    Runs[I].Service.Cancel;
  for I := 0 to Services - 1 do
  begin
    if not Runs[I].Service.Stop(1000000) then
      raise Exception.Create('Service stop timeout');
    if Runs[I].Service.Task.State = fsFaulted then
      raise Exception.Create(Runs[I].Service.Task.ErrorMessage);
  end;
  if not Receiver.Stop(1000000) then
    raise Exception.Create('Receiver stop timeout');
  if not Scheduler.Stop(1000000) then
    raise Exception.Create('Scheduler stop timeout');
  Disposed := Hub.DiscardedCount;
  if (Sent <> Received + Disposed) or (HandlerFaults <> 0) then
    raise Exception.Create('Lost accepted event or handler fault');
  Write('{"format":"runtime-demo-v2","period_us":1000,"planned_cycles":', Cycles,
    ',"services":', Services, ',"sent":', Sent, ',"received":', Received,
    ',"rejected":', Rejected, ',"disposed":', Disposed,
    ',"stopped":true,"carrier_threads":1,"warmup_us":10000,',
    '"work_us":', WorkUs, ',"await_us":', AwaitUs,
    ',"allocation_api_calls":', ProbeMeasuredCalls,
    ',"pascal_heap_used_before":', ProbeBefore.CurrHeapUsed,
    ',"pascal_heap_used_after":', ProbeAfter.CurrHeapUsed,
    {$IFDEF FPC}
    ',"pascal_heap_peak_used":', ProbeAfter.MaxHeapUsed,
    {$ELSE}
    ',"pascal_heap_peak_used":null',
    {$ENDIF}
    ',"events":{"enabled":true,"payload_bytes":', PayloadBytes,
    ',"fanout":1,"capacity":', Capacity, ',"callback_us":', CallbackUs,
    ',"attempted":', Sent + Rejected, ',"accepted":', Sent, ',"delivered":', Received,
    ',"disposed":', Disposed, ',"rejected":', Rejected, ',"handler_faults":', HandlerFaults,
    '},"runs":[');
  for I := 0 to Services - 1 do
  begin
    if I > 0 then
      Write(',');
    if Runs[I].Count > 0 then
      Candidate := Runs[I].Samples[0].EpochUs
    else
      Candidate := Runs[I].Service.EpochUs;
    Write('{"epoch_us":', Candidate, ',"segments":{"discontinuity_count":',
      Runs[I].Service.DiscontinuityCount, ',"crossing_count":', Runs[I].Service.CrossingCount,
      ',"last":');
    WriteSegment(Runs[I].Service.LastSegment);
    Write(',"current":');
    WriteSegment(Runs[I].Service.CurrentSegment);
    Write('},"samples":[');
    for J := 0 to Runs[I].Count - 1 do
    begin
      if J > 0 then
        Write(',');
      S := Runs[I].Samples[J];
      Write('{"index":', S.Index, ',"deadline_us":', S.DeadlineUs,
        ',"start_us":', S.StartUs, ',"finish_us":', S.FinishUs);
      WriteTrace(S);
      Write('}');
    end;
    Write(']}');
  end;
  WriteLn(']}');
  for I := 0 to Services - 1 do
  begin
    Runs[I].Service.Free;
    Runs[I].Free;
  end;
  Receiver.Free;
  Hub.Free;
  Scheduler.Free;
end;

begin
  try
    Run;
  except
    on E: Exception do
    begin
      WriteLn(StdErr, E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
