unit FiberRuntime.Service;
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
interface
uses FiberRuntime.Scheduler, FiberRuntime.Schedule, FiberRuntime.ServiceHooks;
type
  TServiceProc = procedure(ATask: TScheduledTask; const ATick: TPeriodicTick;
    AData: Pointer);
  TFiberService = class
  private
    FScheduler: TFiberScheduler;
    FTask: TScheduledTask;
    FSchedule: TPeriodicSchedule;
    FPeriodUs, FEpochUs: Int64;
    FProc: TServiceProc;
    FData: Pointer;
    FStarted, FCancelled: Boolean;
    FHooks: TServiceHooks;
    FResumeGeneration, FCrossings, FLastCrossingFinished: Int64;
    FLastCrossingTick: TPeriodicTick;
    procedure Execute(ATask: TScheduledTask);
    function GetTask: TScheduledTask;
    function GetStartedCount: Int64;
    function GetSkippedCount: Int64;
    function GetEpochUs: Int64;
    function GetPeriodUs: Int64;
    function GetScheduler: TFiberScheduler;
    function GetDiscontinuityCount: Int64;
    function GetCrossingCount: Int64;
    function GetLastCrossingTick: TPeriodicTick;
    function GetLastCrossingFinished: Int64;
    function GetSegment(Index: Integer): TPeriodicSegment;
  public
    constructor Create(AScheduler: TFiberScheduler; APeriodUs: Int64;
      AProc: TServiceProc; AData: Pointer);
    procedure BeforeDestruction; override;
    destructor Destroy; override;
    procedure Start;
    procedure Cancel;
    function Stop(ATimeoutUs: Int64): Boolean;
    procedure BindLifecycle(Hooks: TServiceHooks);
    property Scheduler: TFiberScheduler read GetScheduler;
    property DiscontinuityCount: Int64 read GetDiscontinuityCount;
    property CrossingCount: Int64 read GetCrossingCount;
    property LastCrossingTick: TPeriodicTick read GetLastCrossingTick;
    property LastCrossingFinishedUs: Int64 read GetLastCrossingFinished;
    property LastSegment: TPeriodicSegment index 0 read GetSegment;
    property CurrentSegment: TPeriodicSegment index 1 read GetSegment;
    property Task: TScheduledTask read GetTask;
    property StartedCount: Int64 read GetStartedCount;
    property SkippedCount: Int64 read GetSkippedCount;
    property EpochUs: Int64 read GetEpochUs;
    property PeriodUs: Int64 read GetPeriodUs;
  end;
implementation
uses SysUtils, FiberRuntime.Context;

procedure ServiceEntry(ATask: TScheduledTask; AData: Pointer);
begin TFiberService(AData).Execute(ATask) end;
function ServiceSettled(Data: Pointer): Boolean;
var Service: TFiberService;
begin
  Service := TFiberService(Data);
  Result := ((Service.FTask = nil) or
    (Service.FTask.State in [fsCompleted, fsCancelled, fsFaulted])) and
    ((Service.FHooks = nil) or Service.FHooks.IsSettled);
end;
constructor TFiberService.Create(AScheduler: TFiberScheduler; APeriodUs: Int64;
  AProc: TServiceProc; AData: Pointer);
begin
  inherited Create;
  if AScheduler = nil then raise EFiberUsage.Create('Service requires scheduler');
  AScheduler.CheckOwner;
  if APeriodUs <= 0 then raise ERangeError.Create('Service period must be positive');
  if not Assigned(AProc) then raise EFiberUsage.Create('Service requires callback');
  FScheduler := AScheduler; FPeriodUs := APeriodUs;
  FProc := AProc; FData := AData;
end;
procedure TFiberService.BeforeDestruction;
begin
  if FScheduler <> nil then FScheduler.CheckOwner;
  if (FTask <> nil) and not (FTask.State in [fsCompleted, fsCancelled, fsFaulted]) then
    raise EFiberUsage.Create('Service has an active task');
  if (FHooks <> nil) and (not FCancelled or not FHooks.IsSettled) then
    raise EFiberUsage.Create('Service communication is not stopped');
  inherited;
end;
destructor TFiberService.Destroy;
begin
  if FHooks <> nil then FHooks.Detach;
  FSchedule.Free; inherited;
end;
procedure TFiberService.BindLifecycle(Hooks: TServiceHooks);
begin
  FScheduler.CheckOwner;
  if (Hooks = nil) or (FHooks <> nil) or FCancelled then
    raise EFiberUsage.Create('Service lifecycle binding unavailable');
  FHooks := Hooks;
end;
procedure TFiberService.Start;
begin
  FScheduler.CheckOwner;
  if FStarted or FCancelled then raise EFiberUsage.Create('Service cannot restart');
  FEpochUs := FScheduler.NowUs;
  FResumeGeneration := FScheduler.ResumeGeneration;
  FSchedule := TPeriodicSchedule.Create(FEpochUs, FPeriodUs);
  try FTask := FScheduler.Spawn(ServiceEntry, Self)
  except FSchedule.Free; FSchedule := nil; raise end;
  FStarted := True;
