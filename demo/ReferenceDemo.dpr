program ReferenceDemo;

{$MODE DELPHI}
{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  SysUtils,
  ConcurrentPool.Types,
  ConcurrentPool.Worker,
  ConcurrentPool.Pool,
  ServiceHost.Service,
  ServiceHost.Host,
  ServiceHost.Bus,
  ServiceHost.Events,
  FiberRuntime.Platform,
  FiberRuntime.Schedule,
  FiberRuntime.Context,
  FiberRuntime.Scheduler,
  FiberRuntime.Service,
  FiberRuntime.EventHub;

type
  TSample = record
    Index, DueUs, StartUs, WorkStartUs, FinishUs: Int64;
  end;

  TPayload = class(TInterfacedObject, IEventPayload)
    Text: string;
    function Describe: string;
  end;

  TReceiver = class
    Timer: TPlatformTimer;
    Delivered, Faults: LongInt;
    constructor Create;
    destructor Destroy; override;
    procedure Consume(const Payload: IEventPayload);
    procedure OnEvent(const Event: TServiceEvent);
  end;

  TDelivery = class(TInterfacedObject, IRunnable)
    Payload: IEventPayload;
    procedure Run(const Token: ICancellationToken);
  end;

  TRun = class(TInterfacedObject, IRunnable)
    Samples: array of TSample;
    Count: Integer;
    Timer: TPlatformTimer;
    Source: string;
    Payload: IEventPayload;
    Delivery: IRunnable;
    Owner: TFiberService;
    Endpoint: TServiceEndpoint;
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
  Services, Cycles, WorkerCount, WorkUs, Events, Capacity, PayloadBytes, CallbackUs: Integer;
  Accepted, Rejected: LongInt;
  Receiver: TReceiver;
  Bus: TEventBus;
  EventPool: TWorkerPool;
  Hub: TFiberEventHub;
  EpochUs, EndUs: Int64;

  {$I AllocationProbe.inc}

function Option(const Name: string; Default: Integer): Integer;
var
  I: Integer;
begin
  Result := Default;
  for I := 1 to ParamCount do
    if ParamStr(I) = Name then
    begin
      if I = ParamCount then
        raise Exception.Create('Missing option');
      Result := StrToInt(ParamStr(I + 1));
    end;
end;

function TPayload.Describe: string;
begin
  Result := Text;
end;

constructor TReceiver.Create;
begin
  inherited Create;
  Timer := TPlatformTimer.Create;
end;

destructor TReceiver.Destroy;
begin
  Timer.Free;
  inherited Destroy;
end;

procedure TReceiver.Consume(const Payload: IEventPayload);
var
  Started: Int64;
begin
  Started := Timer.NowUs;
  if (Payload = nil) or (Length(Payload.Describe) <> PayloadBytes) then
  begin
    InterlockedIncrement(Faults);
    Exit;
  end;
  if CallbackUs > 0 then
    while Timer.NowUs - Started < CallbackUs do ;
  InterlockedIncrement(Delivered);
end;

procedure TReceiver.OnEvent(const Event: TServiceEvent);
begin
  Consume(Event.Payload);
end;

procedure TDelivery.Run(const Token: ICancellationToken);
begin
  Receiver.Consume(Payload);
end;

procedure FiberEvent(Task: TScheduledTask; Source: TServiceEndpoint;
  const Payload: IInterface; Data: Pointer);
begin
  Receiver.Consume(Payload as IEventPayload);
end;

procedure DormantTick(Task: TScheduledTask; const Tick: TPeriodicTick; Data: Pointer);
begin
end;

constructor TRun.Create;
begin
  inherited Create;
  SetLength(Samples, Cycles);
  Timer := TPlatformTimer.Create;
end;

destructor TRun.Destroy;
begin
  Timer.Free;
  inherited Destroy;
end;

procedure TRun.Work(AIndex, ADueUs, AStartUs: Int64);
begin
  if Count >= Length(Samples) then
    Exit;
  Samples[Count].Index := AIndex;
  Samples[Count].DueUs := ADueUs;
  Samples[Count].StartUs := AStartUs;
  if Events <> 0 then
  begin
    if Mode = 'fibers' then
    begin
      if Endpoint.Publish(Payload) then
        InterlockedIncrement(Accepted)
      else
        InterlockedIncrement(Rejected);
    end
    else if Mode = 'pool' then
    begin
      if EventPool.Submit(Delivery) = qwOK then
        InterlockedIncrement(Accepted)
      else
        InterlockedIncrement(Rejected);
    end
    else
    begin
      if Bus.Publish(Source, 'sample', elInfo, '', Count, Payload) then
        InterlockedIncrement(Accepted)
      else
        InterlockedIncrement(Rejected);
    end;
  end;
  Samples[Count].WorkStartUs := Timer.NowUs;
  if WorkUs > 0 then
    while Timer.NowUs - Samples[Count].WorkStartUs < WorkUs do ;
  Samples[Count].FinishUs := Timer.NowUs;
  Inc(Count);
end;

procedure TRun.Execute(Task: TScheduledTask);
var
  Schedule: TPeriodicSchedule;
  Tick: TPeriodicTick;
  Current: Int64;
begin
  Schedule := TPeriodicSchedule.Create(EpochUs, 1000);
  try
    while Schedule.NextDeadlineUs < EndUs do
    begin
      if Task <> nil then
        Task.AwaitUntil(Schedule.NextDeadlineUs)
      else
        Timer.WaitUntil(Schedule.NextDeadlineUs);
      Current := Timer.NowUs;
      if Current >= EndUs then
        Break;
      if Schedule.TryAcquire(Current, Tick) then
      begin
        Work(Tick.Index, Tick.DeadlineUs, Tick.StartedUs);
        Schedule.Complete(Timer.NowUs);
      end;
    end;
  finally
    Schedule.Free;
  end;
end;

procedure TRun.Run(const Token: ICancellationToken);
begin
  Execute(nil);
end;

procedure FiberEntry(Task: TScheduledTask; Data: Pointer);
begin
  TRun(Data).Execute(Task);
end;

procedure THostRun.Tick(const Context: IServiceContext);
var
  Current: Int64;
begin
  Current := Data.Timer.NowUs;
  {$IFDEF REFERENCE_PROVE_HOST_FAULT}
  raise Exception.Create('Injected reference host callback failure');
  {$ENDIF}
  if (Current >= EpochUs + 1000) and (Current < EndUs) then
    Data.Work(Data.Count + 1, 0, Current);
end;

{$I ReferenceBenchmark.inc}

begin
  try
    Benchmark;
  except
    on E: Exception do
    begin
      WriteLn(StdErr, E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
