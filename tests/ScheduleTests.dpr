program ScheduleTests;


{$IFDEF FPC}
{$MODE DELPHI}
{$ENDIF}
{$APPTYPE CONSOLE}

uses
  SysUtils,
  FiberRuntime.Schedule;

var
  Checks: Integer;

procedure Check(Condition: Boolean; const Name: string);
begin
  if not Condition then
  begin
    WriteLn('ASSERTION FAILED: ', Name);
    Halt(1);
  end;
  Inc(Checks);
end;

procedure CheckState(S: TPeriodicSchedule; Deadline, Started, Skipped: Int64;
  Active, Cancelled: Boolean; const Name: string);
begin
  Check((S.NextDeadlineUs = Deadline) and (S.StartedCount = Started) and
    (S.SkippedCount = Skipped) and (S.IsActive = Active) and
    (S.IsCancelled = Cancelled), Name);
end;

procedure TestFixedRate;
var
  S: TPeriodicSchedule;
  T: TPeriodicTick;
begin
  S := TPeriodicSchedule.Create(0, 1000);
  try
    CheckState(S, 1000, 0, 0, False, False, 'INITIAL_STATE');
    Check(not S.TryAcquire(999, T), 'NO_EARLY_EXECUTION');
    Check(S.TryAcquire(1040, T), 'FIRST_ACQUIRE');
    Check((T.Index = 1) and (T.DeadlineUs = 1000) and
      (T.StartedUs = 1040), 'ORIGINAL_DEADLINE');
    Check(not S.TryAcquire(1040, T), 'NO_OVERLAP');
    S.Complete(3200);
    Check(S.NextDeadlineUs = 4000, 'FIXED_RATE_NO_DRIFT');
    CheckState(S, 4000, 1, 2, False, False, 'OVERRUN_ACCOUNTING');
    Check(not S.TryAcquire(3999, T), 'NO_EARLY_AFTER_OVERRUN');
    Check(S.TryAcquire(4000, T), 'NEXT_ACQUIRE');
    Check(T.Index = 4, 'SKIPPED_INDICES');
    S.Complete(4000);
    CheckState(S, 5000, 2, 2, False, False, 'INSTANT_COMPLETION');
  finally
    S.Free
  end;
end;

procedure TestLateAndBoundary;
var
  S: TPeriodicSchedule;
  T: TPeriodicTick;
begin
  S := TPeriodicSchedule.Create(100, 1000);
  try
    Check(S.TryAcquire(3650, T), 'LATE_ACQUIRE');
    Check((T.Index = 3) and (T.DeadlineUs = 3100) and
      (T.StartedUs = 3650), 'LATEST_DUE_ONLY');
    CheckState(S, 3100, 1, 2, True, False, 'LATE_ACCOUNTING');
    S.Complete(4100);
    CheckState(S, 5100, 1, 3, False, False, 'BOUNDARY_IS_SKIPPED');
    Check(S.TryAcquire(10100, T), 'SECOND_LATE_ACQUIRE');
    Check(T.Index = 10, 'SECOND_LATEST_INDEX');
    S.Complete(10100);
    CheckState(S, 11100, 2, 8, False, False, 'CYCLE_RECONCILIATION');
  finally
    S.Free
  end;
end;

procedure TestCancellation;
var
  S: TPeriodicSchedule;
  T: TPeriodicTick;
begin
  S := TPeriodicSchedule.Create(0, 10);
  try
    S.Cancel;
    S.Cancel;
    Check(not S.TryAcquire(100, T), 'CANCEL_BEFORE_START');
    CheckState(S, 10, 0, 0, False, True, 'CANCEL_STICKY_IDLE');
  finally
    S.Free
  end;
  S := TPeriodicSchedule.Create(0, 10);
  try
    Check(S.TryAcquire(10, T), 'START_BEFORE_CANCEL');
    S.Cancel;
    S.Complete(25);
    CheckState(S, 30, 1, 1, False, True, 'COMPLETE_AFTER_CANCEL');
    Check(not S.TryAcquire(30, T), 'CANCEL_STICKY_COMPLETE');
  finally
    S.Free
  end;
end;

procedure TestInvalidConstruction;
var
  S: TPeriodicSchedule;
  Raised: Boolean;
  N: Integer;
  E, P: Int64;
