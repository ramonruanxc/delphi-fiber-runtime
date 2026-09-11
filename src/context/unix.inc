{$LINKLIB fr_context}
{$LINKLIB c}
{$LINKLIB m}
{$LINKLIB pthread}

type
  TNativeEntry = procedure(Data: Pointer); cdecl;

function fr_context_create(Entry: TNativeEntry; Data: Pointer; Bytes: SizeUInt): Pointer;
  cdecl; external;
function fr_context_resume(Context: Pointer): LongInt; cdecl; external;
function fr_context_yield(Context: Pointer): LongInt; cdecl; external;
function fr_context_destroy(Context: Pointer): LongInt; cdecl; external;
function fr_context_backend: PAnsiChar; cdecl; external;
function fr_context_stack_bottom(Context: Pointer): Pointer; cdecl; external;
function fr_context_stack_size(Context: Pointer): SizeUInt; cdecl; external;

{$PUSH}
{$S-}
procedure NativeEntry(Data: Pointer); cdecl;
var
  Task: TFiberTask;
begin
  Task := TFiberTask(Data);
  Task.Execute;
  { Execute has returned: all its exception/managed frames have been removed. }
  SwitchRTL(Task.FRTL, Task.FRuntime.FRTL);
  { Return normally into C, which performs the final jump to the carrier. }
end;

function NativeResume(Task: TFiberTask): LongInt;
begin
  SwitchRTL(Task.FRuntime.FRTL, Task.FRTL);
  Result := fr_context_resume(Task.FNative);
  { Native errors may precede OR follow the switch. Restore before any raising. }
  InstallRTL(Task.FRuntime.FRTL);
end;

function NativeYield(Task: TFiberTask): LongInt;
begin
  SwitchRTL(Task.FRTL, Task.FRuntime.FRTL);
  Result := fr_context_yield(Task.FNative);
  InstallRTL(Task.FRTL);
end;
{$POP}

procedure NativeAttach(Runtime: TFiberRuntime);
var
  Manager: TThreadManager;
begin
  GetThreadManager(Manager);
  { Stock NoThreadManager returns the constant thread ID 1 and shares RTL TLS.
    Do not silently initialize it late: Unix consumers must use cthreads first. }
  if not Assigned(Manager.InitManager) then
    raise EFiberUsage.Create('Unix context requires cthreads first in the program uses list');
  Runtime.FRoot := nil;
end;

procedure NativeDetach(Runtime: TFiberRuntime);
begin
end;

procedure NativeCreate(Task: TFiberTask; Bytes: NativeUInt);
begin
  Task.FNative := fr_context_create(NativeEntry, Task, Bytes);
  if Task.FNative = nil then
    raise EFiberUsage.Create('Native context allocation failed');
  Task.FRTL.Bottom := fr_context_stack_bottom(Task.FNative);
  Task.FRTL.Length := fr_context_stack_size(Task.FNative);
  Task.FRTL.Head := nil;
end;

procedure NativeDestroy(Task: TFiberTask);
var
  Code: LongInt;
begin
  Code := fr_context_destroy(Task.FNative);
  if Code <> 0 then
    raise EFiberUsage.CreateFmt('Native context destroy failed (%d)', [Code]);
  Task.FNative := nil;
end;

function NativeBackend: string;
begin
  Result := string(fr_context_backend);
end;
