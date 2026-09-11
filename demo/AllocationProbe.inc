{ FPC 3.2.2 benchmark-only entry-point observer. One carrier, no helper threads.
  Counts calls through GetMem/AllocMem/ReAllocMem, not OS allocations or bytes.
  ABI source: FPCSource/release_3_2_2/rtl/inc/heaph.inc. No hook may suspend. }
var
  ProbeOriginal: TMemoryManager;
  ProbeCalls, ProbeMeasuredCalls: LongInt;
  ProbeBefore, ProbeAfter: TFPCHeapStatus;

function ProbeGetMem(Size: PtrUInt): Pointer;
begin InterlockedIncrement(ProbeCalls); Result := ProbeOriginal.GetMem(Size); end;
function ProbeAllocMem(Size: PtrUInt): Pointer;
begin InterlockedIncrement(ProbeCalls); Result := ProbeOriginal.AllocMem(Size); end;
function ProbeRealloc(var P: Pointer; Size: PtrUInt): Pointer;
begin InterlockedIncrement(ProbeCalls); Result := ProbeOriginal.ReAllocMem(P, Size); end;
procedure StartAllocationProbe;
var Manager: TMemoryManager;
begin
  GetMemoryManager(ProbeOriginal); Manager := ProbeOriginal;
  ProbeBefore := GetFPCHeapStatus; ProbeCalls := 0;
  Manager.GetMem := ProbeGetMem; Manager.AllocMem := ProbeAllocMem;
  Manager.ReAllocMem := ProbeRealloc; SetMemoryManager(Manager);
end;
procedure StopAllocationProbe;
begin
  SetMemoryManager(ProbeOriginal);
  ProbeMeasuredCalls := ProbeCalls; ProbeAfter := GetFPCHeapStatus;
end;

procedure ValidateAllocationProbe;
var P: Pointer;
begin
  StartAllocationProbe;
  try
    P := GetMem(64);
    try ReAllocMem(P, 128); finally FreeMem(P); end;
  finally StopAllocationProbe; end;
  if ProbeMeasuredCalls < 2 then raise Exception.Create('Allocation observer did not detect probe');
end;
