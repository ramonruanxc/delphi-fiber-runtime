program NotificationTests;

{$IFDEF FPC}
{$MODE DELPHI}
{$ENDIF}
{$IFDEF MSWINDOWS}
{$APPTYPE CONSOLE}
{$ENDIF}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}
  SysUtils,
  Classes,
  SyncObjs,
  FiberRuntime.Platform;

type
  TProducer = class(TThread)
  public
    Timer: TPlatformTimer;
    Request, Published: TEvent;
    Iterations: Integer;
    DelayUs: Int64;
    Count: LongInt;
    ErrorText: string;
    constructor Create(ATimer: TPlatformTimer; AIterations: Integer; ADelayUs: Int64);
    destructor Destroy; override;
    procedure Execute; override;
  end;

procedure Check(Value: Boolean; const Name: string);
begin
  if not Value then
    raise Exception.Create('FAIL: ' + Name);
end;

constructor TProducer.Create(ATimer: TPlatformTimer; AIterations: Integer; ADelayUs: Int64);
begin
  inherited Create(True);
  Timer := ATimer;
  Iterations := AIterations;
  DelayUs := ADelayUs;
  Request := TEvent.Create(nil, False, False, '');
  Published := TEvent.Create(nil, False, False, '');
  Start;
end;

destructor TProducer.Destroy;
begin
  WaitFor;
  Request.Free;
  Published.Free;
  inherited Destroy;
end;

procedure TProducer.Execute;
var
  I: Integer;
  Delay: TPlatformTimer;
begin
  try
    Delay := TPlatformTimer.Create;
    try
      for I := 1 to Iterations do
      begin
        Check(Request.WaitFor(5000) = wrSignaled, 'producer request handshake');
        if DelayUs > 0 then
          Delay.WaitUntil(Delay.NowUs + DelayUs);
        InterlockedIncrement(Count);
        Timer.Notify;
        Published.SetEvent;
      end;
    finally
      Delay.Free;
    end;
  except
    on E: Exception do
      ErrorText := E.Message;
  end;
end;

procedure TestPrepostedAndCoalesced;
var
  Timer: TPlatformTimer;
  I: Integer;
  Deadline: Int64;
begin
  Timer := TPlatformTimer.Create;
  try
    for I := 1 to 100 do
      Timer.Notify;
    Check(Timer.WaitUntilOrWake(Timer.NowUs + 5000000) = twNotified, 'preposted notification');
    Deadline := Timer.NowUs + 1000;
    Check(Timer.WaitUntilOrWake(Deadline) = twDeadline, 'notifications coalesced');
    Check(Timer.NowUs >= Deadline, 'deadline never early');
    Timer.Notify;
    Check(Timer.WaitUntilOrWake(0) = twDeadline, 'deadline priority');
    Check(Timer.WaitUntilOrWake(Timer.NowUs + 5000000) = twNotified,
      'expired deadline preserves notification');
    Timer.Notify;
    Deadline := Timer.NowUs + 1000;
    Check(Timer.WaitUntil(Deadline), 'legacy ignores notification');
    Check(Timer.NowUs >= Deadline, 'legacy deadline never early');
    Timer.Notify;
    Timer.Cancel;
    for I := 1 to 100 do
    begin
      Timer.Notify;
      Timer.Cancel;
      Check(Timer.WaitUntilOrWake(0) = twCancelled, 'cancel wins deadline');
      Check(Timer.WaitUntilOrWake(Timer.NowUs + 5000000) = twCancelled,
        'cancel sticky and wins notification');
      Check(not Timer.WaitUntil(0), 'legacy cancel sticky');
    end;
  finally
    Timer.Free;
  end;
end;

procedure TestHandshake(Iterations: Integer; DelayUs: Int64; Preposted: Boolean);
var
  Timer: TPlatformTimer;
  Producer: TProducer;
  I: Integer;
begin
  Timer := TPlatformTimer.Create;
  try
    Producer := TProducer.Create(Timer, Iterations, DelayUs);
    try
      for I := 1 to Iterations do
      begin
        Producer.Request.SetEvent;
        if Preposted then
          Check(Producer.Published.WaitFor(5000) = wrSignaled, 'preposted handshake');
        Check(Timer.WaitUntilOrWake(Timer.NowUs + 5000000) = twNotified,
          'publish drain park wake');
        Check(InterlockedCompareExchange(Producer.Count, 0, 0) = I,
          'publication visible after wake');
        if not Preposted then
          Check(Producer.Published.WaitFor(5000) = wrSignaled, 'producer completion handshake');
      end;
      Producer.WaitFor;
      Check(Producer.ErrorText = '', Producer.ErrorText);
      Check(Timer.WaitUntilOrWake(Timer.NowUs + 1000) = twDeadline,
        'no stale notification after handshake');
    finally
      Producer.Free;
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
var
  Count: DWORD;
