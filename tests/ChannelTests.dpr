program ChannelTests;
{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}
uses {$IFDEF UNIX}cthreads,{$ENDIF} SysUtils, Classes,
  FiberRuntime.Context, FiberRuntime.Scheduler, FiberRuntime.Channel;
type
  TFakeDriver = class(TSchedulerDriver)
    Time: Int64;
    function NowUs: Int64; override;
    procedure WaitUntil(DeadlineUs: Int64); override;
    procedure Wake; override;
  end;
  TOwnerProbe = class(TThread)
    Channel: TFiberChannel;
    Rejected: Integer;
    procedure Execute; override;
  end;
var
  Driver: TFakeDriver;
  Scheduler: TFiberScheduler;
  Channel: TFiberChannel;
  SenderDone, ReceiverDone, Cleanups: Integer;
  Received: array[0..3] of NativeInt;

procedure Check(Value: Boolean; const Name: string);
begin
  if not Value then begin WriteLn('ASSERTION FAILED: ', Name); Halt(1) end;
end;
function TFakeDriver.NowUs: Int64;
begin Result := Time end;
procedure TFakeDriver.WaitUntil(DeadlineUs: Int64);
begin if DeadlineUs > Time then Time := DeadlineUs end;
procedure TFakeDriver.Wake;
begin end;

procedure Setup(Capacity: Integer);
begin
  SenderDone := 0; ReceiverDone := 0; Cleanups := 0;
  Driver := TFakeDriver.Create;
  Scheduler := TFiberScheduler.Create(16, Driver);
  Channel := TFiberChannel.Create(Scheduler, Capacity);
end;
procedure Teardown;
begin
  Check(Scheduler.Stop(10000), 'CHANNEL_SCHEDULER_STOP');
  Channel.Free; Scheduler.Free; Driver.Free;
end;

procedure Sender(ATask: TScheduledTask; AData: Pointer);
begin
  try
    Check(Channel.Send(Pointer(3)), 'CHANNEL_SEND_AFTER_SPACE');
    Inc(SenderDone);
  finally Inc(Cleanups) end;
end;
procedure Drain(ATask: TScheduledTask; AData: Pointer);
var Value: Pointer; I: Integer;
begin
  Check(SenderDone = 0, 'CHANNEL_FULL_SENDER_PARKED');
  for I := 0 to 2 do begin
    Check(Channel.Receive(Value), 'CHANNEL_RECEIVE_VALUE');
    Received[I] := NativeInt(Value);
  end;
  Inc(ReceiverDone);
end;
procedure WaitReceive(ATask: TScheduledTask; AData: Pointer);
var Value: Pointer;
begin
  try
    Check(not Channel.Receive(Value), 'CHANNEL_CLOSED_RECEIVE');
    Check(Value = nil, 'CHANNEL_CLOSED_OUTPUT');
    Inc(ReceiverDone);
  finally Inc(Cleanups) end;
end;
procedure WaitSend(ATask: TScheduledTask; AData: Pointer);
begin
  try
    Check(not Channel.Send(Pointer(2)), 'CHANNEL_CLOSED_SEND');
    Inc(SenderDone);
  finally Inc(Cleanups) end;
end;
procedure CloseChannel(ATask: TScheduledTask; AData: Pointer);
begin Channel.Close end;
procedure DrainClosed(ATask: TScheduledTask; AData: Pointer);
var Value: Pointer;
begin
  Check(Channel.Receive(Value) and (Value = Pointer(1)), 'CHANNEL_CLOSE_DRAIN');
  Check(not Channel.Receive(Value), 'CHANNEL_CLOSE_DRAIN_END');
