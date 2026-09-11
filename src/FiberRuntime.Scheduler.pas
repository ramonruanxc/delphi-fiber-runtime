unit FiberRuntime.Scheduler;
{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}
interface
uses SysUtils, FiberRuntime.Context;
type
  TSchedulerDriver = class
  public
    function NowUs: Int64; virtual; abstract;
    function ClockGeneration: Int64; virtual;
    procedure WaitUntil(DeadlineUs: Int64); virtual; abstract;
    procedure Wake; virtual; abstract;
  end;
  TFiberScheduler = class;
  TScheduledTask = class;
  TScheduledProc = procedure(ATask: TScheduledTask; AData: Pointer);
  TCarrierProc = procedure(AData: Pointer);
  TTaskWait = (swReady, swParked, swTimer);
  TCarrierWork = record Proc: TCarrierProc; Data: Pointer; end;
  TScheduledTask = class
  private
    FOwner: TFiberScheduler;
    FContext: TFiberTask;
    FProc: TScheduledProc;
    FData: Pointer;
    FWait: TTaskWait;
    FDeadline: Int64;
    FQueued, FRelease: Boolean;
    {$PUSH}{$WARN 3018 OFF}
    constructor Create(AOwner: TFiberScheduler; AProc: TScheduledProc; AData: Pointer);
    {$POP}
    procedure RequireCurrent;
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
    procedure Park;
    procedure Cancel;
    procedure CheckCancelled;
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
    FLastNow, FGeneration: Int64;
    FTasks, FReady: array of TScheduledTask;
    FPosts: array of TCarrierWork;
    FCount, FReadyHead, FReadyCount, FPostHead, FPostCount: Integer;
    FLock: TRTLCriticalSection;
    FCurrent: TScheduledTask;
    FPostFaultCount: Int64;
    procedure RequireCarrier;
    procedure Enqueue(T: TScheduledTask);
    function PopReady: TScheduledTask;
    function TakePost(out Work: TCarrierWork): Boolean;
    function Settled: Boolean;
    function IsStopping: Boolean;
    procedure Maintain(Now: Int64; out Nearest: Int64);
    function Pump(Deadline: Int64; Target: TScheduledTask; Cleanup: Boolean): Boolean;
    function ClockNow(Cleanup: Boolean): Int64;
    function GetCurrentTask: TScheduledTask;
    function GetPostFaultCount: Int64;
    function GetMaxTasks: Integer;
    function GetClockDiscontinuity: Boolean;
  public
    constructor Create(AMaxTasks: Integer = 1024; ADriver: TSchedulerDriver = nil);
    procedure BeforeDestruction; override;
    destructor Destroy; override;
    function Spawn(AProc: TScheduledProc; AData: Pointer): TScheduledTask;
    function RunUntil(ADeadlineUs: Int64): Boolean;
    function RunTaskUntil(ATask: TScheduledTask; ADeadlineUs: Int64): Boolean;
    function NowUs: Int64;
    procedure CheckOwner;
    procedure WakeTask(ATask: TScheduledTask);
    function Post(AProc: TCarrierProc; AData: Pointer): Boolean;
    procedure RequestStop;
    function Stop(ATimeoutUs: Int64): Boolean;
    property CurrentTask: TScheduledTask read GetCurrentTask;
    property PostFaultCount: Int64 read GetPostFaultCount;
    property MaxTasks: Integer read GetMaxTasks;
    property ClockDiscontinuity: Boolean read GetClockDiscontinuity;
  end;
implementation
uses FiberRuntime.Platform;
type
  TNativeSchedulerDriver = class(TSchedulerDriver)
  private FTimer: TPlatformTimer;
  public
    constructor Create;
    destructor Destroy; override;
    function NowUs: Int64; override;
    function ClockGeneration: Int64; override;
    procedure WaitUntil(DeadlineUs: Int64); override;
    procedure Wake; override;
  end;
function TSchedulerDriver.ClockGeneration: Int64;
begin Result := 0; end;
function TNativeSchedulerDriver.ClockGeneration: Int64;
begin Result := FTimer.SuspendGeneration; end;
function Terminal(T: TScheduledTask): Boolean;
begin Result := T.FContext.State in [fsCompleted, fsCancelled, fsFaulted]; end;
function AddDuration(Now, Duration: Int64): Int64;
begin
  if Duration < 0 then raise EFiberUsage.Create('Duration must be nonnegative');
  if Now > High(Int64) - Duration then Result := High(Int64)
  else Result := Now + Duration;
end;
constructor TNativeSchedulerDriver.Create;
begin inherited Create; FTimer := TPlatformTimer.Create; end;
destructor TNativeSchedulerDriver.Destroy;
begin FTimer.Free; inherited; end;
function TNativeSchedulerDriver.NowUs: Int64;
begin Result := FTimer.NowUs; end;
procedure TNativeSchedulerDriver.WaitUntil(DeadlineUs: Int64);
begin FTimer.WaitUntilOrWake(DeadlineUs); end;
procedure TNativeSchedulerDriver.Wake;
begin FTimer.Notify; end;
{$I scheduler/task.inc}
{$I scheduler/lifecycle.inc}
{$I scheduler/pump.inc}
end.
