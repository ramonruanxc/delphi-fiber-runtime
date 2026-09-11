procedure TestUsage;
var
  T, F: TScheduledTask;
  R: Boolean;
  Probe: TOwnerProbe;
begin
  D := TVirtualDriver.Create;
  S := TFiberScheduler.Create(3, D);
  Parked := S.Spawn(Empty, nil);
  Probe := TOwnerProbe.Create(True);
  Probe.Task := Parked;
  Probe.Start;
  Probe.WaitFor;
  Check(Probe.Rejected = 33, 'SCHEDULER_FOREIGN_OWNER');
  Probe.Free;
  R := False;
  try
    Parked.Free;
  except
    on EFiberUsage do
      R := True;
  end;
  Check(R and (Parked.State = fsCreated), 'SCHEDULER_FREE_CREATED');
  R := False;
  try
    Parked.Yield;
  except
    on EFiberUsage do
      R := True;
  end;
  Check(R, 'SCHEDULER_CARRIER_YIELD');
  T := S.Spawn(UsageTask, @Calls);
  F := S.Spawn(FaultTask, nil);
  Check(S.Post(Reenter, nil), 'SCHEDULER_REENTRY_POST');
  Check(S.RunUntil(100), 'SCHEDULER_USAGE_SETTLES');
  Check((T.State = fsCompleted) and (Reentries = 8), 'SCHEDULER_REENTRY_GUARD');
  Check((F.State = fsFaulted) and (F.ErrorClass = 'EConvertError') and
    (F.ErrorMessage = 'task fault'), 'SCHEDULER_FAULT_CONTAINMENT');
  R := False;
  try
    T.Free;
  except
    on EFiberUsage do
      R := True;
  end;
  Check(R and (T.State = fsCompleted), 'SCHEDULER_FREE_TERMINAL');
  R := False;
  try
    S.Spawn(Empty, nil);
  except
    on EFiberUsage do
      R := True;
  end;
  Check(R, 'SCHEDULER_LIFETIME_CAPACITY');
  S.Free;
  D.Free;
end;

procedure TestTimersFairness;
begin
  D := TVirtualDriver.Create;
  S := TFiberScheduler.Create(4, D);
  Parked := S.Spawn(TimerTask, nil);
  S.Spawn(EarlyWake, nil);
  S.Spawn(Fair, Pointer(Ord('A')));
  S.Spawn(Fair, Pointer(Ord('B')));
  Check(S.RunUntil(2000), 'SCHEDULER_FAIR_SETTLES');
  Check(Log = 'ABABAB', 'SCHEDULER_FIFO_FAIRNESS');
  Check(D.Waits = 1, 'SCHEDULER_NO_READY_WAIT');
  S.Free;
  D.Free;
end;

procedure TestStop;
var
  R: Boolean;
  T: TScheduledTask;
begin
  Cleanups := 0;
  Calls := 0;
  D := TVirtualDriver.Create;
  S := TFiberScheduler.Create(3, D);
  Parked := S.Spawn(Parking, nil);
  Check(not S.RunUntil(100), 'SCHEDULER_PARK_TIMEOUT');
  Check((Parked.State = fsSuspended) and (Cleanups = 0), 'SCHEDULER_RETAIN_STACK');
  R := False;
  try
    S.Free;
  except
    on EFiberUsage do
      R := True;
  end;
  Check(R and (Parked.State = fsSuspended), 'SCHEDULER_DESTROY_RETENTION');
  T := S.Spawn(Empty, @Calls);
  T.Cancel;
  T.Cancel;
  Check((T.State = fsCancelled) and (Calls = 0), 'SCHEDULER_CANCEL_CREATED');
  Check(S.Post(Counter, @Calls), 'SCHEDULER_ACCEPT_BEFORE_STOP');
  Check(not S.Stop(0), 'SCHEDULER_STOP_TIMEOUT');
  Check((Cleanups = 0) and (Parked.State = fsSuspended), 'SCHEDULER_STOP_RETAINS_STACK');
  Check(not S.Post(Counter, @Calls), 'SCHEDULER_REJECT_STOPPED_POST');
  R := False;
  try
    S.Spawn(Empty, nil);
  except
    on EFiberUsage do
      R := True;
  end;
  Check(R, 'SCHEDULER_REJECT_STOPPED_SPAWN');
  Check(S.Stop(100), 'SCHEDULER_STOP_CLEANUP');
  Check((Cleanups = 1) and (Calls = 1) and (Parked.State = fsCancelled),
    'SCHEDULER_CANCEL_FINALLY');
  Check(S.Stop(0), 'SCHEDULER_STOP_IDEMPOTENT');
  S.Free;
  D.Free;
