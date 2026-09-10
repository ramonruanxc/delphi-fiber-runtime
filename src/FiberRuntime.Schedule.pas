unit FiberRuntime.Schedule;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}

interface

type
  TPeriodicTick = record
    Index: Int64;
    DeadlineUs: Int64;
    StartedUs: Int64;
  end;

  TPeriodicSchedule = class
  private
    FEpochUs, FPeriodUs, FIndex, FDeadlineUs: Int64;
    FStarted, FSkipped, FLastObservedUs: Int64;
    FActive, FCancelled: Boolean;
    procedure ValidateTime(ANowUs: Int64);
    function DeadlineFor(AIndex: Int64): Int64;
  public
    constructor Create(AEpochUs, APeriodUs: Int64);
    function TryAcquire(ANowUs: Int64; out ATick: TPeriodicTick): Boolean;
    procedure Complete(ANowUs: Int64);
    procedure Cancel;
    function NextDeadlineUs: Int64;
    function StartedCount: Int64;
    function SkippedCount: Int64;
    function IsActive: Boolean;
    function IsCancelled: Boolean;
  end;

implementation

uses SysUtils;

function AddNonnegative(A, B: Int64): Int64;
begin
  if A > High(Int64) - B then
    raise ERangeError.Create('Schedule integer overflow');
  Result := A + B;
end;

constructor TPeriodicSchedule.Create(AEpochUs, APeriodUs: Int64);
begin
  inherited Create;
  if (AEpochUs < 0) or (APeriodUs <= 0) then
    raise ERangeError.Create('Epoch must be nonnegative and period positive');
  FEpochUs := AEpochUs;
  FPeriodUs := APeriodUs;
  FIndex := 1;
  FDeadlineUs := DeadlineFor(FIndex);
  FLastObservedUs := AEpochUs;
end;

procedure TPeriodicSchedule.ValidateTime(ANowUs: Int64);
begin
  if ANowUs < FLastObservedUs then
    raise ERangeError.Create('Schedule time moved backward');
end;

function TPeriodicSchedule.DeadlineFor(AIndex: Int64): Int64;
begin
  if AIndex > (High(Int64) - FEpochUs) div FPeriodUs then
    raise ERangeError.Create('Schedule deadline overflow');
  Result := FEpochUs + AIndex * FPeriodUs;
end;

function TPeriodicSchedule.TryAcquire(ANowUs: Int64;
  out ATick: TPeriodicTick): Boolean;
var DueIndex, NewSkipped, NewStarted, NewDeadline: Int64;
begin
  ValidateTime(ANowUs);
  Result := False;
  if FCancelled or (ANowUs < FDeadlineUs) then
  begin
    FLastObservedUs := ANowUs;
    Exit;
  end;
  {$IFNDEF PROVE_OVERLAP}
  if FActive then
  begin
    FLastObservedUs := ANowUs;
    Exit;
  end;
  {$ENDIF}
  DueIndex := (ANowUs - FEpochUs) div FPeriodUs;
  NewDeadline := DeadlineFor(DueIndex);
  NewSkipped := AddNonnegative(FSkipped, DueIndex - FIndex);
  NewStarted := AddNonnegative(FStarted, 1);
  { Commit only after every range check has succeeded. }
  FIndex := DueIndex;
  FDeadlineUs := NewDeadline;
  FSkipped := NewSkipped;
  FStarted := NewStarted;
  FLastObservedUs := ANowUs;
  FActive := True;
  ATick.Index := FIndex;
  ATick.DeadlineUs := FDeadlineUs;
  ATick.StartedUs := ANowUs;
  Result := True;
end;

procedure TPeriodicSchedule.Complete(ANowUs: Int64);
var DueIndex, NewIndex, NewDeadline, NewSkipped: Int64;
begin
  if not FActive then
    raise Exception.Create('Complete requires an active invocation');
  ValidateTime(ANowUs);
  DueIndex := (ANowUs - FEpochUs) div FPeriodUs;
  NewIndex := AddNonnegative(DueIndex, 1);
  NewDeadline := DeadlineFor(NewIndex);
  {$IFDEF PROVE_DRIFT}
  NewDeadline := AddNonnegative(ANowUs, FPeriodUs);
  {$ENDIF}
  NewSkipped := AddNonnegative(FSkipped, DueIndex - FIndex);
  FIndex := NewIndex;
  FDeadlineUs := NewDeadline;
  FSkipped := NewSkipped;
  FLastObservedUs := ANowUs;
  FActive := False;
end;

procedure TPeriodicSchedule.Cancel;
begin FCancelled := True end;
function TPeriodicSchedule.NextDeadlineUs: Int64;
begin Result := FDeadlineUs end;
function TPeriodicSchedule.StartedCount: Int64;
begin Result := FStarted end;
function TPeriodicSchedule.SkippedCount: Int64;
begin Result := FSkipped end;
function TPeriodicSchedule.IsActive: Boolean;
begin Result := FActive end;
function TPeriodicSchedule.IsCancelled: Boolean;
begin Result := FCancelled end;

end.
