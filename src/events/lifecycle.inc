constructor TFiberEventHub.Create(Scheduler: TFiberScheduler;
  Capacity, MaxSubscriptions: Integer);
var
  I: Integer;
begin
  inherited Create;
  if Scheduler = nil then
    raise EFiberUsage.Create('Event hub requires scheduler');
  Scheduler.CheckOwner;
  if (Capacity <= 0) or (MaxSubscriptions <= 0) then
    raise ERangeError.Create('Event hub bounds must be positive');
  FScheduler := Scheduler;
  InitCriticalSection(FLock);
  FLockReady := True;
  SetLength(FEndpoints, Scheduler.MaxTasks);
  SetLength(FSubscriptions, MaxSubscriptions);
  SetLength(FDeliveries, Capacity);
  SetLength(FEnvelopes, Capacity);
  for I := 0 to High(FEnvelopes) do
    FEnvelopes[I].Hub := Self;
end;

procedure TFiberEventHub.BeforeDestruction;
var
  I: Integer;
begin
  if FScheduler <> nil then
    FScheduler.CheckOwner;
  if FLockReady then
  begin
    EnterCriticalSection(FLock);
    try
      if FPosts <> 0 then
        raise EFiberUsage.Create('Event hub has accepted posts');
    finally
      LeaveCriticalSection(FLock)
    end;
  end;
  for I := 0 to FEndpointCount - 1 do
    if not FEndpoints[I].FDetached then
      raise EFiberUsage.Create('Event hub has attached service');
  for I := 0 to FSubscriptionCount - 1 do
    if not (FSubscriptions[I].FTask.State in [fsCompleted, fsCancelled, fsFaulted]) then
      raise EFiberUsage.Create('Event hub has live dispatcher');
  inherited;
end;

destructor TFiberEventHub.Destroy;
var
  I: Integer;
begin
  for I := 0 to FSubscriptionCount - 1 do
  begin
    FSubscriptions[I].FRelease := True;
    FSubscriptions[I].Free;
  end;
  for I := 0 to FEndpointCount - 1 do
  begin
    FEndpoints[I].FRelease := True;
    FEndpoints[I].Free;
  end;
  if FLockReady then
    DoneCriticalSection(FLock);
  inherited;
end;

function TFiberEventHub.Attach(Service: TFiberService): TServiceEndpoint;
begin
  FScheduler.CheckOwner;
  if (Service = nil) or (Service.Scheduler <> FScheduler) then
    raise EFiberUsage.Create('Service belongs to another scheduler');
  if FEndpointCount = Length(FEndpoints) then
    raise EFiberUsage.Create('Event endpoint capacity exhausted');
  Result := TServiceEndpoint.Create;
  Result.FHub := Self;
  try
    Service.BindLifecycle(Result)
  except
    Result.FRelease := True;
    Result.Free;
    raise
  end;
  FEndpoints[FEndpointCount] := Result;
  Inc(FEndpointCount);
end;

function TFiberEventHub.Subscribe(Recipient: TServiceEndpoint;
  Handler: TServiceEventProc; Data: Pointer): TServiceSubscription;
begin
  FScheduler.CheckOwner;
  if (Recipient = nil) or (Recipient.FHub <> Self) or Recipient.FClosed then
    raise EFiberUsage.Create('Recipient endpoint is unavailable');
  if not Assigned(Handler) then
    raise EFiberUsage.Create('Event handler is required');
  if FSubscriptionCount = Length(FSubscriptions) then
    raise EFiberUsage.Create('Event subscription capacity exhausted');
  Result := TServiceSubscription.Create;
  Result.FHub := Self;
  Result.FRecipient := Recipient;
  Result.FHandler := Handler;
  Result.FData := Data;
  try
    Result.FTask := FScheduler.Spawn(DispatchEntry, Result)
  except
    Result.FRelease := True;
    Result.Free;
    raise
  end;
  FSubscriptions[FSubscriptionCount] := Result;
  Inc(FSubscriptionCount);
end;

procedure TFiberEventHub.CloseEndpoint(Endpoint: TServiceEndpoint);
var
  I: Integer;
  Subscription: TServiceSubscription;
begin
  FScheduler.CheckOwner;
  EnterCriticalSection(FLock);
  try
    Endpoint.FClosed := True
  finally
    LeaveCriticalSection(FLock)
  end;
  Purge(Endpoint, nil);
  for I := 0 to FSubscriptionCount - 1 do
  begin
    Subscription := FSubscriptions[I];
    if Subscription.FRecipient = Endpoint then
    begin
      Subscription.FClosed := True;
      Purge(nil, Subscription);
      Subscription.FTask.Cancel;
    end;
  end;
end;

function TFiberEventHub.EndpointSettled(Endpoint: TServiceEndpoint): Boolean;
var
  I: Integer;
begin
  FScheduler.CheckOwner;
  Result := False;
  if Endpoint.FActive <> 0 then
    Exit;
  for I := 0 to FSubscriptionCount - 1 do
    if (FSubscriptions[I].FRecipient = Endpoint) and not
      (FSubscriptions[I].FTask.State in [fsCompleted, fsCancelled, fsFaulted]) then
      Exit;
  Result := True;
end;

function TFiberEventHub.GetMetric(Index: Integer): Int64;
begin
  FScheduler.CheckOwner;
  case Index of
    0:
      Result := FPublished;
    1:
      Result := FDelivered;
    2:
      Result := FDiscarded;
    3:
      Result := FRejected;
    4:
      Result := FPending;
    5:
      Result := FActive;
    7:
      Result := FPostRejected;
    8:
      Result := Length(FDeliveries);
    10:
      Result := FAdmitted;
    11:
      Result := FAborted;
    else
    begin
      EnterCriticalSection(FLock);
      try
        if Index = 6 then
          Result := FPostAccepted
        else
          Result := FPosts
      finally
        LeaveCriticalSection(FLock)
      end;
    end;
  end;
end;

procedure TServiceEndpoint.BeforeDestruction;
begin
  if FHub <> nil then
    FHub.FScheduler.CheckOwner;
  if not FRelease then
    raise EFiberUsage.Create('Event hub owns endpoint');
  inherited;
end;

function TServiceEndpoint.Publish(const Payload: IInterface): Boolean;
begin
  Result := FHub.Publish(Self, Payload)
end;

function TServiceEndpoint.Post(const Payload: IInterface): Boolean;
begin
  Result := FHub.Post(Self, Payload)
end;

procedure TServiceEndpoint.BeginStop;
begin
  FHub.CloseEndpoint(Self)
end;

function TServiceEndpoint.IsSettled: Boolean;
begin
  Result := FHub.EndpointSettled(Self)
end;

procedure TServiceEndpoint.Detach;
begin
  FHub.FScheduler.CheckOwner;
  if not FClosed or not IsSettled then
    raise EFiberUsage.Create('Endpoint is still active');
  FDetached := True;
end;

function TServiceEndpoint.GetClosed: Boolean;
begin
  FHub.FScheduler.CheckOwner;
  Result := FClosed
end;

procedure TServiceSubscription.BeforeDestruction;
begin
  if FHub <> nil then
    FHub.FScheduler.CheckOwner;
  if not FRelease then
    raise EFiberUsage.Create('Event hub owns subscription');
  inherited;
end;

function TServiceSubscription.GetTask: TScheduledTask;
begin
  FHub.FScheduler.CheckOwner;
  Result := FTask
end;
