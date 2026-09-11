program PeriodicDemo;


{$IFDEF FPC}
{$MODE DELPHI}
{$ENDIF}
{$APPTYPE CONSOLE}

uses
  {$IFDEF FPC}
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  {$ENDIF}
  SysUtils,
  FiberRuntime.Schedule in '../src/FiberRuntime.Schedule.pas',
  FiberRuntime.Platform in '../src/FiberRuntime.Platform.pas';

type
  TSample = record
    Tick: TPeriodicTick;
    FinishUs: Int64;
  end;

function Option(const AName: string; ADefault: Int64): Int64;
var
  I: Integer;
begin
  Result := ADefault;
  for I := 1 to ParamCount do
    if ParamStr(I) = AName then
    begin
      if I = ParamCount then
        raise Exception.Create('Missing value for ' + AName);
      Result := StrToInt64(ParamStr(I + 1));
    end;
end;

procedure Run;
var
  Timer: TPlatformTimer;
  Schedule: TPeriodicSchedule;
  Samples: array of TSample;
  Tick: TPeriodicTick;
  Cycles, PeriodUs, WorkUs, EpochUs, NowUs, EndUs, FinishUs: Int64;
  Count, I: Integer;
begin
  Cycles := Option('--cycles', 5000);
  PeriodUs := Option('--period-us', 1000);
  WorkUs := Option('--work-us', 0);
  if (Cycles < 1) or (Cycles > 1000000) or (PeriodUs < 1) or
    (PeriodUs > 1000000) or (WorkUs < 0) or (WorkUs > 1000000) then
    raise Exception.Create(
      'Options out of range: cycles 1..1000000, period-us 1..1000000, work-us 0..1000000');
  SetLength(Samples, Integer(Cycles));
  Timer := TPlatformTimer.Create;
  try
    { Warm native paths, then separate a 10ms startup margin from samples. }
    Timer.WaitUntil(Timer.NowUs + 10000);
    EpochUs := Timer.NowUs + 10000;
    EndUs := EpochUs + (Cycles + 1) * PeriodUs;
    Schedule := TPeriodicSchedule.Create(EpochUs, PeriodUs);
    try
      Count := 0;
      while Schedule.NextDeadlineUs < EndUs do
      begin
        if not Timer.WaitUntil(Schedule.NextDeadlineUs) then
          raise Exception.Create('Unexpected benchmark cancellation');
        NowUs := Timer.NowUs;
        if NowUs >= EndUs then
          Break;
        if Schedule.TryAcquire(NowUs, Tick) then
        begin
          { Deliberate synthetic CPU workload; never used to poll for a timer. }
          if WorkUs > 0 then
            while Timer.NowUs - NowUs < WorkUs do ;
          FinishUs := Timer.NowUs;
          Samples[Count].Tick := Tick;
          Samples[Count].FinishUs := FinishUs;
          Inc(Count);
          Schedule.Complete(FinishUs);
        end;
      end;
      WriteLn('# format=periodic-v1');
      WriteLn('# backend=', Timer.BackendName);
      {$IFDEF FPC}
      WriteLn('# compiler=FPC ', {$I %FPCVERSION%});
      {$ELSE}
      WriteLn('# compiler=Delphi');
      {$ENDIF}
      WriteLn('# epoch_us=', EpochUs);
      WriteLn('# period_us=', PeriodUs);
      WriteLn('# planned_cycles=', Cycles);
      WriteLn('# started_cycles=', Count);
      WriteLn('# skipped_cycles=', Cycles - Count);
      WriteLn('# work_us=', WorkUs);
      WriteLn('index,deadline_us,start_us,finish_us');
      for I := 0 to Count - 1 do
        WriteLn(Samples[I].Tick.Index, ',', Samples[I].Tick.DeadlineUs, ',',
          Samples[I].Tick.StartedUs, ',', Samples[I].FinishUs);
    finally
      Schedule.Free;
    end;
  finally
    Timer.Free;
  end;
end;

begin
  try
    Run;
  except
    on E: Exception do
    begin
      WriteLn(E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
