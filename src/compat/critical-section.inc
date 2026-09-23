{$IFNDEF FPC}
{ Delphi spelling of the FPC RTL critical-section lifetime calls. Enter/Leave
  already have matching names in the Windows unit. }
procedure InitCriticalSection(var Section: TRTLCriticalSection);
begin
  InitializeCriticalSection(Section);
end;

procedure DoneCriticalSection(var Section: TRTLCriticalSection);
begin
  DeleteCriticalSection(Section);
end;
{$ENDIF}
