program EventHubTests;
{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}
uses {$IFDEF UNIX}cthreads,{$ENDIF} SysUtils, Classes,
  FiberRuntime.Context, FiberRuntime.Schedule, FiberRuntime.Scheduler,
  FiberRuntime.Service, FiberRuntime.EventHub;
type
  TFakeDriver = class(TSchedulerDriver)
    Time: Int64;
    FailWake: Boolean;
    function NowUs: Int64; override;
    procedure WaitUntil(DeadlineUs: Int64); override;
    procedure Wake; override;
  end;
  TPayload = class(TInterfacedObject)
    destructor Destroy; override;
  end;
  TPoster = class(TThread)
    Token: TServiceEndpoint;
    Value: IInterface;
    Accepted: Boolean;
    procedure Execute; override;
  end;
  TOwnerProbe = class(TThread)
    Token: TServiceEndpoint;
    Rejected: Integer;
    procedure Execute; override;
  end;
var
  Driver: TFakeDriver;
  Scheduler: TFiberScheduler;
  Hub: TFiberEventHub;
  Publisher, Recipient: TFiberService;
  Source, Target: TServiceEndpoint;
  Payload: IInterface;
  Handlers, Finished, Destroyed: Integer;
  SuspendHandler: Boolean;

procedure Check(Value: Boolean; const Name: string);
begin if not Value then begin WriteLn('ASSERTION FAILED: ', Name); Halt(1) end end;
function TFakeDriver.NowUs: Int64;
begin Result := Time end;
procedure TFakeDriver.WaitUntil(DeadlineUs: Int64);
begin if DeadlineUs > Time then Time := DeadlineUs end;
procedure TFakeDriver.Wake;
begin if FailWake then raise Exception.Create('injected notify failure') end;
destructor TPayload.Destroy;
begin Inc(Destroyed); inherited end;
procedure TPoster.Execute;
begin Accepted := Token.Post(Value); Value := nil end;
procedure TOwnerProbe.Execute;
begin
  try Token.Publish(nil) except on EFiberUsage do Inc(Rejected) end;
  try Token.BeginStop except on EFiberUsage do Inc(Rejected) end;
  try Token.Detach except on EFiberUsage do Inc(Rejected) end;
  try Token.Free except on EFiberUsage do Inc(Rejected) end;
end;
procedure Idle(Task: TScheduledTask; const Tick: TPeriodicTick; Data: Pointer);
begin end;
procedure Handle(Task: TScheduledTask; Sender: TServiceEndpoint;
  const Value: IInterface; Data: Pointer);
begin
  Check((Sender = Source) and (Value <> nil), 'EVENT_IDENTITY'); Inc(Handlers);
  try if SuspendHandler then begin Task.Yield; Task.Delay(100) end
  finally Inc(Finished) end;
end;
procedure Setup(Capacity: Integer = 4);
begin
  Handlers := 0; Finished := 0; Destroyed := 0; SuspendHandler := False;
  Driver := TFakeDriver.Create; Scheduler := TFiberScheduler.Create(16, Driver);
  Hub := TFiberEventHub.Create(Scheduler, Capacity, 4);
  Publisher := TFiberService.Create(Scheduler, 1000, Idle, nil);
  Recipient := TFiberService.Create(Scheduler, 1000, Idle, nil);
  Source := Hub.Attach(Publisher); Target := Hub.Attach(Recipient);
  Hub.Subscribe(Target, Handle, nil);
end;
procedure Teardown;
begin
  Payload := nil;
  if Publisher <> nil then begin Check(Publisher.Stop(1000), 'EVENT_PUBLISHER_STOP'); Publisher.Free end;
  Check(Recipient.Stop(1000), 'EVENT_RECIPIENT_STOP'); Recipient.Free;
  Check(Scheduler.RunUntil(Driver.Time + 1000), 'EVENT_POST_DRAIN');
  Hub.Free; Scheduler.Free; Driver.Free;
