function TClockContinuityGuard.Observe(ABeforeActive, AInclusive,
  AAfterActive: Int64): Int64;
var Lower, Upper: Int64;
begin
  if (ABeforeActive < 0) or (AInclusive < 0) or
     (AAfterActive < ABeforeActive) or
     (FInitialized and ((ABeforeActive < FLastActive) or
                       (AInclusive < FLastInclusive))) then
    raise EClockDiscontinuity.Create('CLOCK_PAIR_BACKWARD');
  if AAfterActive - ABeforeActive > ClockSampleMaxWidthUs then
    raise EClockDiscontinuity.Create('CLOCK_SAMPLE_UNCERTAIN');
  { Active reads bracket the inclusive read: its true offset lies in [L,U]. }
  Lower := AInclusive - AAfterActive;
  Upper := AInclusive - ABeforeActive;
  if FInitialized then
  begin
    if (FLower >= Low(Int64) + ClockSuspendToleranceUs) and
       (Upper < FLower - ClockSuspendToleranceUs) then
      raise EClockDiscontinuity.Create('CLOCK_OFFSET_BACKWARD');
    if (FUpper <= High(Int64) - ClockSuspendToleranceUs) and
       (Lower > FUpper + ClockSuspendToleranceUs) then
    begin
      if FGeneration = High(Int64) then
        raise EClockDiscontinuity.Create('CLOCK_GENERATION_OVERFLOW');
      Inc(FGeneration);
      FLower := Lower;
      FUpper := Upper;
    end;
  end
  else
  begin
    FLower := Lower;
    FUpper := Upper;
    FInitialized := True;
  end;
  FLastActive := AAfterActive;
  FLastInclusive := AInclusive;
  Result := FGeneration;
end;
