{ Delphi (XE7+) Windows RTL adapter. Experimental and unvalidated: no Delphi
  build has been executed by the project automation.
  SwitchToFiber swaps the thread information block fields that Delphi relies
  on: the Win32 SEH registration chain and the stack base/limit used by Win32
  unwinding, Win64 table-based unwinding and guard-page overflow detection.
  The Delphi RTL keeps no Pascal-side stack bounds or exception-address chain
  that must follow a context, so these hooks deliberately do nothing.

  Other RTL threadvars, including the raise list, remain shared by every task
  on the carrier. Switching in handlers or during unwinding stays prohibited. }

procedure InstallRTL(const Value: TContextRTL);
begin
end;

procedure SwitchRTL(var Source: TContextRTL; const Target: TContextRTL);
begin
end;
