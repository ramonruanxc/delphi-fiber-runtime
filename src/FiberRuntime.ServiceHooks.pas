unit FiberRuntime.ServiceHooks;
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
interface
type
  { Borrowed lifecycle binding. The binding outlives its attached service. }
  TServiceHooks = class
  public
    procedure BeginStop; virtual; abstract;
    function IsSettled: Boolean; virtual; abstract;
    procedure Detach; virtual; abstract;
  end;
implementation
end.
