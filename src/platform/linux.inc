const
  CLOCK_MONOTONIC = 1;
  NATIVE_NONBLOCK = $800;
  NATIVE_CLOEXEC = $80000;
  EINTR = 4;
  EAGAIN = 11;
  POLLIN = 1;
  POLL_FAILURE = $38;
type
  TNativeTimespec = record Seconds, Nanoseconds: Int64; end;
  TTimerSpec = record Interval, Value: TNativeTimespec; end;
  TPollFD = record FD: Integer; Events, Returned: SmallInt; end;
function NativeClockGetTime(ID: Integer; var Value: TNativeTimespec): Integer;
  cdecl; external 'c' name 'clock_gettime';
function NativeTimerCreate(ID, Flags: Integer): Integer;
  cdecl; external 'c' name 'timerfd_create';
function NativeTimerSet(FD, Flags: Integer; var Value: TTimerSpec;
  OldValue: Pointer): Integer; cdecl; external 'c' name 'timerfd_settime';
function NativeEventCreate(Value: Cardinal; Flags: Integer): Integer;
  cdecl; external 'c' name 'eventfd';
function NativePoll(FDs: Pointer; Count: NativeUInt; Timeout: Integer): Integer;
  cdecl; external 'c' name 'poll';
function NativeWrite(FD: Integer; const Value; Count: NativeUInt): NativeInt;
  cdecl; external 'c' name 'write';
function NativeClose(FD: Integer): Integer; cdecl; external 'c' name 'close';
function NativeErrno: PInteger; cdecl; external 'c' name '__errno_location';
procedure NativeError(const Operation: string);
var Code: Integer;
begin
  Code := NativeErrno^;
  raise EOSError.CreateFmt('%s failed (errno %d)', [Operation, Code]);
end;

constructor TPlatformTimer.Create;
begin
  inherited Create;
  FTimer := -1;
  FCancel := -1;
  FTimer := NativeTimerCreate(CLOCK_MONOTONIC, NATIVE_NONBLOCK or NATIVE_CLOEXEC);
  if FTimer < 0 then NativeError('timerfd_create');
  FCancel := NativeEventCreate(0, NATIVE_NONBLOCK or NATIVE_CLOEXEC);
  if FCancel < 0 then NativeError('eventfd');
end;

destructor TPlatformTimer.Destroy;
begin
  if FTimer >= 0 then NativeClose(FTimer);
  if FCancel >= 0 then NativeClose(FCancel);
  inherited Destroy;
end;

function TPlatformTimer.NowUs: Int64;
var Value: TNativeTimespec;
begin
  if NativeClockGetTime(CLOCK_MONOTONIC, Value) <> 0 then
    NativeError('clock_gettime');
  if (Value.Seconds < 0) or (Value.Seconds > High(Int64) div 1000000) or
     (Value.Nanoseconds < 0) or (Value.Nanoseconds >= 1000000000) then
    raise ERangeError.Create('Invalid monotonic timestamp');
  Result := Value.Seconds * 1000000;
  if Result > High(Int64) - Value.Nanoseconds div 1000 then
    raise ERangeError.Create('Monotonic timestamp overflow');
  Result := Result + Value.Nanoseconds div 1000;
end;

function TPlatformTimer.WaitUntil(ADeadlineUs: Int64): Boolean;
var FDs: array[0..1] of TPollFD; Spec: TTimerSpec; Status: Integer;
begin
  FillChar(FDs, SizeOf(FDs), 0);
  FDs[0].FD := FCancel;
  FDs[0].Events := POLLIN;
  FDs[1].FD := FTimer;
  FDs[1].Events := POLLIN;
  while True do
  begin
    repeat
      Status := NativePoll(@FDs[0], 1, 0);
    until (Status >= 0) or (NativeErrno^ <> EINTR);
    if Status < 0 then NativeError('poll cancel');
    if (FDs[0].Returned and POLL_FAILURE) <> 0 then
      raise EOSError.Create('Cancellation descriptor failure');
    if (FDs[0].Returned and POLLIN) <> 0 then Exit(False);
    if NowUs >= ADeadlineUs then Exit(True);
    FillChar(Spec, SizeOf(Spec), 0);
    Spec.Value.Seconds := ADeadlineUs div 1000000;
    Spec.Value.Nanoseconds := (ADeadlineUs mod 1000000) * 1000;
    repeat
      Status := NativeTimerSet(FTimer, 1, Spec, nil);
    until (Status >= 0) or (NativeErrno^ <> EINTR);
    if Status <> 0 then NativeError('timerfd_settime');
    repeat
      Status := NativePoll(@FDs[0], 2, -1);
    until (Status >= 0) or (NativeErrno^ <> EINTR);
    if Status < 0 then NativeError('poll wait');
    if ((FDs[0].Returned or FDs[1].Returned) and POLL_FAILURE) <> 0 then
      raise EOSError.Create('Native wait descriptor failure');
    if (FDs[0].Returned and POLLIN) <> 0 then Exit(False);
    { Rearming clears any old timer expiration; cancellation is never drained. }
  end;
end;

procedure TPlatformTimer.Cancel;
var Value: UInt64; Count: NativeInt;
begin
  Value := 1;
  repeat
    Count := NativeWrite(FCancel, Value, SizeOf(Value));
  until (Count >= 0) or (NativeErrno^ <> EINTR);
  if (Count < 0) and (NativeErrno^ = EAGAIN) then Exit; { already signaled }
  if Count <> SizeOf(Value) then NativeError('eventfd write');
end;

function TPlatformTimer.BackendName: string;
begin
  Result := 'linux-monotonic-timerfd-eventfd';
end;