end;
procedure TestPendingStop;
begin
  Setup;
  Payload := TPayload.Create;
  Check(Source.Publish(Payload), 'EVENT_PUBLISH'); Payload := nil;
  Check(Publisher.Stop(1000), 'EVENT_PENDING_SOURCE_STOP');
  Check((Hub.PendingCount = 0) and (Hub.DiscardedCount = 1), 'EVENT_PENDING_PURGED');
  Check(not Scheduler.RunUntil(10), 'EVENT_RECEIVER_PARKED');
  Check((Handlers = 0) and (Destroyed = 1), 'EVENT_NO_LATE_HANDLER');
  Check(not Source.Publish(nil), 'EVENT_CLOSED_ADMISSION');
  Teardown;
end;
procedure TestActiveTimeout;
var Refused: Boolean;
begin
  Setup; SuspendHandler := True; Publisher.Start;
  Payload := TPayload.Create; Source.Publish(Payload); Payload := nil;
  Check(not Scheduler.RunUntil(1), 'EVENT_HANDLER_SUSPENDED');
  Check(not Publisher.Stop(0), 'EVENT_ACTIVE_STOP_TIMEOUT');
  Refused := False;
  try Publisher.Free except on EFiberUsage do Refused := True end;
  Check(Refused and (Destroyed = 0), 'EVENT_TIMEOUT_RETAINS_PAYLOAD');
  Check(Publisher.Stop(200), 'EVENT_ACTIVE_SETTLED');
  Check((Handlers = 1) and (Finished = 1) and (Destroyed = 1), 'EVENT_ACTIVE_FINALLY');
  Check(Hub.DeliveredCount = 1, 'EVENT_COMPLETION_COUNT');
  Teardown;
end;
procedure TestRecipientStop;
begin
  Setup; SuspendHandler := True;
  Payload := TPayload.Create; Source.Publish(Payload); Source.Publish(Payload);
  Payload := nil;
  Check(not Scheduler.RunUntil(1), 'EVENT_RECIPIENT_ACTIVE');
  Check(Recipient.Stop(1000), 'EVENT_RECIPIENT_CANCEL');
  Check((Finished = 1) and (Hub.PendingCount = 0) and (Destroyed = 1),
    'EVENT_RECIPIENT_RELEASES_ALL');
  Check((Hub.AdmittedCount = 2) and (Hub.AbortedCount = 1) and
    (Hub.DiscardedCount = 1) and (Hub.DeliveredCount = 0), 'EVENT_CANCEL_ACCOUNTING');
  Teardown;
end;
procedure TestPostedLifetime;
var Poster: TPoster; Refused: Boolean; OldToken: TServiceEndpoint;
begin
  Setup;
  Poster := TPoster.Create(True); Poster.Token := Source;
  Poster.Value := TPayload.Create; Poster.Start; Poster.WaitFor;
  Check(Poster.Accepted, 'EVENT_NATIVE_POST_ACCEPTED'); Poster.Free;
  Check(Publisher.Stop(1000), 'EVENT_POSTED_SOURCE_STOP');
  Publisher.Free; Publisher := nil;
  Check(not Source.Post(nil), 'EVENT_STABLE_CLOSED_TOKEN');
  OldToken := Source;
  Publisher := TFiberService.Create(Scheduler, 1000, Idle, nil);
  Source := Hub.Attach(Publisher);
  Check(Source <> OldToken, 'EVENT_NO_TOKEN_REUSE');
  Refused := False;
  try Hub.Free except on EFiberUsage do Refused := True end;
  Check(Refused, 'EVENT_PENDING_HUB_FREE_GUARD');
  Check(not Scheduler.RunUntil(10), 'EVENT_POSTED_ENVELOPE_DRAIN');
  Check((Handlers = 0) and (Destroyed = 1), 'EVENT_POST_AFTER_FREE_SAFE');
  Teardown;
end;
procedure FaultHandler(Task: TScheduledTask; Sender: TServiceEndpoint;
  const Value: IInterface; Data: Pointer);
