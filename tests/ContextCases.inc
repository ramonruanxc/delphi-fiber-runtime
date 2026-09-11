procedure TestInterleave;
var
  A, B: TFiberTask;
  DA, DB: TCaseData;
  RootMode: TFPURoundingMode;
  RootBottom: Pointer;
  RootLength: SizeUInt;
  {$ifdef unix}
  Head: Pointer;
  {$endif}
begin
  FillChar(DA, SizeOf(DA), 0);
  FillChar(DB, SizeOf(DB), 0);
  DA.Number := 1;
  DA.Mode := rmDown;
  DB.Number := 2;
  DB.Mode := rmUp;
  A := Runtime.CreateTask(Interleaved, @DA, 65537);
  B := Runtime.CreateTask(Interleaved, @DB);
  Check((A.State = fsCreated) and (DA.Step = 0), 'CONTEXT_DORMANT');
  RootMode := GetRoundMode;
  RootBottom := System.StackBottom;
  RootLength := System.StackLength;
  {$ifdef unix}
  Head := ExceptionHead;
  {$endif}
  A.Resume;
  {$ifdef unix}
  Check(ExceptionHead = Head, 'CONTEXT_RTL_ISOLATION');
  {$endif}
  Check((A.State = fsSuspended) and (DA.Step = 1), 'CONTEXT_SUSPEND');
  B.Resume;
  {$ifdef unix}
  Check(ExceptionHead = Head, 'CONTEXT_RTL_ISOLATION');
  {$endif}
  Check((System.StackBottom = RootBottom) and (System.StackLength = RootLength),
    'CONTEXT_ROOT_STACK');
  Check(GetRoundMode = RootMode, 'CONTEXT_ROOT_FLOAT');
  FreshException;
  SharedSlot := 99;
  A.Resume;
  FreshException;
  B.Resume;
  Check((DA.Step = 2) and (DB.Step = 2), 'CONTEXT_INTERLEAVE');
  A.Resume;
  B.Resume;
  Check(GetRoundMode = RootMode, 'CONTEXT_FINAL_ROOT_FLOAT');
  Check((System.StackBottom = RootBottom) and (System.StackLength = RootLength),
    'CONTEXT_FINAL_ROOT_STACK');
  Check((A.State = fsCompleted) and (B.State = fsCompleted), 'CONTEXT_COMPLETE');
  Check((DA.Cleanups = 2) and (DB.Cleanups = 2) and (Destroyed = 2),
    'CONTEXT_MANAGED_CLEANUP');
  A.Free;
  B.Free;
end;

procedure TestUsage;
var
  A, Duplicate: TFiberRuntime;
  Task: TFiberTask;
  Rejected: Boolean;
  Thread: TOwnerProbe;
