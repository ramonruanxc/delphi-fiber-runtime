program PlatformTests;
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$IFDEF MSWINDOWS}{$APPTYPE CONSOLE}{$ENDIF}
uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  {$IFDEF MSWINDOWS}Windows,{$ENDIF}
  SysUtils, Classes, FiberRuntime.Platform;
type
  TCancelThread = class(TThread)
  private
    FTimer: TPlatformTimer;
  protected
    procedure Execute; override;
  public
    ErrorText: string;
    constructor Create(ATimer: TPlatformTimer);
  end;
procedure Check(ACondition: Boolean; const AName: string);
begin
  if not ACondition then raise Exception.Create('FAIL: ' + AName);
end;
constructor TCancelThread.Create(ATimer: TPlatformTimer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FTimer := ATimer;
  Start;
end;
procedure TCancelThread.Execute;
var Delay: TPlatformTimer;
begin
  try
    Delay := TPlatformTimer.Create;
    try
      Delay.WaitUntil(Delay.NowUs + 20000);
      FTimer.Cancel;
      FTimer.Cancel;
    finally
      Delay.Free;
    end;
  except
    on E: Exception do ErrorText := E.Message;
  end;
end;
procedure TestClockAndDeadlines;
var Timer: TPlatformTimer; I: Integer; Previous, Current, Deadline: Int64;
begin
  Timer := TPlatformTimer.Create;
  try
    Check(Timer.BackendName <> '', 'backend name');
    Writeln('Backend: ', Timer.BackendName);
    Previous := Timer.NowUs;
    Check(Previous >= 0, 'nonnegative monotonic clock');
    for I := 1 to 1000 do
    begin
      Current := Timer.NowUs;
      Check(Current >= Previous, 'monotonic clock');
      Previous := Current;
    end;
    Check(Timer.WaitUntil(Previous - 1), 'past deadline');
    Check(Timer.WaitUntil(Low(Int64)), 'extreme past deadline');
    for I := 1 to 20 do
    begin
      Deadline := Timer.NowUs + 1000;
      Check(Timer.WaitUntil(Deadline), 'uncancelled wait');
      Check(Timer.NowUs >= Deadline, 'no early return');
    end;
  finally
    Timer.Free;
  end;
end;
procedure TestStickyCancellation;
var Timer: TPlatformTimer; I: Integer;
begin
  Timer := TPlatformTimer.Create;
  try
    Timer.Cancel;
    for I := 1 to 10 do
    begin
      Timer.Cancel;
      Check(not Timer.WaitUntil(Timer.NowUs - 1), 'cancel before past deadline');
      Check(not Timer.WaitUntil(Timer.NowUs + 1000000), 'sticky cancellation');
    end;
  finally
    Timer.Free;
  end;
end;
procedure TestConcurrentCancellation;
var Timer: TPlatformTimer; Worker: TCancelThread; Deadline: Int64;
begin
  Timer := TPlatformTimer.Create;
  try
    Deadline := Timer.NowUs + 5000000;
    Worker := TCancelThread.Create(Timer);
    try
      Check(not Timer.WaitUntil(Deadline), 'cross-thread cancellation wakeup');
      Check(Timer.NowUs < Deadline, 'cancel woke before five-second timer deadline');
      Worker.WaitFor;
      Check(Worker.ErrorText = '', 'cancel worker: ' + Worker.ErrorText);
      Check(not Timer.WaitUntil(0), 'cancellation stays set after wakeup');
    finally
      Worker.WaitFor;
      Worker.Free;
    end;
  finally
    Timer.Free;
  end;
end;
{$IFDEF MSWINDOWS}
function ProcessHandleCount(Process: THandle; var Count: DWORD): BOOL;
  stdcall; external 'kernel32.dll' name 'GetProcessHandleCount';
{$ENDIF}
function OpenResourceCount: Integer;
{$IFDEF MSWINDOWS}
var Count: DWORD;
begin
  if not ProcessHandleCount(GetCurrentProcess, Count) then RaiseLastOSError;
  Result := Count;
end;
{$ELSE}
var Search: TSearchRec;
begin
  Result := 0;
  {$IFDEF LINUX}
  if FindFirst('/proc/self/fd/*', faAnyFile, Search) <> 0 then
  {$ELSE}
  if FindFirst('/dev/fd/*', faAnyFile, Search) <> 0 then
  {$ENDIF}
    raise Exception.Create('Cannot inspect open descriptors');
  try
    repeat
      if (Search.Name <> '.') and (Search.Name <> '..') then Inc(Result);
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;
{$ENDIF}
procedure TestResourceChurn;
var Timer: TPlatformTimer; I, BeforeCount: Integer;
begin
  BeforeCount := OpenResourceCount;
  for I := 1 to 500 do
  begin
    Timer := TPlatformTimer.Create;
    try
      Check(Timer.WaitUntil(Timer.NowUs), 'churn wait');
      Timer.Cancel;
      Check(not Timer.WaitUntil(0), 'churn cancel');
    finally
      Timer.Free;
    end;
  end;
  Check(OpenResourceCount = BeforeCount, 'native resources released after churn');
end;
begin
  try
    TestClockAndDeadlines;
    TestStickyCancellation;
    TestConcurrentCancellation;
    TestResourceChurn;
    Writeln('PASS PlatformTests');
  except
    on E: Exception do
    begin
      Writeln(E.Message);
      Halt(1);
    end;
  end;
end.
