program ContextTests;
{$mode delphi}{$H+}
uses {$ifdef unix}{$ifndef CONTEXT_TEST_NO_CTHREADS}cthreads,{$endif}{$endif}
  SysUtils, Classes, Math, FiberRuntime.Context;
type
  TProbe = class(TInterfacedObject)
    destructor Destroy; override;
  end;
  TCaseData = record
    Number, Step, Cleanups: Integer;
    Mode: TFPURoundingMode;
  end;
  PCaseData = ^TCaseData;
  TOwnerProbe = class(TThread)
    Runtime: TFiberRuntime;
    Task: TFiberTask;
    Rejected: Integer;
    procedure Execute; override;
  end;
var
  Runtime: TFiberRuntime;
  Other: TFiberTask;
  Destroyed: Integer;
  IdentityChecked: Boolean;
  {$ifdef CONTEXT_TEST_NO_CTHREADS}MissingThreadsRejected: Boolean;{$endif}
threadvar SharedSlot: Integer;

procedure Check(Value: Boolean; const Name: string);
begin
  if not Value then begin WriteLn('ASSERTION FAILED: ', Name); Halt(1); end;
end;

destructor TProbe.Destroy;
begin
  Inc(Destroyed);
  inherited;
end;

{$ifdef unix}
function ProbePush(Ft: LongInt; Buf, NewAddr: Pointer): PJmp_buf;
  external name 'FPC_PUSHEXCEPTADDR';
procedure ProbePop; external name 'FPC_POPADDRSTACK';
function ExceptionHead: Pointer;
var Node: TExceptAddr;
begin
  ProbePush(0, nil, @Node);
  Result := Node.Next;
  ProbePop;
end;
{$endif}

procedure CheckStack;
var Local: Byte;
begin
  Check((PtrUInt(@Local) >= PtrUInt(System.StackBottom)) and
    (PtrUInt(@Local) < PtrUInt(System.StackTop)), 'CONTEXT_STACK_BOUNDS');
end;

procedure FreshException;
var Caught: Boolean;
begin
  Caught := False;
  try raise EConvertError.Create('fresh');
  except on E: EConvertError do Caught := E.Message = 'fresh'; end;
  Check(Caught, 'CONTEXT_FRESH_EXCEPTION');
end;

procedure Nested(ATask: TFiberTask; Data: PCaseData);
var Text: string; Ref: IInterface; Local: Integer;
    {$ifdef unix}Head: Pointer;{$endif}
begin
  Text := 'managed-' + IntToStr(Data.Number);
  Ref := TProbe.Create;
  Check(Ref <> nil, 'CONTEXT_INTERFACE');
  Local := Data.Number * 11;
  try
    try
      {$ifdef unix}Head := ExceptionHead;{$endif}
      SetRoundMode(Data.Mode);
      SharedSlot := Data.Number;
      ATask.LocalValue := Data;
      Data.Step := 1;
      ATask.Yield;
      {$ifdef unix}Check(ExceptionHead = Head, 'CONTEXT_RTL_ISOLATION');{$endif}
      CheckStack;
      Check(GetRoundMode = Data.Mode, 'CONTEXT_FLOAT_ISOLATION');
      Check(Text = 'managed-' + IntToStr(Data.Number), 'CONTEXT_STRING');
      Check(Local = Data.Number * 11, 'CONTEXT_LOCAL_STACK');
      Check(ATask.LocalValue = Data, 'CONTEXT_EXPLICIT_LOCAL');
      Check(SharedSlot = 99, 'CONTEXT_SHARED_THREADVAR');
      FreshException;
      Data.Step := 2;
      ATask.Yield;
    finally Inc(Data.Cleanups); end;
  finally
    Inc(Data.Cleanups);
    Ref := nil;
  end;
end;

procedure Interleaved(ATask: TFiberTask; AData: Pointer);
begin
  CheckStack;
  Nested(ATask, PCaseData(AData));
end;