end;

procedure TestPost;
begin
  Calls := 0;
  D := TVirtualDriver.Create;
  S := TFiberScheduler.Create(3, D);
  Check(S.Post(Counter, @Calls), 'SCHEDULER_POST_ACCEPT');
  Check(S.Post(PostedFault, nil), 'SCHEDULER_POST_FAULT_ACCEPT');
  Check(S.Post(ObjectPostFault, nil), 'SCHEDULER_POST_OBJECT_ACCEPT');
  Check(not S.Post(Counter, @Calls), 'SCHEDULER_POST_FULL');
  Check(not S.Post(nil, nil), 'SCHEDULER_POST_NIL');
  Check(S.RunUntil(100), 'SCHEDULER_POST_SETTLES');
  Check((Calls = 1) and (S.PostFaultCount = 2), 'SCHEDULER_POST_CONTAINMENT');
  S.Free;
  D.Free;
end;

procedure TProducer.Execute;
var
  I: Integer;
begin
  for I := 1 to 20000 do
    if Scheduler.Post(Counter, @Posted) then
      Inc(Accepted);
  Scheduler.RequestStop;
end;

procedure TestNativePostRace;
var
  Producer: TProducer;
  I: Integer;
begin
  for I := 1 to 20 do
  begin
    Posted := 0;
    S := TFiberScheduler.Create(8);
    Parked := S.Spawn(Parking, nil);
    Producer := TProducer.Create(True);
    Producer.Scheduler := S;
    Producer.Start;
    Check(S.RunUntil(S.NowUs + 5000000), 'SCHEDULER_NATIVE_POST_WAKE');
    Producer.WaitFor;
    Check(S.Stop(1000000), 'SCHEDULER_NATIVE_STOP');
    Check(Posted = Producer.Accepted, 'SCHEDULER_ACCEPTED_POST_DELIVERY');
    Producer.Free;
    S.Free;
  end;
end;

var
  FloodCalls, FairCalls: Integer;

procedure Flood(Data: Pointer);
begin
  Inc(FloodCalls);
  Inc(D.Clock);
  if FloodCalls < 20 then
    S.Post(Flood, nil);
end;

procedure FairOnce(T: TScheduledTask; Data: Pointer);
begin
  Inc(FairCalls);
end;

procedure TestMailboxFairness;
begin
  D := TVirtualDriver.Create;
  S := TFiberScheduler.Create(2, D, rpStop);
  S.Spawn(FairOnce, nil);
  S.Post(Flood, nil);
  Check(not S.RunUntil(10), 'SCHEDULER_FLOOD_DEADLINE');
  Check(FairCalls = 1, 'SCHEDULER_MAILBOX_FAIRNESS');
  S.RequestStop;
  Check(S.Stop(100), 'SCHEDULER_FLOOD_STOP');
  S.Free;
  D.Free;
end;

procedure TestTargetAndInvalid;
var
  T: TScheduledTask;
  R: Boolean;
begin
  D := TVirtualDriver.Create;
  S := TFiberScheduler.Create(2, D, rpStop);
  R := False;
  try
    S.Spawn(nil, nil);
  except
    on EFiberUsage do
      R := True;
  end;
  Check(R, 'SCHEDULER_NIL_PROC');
  Parked := S.Spawn(Parking, nil);
  T := S.Spawn(Empty, nil);
  Check(S.RunTaskUntil(T, 100), 'SCHEDULER_TARGET_SETTLED');
  Check((D.Clock = 0) and (Parked.State = fsSuspended), 'SCHEDULER_TARGET_ISOLATION');
  R := False;
  try
    S.WakeTask(nil);
  except
    on EFiberUsage do
      R := True;
  end;
  Check(R, 'SCHEDULER_NIL_WAKE');
  R := False;
  try
    S.Stop(-1);
  except
    on EFiberUsage do
      R := True;
  end;
  Check(R and S.Post(Counter, @Calls), 'SCHEDULER_INVALID_STOP_NO_MUTATION');
  Check(S.Stop(100), 'SCHEDULER_TARGET_CLEANUP');
  S.Free;
  D.Free;
end;

procedure TestClockFault;
var
  R: Boolean;
  Mode: Integer;
