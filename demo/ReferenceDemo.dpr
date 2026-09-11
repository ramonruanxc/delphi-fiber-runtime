program ReferenceDemo;
{$MODE DELPHI}{$H+}
uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, ConcurrentPool.Types, ConcurrentPool.Worker, ConcurrentPool.Pool,
  ServiceHost.Service, ServiceHost.Host,
  FiberRuntime.Platform, FiberRuntime.Schedule, FiberRuntime.Context, FiberRuntime.Scheduler;
type
  TSample = record Index, DueUs, StartUs, FinishUs: Int64; end;
  TRun = class(TInterfacedObject, IRunnable)
    Samples: array of TSample;
    Count: Integer;
    Timer: TPlatformTimer;
    constructor Create;
    destructor Destroy; override;
    procedure Work(AIndex, ADueUs, AStartUs: Int64);
    procedure Execute(Task: TScheduledTask);
    procedure Run(const Token: ICancellationToken);
  end;
  THostRun = class(TBaseService)
    Data: TRun;
    procedure Tick(const Context: IServiceContext); override;
  end;
var
  Mode: string;
  Services, Cycles, WorkerCount, WorkUs: Integer;
  EpochUs, EndUs: Int64;

function Option(const Name: string; Default: Integer): Integer;
var I: Integer;
begin
  Result := Default;
  for I := 1 to ParamCount do if ParamStr(I) = Name then begin
    if I = ParamCount then raise Exception.Create('Missing option');
    Result := StrToInt(ParamStr(I + 1));
  end;
end;

constructor TRun.Create;
begin inherited Create; SetLength(Samples, Cycles); Timer := TPlatformTimer.Create; end;
destructor TRun.Destroy;
begin Timer.Free; inherited Destroy; end;

procedure TRun.Work(AIndex, ADueUs, AStartUs: Int64);
begin
  if Count >= Length(Samples) then Exit;
  Samples[Count].Index := AIndex; Samples[Count].DueUs := ADueUs;
  Samples[Count].StartUs := AStartUs;
  if WorkUs > 0 then while Timer.NowUs - AStartUs < WorkUs do;
  Samples[Count].FinishUs := Timer.NowUs;
  Inc(Count);
end;

procedure TRun.Execute(Task: TScheduledTask);
var Schedule: TPeriodicSchedule; Tick: TPeriodicTick; Current: Int64;
begin
  Schedule := TPeriodicSchedule.Create(EpochUs, 1000);
  try
    while Schedule.NextDeadlineUs < EndUs do begin
      if Task <> nil then Task.AwaitUntil(Schedule.NextDeadlineUs)
      else Timer.WaitUntil(Schedule.NextDeadlineUs);
      Current := Timer.NowUs;
      if Current >= EndUs then Break;
      if Schedule.TryAcquire(Current, Tick) then begin
        Work(Tick.Index, Tick.DeadlineUs, Tick.StartedUs);
        Schedule.Complete(Timer.NowUs);
      end;
    end;
  finally Schedule.Free; end;
end;

procedure TRun.Run(const Token: ICancellationToken);
begin Execute(nil); end;
procedure FiberEntry(Task: TScheduledTask; Data: Pointer);
begin TRun(Data).Execute(Task); end;
procedure THostRun.Tick(const Context: IServiceContext);
var Current: Int64;
begin
  Current := Data.Timer.NowUs;
  {$IFDEF REFERENCE_PROVE_HOST_FAULT}
  raise Exception.Create('Injected reference host callback failure');
  {$ENDIF}
  if (Current >= EpochUs + 1000) and (Current < EndUs) then
    Data.Work(Data.Count + 1, 0, Current);
end;

procedure Benchmark;
var Runs: array of TRun; Keep: array of IRunnable; Workers: array of TWorker;
    Tasks: array of TScheduledTask; Pool: TWorkerPool; Scheduler: TFiberScheduler;
    Host: TServiceHost; Service: THostRun; Timer: TPlatformTimer;
    I, J: Integer; Sample: TSample;
