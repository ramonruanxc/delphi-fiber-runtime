program ContextDemo;

{$IFDEF FPC}
{$MODE DELPHI}
{$ENDIF}
{$APPTYPE CONSOLE}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  SysUtils,
  FiberRuntime.Context in '../src/FiberRuntime.Context.pas',
  FiberRuntime.Platform in '../src/FiberRuntime.Platform.pas';

const
  TaskCount = 16;
  YieldsPerTask = 1000;
  StackBytes = 262144;

type
  TWork = record
    YieldCount: Integer;
    LocalTag: Pointer;
  end;
  PWork = ^TWork;

procedure Work(ATask: TFiberTask; AData: Pointer);
var
  I: Integer;
  Context: PWork;
  Saved: NativeUInt;
begin
  Context := PWork(AData);
  Saved := NativeUInt(Context^.LocalTag) * 17;
  for I := 1 to YieldsPerTask do
  begin
    Inc(Context^.YieldCount);
    ATask.Yield;
    if (ATask.LocalValue <> Context^.LocalTag) or
      (Saved <> NativeUInt(Context^.LocalTag) * 17) then
      raise Exception.Create('Task-local or stack state corrupted');
  end;
end;

procedure CancelWork(ATask: TFiberTask; AData: Pointer);
begin
  try
    ATask.Yield;
  finally
    Inc(PInteger(AData)^);
  end;
end;

procedure Run;
var
  Runtime: TFiberRuntime;
  Timer: TPlatformTimer;
  Tasks: array[0..TaskCount - 1] of TFiberTask;
  Data: array[0..TaskCount - 1] of TWork;
  I, Round, Completed, Yielded, CancelCleanups: Integer;
  Started, Elapsed: Int64;
  CancelTask: TFiberTask;
begin
  FillChar(Tasks, SizeOf(Tasks), 0);
  FillChar(Data, SizeOf(Data), 0);
  Runtime := TFiberRuntime.Create;
  Timer := TPlatformTimer.Create;
  for I := 0 to TaskCount - 1 do
  begin
    Data[I].LocalTag := Pointer(NativeUInt(I + 1));
    Tasks[I] := Runtime.CreateTask(Work, @Data[I], StackBytes);
    Tasks[I].LocalValue := Data[I].LocalTag;
  end;
  Started := Timer.NowUs;
  for Round := 0 to YieldsPerTask do
    for I := 0 to TaskCount - 1 do
    begin
      Tasks[I].Resume;
      if Tasks[I].State in [fsFaulted, fsCancelled] then
        raise Exception.Create('Task failed: ' + Tasks[I].ErrorClass + ': ' +
          Tasks[I].ErrorMessage);
    end;
  Elapsed := Timer.NowUs - Started;
  Completed := 0;
  Yielded := 0;
  for I := 0 to TaskCount - 1 do
  begin
    if Tasks[I].State <> fsCompleted then
      raise Exception.Create('Task failed: ' + Tasks[I].ErrorClass + ': ' + Tasks[I].ErrorMessage);
    Inc(Completed);
    Inc(Yielded, Data[I].YieldCount);
    Tasks[I].Free;
  end;
  { Separate cancellation/cleanup demonstration, outside the timing window. }
  CancelCleanups := 0;
  CancelTask := Runtime.CreateTask(CancelWork, @CancelCleanups, StackBytes);
  CancelTask.Resume;
  CancelTask.Cancel;
  CancelTask.Resume;
  if (CancelTask.State <> fsCancelled) or (CancelCleanups <> 1) then
    raise Exception.Create('Cooperative cancellation did not finish cleanup');
  CancelTask.Free;
  WriteLn('{"format":"context-demo-v1","backend":"', Runtime.BackendName,
    '","tasks":', TaskCount, ',"completed":', Completed, ',"yields":', Yielded,
    ',"resume_calls":', TaskCount * (YieldsPerTask + 1), ',"elapsed_us":', Elapsed,
    ',"requested_stack_bytes_per_task":', StackBytes,
    ',"carrier_threads":1,"cancelled":1,"cancel_cleanup_count":', CancelCleanups, '}');
  Timer.Free;
  Runtime.Free;
end;

{$I ConsolePause.inc}

begin
  try
    Run;
  except
    on E: Exception do
    begin
      { A failed experiment exits; it never force-deletes a live stack. }
      WriteLn(E.ClassName, ': ', E.Message);
      PauseUnderDebugger;
      Halt(1);
    end;
  end;
  PauseUnderDebugger;
end.