begin
  for Mode := 0 to 1 do
  begin
    Cleanups := 0;
    D := TVirtualDriver.Create;
    D.Clock := 100;
    S := TFiberScheduler.Create(2, D, rpStop);
    Parked := S.Spawn(Parking, nil);
    Check(not S.RunUntil(200), 'SCHEDULER_CLOCK_PARK');
    if Mode = 0 then
      D.Clock := 199
    else
      Inc(D.Generation);
    R := False;
    try
      S.RunUntil(300);
    except
      on EFiberUsage do
        R := True;
    end;
    Check(R and S.ClockDiscontinuity, 'SCHEDULER_CLOCK_DISCONTINUITY');
    Check((Cleanups = 0) and (Parked.State = fsSuspended), 'SCHEDULER_CLOCK_RETAINS_STACK');
    R := False;
    try
      S.Spawn(Empty, nil);
    except
      on EFiberUsage do
        R := True;
    end;
    Check(R and not S.Post(Counter, @Calls), 'SCHEDULER_CLOCK_REJECTS_ADMISSION');
    Check(S.Stop(100), 'SCHEDULER_CLOCK_STOP_CLEANUP');
    Check((Cleanups = 1) and (Parked.State = fsCancelled), 'SCHEDULER_CLOCK_CANCEL_FINALLY');
    S.Free;
    D.Free;
  end;
end;

type
  TBarrierDriver = class(TSchedulerDriver)
    Timer: TPlatformTimer;
    Entered, Published: TEvent;
    ParkCalls: Integer;
    constructor Create;
    destructor Destroy; override;
    function NowUs: Int64; override;
    procedure WaitUntil(DeadlineUs: Int64); override;
    procedure Wake; override;
  end;

  TBarrierProducer = class(TThread)
    Driver: TBarrierDriver;
    Accepted: Boolean;
    procedure Execute; override;
  end;

constructor TBarrierDriver.Create;
begin
  inherited;
  Timer := TPlatformTimer.Create;
  Entered := TEvent.Create(nil, True, False, '');
  Published := TEvent.Create(nil, True, False, '');
end;

destructor TBarrierDriver.Destroy;
begin
  Published.Free;
  Entered.Free;
  Timer.Free;
  inherited;
end;

function TBarrierDriver.NowUs: Int64;
begin
  Result := Timer.NowUs;
end;

procedure TBarrierDriver.WaitUntil(DeadlineUs: Int64);
begin
  Inc(ParkCalls);
  if ParkCalls = 1 then
  begin
    Entered.SetEvent;
    Check(Published.WaitFor(5000) = wrSignaled, 'SCHEDULER_PUBLISH_HANDSHAKE');
  end;
  Timer.WaitUntilOrWake(DeadlineUs);
end;

procedure TBarrierDriver.Wake;
begin
  Timer.Notify;
end;

procedure TBarrierProducer.Execute;
begin
  Check(Driver.Entered.WaitFor(5000) = wrSignaled, 'SCHEDULER_PARK_HANDSHAKE');
  Accepted := S.Post(Counter, @Posted);
  S.RequestStop;
  Driver.Published.SetEvent;
end;

procedure TestDrainParkRace;
var
  Driver: TBarrierDriver;
  Producer: TBarrierProducer;
  I: Integer;
begin
  for I := 1 to 100 do
  begin
    Posted := 0;
    Driver := TBarrierDriver.Create;
    S := TFiberScheduler.Create(2, Driver);
    S.Spawn(Parking, nil);
    Producer := TBarrierProducer.Create(True);
    Producer.Driver := Driver;
    Producer.Start;
    Check(S.RunUntil(S.NowUs + 5000000), 'SCHEDULER_DRAIN_PARK_SETTLES');
    Producer.WaitFor;
    Check(Producer.Accepted and (Posted = 1) and (Driver.ParkCalls = 1),
      'SCHEDULER_NO_LOST_NOTIFICATION');
    Producer.Free;
    S.Free;
    Driver.Free;
  end;
end;

type
  TFailingDriver = class(TVirtualDriver)
    ReadCount: Integer;
    function NowUs: Int64; override;
  end;

function TFailingDriver.NowUs: Int64;
begin
  Inc(ReadCount);
  if ReadCount = 2 then
    raise EConvertError.Create('injected clock read failure');
  Result := inherited NowUs;
end;

procedure TestDriverFailureRetention;
var
  Driver: TFailingDriver;
  R: Boolean;
begin
  Driver := TFailingDriver.Create;
  S := TFiberScheduler.Create(1, Driver);
  S.Spawn(Empty, nil);
  Driver.ReadCount := 0;
  R := False;
  try
    S.Stop(100);
  except
    on EConvertError do
      R := True;
  end;
  Check(R, 'SCHEDULER_DRIVER_FAILURE_PROPAGATED');
  R := False;
  try
    R := S.Stop(100);
  except
    on EFiberUsage do
      R := False;
  end;
  Check(R, 'SCHEDULER_DRIVER_FAILURE_CLEARS_PUMP');
  S.Free;
  Driver.Free;
end;