procedure Empty(ATask: TFiberTask; AData: Pointer);
begin
  if AData <> nil then Inc(PInteger(AData)^);
end;

procedure Identity(ATask: TFiberTask; AData: Pointer);
var Rejected: Boolean;
begin
  Rejected := False;
  try Other.Yield; except on EFiberUsage do Rejected := True; end;
  Check(Rejected, 'CONTEXT_TASK_IDENTITY');
  IdentityChecked := True;
  Rejected := False;
  try Other.Resume; except on EFiberUsage do Rejected := True; end;
  Check(Rejected, 'CONTEXT_NESTED_RESUME');
  Rejected := False;
  try ATask.Free; except on EFiberUsage do Rejected := True; end;
  Check(Rejected and (ATask.State = fsRunning), 'CONTEXT_FREE_RUNNING');
  try
    raise Exception.Create('handler');
  except
    Rejected := False;
    try ATask.Yield; except on EFiberUsage do Rejected := True; end;
    Check(Rejected, 'CONTEXT_ACTIVE_HANDLER_YIELD');
  end;
  ATask.Yield;
end;

procedure Fault(ATask: TFiberTask; AData: Pointer);
begin
  ATask.Yield;
  raise EConvertError.Create('contained fault');
end;

procedure ObjectFault(ATask: TFiberTask; AData: Pointer);
begin
  raise TObject.Create;
end;

procedure CancelAndReturn(ATask: TFiberTask; AData: Pointer);
begin
  ATask.Cancel;
  Check(ATask.State = fsRunning, 'CONTEXT_CANCEL_RUNNING');
  try ATask.CheckCancelled;
  except on EFiberCancelled do Inc(PInteger(AData)^); end;
end;

procedure CatchCancellation(ATask: TFiberTask; AData: Pointer);
begin
  try ATask.Yield;
  except on EFiberCancelled do Inc(PInteger(AData)^); end;
  Check(ATask.CancelRequested, 'CONTEXT_CANCEL_STICKY');
  try ATask.CheckCancelled;
  except on EFiberCancelled do Inc(PInteger(AData)^); end;
  ATask.Yield;
end;

procedure TOwnerProbe.Execute;
begin
  try Task.Resume; except on EFiberUsage do Inc(Rejected); end;
  try Task.Yield; except on EFiberUsage do Inc(Rejected); end;
  try Task.Cancel; except on EFiberUsage do Inc(Rejected); end;
  try Task.CheckCancelled; except on EFiberUsage do Inc(Rejected); end;
  try Task.Free; except on EFiberUsage do Inc(Rejected); end;
  try Runtime.Free; except on EFiberUsage do Inc(Rejected); end;
  try Runtime.CreateTask(Empty, nil); except on EFiberUsage do Inc(Rejected); end;
  try Check(Task.State = fsSuspended, 'OWNER_READ_STATE');
  except on EFiberUsage do Inc(Rejected); end;
  try Check(not Task.CancelRequested, 'OWNER_READ_CANCEL');
  except on EFiberUsage do Inc(Rejected); end;
  try Check(Task.ErrorClass = '', 'OWNER_READ_ERROR_CLASS');
  except on EFiberUsage do Inc(Rejected); end;
  try Check(Task.ErrorMessage = '', 'OWNER_READ_ERROR_MESSAGE');
  except on EFiberUsage do Inc(Rejected); end;
  try Check(Task.LocalValue = nil, 'OWNER_READ_LOCAL');
  except on EFiberUsage do Inc(Rejected); end;
  try Task.LocalValue := Self; except on EFiberUsage do Inc(Rejected); end;
  try Check(Runtime.BackendName <> '', 'OWNER_READ_BACKEND');
  except on EFiberUsage do Inc(Rejected); end;
end;

procedure TestInterleave;
var A, B: TFiberTask; DA, DB: TCaseData; RootMode: TFPURoundingMode;
    RootBottom: Pointer; RootLength: SizeUInt;
    {$ifdef unix}Head: Pointer;{$endif}