begin
  Duplicate := nil;
  Rejected := False;
  try
    Duplicate := TFiberRuntime.Create;
  except
    on EFiberUsage do
      Rejected := True;
  end;
  Check(Rejected and (Duplicate = nil), 'CONTEXT_ATTACH_DUPLICATE');
  Other := Runtime.CreateTask(Empty, nil);
  Task := Runtime.CreateTask(Identity, nil);
  Task.Resume;
  Check(IdentityChecked, 'CONTEXT_TASK_IDENTITY');
  Rejected := False;
  try
    Task.Free;
  except
    on EFiberUsage do
      Rejected := True;
  end;
  Check(Rejected and (Task.State = fsSuspended), 'CONTEXT_FREE_SUSPENDED');
  Rejected := False;
  try
    Runtime.Free;
  except
    on EFiberUsage do
      Rejected := True;
  end;
  Check(Rejected, 'CONTEXT_FREE_RUNTIME');
  Thread := TOwnerProbe.Create(True);
  Thread.Runtime := Runtime;
  Thread.Task := Task;
  Thread.Start;
  Thread.WaitFor;
  Check(Thread.Rejected = 14, 'CONTEXT_OWNER_THREAD');
  Thread.Free;
  Check((Task.State = fsSuspended) and not Task.CancelRequested and
    (Task.LocalValue = nil), 'CONTEXT_OWNER_PRESERVES_STATE');
  Task.Resume;
  Rejected := False;
  try
    Task.Resume;
  except
    on EFiberUsage do
      Rejected := True;
  end;
  Check(Rejected, 'CONTEXT_TERMINAL_RESUME');
  Task.Free;
  Other.Free;
  Other := nil;
  Rejected := False;
  try
    Task := Runtime.CreateTask(nil, nil);
  except
    on EFiberUsage do
      Rejected := True;
  end;
  Check(Rejected, 'CONTEXT_NIL_CALLBACK');
  Rejected := False;
  try
    Task := Runtime.CreateTask(Empty, nil, 65535);
  except
    on EFiberUsage do
      Rejected := True;
  end;
  Check(Rejected, 'CONTEXT_STACK_TOO_SMALL');
  Rejected := False;
  try
    Task := Runtime.CreateTask(Empty, nil, 67108865);
  except
    on EFiberUsage do
      Rejected := True;
  end;
  Check(Rejected, 'CONTEXT_STACK_TOO_LARGE');
  Task := Runtime.CreateTask(Empty, nil);
  try
    raise Exception.Create('root handler');
  except
    Rejected := False;
    try
      Task.Resume;
    except
      on EFiberUsage do
        Rejected := True;
    end;
    Check(Rejected and (Task.State = fsCreated), 'CONTEXT_ACTIVE_HANDLER_RESUME');
  end;
  Task.Free;
  A := Runtime;
  Check(A.BackendName <> '', 'CONTEXT_BACKEND_NAME');
end;

procedure TestCancellation;
var
  Task: TFiberTask;
  Calls: Integer;
  Data: TCaseData;
  Rejected: Boolean;
begin
  Calls := 0;
  Task := Runtime.CreateTask(Empty, @Calls);
  Task.Cancel;
  Task.Cancel;
  Check((Task.State = fsCancelled) and Task.CancelRequested and (Calls = 0),
    'CONTEXT_CANCEL_CREATED');
  Rejected := False;
  try
    Task.Resume;
  except
    on EFiberUsage do
      Rejected := True;
  end;
  Check(Rejected, 'CONTEXT_CANCELLED_RESUME');
  Task.Free;
  FillChar(Data, SizeOf(Data), 0);
  Data.Mode := rmNearest;
  Task := Runtime.CreateTask(Interleaved, @Data);
  Task.Resume;
  Task.Cancel;
  Check((Task.State = fsSuspended) and Task.CancelRequested, 'CONTEXT_CANCEL_PENDING');
  Task.Resume;
  Check((Task.State = fsCancelled) and (Data.Cleanups = 2) and (Destroyed = 3),
    'CONTEXT_CANCEL_CLEANUP');
  Task.Free;
  Task := Runtime.CreateTask(CatchCancellation, @Calls);
  Task.Resume;
  Task.Cancel;
  Task.Resume;
  Check((Task.State = fsSuspended) and (Calls = 2), 'CONTEXT_CANCEL_CAUGHT');
  Task.Resume;
  Check(Task.State = fsCancelled, 'CONTEXT_CANCEL_RECHECK');
  Task.Free;
  Task := Runtime.CreateTask(Fault, nil);
  Task.Resume;
  Task.Resume;
  Check((Task.State = fsFaulted) and (Task.ErrorClass = 'EConvertError') and
    (Task.ErrorMessage = 'contained fault'), 'CONTEXT_FAULT_CONTAINMENT');
  Task.Free;
  FreshException;
  Task := Runtime.CreateTask(ObjectFault, nil);
  Task.Resume;
  Check((Task.State = fsFaulted) and (Task.ErrorClass = 'TObject'),
    'CONTEXT_OBJECT_FAULT_CONTAINMENT');
  Task.Free;
  Calls := 0;
  Task := Runtime.CreateTask(CancelAndReturn, @Calls);
  Task.Resume;
  Check((Task.State = fsCompleted) and Task.CancelRequested and (Calls = 1),
    'CONTEXT_CAUGHT_CANCEL_COMPLETION');
  Task.Free;
end;