begin
  if not ProcessHandleCount(GetCurrentProcess, Count) then
    RaiseLastOSError;
  Result := Count;
end;
{$ELSE}
var
  Search: TSearchRec;
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
      if (Search.Name <> '.') and (Search.Name <> '..') then
        Inc(Result);
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;
{$ENDIF}

procedure TestClockIntervals;
var
  Guard: TClockContinuityGuard;
  Timer: TPlatformTimer;
  I: Integer;
  Generation: Int64;
  Raised: Boolean;
begin
  Guard := TClockContinuityGuard.Create;
  try
    Check(Guard.Observe(10000, 10000, 10001) = 0, 'clock baseline');
    Check(Guard.Observe(11000, 11000, 11005) = 0, 'paired sample uncertainty');
    Check(Guard.Observe(12000, 13000, 12000) = 0, 'suspend tolerance boundary');
    Check(Guard.Observe(13000, 14001, 13000) = 1, 'suspend offset generation');
    Check(Guard.Observe(14000, 15001, 14000) = 1, 'suspend generation sticky');
    Check(Guard.Observe(15000, 17002, 15000) = 2, 'second suspension generation');
    Raised := False;
    try
      Guard.Observe(14000, 18000, 14000);
    except
      on E: EClockDiscontinuity do
        Raised := E.Message = 'CLOCK_PAIR_BACKWARD';
    end;
    Check(Raised, 'backward active clock rejected');
  finally
    Guard.Free;
  end;
  Guard := TClockContinuityGuard.Create;
  try
    Raised := False;
    try
      Guard.Observe(0, 500, 1001);
    except
      on E: EClockDiscontinuity do
        Raised := E.Message = 'CLOCK_SAMPLE_UNCERTAIN';
    end;
    Check(Raised, 'uncertain sample rejected');
    Guard.Observe(10000, 20000, 10000);
    Raised := False;
    try
      Guard.Observe(20000, 21000, 20000);
    except
      on E: EClockDiscontinuity do
        Raised := E.Message = 'CLOCK_OFFSET_BACKWARD';
    end;
    Check(Raised, 'backward pair offset rejected');
  finally
    Guard.Free;
  end;
  Guard := TClockContinuityGuard.Create;
  try
    Check(Guard.Observe(0, 0, 0) = 0, 'zero clock baseline');
    Check(Guard.Observe(100000000, 100000000, 100001000) = 0,
      'long descheduling and maximum sample width are not suspension');
    Raised := False;
    try
      Guard.Observe(100002000, 99999999, 100002000);
    except
      on E: EClockDiscontinuity do
        Raised := E.Message = 'CLOCK_PAIR_BACKWARD';
    end;
    Check(Raised, 'backward inclusive clock rejected');
  finally
    Guard.Free;
  end;
  Timer := TPlatformTimer.Create;
  try
    Generation := Timer.SuspendGeneration;
    Writeln('Suspend detection available: ', Timer.SuspendDetectionAvailable);
    for I := 1 to 1000 do
      Check(Timer.SuspendGeneration = Generation, 'native paired clock no false suspend');
  finally
    Timer.Free;
  end;
end;

procedure TestChurn;
var
  Timer: TPlatformTimer;
  I, Before: Integer;
begin
  Before := OpenResourceCount;
  for I := 1 to 500 do
  begin
    Timer := TPlatformTimer.Create;
    try
      Timer.Notify;
      Check(Timer.WaitUntilOrWake(Timer.NowUs + 5000000) = twNotified, 'churn notify');
      Timer.Cancel;
      Check(Timer.WaitUntilOrWake(0) = twCancelled, 'churn cancel');
    finally
      Timer.Free;
    end;
  end;
  Check(OpenResourceCount = Before, 'native notification resources released');
end;

begin
  try
    TestPrepostedAndCoalesced;
    TestHandshake(100, 0, True);
    TestHandshake(1000, 0, False);
    TestHandshake(10, 10000, False);
    TestChurn;
    TestClockIntervals;
    Writeln('PASS NotificationTests');
  except
    on E: Exception do
    begin
      Writeln(E.Message);
      Halt(1);
    end;
  end;
end.
