const
  EVFILT_TIMER = -7;
  EVFILT_USER = -10;
  EV_ADD = $1;
  EV_ENABLE = $4;
  EV_ONESHOT = $10;
  EV_CLEAR = $20;
  EV_ERROR = $4000;
  NOTE_ABSOLUTE = $8;
  NOTE_CRITICAL = $20;
  NOTE_MACHTIME = $100;
  NOTE_TRIGGER = $01000000;
  EINTR = 4;
type
  TNativeTimespec = record Seconds, Nanoseconds: Int64; end;
  TTimebase = record Numerator, Denominator: Cardinal; end;
  TKEvent64 = record
    Ident: UInt64;
    Filter: SmallInt;
    Flags: Word;
    FFlags: Cardinal;
    Data: Int64;
    UData: UInt64;
    Ext: array[0..1] of UInt64;
  end;
function NativeAbsoluteTime: UInt64;
  cdecl; external 'c' name 'mach_absolute_time';
function NativeTimebase(var Info: TTimebase): Integer;
  cdecl; external 'c' name 'mach_timebase_info';
function NativeKQueue: Integer; cdecl; external 'c' name 'kqueue';
function NativeKEvent(FD: Integer; Changes: Pointer; NChanges: Integer;
  Events: Pointer; NEvents: Integer; Flags: Cardinal; Timeout: Pointer): Integer;
  cdecl; external 'c' name 'kevent64';
function NativeClose(FD: Integer): Integer; cdecl; external 'c' name 'close';
function NativeErrno: PInteger; cdecl; external 'c' name '__error';
procedure NativeError(const Operation: string);
var Code: Integer;
begin
  Code := NativeErrno^;
  raise EOSError.CreateFmt('%s failed (errno %d)', [Operation, Code]);
end;
procedure SubmitEvent(FD: Integer; var Event: TKEvent64);
var Status: Integer;
begin
  repeat
    { No output buffer: submission cannot steal a waiting owner's event. }
    Status := NativeKEvent(FD, @Event, 1, nil, 0, 0, nil);
  until (Status >= 0) or (NativeErrno^ <> EINTR);
  if Status < 0 then NativeError('kevent64 submit');
end;

constructor TPlatformTimer.Create;
var Info: TTimebase; Event: TKEvent64;
begin
  inherited Create;
  FTimer := -1;
  FCancel := -1;
  if SizeOf(TKEvent64) <> 48 then
    raise Exception.Create('Invalid kevent64 ABI');
  if (NativeTimebase(Info) <> 0) or (Info.Numerator = 0) or
     (Info.Denominator = 0) then
    raise EOSError.Create('mach_timebase_info failed');
  FNumer := Info.Numerator;
  FDenom := Info.Denominator;
  FTimer := NativeKQueue;
  if FTimer < 0 then NativeError('kqueue');
  FillChar(Event, SizeOf(Event), 0);
  Event.Ident := 1;
  Event.Filter := EVFILT_USER;
  Event.Flags := EV_ADD or EV_ENABLE or EV_CLEAR;
  SubmitEvent(FTimer, Event);
  Event.Ident := 3;
  SubmitEvent(FTimer, Event);
end;

destructor TPlatformTimer.Destroy;
begin
  if FTimer >= 0 then NativeClose(FTimer);
  inherited Destroy;
end;

function TPlatformTimer.NowUs: Int64;
var Ticks: UInt64;
begin
  Ticks := NativeAbsoluteTime;
  if Ticks > UInt64(High(Int64)) then
    raise ERangeError.Create('Mach monotonic timestamp overflow');
  Result := Scale(Int64(Ticks), FNumer, Int64(FDenom) * 1000, False);
end;

function TPlatformTimer.WaitUntilOrWake(ADeadlineUs: Int64): TTimerWaitResult;
var Change, Event: TKEvent64; Status: Integer;
begin
  while True do
  begin
    if InterlockedCompareExchange(FCancelled, 0, 0) <> 0 then Exit(twCancelled);
    if NowUs >= ADeadlineUs then Exit(twDeadline);
    if InterlockedExchange(FNotified, 0) <> 0 then
    begin
      if InterlockedCompareExchange(FCancelled, 0, 0) <> 0 then Exit(twCancelled);
      Exit(twNotified);
    end;
    FillChar(Change, SizeOf(Change), 0);
    Change.Ident := 2;
    Change.Filter := EVFILT_TIMER;
    Change.Flags := EV_ADD or EV_ENABLE or EV_ONESHOT;
    { Ask the kernel to reduce timer coalescing; no realtime thread priority. }
    Change.FFlags := NOTE_ABSOLUTE or NOTE_MACHTIME or NOTE_CRITICAL;
    Change.Data := Scale(ADeadlineUs, Int64(FDenom) * 1000, FNumer, True);
    SubmitEvent(FTimer, Change);
    repeat
      Status := NativeKEvent(FTimer, nil, 0, @Event, 1, 0, nil);
    until (Status >= 0) or (NativeErrno^ <> EINTR);
    if Status < 0 then NativeError('kevent64 wait');
    if (Status > 0) and ((Event.Flags and EV_ERROR) <> 0) then
      raise EOSError.CreateFmt('kevent64 event failed (%d)', [Event.Data]);
    { Clock and sticky atomic flag are rechecked after every notification. }
  end;
end;

procedure TPlatformTimer.Notify;
var Event: TKEvent64;
begin
  { Publish a persistent predicate before triggering. Do not clear the kernel
    event here: a concurrent trigger between predicate drain and park must stay. }
  InterlockedExchange(FNotified, 1);
  FillChar(Event, SizeOf(Event), 0);
  Event.Ident := 3;
  Event.Filter := EVFILT_USER;
  Event.FFlags := NOTE_TRIGGER;
  SubmitEvent(FTimer, Event);
end;

procedure TPlatformTimer.Cancel;
var Event: TKEvent64;
begin
  InterlockedExchange(FCancelled, 1);
  FillChar(Event, SizeOf(Event), 0);
  Event.Ident := 1;
  Event.Filter := EVFILT_USER;
  Event.FFlags := NOTE_TRIGGER;
  SubmitEvent(FTimer, Event);
end;

function TPlatformTimer.BackendName: string;
begin
  Result := 'darwin-mach-kevent64-absolute-critical';
end;
