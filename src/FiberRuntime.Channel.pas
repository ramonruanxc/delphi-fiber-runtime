unit FiberRuntime.Channel;

{$IFDEF FPC}
{$MODE DELPHI}
{$ENDIF}

interface

uses
  FiberRuntime.Scheduler;

type
  TFiberChannel = class
  private
    FScheduler: TFiberScheduler;
    FValues: array of Pointer;
    FSenders, FReceivers: array of TScheduledTask;
    FHead, FCount, FWaiters: Integer;
    FClosed: Boolean;
    function RequireTask: TScheduledTask;
    function RegisterWaiter(var Waiters: array of TScheduledTask;
      Task: TScheduledTask): Integer;
    procedure RemoveWaiter(var Waiters: array of TScheduledTask; Slot: Integer);
    procedure WakeAll(const Waiters: array of TScheduledTask);
  public
    constructor Create(AScheduler: TFiberScheduler; ACapacity: Integer);
    procedure BeforeDestruction; override;
    function TrySend(AValue: Pointer): Boolean;
    function Send(AValue: Pointer): Boolean;
    function Receive(out AValue: Pointer): Boolean;
    procedure Close;
    procedure Discard;
  end;

implementation

uses
  SysUtils,
  FiberRuntime.Context;

constructor TFiberChannel.Create(AScheduler: TFiberScheduler; ACapacity: Integer);
begin
  inherited Create;
  if AScheduler = nil then
    raise EFiberUsage.Create('Channel requires scheduler');
  AScheduler.CheckOwner;
  if ACapacity <= 0 then
    raise ERangeError.Create('Channel capacity must be positive');
  FScheduler := AScheduler;
  SetLength(FValues, ACapacity);
  { Every task can register at most one wait while suspended. }
  SetLength(FSenders, FScheduler.MaxTasks);
  SetLength(FReceivers, FScheduler.MaxTasks);
end;

procedure TFiberChannel.BeforeDestruction;
begin
  if FScheduler <> nil then
    FScheduler.CheckOwner;
  if FWaiters <> 0 then
    raise EFiberUsage.Create('Channel has active waiters');
  inherited;
end;

function TFiberChannel.RequireTask: TScheduledTask;
begin
  FScheduler.CheckOwner;
  Result := FScheduler.CurrentTask;
  if Result = nil then
    raise EFiberUsage.Create('Channel wait requires current task');
  Result.CheckCancelled;
end;

function TFiberChannel.RegisterWaiter(var Waiters: array of TScheduledTask;
  Task: TScheduledTask): Integer;
var
  I: Integer;
begin
  for I := 0 to High(Waiters) do
    if Waiters[I] = nil then
    begin
      Waiters[I] := Task;
      Inc(FWaiters);
      Result := I;
      Exit;
    end;
  raise EFiberUsage.Create('Channel waiter capacity exhausted');
end;

procedure TFiberChannel.RemoveWaiter(var Waiters: array of TScheduledTask;
  Slot: Integer);
begin
  Waiters[Slot] := nil;
  Dec(FWaiters)
end;

procedure TFiberChannel.WakeAll(const Waiters: array of TScheduledTask);
var
  I: Integer;
begin
  for I := 0 to High(Waiters) do
    if Waiters[I] <> nil then
      FScheduler.WakeTask(Waiters[I]);
end;

function TFiberChannel.TrySend(AValue: Pointer): Boolean;
begin
  FScheduler.CheckOwner;
  Result := False;
  if FClosed or (FCount = Length(FValues)) then
    Exit;
  FValues[(FHead + FCount) mod Length(FValues)] := AValue;
  Inc(FCount);
  WakeAll(FReceivers);
  Result := True;
end;

function TFiberChannel.Send(AValue: Pointer): Boolean;
var
  Task: TScheduledTask;
  Slot: Integer;
begin
  FScheduler.CheckOwner;
  Task := FScheduler.CurrentTask;
  if Task <> nil then
    Task.CheckCancelled;
  while not FClosed do
  begin
    if TrySend(AValue) then
    begin
      Result := True;
      Exit
    end;
    Task := RequireTask;
    Slot := RegisterWaiter(FSenders, Task);
    try
      Task.Park
    finally
      RemoveWaiter(FSenders, Slot)
    end;
  end;
  Result := False;
end;

function TFiberChannel.Receive(out AValue: Pointer): Boolean;
var
  Task: TScheduledTask;
  Slot: Integer;
begin
  FScheduler.CheckOwner;
  AValue := nil;
  Task := FScheduler.CurrentTask;
  if Task <> nil then
    Task.CheckCancelled;
  while FCount = 0 do
  begin
    if FClosed then
    begin
      Result := False;
      Exit
    end;
    Task := RequireTask;
    Slot := RegisterWaiter(FReceivers, Task);
    try
      Task.Park
    finally
      RemoveWaiter(FReceivers, Slot)
    end;
  end;
  AValue := FValues[FHead];
  FValues[FHead] := nil;
  FHead := (FHead + 1) mod Length(FValues);
  Dec(FCount);
  WakeAll(FSenders);
  Result := True;
end;

procedure TFiberChannel.Close;
begin
  FScheduler.CheckOwner;
  FClosed := True;
  WakeAll(FSenders);
  WakeAll(FReceivers);
end;

procedure TFiberChannel.Discard;
begin
  FScheduler.CheckOwner;
  while FCount <> 0 do
  begin
    FValues[FHead] := nil;
    FHead := (FHead + 1) mod Length(FValues);
    Dec(FCount);
  end;
  WakeAll(FSenders);
end;

end.