begin
  for N := 1 to 5 do
  begin
    E := 0;
    P := 1;
    case N of
      1:
        E := -1;
      2:
        P := 0;
      3:
        P := -1;
      4:
        E := High(Int64);
      5:
      begin
        E := 1;
        P := High(Int64)
      end;
    end;
    Raised := False;
    S := nil;
    try
      try
        S := TPeriodicSchedule.Create(E, P);
      except
        on ERangeError do
          Raised := True
      end;
    finally
      S.Free
    end;
    Check(Raised, 'INVALID_CONSTRUCTOR_' + IntToStr(N));
  end;
end;

procedure TestBackwardAndUsage;
var
  S: TPeriodicSchedule;
  T: TPeriodicTick;
  Raised: Boolean;
begin
  S := TPeriodicSchedule.Create(100, 100);
  try
    Raised := False;
    try
      S.TryAcquire(99, T);
    except
      on ERangeError do
        Raised := True
    end;
    Check(Raised, 'BEFORE_EPOCH_REJECTED');
    CheckState(S, 200, 0, 0, False, False, 'BEFORE_EPOCH_ATOMIC');
    Check(not S.TryAcquire(150, T), 'OBSERVE_EARLY_TIME');
    Raised := False;
    try
      S.TryAcquire(149, T);
    except
      on ERangeError do
        Raised := True
    end;
    Check(Raised, 'BACKWARD_IDLE_REJECTED');
    CheckState(S, 200, 0, 0, False, False, 'BACKWARD_IDLE_ATOMIC');
    Raised := False;
    try
      S.Complete(10000);
    except
      on Exception do
        Raised := True
    end;
    Check(Raised, 'UNMATCHED_COMPLETE_REJECTED');
    CheckState(S, 200, 0, 0, False, False, 'UNMATCHED_COMPLETE_ATOMIC');
    Check(S.TryAcquire(200, T), 'USAGE_FAILURE_PRESERVES_CLOCK');
    Check(not S.TryAcquire(250, T), 'ACTIVE_OBSERVES_TIME');
    Raised := False;
    try
      S.Complete(249);
    except
      on ERangeError do
        Raised := True
    end;
    Check(Raised, 'BACKWARD_COMPLETE_REJECTED');
    CheckState(S, 200, 1, 0, True, False, 'BACKWARD_COMPLETE_ATOMIC');
    Raised := False;
    try
      S.TryAcquire(249, T);
    except
      on ERangeError do
        Raised := True
    end;
    Check(Raised, 'BACKWARD_ACTIVE_REJECTED');
    S.Complete(250);
    CheckState(S, 300, 1, 0, False, False, 'RECOVER_FROM_BACKWARD_TIME');
    Raised := False;
    try
      S.TryAcquire(249, T);
    except
      on ERangeError do
        Raised := True
    end;
    Check(Raised, 'COMPLETE_OBSERVES_TIME');
  finally
    S.Free
  end;
end;

procedure TestOverflowAtomicity;
var
  S: TPeriodicSchedule;
  T: TPeriodicTick;
  Raised: Boolean;
begin
  S := TPeriodicSchedule.Create(High(Int64) - 20, 10);
  try
    Check(S.TryAcquire(High(Int64) - 10, T), 'HIGH_EPOCH_ACQUIRE');
    Raised := False;
    try
      S.Complete(High(Int64));
    except
      on ERangeError do
        Raised := True
    end;
    Check(Raised, 'DEADLINE_OVERFLOW_REJECTED');
    CheckState(S, High(Int64) - 10, 1, 0, True, False,
      'DEADLINE_OVERFLOW_ATOMIC');
    S.Complete(High(Int64) - 1);
    CheckState(S, High(Int64), 1, 0, False, False,
      'OVERFLOW_PRESERVES_OBSERVED_TIME');
    Check(S.TryAcquire(High(Int64), T), 'FINAL_REPRESENTABLE_DEADLINE');
    Check(T.Index = 2, 'HIGH_EPOCH_INDEX');
  finally
    S.Free
  end;
  S := TPeriodicSchedule.Create(0, 1);
  try
    Check(S.TryAcquire(High(Int64) - 1, T), 'HIGH_INDEX_ACQUIRE');
    Check(T.Index = High(Int64) - 1, 'HIGH_INDEX_EXACT');
    Check(S.SkippedCount = High(Int64) - 2, 'HIGH_SKIPPED_COUNT');
    Raised := False;
    try
      S.Complete(High(Int64));
    except
      on ERangeError do
        Raised := True
    end;
    Check(Raised, 'INDEX_OVERFLOW_REJECTED');
    CheckState(S, High(Int64) - 1, 1, High(Int64) - 2, True, False,
      'INDEX_OVERFLOW_ATOMIC');
    S.Complete(High(Int64) - 1);
    Check(S.TryAcquire(High(Int64), T), 'MAX_INDEX_ACQUIRE');
    Check((T.Index = High(Int64)) and (S.StartedCount = 2),
      'MAX_INDEX_RECONCILIATION');
  finally
    S.Free
  end;
