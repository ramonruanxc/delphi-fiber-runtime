unit FiberRuntime.Context;

{$IFNDEF FPC}
{$MESSAGE FATAL 'Context experiment requires FPC 3.2.2'}
{$ENDIF}
{$IFDEF FPC}
{$MODE DELPHI}
{$H+}
{$IF FPC_FULLVERSION <> 30202}
{$FATAL Context experiment requires FPC 3.2.2}
{$ENDIF}
{$ENDIF}
{$IFDEF MSWINDOWS}
{$DEFINE WINDOWS}
{$ENDIF}
{$IFDEF WINDOWS}
{$IFDEF CPU386}
{$IFNDEF FPC_USE_WIN32_SEH}
{$FATAL Context requires native Win32 SEH}
{$ENDIF}
{$ELSE}
{$IFDEF CPUX86_64}
{$IFNDEF FPC_USE_WIN64_SEH}
{$FATAL Context requires native Win64 SEH}
{$ENDIF}
{$ELSE}
{$FATAL Unsupported Windows context CPU}
{$ENDIF}
{$ENDIF}
{$ELSE}
{$IFDEF LINUX}
{$IFNDEF CPUX86_64}
{$FATAL Linux context requires x86_64}
{$ENDIF}
{$ELSE}
{$IFDEF DARWIN}
{$IFNDEF CPUX86_64}
{$IFNDEF CPUAARCH64}
{$FATAL Unsupported Darwin context CPU}
{$ENDIF}
{$ENDIF}
{$ELSE}
{$FATAL Unsupported context platform}
{$ENDIF}
{$ENDIF}
{$ENDIF}

interface

uses
  SysUtils;

type
  EFiberUsage = class(Exception);
  EFiberCancelled = class(Exception);
  TFiberState = (fsCreated, fsRunning, fsSuspended, fsCompleted, fsCancelled, fsFaulted);
  TFiberTask = class;
  TFiberProc = procedure(ATask: TFiberTask; AData: Pointer);
  { Internal, unmanaged snapshot. Layout is private to this experiment. }
  TContextRTL = record
    Bottom: Pointer;
    Length: SizeUInt;
    {$IFNDEF WINDOWS}
    Head: PExceptAddr;
    {$ENDIF}
  end;

  TFiberRuntime = class
  private
    FOwner: TThreadID;
    FChildren: SizeInt;
    FAttached: Boolean;
    FRoot: Pointer;
    FCurrent: TFiberTask;
    FRTL: TContextRTL;
    procedure CheckOwner;
  public
    constructor Create;
    destructor Destroy; override;
    procedure BeforeDestruction; override;
    function CreateTask(AProc: TFiberProc; AData: Pointer;
      AStackBytes: NativeUInt = 262144): TFiberTask;
    function BackendName: string;
  end;

  TFiberTask = class
  private
    FRuntime: TFiberRuntime;
    FNative: Pointer;
    FRegistered: Boolean;
    FProc: TFiberProc;
    FData, FLocalValue: Pointer;
    FState: TFiberState;
    FCancelRequested: Boolean;
    FErrorClass, FErrorMessage: string;
    FRTL: TContextRTL;
    { Tasks are created only by their runtime factory. }
    {$PUSH}
    {$WARN 3018 OFF}
    constructor Create(ARuntime: TFiberRuntime; AProc: TFiberProc;
      AData: Pointer; AStackBytes: NativeUInt);
    {$POP}
    procedure CheckOwner;
    procedure Execute;
    procedure DoYield;
    function GetState: TFiberState;
    function GetCancelRequested: Boolean;
    function GetErrorClass: string;
    function GetErrorMessage: string;
    function GetLocalValue: Pointer;
    procedure SetLocalValue(Value: Pointer);
  public
    destructor Destroy; override;
    procedure BeforeDestruction; override;
    procedure Resume;
    procedure Yield;
    procedure Cancel;
    procedure CheckCancelled;
    property State: TFiberState read GetState;
    property CancelRequested: Boolean read GetCancelRequested;
    property ErrorClass: string read GetErrorClass;
    property ErrorMessage: string read GetErrorMessage;
    { Borrowed application pointer; never freed by the runtime. }
    property LocalValue: Pointer read GetLocalValue write SetLocalValue;
  end;

implementation

{$IFDEF WINDOWS}

uses
  Windows;
  {$ENDIF}

threadvar
  AttachedRuntime: TFiberRuntime;

  {$I context/fpc322-rtl.inc}
  {$IFDEF WINDOWS}
  {$I context/windows.inc}
  {$ELSE}
  {$I context/unix.inc}
  {$ENDIF}

procedure RequireNoHandler;
begin
  if RaiseList <> nil then
    raise EFiberUsage.Create('Context switching during exception handling is prohibited');
end;

procedure TFiberRuntime.CheckOwner;
begin
  if GetCurrentThreadID <> FOwner then
    raise EFiberUsage.Create('Runtime operation belongs to its creating thread');
end;

constructor TFiberRuntime.Create;
begin
  inherited Create;
  FOwner := GetCurrentThreadID;
  if AttachedRuntime <> nil then
    raise EFiberUsage.Create('A runtime is already attached to this thread');
  RequireNoHandler;
  NativeAttach(Self);
  FAttached := True;
  AttachedRuntime := Self;
end;

procedure TFiberRuntime.BeforeDestruction;
begin
  CheckOwner;
  if FChildren <> 0 then
    raise EFiberUsage.Create('Free every task before destroying its runtime');
  inherited BeforeDestruction;
