{$IFDEF FPC}
{ FPC 3.2.2 benchmark-only entry-point observer. Counter increments are atomic across benchmark threads.
  Counts calls through GetMem/AllocMem/ReAllocMem, not OS allocations or bytes.
  Install before creating helper threads and restore after joins.
  ABI source: FPCSource/release_3_2_2/rtl/inc/heaph.inc. No hook may suspend. }
var
  ProbeOriginal: TMemoryManager;
  ProbeCalls, ProbeMeasuredCalls: LongInt;
  ProbeBefore, ProbeAfter: TFPCHeapStatus;

function ProbeGetMem(Size: PtrUInt): Pointer;
begin
  InterlockedIncrement(ProbeCalls);
  Result := ProbeOriginal.GetMem(Size);
end;

function ProbeAllocMem(Size: PtrUInt): Pointer;
begin
  InterlockedIncrement(ProbeCalls);
  Result := ProbeOriginal.AllocMem(Size);
end;

function ProbeRealloc(var P: Pointer; Size: PtrUInt): Pointer;
begin
  InterlockedIncrement(ProbeCalls);
  Result := ProbeOriginal.ReAllocMem(P, Size);
end;

procedure StartAllocationProbe;
var
  Manager: TMemoryManager;
begin
  GetMemoryManager(ProbeOriginal);
  Manager := ProbeOriginal;
  ProbeBefore := GetFPCHeapStatus;
  ProbeCalls := 0;
  Manager.GetMem := ProbeGetMem;
  Manager.AllocMem := ProbeAllocMem;
  Manager.ReAllocMem := ProbeRealloc;
  SetMemoryManager(Manager);
end;

procedure StopAllocationProbe;
begin
  SetMemoryManager(ProbeOriginal);
  ProbeMeasuredCalls := ProbeCalls;
  ProbeAfter := GetFPCHeapStatus;
end;

procedure ValidateAllocationProbe;
var
  P: Pointer;
begin
  StartAllocationProbe;
  try
    P := GetMem(64);
    try
      ReAllocMem(P, 128);
    finally
      FreeMem(P);
    end;
  finally
    StopAllocationProbe;
  end;
  if ProbeMeasuredCalls < 2 then
    raise Exception.Create('Allocation observer did not detect probe');
end;
{$ELSE}
{ Delphi XE3+ variant of the same entry-point observer, using TMemoryManagerEx.
  Unvalidated: no Delphi build has been executed by the project automation.
  CurrHeapUsed sums the built-in memory manager's allocated small, medium and
  large block sizes from GetMemoryManagerState; it describes that manager only,
  not a replacement installed by the application, and not OS committed memory.
  The Delphi RTL keeps no peak, so no MaxHeapUsed value is reported.
  Counter increments are atomic. No hook may suspend. }
type
  TProbeHeapStatus = record
    CurrHeapUsed: Int64;
  end;

var
  ProbeOriginal: TMemoryManagerEx;
  ProbeCalls, ProbeMeasuredCalls: Integer;
  ProbeBefore, ProbeAfter: TProbeHeapStatus;

function ProbeGetMem(Size: NativeInt): Pointer;
begin
  AtomicIncrement(ProbeCalls);
  Result := ProbeOriginal.GetMem(Size);
end;

function ProbeAllocMem(Size: NativeInt): Pointer;
begin
  AtomicIncrement(ProbeCalls);
  Result := ProbeOriginal.AllocMem(Size);
end;

function ProbeRealloc(P: Pointer; Size: NativeInt): Pointer;
begin
  AtomicIncrement(ProbeCalls);
  Result := ProbeOriginal.ReallocMem(P, Size);
end;

function ProbeHeapStatus: TProbeHeapStatus;
var
  State: TMemoryManagerState;
  I: Integer;
begin
  GetMemoryManagerState(State);
  Result.CurrHeapUsed := Int64(State.TotalAllocatedMediumBlockSize) +
    Int64(State.TotalAllocatedLargeBlockSize);
  for I := Low(State.SmallBlockTypeStates) to High(State.SmallBlockTypeStates) do
    Result.CurrHeapUsed := Result.CurrHeapUsed +
      Int64(State.SmallBlockTypeStates[I].AllocatedBlockCount) *
      State.SmallBlockTypeStates[I].UseableBlockSize;
end;

procedure StartAllocationProbe;
var
  Manager: TMemoryManagerEx;
begin
  GetMemoryManager(ProbeOriginal);
  Manager := ProbeOriginal;
  ProbeBefore := ProbeHeapStatus;
  ProbeCalls := 0;
  Manager.GetMem := ProbeGetMem;
  Manager.AllocMem := ProbeAllocMem;
  Manager.ReallocMem := ProbeRealloc;
  SetMemoryManager(Manager);
end;

procedure StopAllocationProbe;
begin
  SetMemoryManager(ProbeOriginal);
  ProbeMeasuredCalls := ProbeCalls;
  ProbeAfter := ProbeHeapStatus;
end;

procedure ValidateAllocationProbe;
var
  P: Pointer;
begin
  StartAllocationProbe;
  try
    GetMem(P, 64);
    try
      ReallocMem(P, 128);
    finally
      FreeMem(P);
    end;
  finally
    StopAllocationProbe;
  end;
  if ProbeMeasuredCalls < 2 then
    raise Exception.Create('Allocation observer did not detect probe');
end;
{$ENDIF}
