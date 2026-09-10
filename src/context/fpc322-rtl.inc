{ Pinned to FPC 3.2.2 rtl/inc/except.inc and systemh.inc.
  SJLJ helpers use the compiler's DEFAULT Pascal ABI, never cdecl.
  TExceptAddr is System's public record: Buf, Next, FrameType.
  The synthetic node exposes the old head and installs a new head on pop.
  There are NO managed values, try frames, allocations or raising operations
  in these procedures. Keep stack checks off until the physical stack matches.
  Windows SEH is switched by the OS; only Pascal stack metadata is handled here.

  Prohibited: switching in handlers, unwinding, allocator/error hooks, or while
  holding native locks. RaiseList is only an active-object guard, NOT universal
  unwinding detection. Async signals in this tiny switch interval are unsupported.
  Other RTL threadvars remain shared and are not claimed to be fiber-local. }
{$PUSH}{$S-}
{$IFNDEF WINDOWS}
function ContextPush(Ft: LongInt; Buf, NewAddr: Pointer): PJmp_buf;
  external name 'FPC_PUSHEXCEPTADDR';
procedure ContextPop; external name 'FPC_POPADDRSTACK';

procedure InstallHead(Head: PExceptAddr);
var Node: TExceptAddr;
begin
  ContextPush(0, nil, @Node);
  Node.Next := Head;
  ContextPop;
end;
{$ENDIF}

procedure InstallRTL(const Value: TContextRTL);
begin
  System.StackBottom := Value.Bottom;
  System.StackLength := Value.Length;
  {$IFNDEF WINDOWS}
  {$IFNDEF CONTEXT_PROVE_RTL}InstallHead(Value.Head);{$ENDIF}
  {$ENDIF}
end;

procedure SwitchRTL(var Source: TContextRTL; const Target: TContextRTL);
{$IFNDEF WINDOWS}var Node: TExceptAddr;{$ENDIF}
begin
  Source.Bottom := System.StackBottom;
  Source.Length := System.StackLength;
  {$IFNDEF WINDOWS}
  ContextPush(0, nil, @Node);
  Source.Head := Node.Next;
  ContextPop;
  {$ENDIF}
  InstallRTL(Target);
end;
{$POP}
