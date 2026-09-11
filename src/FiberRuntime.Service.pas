unit FiberRuntime.Service;
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
interface
uses FiberRuntime.Scheduler, FiberRuntime.Schedule;
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
    procedure Execute(ATask: TScheduledTask);
    function GetTask: TScheduledTask;
    function GetStartedCount: Int64;
    function GetSkippedCount: Int64;
    function GetEpochUs: Int64;
    function GetPeriodUs: Int64;
  public
    constructor Create(AScheduler: TFiberScheduler; APeriodUs: Int64;
      AProc: TServiceProc; AData: Pointer);
    procedure BeforeDestruction; override;
    destructor Destroy; override;
    procedure Start;
    procedure Cancel;
    function Stop(ATimeoutUs: Int64): Boolean;
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
  inherited;
end;
destructor TFiberService.Destroy;
begin FSchedule.Free; inherited end;
procedure TFiberService.Start;
begin
  FScheduler.CheckOwner;
  if FStarted or FCancelled then raise EFiberUsage.Create('Service cannot restart');
  FEpochUs := FScheduler.NowUs;
  FSchedule := TPeriodicSchedule.Create(FEpochUs, FPeriodUs);
  try FTask := FScheduler.Spawn(ServiceEntry, Self)
  except FSchedule.Free; FSchedule := nil; raise end;
  FStarted := True;
end;
procedure TFiberService.Execute(ATask: TScheduledTask);
var Tick: TPeriodicTick;
begin
  while not FCancelled do begin
    ATask.AwaitUntil(FSchedule.NextDeadlineUs);
    if FCancelled then Exit;
    if FSchedule.TryAcquire(FScheduler.NowUs, Tick) then begin
      FProc(ATask, Tick, FData);
      { A suspended callback remains acquired until it returns. }
      FSchedule.Complete(FScheduler.NowUs);
    end;
  end;
end;
procedure TFiberService.Cancel;
begin
  FScheduler.CheckOwner;
  {$IFNDEF CONTEXT_PROVE_SERVICE_STOP}
  FCancelled := True;
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
  if (FTask = nil) or (FTask.State in [fsCompleted, fsCancelled, fsFaulted]) then
    begin Result := True; Exit end;
  Now := FScheduler.NowUs;
  if Now > High(Int64) - ATimeoutUs then Deadline := High(Int64)
  else Deadline := Now + ATimeoutUs;
  Result := FScheduler.RunTaskUntil(FTask, Deadline);
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
end.