end;
procedure TOwnerProbe.Execute;
var Value: Pointer;
begin
  try Channel.TrySend(nil) except on EFiberUsage do Inc(Rejected) end;
  try Channel.Send(nil) except on EFiberUsage do Inc(Rejected) end;
  try Channel.Receive(Value) except on EFiberUsage do Inc(Rejected) end;
  try Channel.Close except on EFiberUsage do Inc(Rejected) end;
  try Channel.Discard except on EFiberUsage do Inc(Rejected) end;
  try Channel.Free except on EFiberUsage do Inc(Rejected) end;
end;

procedure TestFIFO;
begin
  Setup(2);
  Check(Channel.TrySend(Pointer(1)), 'CHANNEL_TRYSEND_FIRST');
  Check(Channel.TrySend(Pointer(2)), 'CHANNEL_TRYSEND_SECOND');
  Check(not Channel.TrySend(Pointer(9)), 'CHANNEL_NO_OVERWRITE');
  Scheduler.Spawn(Sender, nil); Scheduler.Spawn(Drain, nil);
  Check(Scheduler.RunUntil(100), 'CHANNEL_FIFO_SETTLED');
  Check((Received[0] = 1) and (Received[1] = 2) and (Received[2] = 3),
    'CHANNEL_FIFO');
  Check((SenderDone = 1) and (ReceiverDone = 1) and (Cleanups = 1),
    'CHANNEL_BACKPRESSURE_COMPLETE');
  Teardown;
end;
procedure TestClose;
begin
  Setup(1);
  Scheduler.Spawn(WaitReceive, nil); Scheduler.Spawn(CloseChannel, nil);
  Check(Scheduler.RunUntil(100), 'CHANNEL_CLOSE_WAKES_RECEIVER');
  Check((ReceiverDone = 1) and (Cleanups = 1), 'CHANNEL_RECEIVER_CLEANUP');
  Channel.Close;
  Check(not Channel.TrySend(nil), 'CHANNEL_CLOSED_TRYSEND');
  Teardown;
  Setup(1);
  Channel.TrySend(Pointer(1));
  Scheduler.Spawn(WaitSend, nil); Scheduler.Spawn(CloseChannel, nil);
  Check(Scheduler.RunUntil(100), 'CHANNEL_CLOSE_WAKES_SENDER');
  Check((SenderDone = 1) and (Cleanups = 1), 'CHANNEL_SENDER_CLEANUP');
  Scheduler.Spawn(DrainClosed, nil);
  Check(Scheduler.RunUntil(100), 'CHANNEL_DRAIN_SETTLED');
  Teardown;
end;
procedure TestCancellation;
var Task: TScheduledTask; Rejected: Boolean;
begin
  Setup(1);
  Task := Scheduler.Spawn(WaitReceive, nil);
  Check(not Scheduler.RunUntil(1), 'CHANNEL_EMPTY_PARKED');
  Rejected := False;
  try Channel.Free except on EFiberUsage do Rejected := True end;
  Check(Rejected, 'CHANNEL_FREE_WAITER_GUARD');
  Task.Cancel;
  Check(Scheduler.RunUntil(10), 'CHANNEL_CANCEL_RECEIVER_SETTLED');
  Check((Task.State = fsCancelled) and (Cleanups = 1), 'CHANNEL_CANCEL_FINALLY');
  { Free proves that cancellation removed the registered waiter. }
  Teardown;
  Setup(1); Channel.TrySend(Pointer(1));
  Task := Scheduler.Spawn(WaitSend, nil);
  Check(not Scheduler.RunUntil(1), 'CHANNEL_FULL_PARKED');
  Task.Cancel;
  Check(Scheduler.RunUntil(10), 'CHANNEL_CANCEL_SENDER_SETTLED');
  Check((Task.State = fsCancelled) and (Cleanups = 1), 'CHANNEL_SEND_FINALLY');
  Channel.Discard;
  Check(Channel.TrySend(nil), 'CHANNEL_DISCARD_MAKES_SPACE');
  Teardown;