end;

procedure TestRebase;
var
  S: TPeriodicSchedule;
  T: TPeriodicTick;
  Segment: TPeriodicSegment;
  Raised: Boolean;
begin
  S := TPeriodicSchedule.Create(0, 100);
  try
    Check(S.TryAcquire(250, T), 'REBASE_INITIAL_ACQUIRE');
    S.Complete(250);
    S.Rebase(10000);
    CheckState(S, 10100, 1, 1, False, False, 'REBASE_RETAINS_AGGREGATES');
    Check((S.EpochUs = 10000) and (S.DiscontinuityCount = 1), 'REBASE_METADATA');
    Segment := S.LastSegment;
    Check((Segment.Generation = 0) and (Segment.EpochUs = 0) and
      (Segment.EndedUs = 10000) and (Segment.StartedCount = 1) and
      (Segment.SkippedCount = 1), 'REBASE_SEGMENT_SNAPSHOT');
    Check(not S.TryAcquire(10099, T), 'REBASE_NO_REPLAY_OR_EARLY');
    Check(S.TryAcquire(10100, T) and (T.Index = 1) and (T.Segment = 1), 'REBASE_NEW_SEGMENT');
    Raised := False;
    try
      S.Rebase(20000);
    except
      on Exception do
        Raised := True;
    end;
    Check(Raised and S.IsActive and (S.EpochUs = 10000), 'REBASE_ACTIVE_REJECTED');
    Raised := False;
    try
      S.CompleteAndRebase(High(Int64));
    except
      on ERangeError do
        Raised := True;
    end;
    Check(Raised and S.IsActive and (S.DiscontinuityCount = 1), 'REBASE_ACTIVE_OVERFLOW_ATOMIC');
    S.CompleteAndRebase(100000);
    CheckState(S, 100100, 2, 1, False, False, 'REBASE_ACTIVE_EXCLUDES_SLEEP_SKIPS');
    Segment := S.LastSegment;
    Check((S.DiscontinuityCount = 2) and (Segment.Generation = 1) and
      (Segment.StartedCount = 1) and (Segment.SkippedCount = 0), 'REBASE_ACTIVE_SEGMENT');
    Segment := S.CurrentSegment;
    Check((Segment.Generation = 2) and (Segment.EpochUs = 100000) and
      (Segment.StartedCount = 0) and (Segment.SkippedCount = 0), 'REBASE_CURRENT_SEGMENT');
    Raised := False;
    try
      S.CompleteAndRebase(200000);
    except
      on Exception do
        Raised := True;
    end;
    Check(Raised and (S.EpochUs = 100000), 'REBASE_UNMATCHED_COMPLETE');
    Raised := False;
    try
      S.Rebase(99999);
    except
      on ERangeError do
        Raised := True;
    end;
    Check(Raised and (S.DiscontinuityCount = 2), 'REBASE_BACKWARD_ATOMIC');
    Raised := False;
    try
      S.Rebase(High(Int64));
    except
      on ERangeError do
        Raised := True;
    end;
    Check(Raised and (S.EpochUs = 100000), 'REBASE_OVERFLOW_ATOMIC');
    S.Cancel;
    S.Rebase(200000);
    Check(S.IsCancelled and not S.TryAcquire(200100, T), 'REBASE_CANCEL_STICKY');
  finally
    S.Free;
  end;
end;

begin
  Checks := 0;
  try
    TestFixedRate;
    TestLateAndBoundary;
    TestCancellation;
    TestInvalidConstruction;
    TestBackwardAndUsage;
    TestOverflowAtomicity;
    TestRebase;
    WriteLn('PASS ScheduleTests checks=', Checks);
  except
    on E: Exception do
    begin
      WriteLn('UNEXPECTED EXCEPTION: ', E.ClassName, ': ', E.Message);
      Halt(2);
    end;
  end;
end.
