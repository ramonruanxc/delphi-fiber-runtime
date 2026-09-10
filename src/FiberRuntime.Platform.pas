unit FiberRuntime.Platform;
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$IFDEF MSWINDOWS}{$DEFINE WINDOWS}{$ENDIF}
interface
uses SysUtils;
type
  { One wait owner; Cancel is cross-thread and sticky. Join before destruction. }
  TPlatformTimer = class
  private
    {$IFDEF WINDOWS}
    FTimer, FCancel: THandle;
    FFrequency: Int64;
    FHighResolution: Boolean;
    {$ELSE}
    FTimer, FCancel: Integer;
    {$IFDEF DARWIN}
    FCancelled: LongInt;
    FNumer, FDenom: Cardinal;
    {$ENDIF}
    {$ENDIF}
  public
    constructor Create;
    destructor Destroy; override;
    function NowUs: Int64;
    function WaitUntil(ADeadlineUs: Int64): Boolean;
    procedure Cancel;
    function BackendName: string;
  end;
implementation
{$IFDEF WINDOWS}
uses Windows;
{$ENDIF}

{ Exact rational conversion without overflowing the intermediate product.
  Native clock scale factors are at most 32-bit values times 1000. }
function Scale(A, B, C: Int64; RoundUp: Boolean): Int64;
var Bit: Integer; R, Addend: Int64;
begin
  if (A < 0) or (B <= 0) or (C <= 0) or
     (B > High(Int64) div 3) or (C > High(Int64) div 3) then
    raise ERangeError.Create('Invalid native clock conversion');
  if A <= High(Int64) div B then
  begin
    R := A * B;
    Result := R div C;
    if RoundUp and ((R mod C) <> 0) then Inc(Result);
    Exit;
  end;
  Result := 0;
  R := 0;
  for Bit := 62 downto 0 do
  begin
    if Result > High(Int64) div 2 then
      raise ERangeError.Create('Native clock conversion overflow');
    Result := Result * 2;
    R := R * 2;
    if ((A shr Bit) and 1) <> 0 then R := R + B;
    Addend := R div C;
    if Result > High(Int64) - Addend then
      raise ERangeError.Create('Native clock conversion overflow');
    Result := Result + Addend;
    R := R mod C;
  end;
  if RoundUp and (R <> 0) then
  begin
    if Result = High(Int64) then
      raise ERangeError.Create('Native deadline conversion overflow');
    Inc(Result);
  end;
end;

{$IFDEF WINDOWS}
{$I platform/windows.inc}
{$ELSE}
{$IFDEF LINUX}
{$IFNDEF CPUX86_64}{$FATAL Linux adapter requires x86_64}{$ENDIF}
{$I platform/linux.inc}
{$ELSE}
{$IFDEF DARWIN}
{$I platform/darwin.inc}
{$ELSE}
{$MESSAGE FATAL 'Unsupported native timer platform'}
{$ENDIF}
{$ENDIF}
{$ENDIF}
end.