end;
procedure TestOwnership;
var Probe: TOwnerProbe; Rejected: Boolean;
begin
  Setup(1);
  Probe := TOwnerProbe.Create(True);
  Probe.Channel := Channel; Probe.Start; Probe.WaitFor;
  Check(Probe.Rejected = 6, 'CHANNEL_FOREIGN_OWNER'); Probe.Free;
  Rejected := False;
  try TFiberChannel.Create(Scheduler, 0).Free
  except on ERangeError do Rejected := True end;
  Check(Rejected, 'CHANNEL_CAPACITY_GUARD');
  Check(Channel.TrySend(nil), 'CHANNEL_FOREIGN_FREE_PRESERVES_OBJECT');
  Teardown;
end;
procedure TestCarrierPredicates;
var Value: Pointer; Rejected: Boolean;
begin
  Setup(1);
  Check(Channel.Send(nil), 'CHANNEL_CARRIER_IMMEDIATE_SEND');
  Check(Channel.Receive(Value) and (Value = nil), 'CHANNEL_BORROWED_NIL');
  Rejected := False;
  try Channel.Receive(Value) except on EFiberUsage do Rejected := True end;
  Check(Rejected, 'CHANNEL_CARRIER_CANNOT_PARK');
  Channel.Close;
  Check(not Channel.Send(nil), 'CHANNEL_CARRIER_CLOSED_SEND');
  Check(not Channel.Receive(Value), 'CHANNEL_CARRIER_CLOSED_RECEIVE');
  Teardown;
end;
procedure IndexedSender(ATask: TScheduledTask; AData: Pointer);
begin
  try
    Check(Channel.Send(AData), 'CHANNEL_MULTIPLE_SENDER'); Inc(SenderDone);
  finally Inc(Cleanups) end;
end;
procedure DrainMany(ATask: TScheduledTask; AData: Pointer);
var Value: Pointer; I: Integer;
begin
  for I := 0 to 3 do begin
    Check(Channel.Receive(Value), 'CHANNEL_MULTIPLE_RECEIVE');
    Check(NativeInt(Value) = I, 'CHANNEL_MULTIPLE_FIFO');
  end;
end;
procedure TestMultipleWaiters;
var Tasks: array[0..2] of TScheduledTask; I: Integer;
begin
  Setup(1); Channel.TrySend(nil);
  for I := 0 to 2 do Tasks[I] := Scheduler.Spawn(IndexedSender, Pointer(I + 1));
  Check(not Scheduler.RunUntil(1), 'CHANNEL_MULTIPLE_PARKED');
  for I := 0 to 2 do begin
    Scheduler.WakeTask(Tasks[I]); Scheduler.WakeTask(Tasks[I]);
  end;
  Check(not Scheduler.RunUntil(2), 'CHANNEL_SPURIOUS_WAKE_RECHECK');
  Check(SenderDone = 0, 'CHANNEL_SPURIOUS_WAKE_NO_OVERWRITE');
  Scheduler.Spawn(DrainMany, nil);
  Check(Scheduler.RunUntil(3), 'CHANNEL_MULTIPLE_SETTLED');
  Check((SenderDone = 3) and (Cleanups = 3), 'CHANNEL_MULTIPLE_CLEANUP');
  Teardown;
  Setup(1);
  for I := 0 to 2 do Tasks[I] := Scheduler.Spawn(WaitReceive, nil);
  Check(not Scheduler.RunUntil(1), 'CHANNEL_MULTIPLE_EMPTY');
  Channel.Close; Tasks[1].Cancel;
  Check(Scheduler.RunUntil(2), 'CHANNEL_CLOSE_CANCEL_RACE');
  Check((ReceiverDone = 2) and (Cleanups = 3), 'CHANNEL_ALL_WAITERS_REMOVED');
  Teardown;
end;
begin
  TestCarrierPredicates; TestFIFO; TestClose; TestCancellation; TestOwnership;
  TestMultipleWaiters;
  WriteLn('PASS: channel FIFO, backpressure, close/drain, cancellation, ownership');
end.
