type
  TSnapshotDriver = class(TVirtualDriver)
    TimeReads, GenerationReads, ChangeAtGenerationRead: Integer;
    ChangeDuringTime, Churn: Boolean;
    function NowUs: Int64; override;
    function ClockGeneration: Int64; override;
  end;

function TSnapshotDriver.NowUs: Int64;
begin
  Inc(TimeReads);
  if ChangeDuringTime or Churn then
  begin
    ChangeDuringTime := False;
    Inc(Generation);
    Clock := 11000;
  end;
  Result := Clock;
end;

function TSnapshotDriver.ClockGeneration: Int64;
begin
  Inc(GenerationReads);
  if (ChangeAtGenerationRead > 0) and (GenerationReads = ChangeAtGenerationRead) then
  begin
    Inc(Generation);
    Clock := 11000
  end;
  Result := Generation;
end;

procedure TestConsistentClockSnapshot;
var
  Driver: TSnapshotDriver;
  Mode: Integer;
  Now: Int64;
  Refused: Boolean;
begin
  for Mode := 0 to 2 do
  begin
    Driver := TSnapshotDriver.Create;
    S := TFiberScheduler.Create(1, Driver);
    Check(S.NowUs = 0, 'SCHEDULER_SNAPSHOT_INITIAL');
    Driver.TimeReads := 0;
    Driver.GenerationReads := 0;
    if Mode = 0 then
      Driver.ChangeDuringTime := True
    else
      Driver.ChangeAtGenerationRead := Mode;
    Now := S.NowUs;
    Check((Now = 11000) and (S.ResumeGeneration = 1) and
      (S.ResumeEpochUs = 11000), 'SCHEDULER_SNAPSHOT_CONSISTENT');
    if Mode = 1 then
      Check(Driver.TimeReads = 1, 'SCHEDULER_SNAPSHOT_STABLE_ONCE')
    else
      Check(Driver.TimeReads = 2, 'SCHEDULER_SNAPSHOT_RETRIED');
    Driver.ChangeAtGenerationRead := 0;
    Check(S.Stop(1), 'SCHEDULER_SNAPSHOT_STOP');
    S.Free;
    Driver.Free;
  end;
  Driver := TSnapshotDriver.Create;
  S := TFiberScheduler.Create(1, Driver);
  Check(S.NowUs = 0, 'SCHEDULER_SNAPSHOT_CHURN_INITIAL');
  Driver.TimeReads := 0;
  Driver.GenerationReads := 0;
  Driver.Churn := True;
  Refused := False;
  try
    S.NowUs
  except
    on EFiberUsage do
      Refused := True
  end;
  Check(Refused and S.ClockDiscontinuity, 'SCHEDULER_SNAPSHOT_CHURN_FAIL_CLOSED');
  Check((Driver.TimeReads = 3) and (Driver.GenerationReads = 6),
    'SCHEDULER_SNAPSHOT_THREE_ATTEMPT_BOUND');
  Driver.Churn := False;
  Check(S.Stop(1), 'SCHEDULER_SNAPSHOT_CHURN_CLEANUP');
  S.Free;
  Driver.Free;
end;