begin
  if ParamCount < 1 then raise Exception.Create('First argument: fibers, workers, pool or host');
  Mode := ParamStr(1);
  if (Mode <> 'fibers') and (Mode <> 'workers') and (Mode <> 'pool') and (Mode <> 'host') then
    raise Exception.Create('Unknown comparison mode');
  Services := Option('--services', 8); Cycles := Option('--cycles', 200);
  WorkerCount := Option('--workers', 4); WorkUs := Option('--work-us', 0);
  if (Services < 1) or (Services > 128) or (Cycles < 1) or (Cycles > 10000) or
     (WorkerCount < 1) or (WorkerCount > 128) or (WorkUs < 0) or (WorkUs > 100000) then
    raise Exception.Create('Comparison options out of bounds');
  Timer := TPlatformTimer.Create;
  SetLength(Runs, Services); SetLength(Keep, Services); SetLength(Workers, Services);
  SetLength(Tasks, Services);
  for I := 0 to Services - 1 do begin Runs[I] := TRun.Create; Keep[I] := Runs[I]; end;
  Pool := nil; Scheduler := nil; Host := nil;
  if Mode = 'pool' then Pool := TWorkerPool.Create(WorkerCount, Services);
  if Mode = 'fibers' then Scheduler := TFiberScheduler.Create(Services);
  if Mode = 'host' then Host := TServiceHost.Create(nil, Services * 2);
  { All modes use a declared 50ms startup window before the common epoch. }
  EpochUs := Timer.NowUs + 50000; EndUs := EpochUs + (Int64(Cycles) + 1) * 1000;
  for I := 0 to Services - 1 do begin
    if Mode = 'workers' then begin Workers[I] := TWorker.Create(Keep[I]); Workers[I].Start; end
    else if Mode = 'pool' then begin
      if Pool.Submit(Keep[I]) <> qwOK then raise Exception.Create('Reference pool rejected admission');
    end else if Mode = 'fibers' then Tasks[I] := Scheduler.Spawn(FiberEntry, Runs[I])
    else begin
      Service := THostRun.Create('service-' + IntToStr(I), 1); Service.Data := Runs[I];
      Host.Register(Service);
    end;
  end;
  if Mode = 'host' then begin Host.StartAll; Timer.WaitUntil(EndUs);
    if not Host.StopAll(5000) then raise Exception.Create('Reference host stop timeout'); end;
  if Mode = 'host' then for I := 0 to Services - 1 do
    if Host.FaultCountOf('service-' + IntToStr(I)) <> 0 then begin
      {$IFDEF REFERENCE_PROVE_HOST_FAULT}
      WriteLn('ASSERTION FAILED: REFERENCE_HOST_FAULT'); Halt(1);
      {$ELSE}
      raise Exception.Create('Reference host callback fault');
      {$ENDIF}
    end;
  if Mode = 'workers' then for I := 0 to Services - 1 do begin
    if not Workers[I].WaitFor(5000) then raise Exception.Create('Reference worker timeout');
    if Workers[I].State = wsFaulted then raise Exception.Create('Reference worker fault');
  end;
  if Mode = 'pool' then begin
    if not Pool.Shutdown(5000) then raise Exception.Create('Reference pool shutdown timeout');
    if (Pool.Completed <> Services) or (Pool.Faulted <> 0) or (Pool.Dropped <> 0) then
      raise Exception.Create('Reference pool accounting failed');
  end;
  if Mode = 'fibers' then begin
    if not Scheduler.RunUntil(EndUs + 1000000) then raise Exception.Create('Fiber comparison timeout');
    for I := 0 to Services - 1 do if Tasks[I].State <> fsCompleted then
      raise Exception.Create('Fiber comparison callback failed');
    if not Scheduler.Stop(1000000) then raise Exception.Create('Fiber stop failed');
  end;
  Write('{"format":"reference-bench-v1","mode":"', Mode,
    '","services":', Services, ',"workers":', WorkerCount,
    ',"period_us":1000,"planned_cycles":', Cycles, ',"warmup_us":50000,',
    '"work_us":', WorkUs, ',"runs":[');
  for I := 0 to Services - 1 do begin
    if I > 0 then Write(',');
    Write('{"epoch_us":', EpochUs, ',"samples":[');
    for J := 0 to Runs[I].Count - 1 do begin
      if J > 0 then Write(','); Sample := Runs[I].Samples[J];
      Write('{"index":', Sample.Index, ',"deadline_us":', Sample.DueUs,
        ',"start_us":', Sample.StartUs, ',"finish_us":', Sample.FinishUs, '}');
    end;
    Write(']}');
  end;
  WriteLn(']}');
  Host.Free; Pool.Free; Scheduler.Free;
  for I := 0 to Services - 1 do begin Workers[I].Free; Keep[I] := nil; end;
  Timer.Free;
end;
begin
  try Benchmark; except on E: Exception do begin WriteLn(StdErr, E.ClassName, ': ', E.Message); Halt(1); end; end;
end.
