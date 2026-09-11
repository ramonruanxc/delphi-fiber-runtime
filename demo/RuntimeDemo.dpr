program RuntimeDemo;
{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}
{$APPTYPE CONSOLE}
uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, FiberRuntime.Context, FiberRuntime.Schedule, FiberRuntime.Platform,
  FiberRuntime.Scheduler, FiberRuntime.Channel, FiberRuntime.Service;
type
  TSample = record Index, DeadlineUs, StartUs, FinishUs: Int64; end;
  TRun = class
    Service: TFiberService;
    Samples: array of TSample;
    Count: Integer;
  end;
var
  Scheduler: TFiberScheduler;
  Channel: TFiberChannel;
  Runs: array of TRun;
  Services, Cycles, WorkUs, AwaitUs: Integer;
  Sent, Received, Rejected: Int64;

{$I AllocationProbe.inc}

function Option(const Name: string; Default: Integer): Integer;
var I: Integer;
begin
  Result := Default;
  for I := 1 to ParamCount do if ParamStr(I) = Name then begin
    if I = ParamCount then raise Exception.Create('Missing option value');
    Result := StrToInt(ParamStr(I + 1));
  end;
end;

procedure Tick(Task: TScheduledTask; const Value: TPeriodicTick; Data: Pointer);
var R: TRun; Started: Int64; Slot: Integer;
begin
  R := TRun(Data);
  if Value.Index > Cycles then begin Task.Cancel; Task.CheckCancelled; end;
  Slot := R.Count;
  R.Samples[Slot].Index := Value.Index;
  R.Samples[Slot].DeadlineUs := Value.DeadlineUs;
  R.Samples[Slot].StartUs := Value.StartedUs;
  Inc(R.Count);
  if Channel.TrySend(Data) then Inc(Sent) else Inc(Rejected);
  Started := Scheduler.NowUs;
  try
    if WorkUs > 0 then while Scheduler.NowUs - Started < WorkUs do;
    if AwaitUs > 0 then Task.Delay(AwaitUs);
  finally
    R.Samples[Slot].FinishUs := Scheduler.NowUs;
  end;
end;

procedure ReceiveEvents(Task: TScheduledTask; Data: Pointer);
var Value: Pointer;
begin
  while Channel.Receive(Value) do begin
    if Value = nil then raise Exception.Create('Invalid event identity');
    Inc(Received);
  end;
end;

procedure Run;
var I, J: Integer; EndUs, Candidate: Int64; Receiver: TScheduledTask;
    Timer: TPlatformTimer; S: TSample;
begin
  ValidateAllocationProbe;
  Services := Option('--services', 8); Cycles := Option('--cycles', 200);
  WorkUs := Option('--work-us', 0); AwaitUs := Option('--await-us', 0);
  if (Services < 1) or (Services > 128) or (Cycles < 1) or (Cycles > 10000) or
     (WorkUs < 0) or (WorkUs > 100000) or (AwaitUs < 0) or (AwaitUs > 100000) then
    raise Exception.Create('Options outside demo bounds');
  Scheduler := TFiberScheduler.Create(Services + 1);
  Channel := TFiberChannel.Create(Scheduler, Services * 2);
  SetLength(Runs, Services);
  for I := 0 to Services - 1 do begin
    Runs[I] := TRun.Create;
    SetLength(Runs[I].Samples, Cycles);
    Runs[I].Service := TFiberService.Create(Scheduler, 1000, Tick, Runs[I]);
  end;
  { Separate native warmup before service epochs and measurement. }
  Timer := TPlatformTimer.Create;
  Timer.WaitUntil(Timer.NowUs + 10000); Timer.Free;
  Receiver := Scheduler.Spawn(ReceiveEvents, nil);
  EndUs := High(Int64);
  for I := 0 to Services - 1 do begin
    Runs[I].Service.Start;
    Candidate := Runs[I].Service.EpochUs + (Int64(Cycles) + 1) * 1000;
    if Candidate < EndUs then EndUs := Candidate;
  end;
  StartAllocationProbe;
  try Scheduler.RunUntil(EndUs); finally StopAllocationProbe; end;
  for I := 0 to Services - 1 do Runs[I].Service.Cancel;
  for I := 0 to Services - 1 do begin
    if not Runs[I].Service.Stop(1000000) then raise Exception.Create('Service stop timeout');
    if Runs[I].Service.Task.State = fsFaulted then
      raise Exception.Create(Runs[I].Service.Task.ErrorMessage);
  end;
  Channel.Close;
  if not Scheduler.RunTaskUntil(Receiver, Scheduler.NowUs + 1000000) then
    raise Exception.Create('Receiver stop timeout');
  if Receiver.State = fsFaulted then raise Exception.Create(Receiver.ErrorMessage);
  if not Scheduler.Stop(1000000) then raise Exception.Create('Scheduler stop timeout');
  if Sent <> Received then raise Exception.Create('Lost accepted event');
  Write('{"format":"runtime-demo-v1","period_us":1000,"planned_cycles":', Cycles,
    ',"services":', Services, ',"sent":', Sent, ',"received":', Received,
    ',"rejected":', Rejected, ',"stopped":true,"carrier_threads":1,"warmup_us":10000,',
    '"work_us":', WorkUs, ',"await_us":', AwaitUs,
    ',"allocation_api_calls":', ProbeMeasuredCalls,
    ',"pascal_heap_used_before":', ProbeBefore.CurrHeapUsed,
    ',"pascal_heap_used_after":', ProbeAfter.CurrHeapUsed,
    ',"pascal_heap_peak_used":', ProbeAfter.MaxHeapUsed, ',"runs":[');
  for I := 0 to Services - 1 do begin
    if I > 0 then Write(',');
    Write('{"epoch_us":', Runs[I].Service.EpochUs, ',"samples":[');
    for J := 0 to Runs[I].Count - 1 do begin
      if J > 0 then Write(','); S := Runs[I].Samples[J];
      Write('{"index":', S.Index, ',"deadline_us":', S.DeadlineUs,
        ',"start_us":', S.StartUs, ',"finish_us":', S.FinishUs, '}');
    end;
    Write(']}');
  end;
  WriteLn(']}');
  for I := 0 to Services - 1 do begin Runs[I].Service.Free; Runs[I].Free; end;
  Channel.Free; Scheduler.Free;
end;
begin
  try Run; except on E: Exception do begin WriteLn(StdErr, E.ClassName, ': ', E.Message); Halt(1); end; end;
end.