end;
procedure TFiberService.Execute(ATask: TScheduledTask);
var Tick: TPeriodicTick; Now: Int64;
begin
  while not FCancelled do begin
    Now := FScheduler.NowUs;
    if FResumeGeneration <> FScheduler.ResumeGeneration then begin
      FSchedule.Rebase(FScheduler.ResumeEpochUs);
      FEpochUs := FSchedule.EpochUs; FResumeGeneration := FScheduler.ResumeGeneration;
    end;
    if not ATask.AwaitUntilOrResume(FSchedule.NextDeadlineUs, FResumeGeneration) then Continue;
    if FCancelled then Exit;
    if FSchedule.TryAcquire(FScheduler.NowUs, Tick) then begin
      FProc(ATask, Tick, FData);
      { A suspended callback remains acquired until it returns. }
      Now := FScheduler.NowUs;
      if FResumeGeneration <> FScheduler.ResumeGeneration then begin
        Inc(FCrossings); FLastCrossingTick := Tick; FLastCrossingFinished := Now;
        FSchedule.CompleteAndRebase(Now);
        FEpochUs := FSchedule.EpochUs; FResumeGeneration := FScheduler.ResumeGeneration;
      end else FSchedule.Complete(Now);
    end;
  end;
end;
procedure TFiberService.Cancel;
begin
  FScheduler.CheckOwner;
  {$IFNDEF CONTEXT_PROVE_SERVICE_STOP}
  FCancelled := True;
  if FHooks <> nil then FHooks.BeginStop;
  if FSchedule <> nil then FSchedule.Cancel;
  if FTask <> nil then FTask.Cancel;
  {$ENDIF}
end;
function TFiberService.Stop(ATimeoutUs: Int64): Boolean;
var Now, Deadline: Int64;
begin
  FScheduler.CheckOwner;
  if ATimeoutUs < 0 then raise EFiberUsage.Create('Stop timeout must be nonnegative');
  if FScheduler.CurrentTask <> nil then
    raise EFiberUsage.Create('Service Stop requires carrier');
  Cancel;
  if ServiceSettled(Self) then begin Result := True; Exit end;
  {$IFDEF CONTEXT_PROVE_SERVICE_STOP}
  { Also omit StopTask's cancellation, so the mutation tests missing service
    stop admission without its cleanup helper repairing that omission. }
  Now := FScheduler.NowUs;
  if Now > High(Int64) - ATimeoutUs then Deadline := High(Int64)
  else Deadline := Now + ATimeoutUs;
  Result := FScheduler.RunTaskUntil(FTask, Deadline);
  {$ELSE}
  Now := FScheduler.CleanupNowUs;
  if Now > High(Int64) - ATimeoutUs then Deadline := High(Int64)
  else Deadline := Now + ATimeoutUs;
  Result := FScheduler.RunUntilCondition(ServiceSettled, Self, Deadline);
  {$ENDIF}
end;
function TFiberService.GetTask: TScheduledTask;
begin FScheduler.CheckOwner; Result := FTask end;
function TFiberService.GetStartedCount: Int64;
begin
  FScheduler.CheckOwner; Result := 0;
  if FSchedule <> nil then Result := FSchedule.StartedCount;
end;
function TFiberService.GetSkippedCount: Int64;
begin
  FScheduler.CheckOwner; Result := 0;
  if FSchedule <> nil then Result := FSchedule.SkippedCount;
end;
function TFiberService.GetEpochUs: Int64;
begin FScheduler.CheckOwner; Result := FEpochUs end;
function TFiberService.GetPeriodUs: Int64;
begin FScheduler.CheckOwner; Result := FPeriodUs end;
function TFiberService.GetScheduler: TFiberScheduler;
begin FScheduler.CheckOwner; Result := FScheduler end;
function TFiberService.GetDiscontinuityCount: Int64;
begin
  FScheduler.CheckOwner; Result := 0;
  if FSchedule <> nil then Result := FSchedule.DiscontinuityCount;
end;
function TFiberService.GetCrossingCount: Int64;
begin FScheduler.CheckOwner; Result := FCrossings end;
function TFiberService.GetLastCrossingTick: TPeriodicTick;
begin FScheduler.CheckOwner; Result := FLastCrossingTick end;
function TFiberService.GetLastCrossingFinished: Int64;
begin FScheduler.CheckOwner; Result := FLastCrossingFinished end;
function TFiberService.GetSegment(Index: Integer): TPeriodicSegment;
begin
  FScheduler.CheckOwner;
  if FSchedule = nil then begin FillChar(Result, SizeOf(Result), 0); Result.Generation := -1 end
  else if Index = 0 then Result := FSchedule.LastSegment else Result := FSchedule.CurrentSegment;
end;
end.
