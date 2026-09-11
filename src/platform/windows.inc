type
  TCreateTimerEx = function(Attributes: Pointer; Name: PWideChar;
    Flags, Access: DWORD): THandle; stdcall;

constructor TPlatformTimer.Create;
var CreateEx: TCreateTimerEx;
begin
  inherited Create;
  if not QueryPerformanceFrequency(FFrequency) or (FFrequency <= 0) then
    raise EOSError.Create('QueryPerformanceFrequency failed');
  FCancel := CreateEvent(nil, True, False, nil);
  if FCancel = 0 then RaiseLastOSError;
  FNotify := CreateEvent(nil, False, False, nil);
  if FNotify = 0 then RaiseLastOSError;
  CreateEx := TCreateTimerEx(GetProcAddress(GetModuleHandle('kernel32.dll'),
    'CreateWaitableTimerExW'));
  if Assigned(CreateEx) then
  begin
    FTimer := CreateEx(nil, nil, 2, $001F0003);
    FHighResolution := FTimer <> 0;
  end;
  if FTimer = 0 then FTimer := CreateWaitableTimer(nil, False, nil);
  if FTimer = 0 then RaiseLastOSError;
end;

destructor TPlatformTimer.Destroy;
begin
  if FTimer <> 0 then CloseHandle(FTimer);
  if FCancel <> 0 then CloseHandle(FCancel);
  if FNotify <> 0 then CloseHandle(FNotify);
  inherited Destroy;
end;

function TPlatformTimer.NowUs: Int64;
var Counter: Int64;
begin
  if not QueryPerformanceCounter(Counter) then RaiseLastOSError;
  Result := Scale(Counter, 1000000, FFrequency, False);
end;

function TPlatformTimer.WaitUntilOrWake(ADeadlineUs: Int64): TTimerWaitResult;
var Handles: array[0..2] of THandle; Status: DWORD;
    Remaining, Due, Current: Int64;
begin
  Handles[0] := FCancel; { cancellation wins simultaneous readiness }
  Handles[1] := FNotify;
  Handles[2] := FTimer;
  while True do
  begin
    Status := WaitForSingleObject(FCancel, 0);
    if Status = WAIT_OBJECT_0 then Exit(twCancelled);
    if Status <> WAIT_TIMEOUT then RaiseLastOSError;
    Current := NowUs;
    if Current >= ADeadlineUs then Exit(twDeadline);
    Status := WaitForSingleObject(FNotify, 0);
    if Status = WAIT_OBJECT_0 then
    begin
      if WaitForSingleObject(FCancel, 0) = WAIT_OBJECT_0 then Exit(twCancelled);
      Exit(twNotified);
    end;
    if Status <> WAIT_TIMEOUT then RaiseLastOSError;
    Remaining := ADeadlineUs - Current;
    if Remaining <= 0 then Exit(twDeadline);
    if Remaining > High(Int64) div 10 then
      raise ERangeError.Create('Windows relative deadline overflow');
    Due := -(Remaining * 10);
    if not SetWaitableTimer(FTimer, Due, 0, nil, nil, False) then
      RaiseLastOSError;
    Status := WaitForMultipleObjects(3, @Handles[0], False, INFINITE);
    if Status = WAIT_OBJECT_0 then Exit(twCancelled);
    if Status = WAIT_OBJECT_0 + 1 then
    begin
      if WaitForSingleObject(FCancel, 0) = WAIT_OBJECT_0 then Exit(twCancelled);
      if NowUs >= ADeadlineUs then
      begin
        Notify; { retain the consumed hint when the deadline wins }
        Exit(twDeadline);
      end;
      Exit(twNotified);
    end;
    if Status <> WAIT_OBJECT_0 + 2 then RaiseLastOSError;
    { Notifications are hints; always recheck the monotonic deadline. }
  end;
end;

procedure TPlatformTimer.Notify;
begin
  if not SetEvent(FNotify) then RaiseLastOSError;
end;

procedure TPlatformTimer.Cancel;
begin
  if not SetEvent(FCancel) then RaiseLastOSError;
end;

function TPlatformTimer.BackendName: string;
begin
  if FHighResolution then Result := 'windows-qpc-waitable-high-resolution'
  else Result := 'windows-qpc-waitable-standard';
end;
