program ServiceTests;
{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}
uses {$IFDEF UNIX}cthreads,{$ENDIF} SysUtils, Classes,
  FiberRuntime.Context, FiberRuntime.Schedule, FiberRuntime.Scheduler,
  FiberRuntime.Service;
type
  TFakeDriver = class(TSchedulerDriver)
    Time: Int64;
    Generation: Int64;
    FailClock: Boolean;
    function NowUs: Int64; override;
    procedure WaitUntil(DeadlineUs: Int64); override;
    procedure Wake; override;
    function ClockGeneration: Int64; override;
  end;
  TOwnerProbe = class(TThread)
    Service: TFiberService;
    Rejected: Integer;
    procedure Execute; override;
  end;
var
  Driver: TFakeDriver;
  Scheduler: TFiberScheduler;
  Service, OtherService: TFiberService;
  Calls, Active, Cleanups: Integer;
  Identity: TScheduledTask;
  TickDeadlines: array[0..3] of Int64;

procedure Check(Value: Boolean; const Name: string);
begin
  if not Value then begin WriteLn('ASSERTION FAILED: ', Name); Halt(1) end;
end;
function TFakeDriver.NowUs: Int64;
begin
  if FailClock then raise Exception.Create('clock unavailable after service stopped');
  Result := Time;
end;
procedure TFakeDriver.WaitUntil(DeadlineUs: Int64);
begin if DeadlineUs > Time then Time := DeadlineUs end;
procedure TFakeDriver.Wake;
begin end;
function TFakeDriver.ClockGeneration: Int64;
begin Result := Generation end;
procedure Setup;
begin
  Calls := 0; Active := 0; Cleanups := 0; Identity := nil;
  Driver := TFakeDriver.Create;
  Scheduler := TFiberScheduler.Create(16, Driver, rpStop);
end;
procedure Teardown;
begin
  Check(Service.Stop(10000), 'SERVICE_TEARDOWN_STOP');
  Service.Free;
  Check(Scheduler.Stop(10000), 'SERVICE_SCHEDULER_STOP');
  Scheduler.Free; Driver.Free;
end;
procedure Count(ATask: TScheduledTask; const ATick: TPeriodicTick; AData: Pointer);
begin Inc(Calls) end;
procedure Idle(ATask: TScheduledTask; const ATick: TPeriodicTick; AData: Pointer);
begin end;
procedure Slow(ATask: TScheduledTask; const ATick: TPeriodicTick; AData: Pointer);
begin
  Check(Active = 0, 'SERVICE_NO_OVERLAP'); Inc(Active);
  if Identity = nil then Identity := ATask;
  Check(Identity = ATask, 'SERVICE_PERSISTENT_TASK');
  Check(ATick.StartedUs >= ATick.DeadlineUs, 'SERVICE_NO_EARLY_TICK');
  TickDeadlines[Calls] := ATick.DeadlineUs; Inc(Calls);
  try
    if Calls = 1 then ATask.Delay(2200);
    if Calls = 2 then Service.Cancel;
  finally Dec(Active); Inc(Cleanups) end;
end;
procedure Suspended(ATask: TScheduledTask; const ATick: TPeriodicTick; AData: Pointer);
begin
  Inc(Calls);
  try ATask.Delay(100000) finally Inc(Cleanups) end;
end;
procedure Fault(ATask: TScheduledTask; const ATick: TPeriodicTick; AData: Pointer);
begin raise EConvertError.Create('service fault') end;
procedure TOwnerProbe.Execute;
var N: Int64; T: TScheduledTask;
begin
  try Service.Start except on EFiberUsage do Inc(Rejected) end;
  try Service.Cancel except on EFiberUsage do Inc(Rejected) end;
  try Service.Stop(1) except on EFiberUsage do Inc(Rejected) end;
  try Service.Free except on EFiberUsage do Inc(Rejected) end;
  try T := Service.Task; if T = nil then N := 0
  except on EFiberUsage do Inc(Rejected) end;
  try N := Service.StartedCount except on EFiberUsage do Inc(Rejected) end;
  try N := Service.SkippedCount except on EFiberUsage do Inc(Rejected) end;
  try N := Service.EpochUs except on EFiberUsage do Inc(Rejected) end;
  try N := Service.PeriodUs except on EFiberUsage do Inc(Rejected) end;