end;

destructor TFiberRuntime.Destroy;
begin
  { Failed constructors bypass BeforeDestruction in pinned FPC; register last. }
  if FAttached then
  begin
    NativeDetach(Self);
    AttachedRuntime := nil;
  end;
  inherited Destroy;
end;

function TFiberRuntime.CreateTask(AProc: TFiberProc; AData: Pointer;
  AStackBytes: NativeUInt): TFiberTask;
begin
  CheckOwner;
  if not Assigned(AProc) then
    raise EFiberUsage.Create('Task callback is required');
  if (AStackBytes < 65536) or (AStackBytes > 67108864) then
    raise EFiberUsage.Create('Task stack must be between 65536 and 67108864 bytes');
  Result := TFiberTask.Create(Self, AProc, AData, AStackBytes);
end;

function TFiberRuntime.BackendName: string;
begin
  CheckOwner;
  Result := NativeBackend;
end;

constructor TFiberTask.Create(ARuntime: TFiberRuntime; AProc: TFiberProc;
  AData: Pointer; AStackBytes: NativeUInt);
begin
  inherited Create;
  FRuntime := ARuntime;
  FProc := AProc;
  FData := AData;
  FState := fsCreated;
  NativeCreate(Self, AStackBytes);
  Inc(FRuntime.FChildren);
  FRegistered := True;
end;

procedure TFiberTask.CheckOwner;
begin
  FRuntime.CheckOwner;
end;

procedure TFiberTask.BeforeDestruction;
begin
  CheckOwner;
  if FState in [fsRunning, fsSuspended] then
    raise EFiberUsage.Create('A live task must finish before destruction');
  inherited BeforeDestruction;
end;

destructor TFiberTask.Destroy;
begin
  if FNative <> nil then
    NativeDestroy(Self);
  if FRegistered then
    Dec(FRuntime.FChildren);
  inherited Destroy;
end;

procedure TFiberTask.Resume;
var
  Previous: TFiberState;
  Code: LongInt;
begin
  CheckOwner;
  if FRuntime.FCurrent <> nil then
    raise EFiberUsage.Create('Resume belongs to the carrier');
  if not (FState in [fsCreated, fsSuspended]) then
    raise EFiberUsage.Create('Task cannot resume in this state');
  RequireNoHandler;
  Previous := FState;
  FState := fsRunning;
  FRuntime.FCurrent := Self;
  Code := NativeResume(Self);
  FRuntime.FCurrent := nil;
  if Code <> 0 then
  begin
    { A native error can also follow a successful switch; preserve terminal state. }
    if FState = fsRunning then
      FState := Previous;
    raise EFiberUsage.CreateFmt('Native context resume failed (%d)', [Code]);
  end;
end;

procedure TFiberTask.Yield;
begin
  CheckOwner;
  {$IFNDEF CONTEXT_PROVE_IDENTITY}
  if FRuntime.FCurrent <> Self then
    raise EFiberUsage.Create('Yield belongs to the executing task');
  {$ENDIF}
  if FRuntime.FCurrent = nil then
    raise EFiberUsage.Create('No task is executing');
  RequireNoHandler;
  { Routing through the active context keeps the identity mutation non-crashing. }
  FRuntime.FCurrent.DoYield;
end;

procedure TFiberTask.DoYield;
var
  Code: LongInt;
begin
  FState := fsSuspended;
  FRuntime.FCurrent := nil;
  Code := NativeYield(Self);
  FRuntime.FCurrent := Self;
  FState := fsRunning;
  if Code <> 0 then
    raise EFiberUsage.CreateFmt('Native context yield failed (%d)', [Code]);
  CheckCancelled;
end;

procedure TFiberTask.Cancel;
begin
  CheckOwner;
  FCancelRequested := True;
  if FState = fsCreated then
    FState := fsCancelled;
end;

procedure TFiberTask.CheckCancelled;
begin
  CheckOwner;
  if FCancelRequested then
    raise EFiberCancelled.Create('Task cancellation requested');
end;

procedure TFiberTask.Execute;
begin
  try
    try
      FProc(Self, FData);
      FState := fsCompleted;
    except
      on E: EFiberCancelled do
        FState := fsCancelled;
      on E: Exception do
      begin
        FState := fsFaulted;
        FErrorClass := E.ClassName;
        FErrorMessage := E.Message;
      end;
      else
      begin
        FState := fsFaulted;
        FErrorClass := 'TObject';
        FErrorMessage := 'Non-Exception Pascal object raised';
      end;
    end;
  except
    { Even failure to copy an exception must not unwind into the C/native entry. }
    FState := fsFaulted;
    FErrorClass := 'Exception';
    FErrorMessage := 'Could not copy callback error';
  end;
end;

function TFiberTask.GetState: TFiberState;
begin
  CheckOwner;
  Result := FState;
end;

function TFiberTask.GetCancelRequested: Boolean;
begin
  CheckOwner;
  Result := FCancelRequested;
end;

function TFiberTask.GetErrorClass: string;
begin
  CheckOwner;
  Result := FErrorClass;
end;

function TFiberTask.GetErrorMessage: string;
begin
  CheckOwner;
  Result := FErrorMessage;
end;

function TFiberTask.GetLocalValue: Pointer;
begin
  CheckOwner;
  Result := FLocalValue;
end;

procedure TFiberTask.SetLocalValue(Value: Pointer);
begin
  CheckOwner;
  FLocalValue := Value;
end;

end.
