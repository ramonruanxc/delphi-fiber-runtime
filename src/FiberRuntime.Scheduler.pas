unit FiberRuntime.Scheduler;

{$IFDEF FPC}
{$MODE DELPHI}
{$H+}
{$ENDIF}

interface

uses
  {$IFNDEF FPC}
  Windows,
  {$ENDIF}
  SysUtils,
  FiberRuntime.Context;

type
  TSchedulerDriver = class
  public
    function NowUs: Int64; virtual; abstract;
    function ClockGeneration: Int64; virtual;
    procedure WaitUntil(DeadlineUs: Int64); virtual; abstract;
    { Notification only: called under the mailbox lock, possibly by a foreign
      thread. Must not suspend or call back into this scheduler. }
    procedure Wake; virtual; abstract;
  end;

  TFiberScheduler = class;
  TScheduledTask = class;
  TScheduledProc = procedure(ATask: TScheduledTask; AData: Pointer);
  TCarrierProc = procedure(AData: Pointer);
  TCarrierCondition = function(AData: Pointer): Boolean;
  TResumePolicy = (rpRebasePeriodic, rpStop);
  TReadyReason = (rrSpawn, rrYield, rrWake, rrTimer, rrCancel, rrResume);

  TSchedulerTaskTrace = record
    HasWaitDeadline, HasTimerObservation, HasReadyEnqueue, HasResume: Boolean;
    WaitDeadlineUs, TimerObservedUs, ReadyEnqueuedUs, ResumedUs: Int64;
    ReadyReason: TReadyReason;
    ReadyGeneration, ResumeGeneration: Int64;
  end;
  TTaskWait = (swReady, swParked, swTimer);

  TCarrierWork = record
    Proc: TCarrierProc;
    Data: Pointer;
  end;

  TScheduledTask = class
  private
    FOwner: TFiberScheduler;
    FContext: TFiberTask;
    FProc: TScheduledProc;
    FData: Pointer;
    FWait: TTaskWait;
    FTrace: TSchedulerTaskTrace;
    FDeadline: Int64;
    FQueued, FRelease: Boolean;
    {$IFDEF FPC}
    {$PUSH}
    {$WARN 3018 OFF}
    {$ENDIF}
    constructor Create(AOwner: TFiberScheduler; AProc: TScheduledProc; AData: Pointer);
    {$IFDEF FPC}
    {$POP}
    {$ENDIF}
    procedure RequireCurrent;
    procedure BeginTimedWait(ADeadline: Int64);
    function GetTrace: TSchedulerTaskTrace;
    procedure Suspend(AWait: TTaskWait; ADeadline: Int64);
    function GetState: TFiberState;
    function GetCancelRequested: Boolean;
    function GetErrorClass: string;
    function GetErrorMessage: string;
    function GetScheduler: TFiberScheduler;
    function GetLocalValue: Pointer;
    procedure SetLocalValue(Value: Pointer);
  public
    procedure BeforeDestruction; override;
    destructor Destroy; override;
    procedure Yield;
    procedure Delay(ADurationUs: Int64);
    procedure AwaitUntil(ADeadlineUs: Int64);
    function AwaitUntilOrResume(ADeadlineUs, AExpectedGeneration: Int64): Boolean;
    procedure Park;
    procedure Cancel;
    procedure CheckCancelled;
    property Trace: TSchedulerTaskTrace read GetTrace;
    property State: TFiberState read GetState;
    property CancelRequested: Boolean read GetCancelRequested;
    property ErrorClass: string read GetErrorClass;
    property ErrorMessage: string read GetErrorMessage;
    property Scheduler: TFiberScheduler read GetScheduler;
    property LocalValue: Pointer read GetLocalValue write SetLocalValue;
  end;

  TFiberScheduler = class
  private
    FOwner: TThreadID;
    FRuntime: TFiberRuntime;
    FDriver: TSchedulerDriver;
    FOwnDriver, FLockReady, FPumping, FClockSeen, FClockFault: Boolean;
    FStopping, FInCleanup, FGenerationSeen: Boolean;
    FLastNow, FGeneration, FResumeEpochUs: Int64;
    FResumePolicy: TResumePolicy;
    FTasks, FReady: array of TScheduledTask;
    FPosts: array of TCarrierWork;
    FCount, FReadyHead, FReadyCount, FPostHead, FPostCount: Integer;
    FLock: TRTLCriticalSection;
    FCurrent: TScheduledTask;
    FPostFaultCount: Int64;
    procedure RequireCarrier;
    procedure Enqueue(T: TScheduledTask; Reason: TReadyReason = rrWake);
    function TraceNow(out Value: Int64): Boolean;
    function PopReady: TScheduledTask;
    function TakePost(out Work: TCarrierWork): Boolean;
    function Settled: Boolean;
    function IsStopping: Boolean;
    procedure Maintain(Now: Int64; out Nearest: Int64);
    function Pump(Deadline: Int64; Target: TScheduledTask; Cleanup: Boolean;
      Condition: TCarrierCondition = nil; Data: Pointer = nil): Boolean;
    function ClockNow(Cleanup: Boolean): Int64;
    function GetCurrentTask: TScheduledTask;
    function GetPostFaultCount: Int64;
    function GetMaxTasks: Integer;
    function GetClockDiscontinuity: Boolean;
    function GetResumeGeneration: Int64;
    function GetResumeEpochUs: Int64;
  public
    constructor Create(AMaxTasks: Integer = 1024; ADriver: TSchedulerDriver = nil;
      AResumePolicy: TResumePolicy = rpRebasePeriodic);
    procedure BeforeDestruction; override;
    destructor Destroy; override;
    function Spawn(AProc: TScheduledProc; AData: Pointer): TScheduledTask;
    function RunUntil(ADeadlineUs: Int64): Boolean;
    function RunUntilCondition(ACondition: TCarrierCondition; AData: Pointer;
      ADeadlineUs: Int64): Boolean;
    function CleanupNowUs: Int64;
    function RunTaskUntil(ATask: TScheduledTask; ADeadlineUs: Int64): Boolean;
    function NowUs: Int64;
    procedure CheckOwner;
    procedure WakeTask(ATask: TScheduledTask);
    function Post(AProc: TCarrierProc; AData: Pointer): Boolean;
    procedure RequestStop;
    function Stop(ATimeoutUs: Int64): Boolean;
    function StopTask(ATask: TScheduledTask; ATimeoutUs: Int64): Boolean;
    property CurrentTask: TScheduledTask read GetCurrentTask;
    property PostFaultCount: Int64 read GetPostFaultCount;
    property MaxTasks: Integer read GetMaxTasks;
    property ClockDiscontinuity: Boolean read GetClockDiscontinuity;
    property ResumeGeneration: Int64 read GetResumeGeneration;
    property ResumeEpochUs: Int64 read GetResumeEpochUs;
  end;

