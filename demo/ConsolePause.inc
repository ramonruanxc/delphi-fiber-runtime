{ Keeps the console open when a demo is started from the Delphi IDE (F9).
  It never waits under FPC, CI or a plain command-line run. }
procedure PauseUnderDebugger;
begin
  {$IFNDEF FPC}
  if DebugHook <> 0 then
  begin
    Write('Press Enter to exit...');
    ReadLn;
  end;
  {$ENDIF}
end;
