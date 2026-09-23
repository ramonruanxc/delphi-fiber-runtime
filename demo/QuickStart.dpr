program QuickStart;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}
{$APPTYPE CONSOLE}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  SysUtils,
  FiberRuntime.Context in '../src/FiberRuntime.Context.pas',
  FiberRuntime.Schedule in '../src/FiberRuntime.Schedule.pas',
  FiberRuntime.Platform in '../src/FiberRuntime.Platform.pas',
  FiberRuntime.Scheduler in '../src/FiberRuntime.Scheduler.pas',
  FiberRuntime.ServiceHooks in '../src/FiberRuntime.ServiceHooks.pas',
  FiberRuntime.Service in '../src/FiberRuntime.Service.pas',
  FiberRuntime.EventHub in '../src/FiberRuntime.EventHub.pas';

type
  IMessage = interface
    ['{3DBB67CE-7E53-42CF-8B34-998B0E017D5E}']
    function Text: string;
  end;

  TMessage = class(TInterfacedObject, IMessage)
  private
    FText: string;
  public
    constructor Create(const AText: string);
    function Text: string;
  end;

var
  Scheduler: TFiberScheduler;
  Hub: TFiberEventHub;
  Producer: TFiberService;
  Receiver: TFiberService;
  Publisher: TServiceEndpoint;
  Subscription: TServiceSubscription;
  Received: Integer;
  LastMessage: string;

constructor TMessage.Create(const AText: string);
begin
  inherited Create;
  FText := AText;
end;

function TMessage.Text: string;
begin
  Result := FText;
end;

procedure PublishTick(Task: TScheduledTask; const Tick: TPeriodicTick;
  Data: Pointer);
var
  Message: IMessage;
begin
  Message := TMessage.Create('Hello from tick ' + IntToStr(Tick.Index));
  if not Publisher.Publish(Message) then
    raise Exception.Create('Event capacity exhausted');
  Task.Delay(5000);  { Other tasks can run during this 5 ms wait. }
end;

procedure ReceiveMessage(Task: TScheduledTask; Source: TServiceEndpoint;
  const Payload: IInterface; Data: Pointer);
begin
  LastMessage := (Payload as IMessage).Text;
  Inc(Received);
end;

procedure DormantTick(Task: TScheduledTask; const Tick: TPeriodicTick;
  Data: Pointer);
begin
  { The recipient owns a subscription but does not start periodic work. }
end;

procedure StopAll;
begin
  { This runs on the scheduler owner, outside callbacks. Stop also cancels
    waits and settles events attributed to each source or recipient. }
  if Producer <> nil then
    Producer.Cancel;
  if Receiver <> nil then
    Receiver.Cancel;
  if Producer <> nil then
    if not Producer.Stop(1000000) then
      raise Exception.Create('Producer stop timed out; resources retained');
  if Receiver <> nil then
    if not Receiver.Stop(1000000) then
      raise Exception.Create('Receiver stop timed out; resources retained');
  if Scheduler <> nil then
    if not Scheduler.Stop(1000000) then
      raise Exception.Create('Scheduler stop timed out; resources retained');
end;

procedure CheckTask(Task: TScheduledTask);
begin
  if Task.State = fsFaulted then
    raise Exception.Create(Task.ErrorClass + ': ' + Task.ErrorMessage);
end;

procedure Run;
begin
  try
    Scheduler := TFiberScheduler.Create(2);
    Hub := TFiberEventHub.Create(Scheduler, 16, 1);
    Producer := TFiberService.Create(Scheduler, 50000, PublishTick, nil);
    Receiver := TFiberService.Create(Scheduler, 50000, DormantTick, nil);
    Publisher := Hub.Attach(Producer);
    Subscription := Hub.Subscribe(Hub.Attach(Receiver), ReceiveMessage, nil);

    Producer.Start;
    { False is normal here: the periodic task and subscription stay alive. }
    Scheduler.RunUntil(Scheduler.NowUs + 275000);
    StopAll;

    CheckTask(Producer.Task);
    CheckTask(Subscription.Task);
    if (Received = 0) or (Hub.PendingCount <> 0) or (Hub.ActiveCount <> 0) or
       (Hub.AdmittedCount <> Hub.DeliveredCount + Hub.DiscardedCount +
        Hub.AbortedCount) then
      raise Exception.Create('Event delivery did not settle correctly');

    WriteLn('Last message: ', LastMessage);
    WriteLn('period_us=50000 started=', Producer.StartedCount,
      ' skipped=', Producer.SkippedCount);
    WriteLn('published=', Hub.PublishedCount, ' received=', Received,
      ' discarded=', Hub.DiscardedCount, ' aborted=', Hub.AbortedCount);
    WriteLn('PASS: QuickStart services and managed events stopped cleanly');
  finally
    { If StopAll raises, none of these Free calls execute. In a long-running
      application retain these objects and borrowed callback data, then retry
      Stop on this owner thread. This console demo exits nonzero instead. }
    StopAll;
    Producer.Free;
    Receiver.Free;
    Hub.Free;
    Scheduler.Free;
  end;
end;

{$I ConsolePause.inc}

begin
  try
    Run;
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput, E.ClassName, ': ', E.Message);
      PauseUnderDebugger;
      Halt(1);
    end;
  end;
  PauseUnderDebugger;
end.
