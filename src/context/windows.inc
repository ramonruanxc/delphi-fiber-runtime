const
  ContextFloatSwitch = 1;

type
  TNativeFiberEntry = procedure(Data: Pointer); stdcall;

function ContextConvertThread(Data: Pointer; Flags: DWORD): Pointer; stdcall;
  external 'kernel32.dll' name 'ConvertThreadToFiberEx';
function ContextConvertBack: BOOL; stdcall;
  external 'kernel32.dll' name 'ConvertFiberToThread';
function ContextCreateFiber(Commit, Reserve: SIZE_T; Flags: DWORD;
  Entry: TNativeFiberEntry; Data: Pointer): Pointer; stdcall;
  external 'kernel32.dll' name 'CreateFiberEx';
procedure ContextSwitchFiber(Fiber: Pointer); stdcall;
  external 'kernel32.dll' name 'SwitchToFiber';
procedure ContextDeleteFiber(Fiber: Pointer); stdcall;
  external 'kernel32.dll' name 'DeleteFiber';

{$IFDEF FPC}
{$PUSH}
{$S-}
{$ENDIF}
procedure NativeEntry(Data: Pointer); stdcall;
var
  Task: TFiberTask;
begin
  Task := TFiberTask(Data);
  {$IFDEF FPC}
  { StackTop reads the native TIB. Requested reserve rounds to 64 KiB;
    metadata is conservative when the EXE default commit makes the OS reserve
    more. Bounds tests do not qualify guard-page/stack-overflow recovery. }
  Task.FRTL.Bottom := PByte(System.StackTop) - Task.FRTL.Length;
  {$ENDIF}
  InstallRTL(Task.FRTL);
  Task.Execute;
  SwitchRTL(Task.FRTL, Task.FRuntime.FRTL);
  ContextSwitchFiber(Task.FRuntime.FRoot);
  { Terminal contexts are never resumed. Native fiber entries must not return. }
  Halt(255);
end;

function NativeResume(Task: TFiberTask): LongInt;
begin
  SwitchRTL(Task.FRuntime.FRTL, Task.FRTL);
  ContextSwitchFiber(Task.FNative);
  InstallRTL(Task.FRuntime.FRTL);
  Result := 0;
end;

function NativeYield(Task: TFiberTask): LongInt;
begin
  SwitchRTL(Task.FRTL, Task.FRuntime.FRTL);
  ContextSwitchFiber(Task.FRuntime.FRoot);
  InstallRTL(Task.FRTL);
  Result := 0;
end;
{$IFDEF FPC}
{$POP}
{$ENDIF}

procedure NativeAttach(Runtime: TFiberRuntime);
begin
  Runtime.FRoot := ContextConvertThread(nil, ContextFloatSwitch);
  if Runtime.FRoot = nil then
    raise EFiberUsage.CreateFmt('ConvertThreadToFiberEx failed (%d)', [GetLastError]);
end;

procedure NativeDetach(Runtime: TFiberRuntime);
begin
  if not ContextConvertBack then
    raise EFiberUsage.CreateFmt('ConvertFiberToThread failed (%d)', [GetLastError]);
end;

procedure NativeCreate(Task: TFiberTask; Bytes: NativeUInt);
begin
  Task.FRTL.Length := ((Bytes + 65535) div 65536) * 65536;
  Task.FNative := ContextCreateFiber(0, Task.FRTL.Length, ContextFloatSwitch, NativeEntry, Task);
  if Task.FNative = nil then
    raise EFiberUsage.CreateFmt('CreateFiberEx failed (%d)', [GetLastError]);
end;

procedure NativeDestroy(Task: TFiberTask);
begin
  ContextDeleteFiber(Task.FNative);
  Task.FNative := nil;
end;

function NativeBackend: string;
begin
  Result := 'windows-native-fibers-float-switch';
end;