end;
procedure TestStopBeforeCallback;
begin
  Setup;
  Service := TFiberService.Create(Scheduler, 1000, Count, nil);
  Service.Start;
  Check(Service.Stop(10000), 'SERVICE_STOP_NO_CALLBACK');
  Check(Scheduler.RunUntil(20000), 'SERVICE_STOP_SETTLED');
  Check((Calls = 0) and (Service.StartedCount = 0), 'SERVICE_STOP_NO_CALLBACK');
  Driver.FailClock := True;
  Check(Service.Stop(1), 'SERVICE_STOPPED_DOES_NOT_READ_CLOCK');
  Driver.FailClock := False;
  Teardown;
end;
procedure TestFixedRate;
begin
  Setup;
  Service := TFiberService.Create(Scheduler, 1000, Slow, nil);
  Service.Start;
  Check(not Scheduler.RunUntil(999), 'SERVICE_PENDING_FIRST_TICK');
  Check(Calls = 0, 'SERVICE_FIRST_DEADLINE');
  Check(Scheduler.RunUntil(5000), 'SERVICE_FIXED_RATE_SETTLED');
  Check((Calls = 2) and (Cleanups = 2) and (Active = 0), 'SERVICE_ACTIVE_LIFETIME');
  Check((TickDeadlines[0] = 1000) and (TickDeadlines[1] = 4000),
    'SERVICE_ORIGINAL_EPOCH');
  Check((Service.StartedCount = 2) and (Service.SkippedCount = 2),
    'SERVICE_SKIP_ACCOUNTING');
  Check(Service.Task = Identity, 'SERVICE_TASK_HANDLE');
  Teardown;
end;
procedure TestStopTimeout;
var Rejected: Boolean;
begin
  Setup;
  Service := TFiberService.Create(Scheduler, 1000, Suspended, nil);
  Service.Start;
  Check(not Scheduler.RunUntil(1500), 'SERVICE_CALLBACK_SUSPENDED');
  Check(not Service.Stop(0), 'SERVICE_STOP_TIMEOUT');
  Check((Service.Task.State = fsSuspended) and (Cleanups = 0),
    'SERVICE_TIMEOUT_RETAINS_LIVE');
  Rejected := False;
  try Service.Free except on EFiberUsage do Rejected := True end;
  Check(Rejected, 'SERVICE_FREE_ACTIVE_GUARD');
  Check(Service.Stop(1000), 'SERVICE_CANCEL_CLEANUP');
  Check((Calls = 1) and (Cleanups = 1), 'SERVICE_NO_CALLBACK_AFTER_STOP');
  Teardown;
end;
procedure TestIndependentStop;
var BeforeStop: Int64;
begin
  Setup;
  Service := TFiberService.Create(Scheduler, 1000, Suspended, nil);
  OtherService := TFiberService.Create(Scheduler, 1000, Idle, nil);
  Service.Start; OtherService.Start;
  Check(not Scheduler.RunUntil(1500), 'SERVICE_TWO_ACTIVE');
  BeforeStop := Driver.Time;
  Check(Service.Stop(50000), 'SERVICE_INDEPENDENT_STOP');
  Check(Driver.Time = BeforeStop, 'SERVICE_STOP_DOES_NOT_WAIT_OTHER');
  Check(not OtherService.Task.CancelRequested, 'SERVICE_STOP_PRESERVES_OTHER');
  Check(not Scheduler.RunUntil(2500), 'SERVICE_OTHER_STILL_RUNNING');
  Check((OtherService.StartedCount = 2) and (Calls = 1),
    'SERVICE_OTHER_CONTINUES_AFTER_STOP');
  Check(OtherService.Stop(10000), 'SERVICE_OTHER_STOP'); OtherService.Free;
  Teardown;
