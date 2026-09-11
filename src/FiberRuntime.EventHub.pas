unit FiberRuntime.EventHub;
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
interface
uses FiberRuntime.Scheduler, FiberRuntime.Service, FiberRuntime.ServiceHooks;
type
  TFiberEventHub = class;
  TServiceEndpoint = class;
  TServiceSubscription = class;
  TServiceEventProc = procedure(Task: TScheduledTask; Source: TServiceEndpoint;
    const Payload: IInterface; Data: Pointer);
  TServiceEndpoint = class(TServiceHooks)
  private
    FHub: TFiberEventHub;
    FClosed, FDetached, FRelease: Boolean;
    FActive: Integer;
    function GetClosed: Boolean;
  public
    procedure BeforeDestruction; override;
    function Publish(const Payload: IInterface): Boolean;
    { True accepts a bounded envelope. Deferred admission is counted separately. }
    function Post(const Payload: IInterface): Boolean;
    procedure BeginStop; override;
    function IsSettled: Boolean; override;
    procedure Detach; override;
    property Closed: Boolean read GetClosed;
  end;
  TServiceSubscription = class
  private
    FHub: TFiberEventHub;
    FRecipient: TServiceEndpoint;
    FHandler: TServiceEventProc;
    FData: Pointer;
    FTask: TScheduledTask;
    FClosed, FRelease: Boolean;
    function GetTask: TScheduledTask;
    procedure Execute(Task: TScheduledTask);
  public
    procedure BeforeDestruction; override;
    property Task: TScheduledTask read GetTask;
  end;
  TEventDelivery = record
    Source: TServiceEndpoint;
    Recipient: TServiceSubscription;
    Payload: IInterface;
    Sequence: Int64;
  end;
  TPostEnvelope = record
    Hub: TFiberEventHub;
    Source: TServiceEndpoint;
    Payload: IInterface;
    Used: Boolean;
  end;
  PPostEnvelope = ^TPostEnvelope;
  TFiberEventHub = class
  private
    FScheduler: TFiberScheduler;
    FEndpoints: array of TServiceEndpoint;
    FSubscriptions: array of TServiceSubscription;
    FDeliveries: array of TEventDelivery;
    FEnvelopes: array of TPostEnvelope;
    FEndpointCount, FSubscriptionCount, FPending, FActive, FPosts: Integer;
    FSequence, FPublished, FDelivered, FDiscarded, FRejected: Int64;
    FPostAccepted, FPostRejected: Int64;
    FAdmitted, FAborted: Int64;
    FLock: TRTLCriticalSection;
    FLockReady: Boolean;
    function Publish(Source: TServiceEndpoint; const Payload: IInterface): Boolean;
    function Post(Source: TServiceEndpoint; const Payload: IInterface): Boolean;
    procedure Purge(Source: TServiceEndpoint; Recipient: TServiceSubscription);
    function Take(Recipient: TServiceSubscription; out Delivery: TEventDelivery): Boolean;
    procedure CloseEndpoint(Endpoint: TServiceEndpoint);
    function EndpointSettled(Endpoint: TServiceEndpoint): Boolean;
    function GetMetric(Index: Integer): Int64;
  public
    constructor Create(Scheduler: TFiberScheduler; Capacity, MaxSubscriptions: Integer);
    procedure BeforeDestruction; override;
    destructor Destroy; override;
    function Attach(Service: TFiberService): TServiceEndpoint;
    function Subscribe(Recipient: TServiceEndpoint; Handler: TServiceEventProc;
      Data: Pointer): TServiceSubscription;
    property PublishedCount: Int64 index 0 read GetMetric;
    property DeliveredCount: Int64 index 1 read GetMetric;
    property DiscardedCount: Int64 index 2 read GetMetric;
    property RejectedCount: Int64 index 3 read GetMetric;
    property PendingCount: Int64 index 4 read GetMetric;
    property ActiveCount: Int64 index 5 read GetMetric;
    property PostAcceptedCount: Int64 index 6 read GetMetric;
    property PostRejectedCount: Int64 index 7 read GetMetric;
    property Capacity: Int64 index 8 read GetMetric;
    property PendingPostCount: Int64 index 9 read GetMetric;
    property AdmittedCount: Int64 index 10 read GetMetric;
    property AbortedCount: Int64 index 11 read GetMetric;
  end;
implementation
uses SysUtils, FiberRuntime.Context;
procedure DispatchEntry(Task: TScheduledTask; Data: Pointer);
begin TServiceSubscription(Data).Execute(Task) end;
procedure PostedDelivery(Data: Pointer);
var Envelope: PPostEnvelope; Hub: TFiberEventHub;
  Source: TServiceEndpoint; Payload: IInterface;
begin
  Envelope := PPostEnvelope(Data); Hub := Envelope.Hub;
  EnterCriticalSection(Hub.FLock);
  try
    Source := Envelope.Source; Payload := Envelope.Payload;
    Envelope.Payload := nil; Envelope.Source := nil; Envelope.Used := False;
    Dec(Hub.FPosts);
  finally LeaveCriticalSection(Hub.FLock) end;
  if not Hub.Publish(Source, Payload) then Inc(Hub.FPostRejected);
end;
{$I events/lifecycle.inc}
{$I events/delivery.inc}
end.