implementation

uses
  FiberRuntime.Platform;

{$I compat/critical-section.inc}

{$IFNDEF FPC}
{ FPC's System unit provides this; declare it for Delphi (Vista or later). }
function GetTickCount64: UInt64; stdcall; external 'kernel32.dll' name 'GetTickCount64';
{$ENDIF}

type
  TNativeSchedulerDriver = class(TSchedulerDriver)
  private
    FTimer: TPlatformTimer;
  public
    constructor Create;
    destructor Destroy; override;
    function NowUs: Int64; override;
    function ClockGeneration: Int64; override;
    procedure WaitUntil(DeadlineUs: Int64); override;
    procedure Wake; override;
  end;

function TSchedulerDriver.ClockGeneration: Int64;
begin
  Result := 0;
end;

function TNativeSchedulerDriver.ClockGeneration: Int64;
begin
  Result := FTimer.SuspendGeneration;
end;

function Terminal(T: TScheduledTask): Boolean;
begin
  Result := T.FContext.State in [fsCompleted, fsCancelled, fsFaulted];
end;

function AddDuration(Now, Duration: Int64): Int64;
begin
  if Duration < 0 then
    raise EFiberUsage.Create('Duration must be nonnegative');
  if Now > High(Int64) - Duration then
    Result := High(Int64)
  else
    Result := Now + Duration;
end;

constructor TNativeSchedulerDriver.Create;
begin
  inherited Create;
  FTimer := TPlatformTimer.Create;
end;

destructor TNativeSchedulerDriver.Destroy;
begin
  FTimer.Free;
  inherited;
end;

function TNativeSchedulerDriver.NowUs: Int64;
begin
  Result := FTimer.NowUs;
end;

procedure TNativeSchedulerDriver.WaitUntil(DeadlineUs: Int64);
begin
  FTimer.WaitUntilOrWake(DeadlineUs);
end;

procedure TNativeSchedulerDriver.Wake;
begin
  FTimer.Notify;
end;
{$I scheduler/task.inc}
{$I scheduler/lifecycle.inc}
{$I scheduler/pump.inc}
end.