end;
procedure TestClockFaultStop(GenerationChange: Boolean);
var FaultDetected, Stopped: Boolean;
begin
  Setup;
  Service := TFiberService.Create(Scheduler, 1000, Suspended, nil);
  Service.Start;
  Check(not Scheduler.RunUntil(1500), 'SERVICE_CLOCK_CASE_SUSPENDED');
  Check((Calls = 1) and (Cleanups = 0), 'SERVICE_CLOCK_CASE_ACTIVE');
  if GenerationChange then Inc(Driver.Generation) else Driver.Time := 1000;
  FaultDetected := False;
  try Scheduler.RunUntil(1600)
  except on EFiberUsage do FaultDetected := True end;
  Check(FaultDetected and Scheduler.ClockDiscontinuity, 'SERVICE_CLOCK_FAULT_DETECTED');
  Stopped := False;
  try Stopped := Service.Stop(1000)
  except on EFiberUsage do Stopped := False end;
  if GenerationChange then Check(Stopped, 'SERVICE_GENERATION_STOP_CLEANUP')
  else Check(Stopped, 'SERVICE_BACKWARD_STOP_CLEANUP');
  Check((Service.Task.State = fsCancelled) and (Cleanups = 1),
    'SERVICE_CLOCK_FINALLY_ONCE');
  Check(Service.Stop(1000), 'SERVICE_CLOCK_REPEAT_STOP');
  Check(Scheduler.Stop(1000), 'SERVICE_CLOCK_SCHEDULER_SETTLED');
  Check((Calls = 1) and (Cleanups = 1), 'SERVICE_CLOCK_NO_FURTHER_CALLBACK');
  Teardown;
end;
procedure TestGuardsAndFault;
var Rejected: Boolean; Probe: TOwnerProbe;
begin
  Setup;
  Service := TFiberService.Create(Scheduler, 1000, Fault, nil);
  Probe := TOwnerProbe.Create(True); Probe.Service := Service;
  Probe.Start; Probe.WaitFor;
  Check(Probe.Rejected = 9, 'SERVICE_FOREIGN_OWNER'); Probe.Free;
  Service.Start;
  Rejected := False;
  try Service.Start except on EFiberUsage do Rejected := True end;
  Check(Rejected, 'SERVICE_START_ONCE');
  Check(Scheduler.RunUntil(2000), 'SERVICE_FAULT_SETTLED');
  Check((Service.Task.State = fsFaulted) and
    (Service.Task.ErrorClass = 'EConvertError') and
    (Service.Task.ErrorMessage = 'service fault'), 'SERVICE_FAULT_RETAINED');
  Teardown;
  Setup;
  Service := TFiberService.Create(Scheduler, 1000, Count, nil);
  Check(Service.Stop(1), 'SERVICE_DORMANT_STOP');
  Rejected := False;
  try Service.Start except on EFiberUsage do Rejected := True end;
  Check(Rejected and (Calls = 0), 'SERVICE_STOPPED_START_REJECTED');
  Teardown;
end;
procedure TestDormantEpochAndArguments;
var Rejected: Boolean;
begin
  Setup;
  Rejected := False;
  try TFiberService.Create(nil, 1000, Count, nil).Free
  except on EFiberUsage do Rejected := True end;
  Check(Rejected, 'SERVICE_NIL_SCHEDULER');
  Rejected := False;
  try TFiberService.Create(Scheduler, 0, Count, nil).Free
  except on ERangeError do Rejected := True end;
  Check(Rejected, 'SERVICE_INVALID_PERIOD');
  Rejected := False;
  try TFiberService.Create(Scheduler, 1000, nil, nil).Free
  except on EFiberUsage do Rejected := True end;
  Check(Rejected, 'SERVICE_NIL_CALLBACK');
  Service := TFiberService.Create(Scheduler, 1000, Count, nil);
  Driver.Time := 500;
  Check((Service.Task = nil) and (Service.StartedCount = 0), 'SERVICE_DORMANT');
  Service.Start;
  Check((Service.EpochUs = 500) and (Service.PeriodUs = 1000), 'SERVICE_START_EPOCH');
  Check(not Scheduler.RunUntil(1499), 'SERVICE_DELAYED_EPOCH_WAIT');
  Check(Calls = 0, 'SERVICE_DELAYED_EPOCH_NO_EARLY');
  Check(not Scheduler.RunUntil(1501), 'SERVICE_DELAYED_EPOCH_ACTIVE');
  Check(Calls = 1, 'SERVICE_DELAYED_EPOCH_CALLBACK');
  Rejected := False;
  try Service.Stop(-1) except on EFiberUsage do Rejected := True end;
  Check(Rejected and not Service.Task.CancelRequested, 'SERVICE_BAD_STOP_PRESERVES_TASK');
  Teardown;
end;
begin
  TestStopBeforeCallback; TestFixedRate; TestStopTimeout;
  TestIndependentStop; TestGuardsAndFault; TestDormantEpochAndArguments;
  TestClockFaultStop(False); TestClockFaultStop(True);
  WriteLn('PASS: service fixed epoch, persistent task, skips, stop, timeout, ownership');
end.
