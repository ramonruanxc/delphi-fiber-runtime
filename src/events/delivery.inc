function TFiberEventHub.Publish(Source: TServiceEndpoint;
  const Payload: IInterface): Boolean;
var
  I, Slot, Needed: Integer;
begin
  FScheduler.CheckOwner;
  Result := False;
  if Source.FClosed then
  begin
    Inc(FRejected);
    Exit
  end;
  Needed := 0;
  for I := 0 to FSubscriptionCount - 1 do
    if not FSubscriptions[I].FClosed then
      Inc(Needed);
  if (Needed > Length(FDeliveries) - FPending) or
    (FSequence > High(Int64) - Needed) then
  begin
    Inc(FRejected);
    Exit
  end;
  Slot := 0;
  for I := 0 to FSubscriptionCount - 1 do
    if not FSubscriptions[I].FClosed then
    begin
      while FDeliveries[Slot].Recipient <> nil do
        Inc(Slot);
      Inc(FSequence);
      FDeliveries[Slot].Source := Source;
      FDeliveries[Slot].Payload := Payload;
      FDeliveries[Slot].Sequence := FSequence;
      FDeliveries[Slot].Recipient := FSubscriptions[I];
      Inc(FPending);
      FScheduler.WakeTask(FSubscriptions[I].FTask);
    end;
  Inc(FPublished);
  Inc(FAdmitted, Needed);
  Result := True;
end;

function TFiberEventHub.Post(Source: TServiceEndpoint;
  const Payload: IInterface): Boolean;
var
  I: Integer;
  RejectedPayload: IInterface;
begin
  Result := False;
  EnterCriticalSection(FLock);
  try
    if Source.FClosed then
      Exit;
    for I := 0 to High(FEnvelopes) do
      if not FEnvelopes[I].Used then
      begin
        FEnvelopes[I].Used := True;
        FEnvelopes[I].Source := Source;
        FEnvelopes[I].Payload := Payload;
        Inc(FPosts);
        try
          Result := FScheduler.Post(PostedDelivery, @FEnvelopes[I]);
          if Result then
            Inc(FPostAccepted);
        finally
          if not Result then
          begin
            RejectedPayload := FEnvelopes[I].Payload;
            FEnvelopes[I].Payload := nil;
            FEnvelopes[I].Source := nil;
            FEnvelopes[I].Used := False;
            Dec(FPosts);
          end;
        end;
        Exit;
      end;
  finally
    LeaveCriticalSection(FLock)
  end;
end;

procedure TFiberEventHub.Purge(Source: TServiceEndpoint; Recipient: TServiceSubscription);
var
  I: Integer;
begin
  for I := 0 to High(FDeliveries) do
    if (FDeliveries[I].Recipient <> nil) and
      (((Source <> nil) and (FDeliveries[I].Source = Source)) or
      ((Recipient <> nil) and (FDeliveries[I].Recipient = Recipient))) then
    begin
      FDeliveries[I].Recipient := nil;
      FDeliveries[I].Source := nil;
      FDeliveries[I].Payload := nil;
      Dec(FPending);
      Inc(FDiscarded);
    end;
end;

function TFiberEventHub.Take(Recipient: TServiceSubscription;
  out Delivery: TEventDelivery): Boolean;
var
  I, Slot: Integer;
  Sequence: Int64;
begin
  Slot := -1;
  Sequence := High(Int64);
  for I := 0 to High(FDeliveries) do
    if (FDeliveries[I].Recipient = Recipient) and
      (FDeliveries[I].Sequence <= Sequence) then
    begin
      Slot := I;
      Sequence := FDeliveries[I].Sequence;
    end;
  Result := Slot >= 0;
  if Result then
  begin
    Delivery := FDeliveries[Slot];
    FDeliveries[Slot].Payload := nil;
    FDeliveries[Slot].Recipient := nil;
    FDeliveries[Slot].Source := nil;
    Dec(FPending);
  end;
end;

procedure TServiceSubscription.Execute(Task: TScheduledTask);
var
  Delivery: TEventDelivery;
  Completed: Boolean;
begin
  try
    while not FClosed do
    begin
      if not FHub.Take(Self, Delivery) then
      begin
        Task.Park;
        Continue
      end;
      Inc(Delivery.Source.FActive);
      Inc(FHub.FActive);
      Completed := False;
      try
        FHandler(Task, Delivery.Source, Delivery.Payload, FData);
        Completed := True;
        Inc(FHub.FDelivered);
      finally
        if not Completed then
          Inc(FHub.FAborted);
        Delivery.Payload := nil;
        Dec(Delivery.Source.FActive);
        Dec(FHub.FActive);
      end;
    end;
  finally
    FClosed := True;
    FHub.Purge(nil, Self)
  end;
end;