begin raise EConvertError.Create('event handler fault') end;
procedure TestGuardsAndFaults;
var Probe: TOwnerProbe; Refused: Boolean; Sub: TServiceSubscription;
begin
  Setup;
  Probe := TOwnerProbe.Create(True); Probe.Token := Source;
  Probe.Start; Probe.WaitFor;
  Check(Probe.Rejected = 4, 'EVENT_FOREIGN_OWNER'); Probe.Free;
  Refused := False;
  try Hub.Attach(Publisher) except on EFiberUsage do Refused := True end;
  Check(Refused, 'EVENT_SINGLE_LIFECYCLE_BINDING');
  Refused := False;
  try Source.Free except on EFiberUsage do Refused := True end;
  Check(Refused, 'EVENT_HUB_OWNS_TOKEN');
  Sub := Hub.Subscribe(Target, FaultHandler, nil);
  Refused := False;
  try Sub.Free except on EFiberUsage do Refused := True end;
  Check(Refused, 'EVENT_HUB_OWNS_SUBSCRIPTION');
  Payload := TPayload.Create; Source.Publish(Payload); Source.Publish(Payload); Payload := nil;
  Check(not Scheduler.RunUntil(1), 'EVENT_FAULT_CONTAINED');
  Check((Sub.Task.State = fsFaulted) and (Sub.Task.ErrorClass = 'EConvertError'),
    'EVENT_FAULT_RETAINED');
  Check((Destroyed = 1) and (Hub.PendingCount = 0), 'EVENT_FAULT_RELEASES_PAYLOADS');
  Check(Hub.AdmittedCount = Hub.DeliveredCount + Hub.DiscardedCount + Hub.AbortedCount,
    'EVENT_FAULT_ACCOUNTING');
  Teardown;
end;
procedure TestPostNotifyFailure;
var Raised: Boolean;
begin
  Setup(1); Payload := TPayload.Create; Driver.FailWake := True;
  Raised := False;
  try Source.Post(Payload) except on Exception do Raised := True end;
  Driver.FailWake := False; Payload := nil;
  Check(Raised, 'EVENT_NOTIFY_EXCEPTION_OBSERVED');
  Check((Hub.PendingPostCount = 0) and (Destroyed = 1), 'EVENT_NOTIFY_ROLLBACK');
  Payload := TPayload.Create;
  Check(Source.Post(Payload), 'EVENT_NOTIFY_POOL_RECOVERED'); Payload := nil;
  Check(not Scheduler.RunUntil(1), 'EVENT_NOTIFY_RECOVERY_DELIVERY');
  Check((Handlers = 1) and (Destroyed = 2), 'EVENT_NOTIFY_RECOVERY_RELEASE');
  Teardown;
end;
procedure TestPostBackpressure;
begin
  Setup(1);
  Payload := TPayload.Create;
  Check(Source.Post(Payload), 'EVENT_POST_POOL_FIRST');
  Check(not Source.Post(Payload), 'EVENT_POST_POOL_BOUNDED');
  Check(Source.Publish(Payload), 'EVENT_FILL_BEFORE_POST_DELIVERY'); Payload := nil;
  Check(not Scheduler.RunUntil(1), 'EVENT_POST_ADMISSION_SETTLED');
  Check((Hub.PostAcceptedCount = 1) and (Hub.PostRejectedCount = 1),
    'EVENT_DEFERRED_REJECTION_VISIBLE');
  Check((Handlers = 1) and (Destroyed = 1), 'EVENT_POST_REJECT_RELEASE');
  Teardown;
end;
procedure TestBoundedFanout;
begin
  Setup(2); Hub.Subscribe(Target, Handle, nil);
  Payload := TPayload.Create;
  Check(Source.Publish(Payload), 'EVENT_ATOMIC_FANOUT_ACCEPTED');
  Check(not Source.Publish(Payload), 'EVENT_ATOMIC_FANOUT_FULL');
  Check(Hub.PendingCount = 2, 'EVENT_BOUNDED_CAPACITY');
  Payload := nil;
  Check(not Scheduler.RunUntil(1), 'EVENT_FANOUT_DRAINED');
  Check((Handlers = 2) and (Destroyed = 1), 'EVENT_SAME_PAYLOAD_RELEASE_ONCE');
  Teardown;
end;
begin
  TestPostNotifyFailure;
  TestPendingStop; TestActiveTimeout; TestRecipientStop;
  TestPostedLifetime; TestBoundedFanout;
  TestGuardsAndFaults; TestPostBackpressure;
  WriteLn('PASS: managed event lifetime, bounded fanout, stop, active timeout, native post');
end.