begin
  FillChar(DA, SizeOf(DA), 0); FillChar(DB, SizeOf(DB), 0);
  DA.Number := 1; DA.Mode := rmDown; DB.Number := 2; DB.Mode := rmUp;
  A := Runtime.CreateTask(Interleaved, @DA, 65537);
  B := Runtime.CreateTask(Interleaved, @DB);
  Check((A.State = fsCreated) and (DA.Step = 0), 'CONTEXT_DORMANT');
  RootMode := GetRoundMode;
  RootBottom := System.StackBottom; RootLength := System.StackLength;
  {$ifdef unix}Head := ExceptionHead;{$endif}
  A.Resume;
  {$ifdef unix}Check(ExceptionHead = Head, 'CONTEXT_RTL_ISOLATION');{$endif}
  Check((A.State = fsSuspended) and (DA.Step = 1), 'CONTEXT_SUSPEND');
  B.Resume;
  {$ifdef unix}Check(ExceptionHead = Head, 'CONTEXT_RTL_ISOLATION');{$endif}
  Check((System.StackBottom = RootBottom) and (System.StackLength = RootLength),
    'CONTEXT_ROOT_STACK');
  Check(GetRoundMode = RootMode, 'CONTEXT_ROOT_FLOAT');
  FreshException;
  SharedSlot := 99;
  A.Resume; FreshException; B.Resume;
  Check((DA.Step = 2) and (DB.Step = 2), 'CONTEXT_INTERLEAVE');
  A.Resume; B.Resume;
  Check(GetRoundMode = RootMode, 'CONTEXT_FINAL_ROOT_FLOAT');
  Check((System.StackBottom = RootBottom) and (System.StackLength = RootLength),
    'CONTEXT_FINAL_ROOT_STACK');
  Check((A.State = fsCompleted) and (B.State = fsCompleted), 'CONTEXT_COMPLETE');
  Check((DA.Cleanups = 2) and (DB.Cleanups = 2) and (Destroyed = 2),
    'CONTEXT_MANAGED_CLEANUP');
  A.Free; B.Free;
end;

procedure TestUsage;
var A, Duplicate: TFiberRuntime; Task: TFiberTask; Rejected: Boolean;
    Thread: TOwnerProbe;
begin
  Duplicate := nil; Rejected := False;
  try Duplicate := TFiberRuntime.Create; except on EFiberUsage do Rejected := True; end;
  Check(Rejected and (Duplicate = nil), 'CONTEXT_ATTACH_DUPLICATE');
  Other := Runtime.CreateTask(Empty, nil);
  Task := Runtime.CreateTask(Identity, nil);
  Task.Resume;
  Check(IdentityChecked, 'CONTEXT_TASK_IDENTITY');
  Rejected := False;
  try Task.Free; except on EFiberUsage do Rejected := True; end;
  Check(Rejected and (Task.State = fsSuspended), 'CONTEXT_FREE_SUSPENDED');
  Rejected := False;
  try Runtime.Free; except on EFiberUsage do Rejected := True; end;
  Check(Rejected, 'CONTEXT_FREE_RUNTIME');
  Thread := TOwnerProbe.Create(True);
  Thread.Runtime := Runtime; Thread.Task := Task; Thread.Start; Thread.WaitFor;
  Check(Thread.Rejected = 14, 'CONTEXT_OWNER_THREAD');
  Thread.Free;
  Check((Task.State = fsSuspended) and not Task.CancelRequested and
    (Task.LocalValue = nil), 'CONTEXT_OWNER_PRESERVES_STATE');
  Task.Resume;
  Rejected := False;
  try Task.Resume; except on EFiberUsage do Rejected := True; end;
  Check(Rejected, 'CONTEXT_TERMINAL_RESUME');
  Task.Free; Other.Free; Other := nil;
  Rejected := False;
  try Task := Runtime.CreateTask(nil, nil); except on EFiberUsage do Rejected := True; end;
  Check(Rejected, 'CONTEXT_NIL_CALLBACK');
  Rejected := False;
  try Task := Runtime.CreateTask(Empty, nil, 65535); except on EFiberUsage do Rejected := True; end;
  Check(Rejected, 'CONTEXT_STACK_TOO_SMALL');
  Rejected := False;
  try Task := Runtime.CreateTask(Empty, nil, 67108865); except on EFiberUsage do Rejected := True; end;
  Check(Rejected, 'CONTEXT_STACK_TOO_LARGE');
  Task := Runtime.CreateTask(Empty, nil);
  try
    raise Exception.Create('root handler');
  except
    Rejected := False;
    try Task.Resume; except on EFiberUsage do Rejected := True; end;
    Check(Rejected and (Task.State = fsCreated), 'CONTEXT_ACTIVE_HANDLER_RESUME');
  end;
  Task.Free;
  A := Runtime; Check(A.BackendName <> '', 'CONTEXT_BACKEND_NAME');
