program ServiceResumeTests;
{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}
uses {$IFDEF UNIX}cthreads,{$ENDIF} SysUtils,
  FiberRuntime.Context, FiberRuntime.Schedule, FiberRuntime.Scheduler, FiberRuntime.Service;
type
  TFakeDriver = class(TSchedulerDriver)
    Time, Generation: Int64;
    function NowUs: Int64; override;
    function ClockGeneration: Int64; override;
    procedure WaitUntil(DeadlineUs: Int64); override;
    procedure Wake; override;
  end;
var
  Driver: TFakeDriver; Scheduler: TFiberScheduler; Service, Other: TFiberService;
  Calls, Active, Finishes: Integer; Slow: Boolean;
  WaitDuration: Int64;
  LastTick: TPeriodicTick;
procedure Check(Value: Boolean; const Name: string);
begin if not Value then begin WriteLn('ASSERTION FAILED: ', Name); Halt(1) end end;
function TFakeDriver.NowUs: Int64;
begin Result := Time end;
function TFakeDriver.ClockGeneration: Int64;
begin Result := Generation end;
procedure TFakeDriver.WaitUntil(DeadlineUs: Int64);
begin if DeadlineUs > Time then Time := DeadlineUs end;
procedure TFakeDriver.Wake;
begin end;
procedure Callback(Task: TScheduledTask; const Tick: TPeriodicTick; Data: Pointer);
begin
  Check(Active = 0, 'SERVICE_RESUME_NO_OVERLAP'); Inc(Active); Inc(Calls);
  LastTick := Tick;
  try if Slow and (Calls = 1) then Task.Delay(WaitDuration)
  finally Dec(Active); Inc(Finishes) end;
end;
procedure Idle(Task: TScheduledTask; const Tick: TPeriodicTick; Data: Pointer);
begin end;
procedure Setup;
begin
  Calls := 0; Active := 0; Finishes := 0; Slow := False;
  WaitDuration := 5000;
  Driver := TFakeDriver.Create; Scheduler := TFiberScheduler.Create(16, Driver);
  Service := TFiberService.Create(Scheduler, 1000, Callback, nil); Service.Start;
end;
procedure Teardown;
begin
  Check(Service.Stop(1000), 'SERVICE_RESUME_STOP'); Service.Free;
  Check(Scheduler.Stop(1000), 'SERVICE_RESUME_SCHEDULER_STOP');
  Scheduler.Free; Driver.Free;
end;
procedure TestIdleResume;
begin
  Setup;
  Other := TFiberService.Create(Scheduler, 1000, Idle, nil); Other.Start;
  Check(not Scheduler.RunUntil(500), 'SERVICE_IDLE_WAIT');
  Driver.Time := 10500; Inc(Driver.Generation);
  Check(not Scheduler.RunUntil(10501), 'SERVICE_RESUME_REBASED');
  Check((Calls = 0) and (Service.EpochUs = 10500) and (Other.EpochUs = 10500),
    'SERVICE_RESUME_COMMON_EPOCH');
  Check(not Scheduler.RunUntil(11500), 'SERVICE_RESUME_STRICT_DEADLINE');
  Check(Calls = 0, 'SERVICE_RESUME_NO_REPLAY');
  Check(not Scheduler.RunUntil(11501), 'SERVICE_RESUME_FIRST_NEW_TICK');
  Check((Calls = 1) and (LastTick.Index = 1) and (LastTick.DeadlineUs = 11500) and
    (LastTick.Segment = 1), 'SERVICE_RESUME_TICK_SEGMENT');
  Check((Service.SkippedCount = 0) and (Service.DiscontinuityCount = 1),
    'SERVICE_RESUME_EXCLUDES_SLEEP_SKIPS');
  Check((Service.LastSegment.EpochUs = 0) and (Service.CurrentSegment.EpochUs = 10500),
    'SERVICE_RESUME_SEGMENT_EVIDENCE');
  Check(Other.Stop(1000), 'SERVICE_RESUME_OTHER_STOP'); Other.Free;
  Teardown;
end;
procedure TestActiveWaitPreserved;
begin
  Setup; Slow := True; WaitDuration := 50000;
  Check(not Scheduler.RunUntil(1500), 'SERVICE_RESUME_LONG_WAIT');
  Driver.Time := 10500; Inc(Driver.Generation);
  Check(not Scheduler.RunUntil(10501), 'SERVICE_RESUME_LONG_WAIT_PRESERVED');
  Check((Calls = 1) and (Finishes = 0) and (Active = 1), 'SERVICE_RESUME_NO_EARLY_COMPLETION');
  Check(not Scheduler.RunUntil(51001), 'SERVICE_RESUME_LONG_COMPLETED');
  Check((Finishes = 1) and (Service.CrossingCount = 1) and (Service.EpochUs = 51000),
    'SERVICE_RESUME_REBASE_AFTER_ACTIVE');
  Check(not Scheduler.RunUntil(52001), 'SERVICE_RESUME_LONG_NEXT_TICK');
  Check((Calls = 2) and (LastTick.DeadlineUs = 52000), 'SERVICE_RESUME_LONG_NEXT_DEADLINE');
  Teardown;
end;
procedure TestActiveResume;
begin
  Setup; Slow := True;
  Check(not Scheduler.RunUntil(1500), 'SERVICE_RESUME_ACTIVE_SUSPENDED');
  Driver.Time := 10500; Inc(Driver.Generation);
  Check(not Scheduler.RunUntil(10501), 'SERVICE_RESUME_ACTIVE_COMPLETED');
  Check((Calls = 1) and (Finishes = 1) and (Active = 0), 'SERVICE_RESUME_PRESERVED_INVOCATION');
  Check((Service.CrossingCount = 1) and (Service.LastCrossingTick.Index = 1) and
    (Service.LastCrossingFinishedUs = 10500), 'SERVICE_RESUME_CROSSING_RECORDED');
  Check((Service.SkippedCount = 0) and (Service.EpochUs = 10500),
    'SERVICE_RESUME_ACTIVE_NEW_EPOCH');
  Check(not Scheduler.RunUntil(11501), 'SERVICE_RESUME_ACTIVE_NEXT');
  Check((Calls = 2) and (LastTick.DeadlineUs = 11500), 'SERVICE_RESUME_ACTIVE_NEXT_DEADLINE');
  Teardown;
end;
procedure TestCancellationDuringResume;
begin
  Setup;
  Check(not Scheduler.RunUntil(500), 'SERVICE_RESUME_CANCEL_WAIT');
  Driver.Time := 10500; Inc(Driver.Generation); Service.Cancel;
  Check(Service.Stop(1000), 'SERVICE_RESUME_CANCEL_STOP');
  Check(Calls = 0, 'SERVICE_RESUME_CANCEL_NO_CALLBACK');
  Teardown;
end;
begin
  TestIdleResume; TestActiveResume; TestActiveWaitPreserved; TestCancellationDuringResume;
  WriteLn('PASS: periodic resume rebase, no replay, active preservation, segments, cancellation');
end.