end;

procedure TestCancellation;
var Task: TFiberTask; Calls: Integer; Data: TCaseData; Rejected: Boolean;
begin
  Calls := 0;
  Task := Runtime.CreateTask(Empty, @Calls);
  Task.Cancel; Task.Cancel;
  Check((Task.State = fsCancelled) and Task.CancelRequested and (Calls = 0),
    'CONTEXT_CANCEL_CREATED');
  Rejected := False;
  try Task.Resume; except on EFiberUsage do Rejected := True; end;
  Check(Rejected, 'CONTEXT_CANCELLED_RESUME'); Task.Free;
  FillChar(Data, SizeOf(Data), 0); Data.Mode := rmNearest;
  Task := Runtime.CreateTask(Interleaved, @Data);
  Task.Resume; Task.Cancel;
  Check((Task.State = fsSuspended) and Task.CancelRequested, 'CONTEXT_CANCEL_PENDING');
  Task.Resume;
  Check((Task.State = fsCancelled) and (Data.Cleanups = 2) and (Destroyed = 3),
    'CONTEXT_CANCEL_CLEANUP'); Task.Free;
  Task := Runtime.CreateTask(CatchCancellation, @Calls);
  Task.Resume; Task.Cancel; Task.Resume;
  Check((Task.State = fsSuspended) and (Calls = 2), 'CONTEXT_CANCEL_CAUGHT');
  Task.Resume; Check(Task.State = fsCancelled, 'CONTEXT_CANCEL_RECHECK'); Task.Free;
  Task := Runtime.CreateTask(Fault, nil); Task.Resume; Task.Resume;
  Check((Task.State = fsFaulted) and (Task.ErrorClass = 'EConvertError') and
    (Task.ErrorMessage = 'contained fault'), 'CONTEXT_FAULT_CONTAINMENT');
  Task.Free; FreshException;
  Task := Runtime.CreateTask(ObjectFault, nil); Task.Resume;
  Check((Task.State = fsFaulted) and (Task.ErrorClass = 'TObject'),
    'CONTEXT_OBJECT_FAULT_CONTAINMENT'); Task.Free;
  Calls := 0;
  Task := Runtime.CreateTask(CancelAndReturn, @Calls); Task.Resume;
  Check((Task.State = fsCompleted) and Task.CancelRequested and (Calls = 1),
    'CONTEXT_CAUGHT_CANCEL_COMPLETION'); Task.Free;
end;

begin
  {$ifdef CONTEXT_TEST_NO_CTHREADS}
  try Runtime := TFiberRuntime.Create;
  except on EFiberUsage do MissingThreadsRejected := True; end;
  Check(MissingThreadsRejected, 'CONTEXT_REQUIRES_CTHREADS');
  WriteLn('PASS ContextTests no-cthreads rejection');
  {$else}
  Runtime := TFiberRuntime.Create;
  TestInterleave;
  TestUsage;
  TestCancellation;
  Runtime.Free;
  Runtime := TFiberRuntime.Create; Runtime.Free;
  WriteLn('PASS ContextTests');
  {$endif}
end.
