defmodule Tymeslot.Infrastructure.CrashReporter do
  @moduledoc """
  Global `:logger` handler that records process crashes in ErrorTracker.

  ErrorTracker's integrations record exceptions raised in Phoenix requests,
  in the LiveView callbacks Phoenix instruments (mount, handle_params,
  handle_event, render) and in Oban jobs. Everything else (a GenServer, a
  supervised Task, a bare process, a LiveView's `handle_info/2`) is visible
  only as the crash report OTP logs when the process dies: an `:error` event
  carrying `crash_reason` metadata. This handler matches those events and
  passes them to `ErrorTracker.report/3`, which applies the same Ignorer and
  Filter as the integrations. Alerting on what is recorded is
  `Tymeslot.Infrastructure.ErrorTracking.Alerter`'s job, not this module's.

  ## Recording each crash once

  A crash an integration recorded is then logged by the dying process too: a
  LiveView event handler that raises is recorded by the LiveView integration
  and then terminates the LiveView's GenServer, which logs it. `attach/0`
  therefore also listens to ErrorTracker's `[:error_tracker, :occurrence,
  :new]` event and remembers, in the process that reported, what it recorded.
  The `:logger` handler runs in the process that crashed, so it can tell
  whether the crash it is looking at was recorded a moment earlier in the
  same process, and skip it.

  Matching on the recorded crash rather than on which integration's context
  keys the process carries is deliberate: a LiveView process carries
  `"live_view.*"` context from mount onwards, but a crash in its
  `handle_info/2` is recorded by no integration.

  ## Safety

    * The handler callback does no database work. It filters and offloads
      the report to `Tymeslot.TaskSupervisor`, so a slow or failing database
      can never block or kill the logging pipeline. The crashing process's
      ErrorTracker context is captured first and passed along, since the
      offloaded task has none of its own.
    * A failure inside the offloaded report is logged under this module's own
      domain, which the handler's filter drops, so it cannot re-enter the
      handler.
    * Nothing is done while ErrorTracker's `enabled` switch is off, read on
      every crash as ErrorTracker itself reads it.
    * Orderly exits are not recorded. A LiveView or LiveComponent sent an
      event name none of its `handle_event/3` clauses matches is logged as a
      warning instead, by the rule in
      `Tymeslot.Infrastructure.ErrorTracking.UnmatchedEvent`.
  """

  alias String.Chars
  alias Tymeslot.Infrastructure.ErrorTracking
  alias Tymeslot.Infrastructure.ErrorTracking.UnmatchedEvent

  require Logger

  @own_domain [:tymeslot, :crash_reporter]

  @handler_id :tymeslot_crash_reporter
  @telemetry_handler_id "tymeslot-crash-reporter-recorded"

  # Process dictionary key holding the last crash ErrorTracker recorded in
  # this process, as `{kind, reason}` strings.
  @recorded_key :tymeslot_crash_reporter_recorded

  @normal_exits [:normal, :shutdown]

  @event_name_max_length 100

  @doc """
  Installs the crash reporter: the global `:logger` handler, and the
  telemetry handler that tells it which crashes are already recorded.

  Idempotent, so safe to call on application restart inside the same BEAM.
  """
  @spec attach() :: :ok | {:error, term()}
  def attach do
    detach()

    :ok =
      :telemetry.attach(
        @telemetry_handler_id,
        [:error_tracker, :occurrence, :new],
        &__MODULE__.remember_recorded/4,
        nil
      )

    :logger.add_handler(@handler_id, __MODULE__, %{
      level: :error,
      filter_default: :log,
      filters: [
        # Loop prevention: drop anything this module logs under its own domain.
        # Elixir's Logger prepends :elixir to custom domains, so the match domain
        # is [:elixir | @own_domain], not @own_domain itself.
        own_logs: {&:logger_filters.domain/2, {:stop, :sub, [:elixir | @own_domain]}},
        # Oban job failures are recorded by ErrorTracker's Oban integration and
        # today carry no crash_reason. Dropping Oban's domain means a future
        # Oban that logs them with crash_reason cannot record them twice.
        oban_logs: {&:logger_filters.domain/2, {:stop, :sub, [:elixir, :oban]}}
      ]
    })
  end

  @doc "Removes both handlers if installed. Used by tests."
  @spec detach() :: :ok
  def detach do
    _removed = :logger.remove_handler(@handler_id)
    _detached = :telemetry.detach(@telemetry_handler_id)
    :ok
  end

  @doc """
  Returns true unless the crash is an orderly exit (`:normal`, `:shutdown`,
  `{:shutdown, _}`). Whether an exception is client-error noise is the
  Ignorer's decision, made inside `ErrorTracker.report/3`.
  """
  @spec reportable?(atom(), term()) :: boolean()
  def reportable?(:exit, reason) when reason in @normal_exits, do: false
  def reportable?(:exit, {:shutdown, _reason}), do: false
  def reportable?(_kind, _reason), do: true

  @doc false
  # Telemetry handler for `[:error_tracker, :occurrence, :new]`. Runs in the
  # process that reported; telemetry detaches a handler that raises, so it
  # only ever matches and stores.
  @spec remember_recorded([atom()], map(), map(), term()) :: :ok
  def remember_recorded(_event, _measurements, metadata, _config) do
    case metadata do
      %{error: %{kind: kind}, occurrence: %{reason: reason}} ->
        Process.put(@recorded_key, {kind, reason})

      _other ->
        nil
    end

    :ok
  end

  # :logger handler callback. Return value is ignored by :logger.
  # Clauses are ordered: exception, then throw, then the catch-all exit.

  @doc false
  @spec log(:logger.log_event(), :logger.handler_config()) :: :ok
  def log(%{meta: %{crash_reason: {reason, stacktrace}} = meta}, _config)
      when is_exception(reason) and is_list(stacktrace) do
    handle_crash(:error, reason, stacktrace, meta)
  end

  def log(%{meta: %{crash_reason: {{:nocatch, reason}, stacktrace}} = meta}, _config)
      when is_list(stacktrace) do
    handle_crash(:throw, reason, stacktrace, meta)
  end

  def log(%{meta: %{crash_reason: {reason, stacktrace}} = meta}, _config)
      when is_list(stacktrace) do
    handle_crash(:exit, reason, stacktrace, meta)
  end

  def log(_log_event, _config), do: :ok

  defp handle_crash(kind, reason, stacktrace, meta) do
    cond do
      UnmatchedEvent.exception?(reason) -> log_unmatched_client_event(reason, stacktrace)
      not tracking_enabled?() -> :ok
      not reportable?(kind, reason) -> :ok
      already_recorded?(kind, reason, stacktrace) -> :ok
      true -> offload(kind, reason, stacktrace, crash_context(meta))
    end

    :ok
  rescue
    # Runs in the logging process. A transient failure of a dependency (e.g.
    # TaskSupervisor briefly unavailable after a crash) must degrade to "drop
    # this report", never propagate into the logging pipeline or count toward
    # handler removal.
    #
    # Logging here would re-enter the very pipeline that just failed, so this
    # clause must stay silent; the check documents it as the deliberate residual.
    # credo:disable-for-next-line CredoChecks.NoSwallowedException
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  # Read per crash, as ErrorTracker reads it per report, so switching error
  # tracking off also stops the offloaded work here.
  defp tracking_enabled?,
    do: Application.get_env(:error_tracker, :enabled, true) not in [false, nil]

  # Compares the crash with what ErrorTracker last recorded in this process,
  # normalised the way ErrorTracker normalises it. The entry is consumed, so
  # a later crash of a long-lived process is never matched against it.
  defp already_recorded?(kind, reason, stacktrace) do
    case Process.delete(@recorded_key) do
      nil -> false
      recorded -> recorded == identity(kind, reason, stacktrace)
    end
  rescue
    # An identity that cannot be computed is not a match: record the crash.
    # credo:disable-for-next-line CredoChecks.NoSwallowedException
    _exception -> false
  end

  defp identity(kind, reason, stacktrace) do
    case Exception.normalize(kind, reason, stacktrace) do
      %module{} = exception when is_exception(exception) ->
        {to_string(module), Exception.message(exception)}

      payload ->
        {to_string(kind), payload_to_string(payload)}
    end
  end

  # ErrorTracker's own fallback: `to_string/1` where the payload implements
  # `String.Chars`, `inspect/1` otherwise.
  defp payload_to_string(payload) do
    if Chars.impl_for(payload), do: to_string(payload), else: inspect(payload)
  end

  # Logged from the handler process under our own domain, so it can never
  # re-enter this handler. The event name is in the top frame when the BEAM
  # reports the failed call with its arguments.
  defp log_unmatched_client_event(%FunctionClauseError{module: module}, stacktrace) do
    event =
      case stacktrace do
        [{_module, :handle_event, [event, _params, _socket], _location} | _frames] ->
          event_name(event)

        _other ->
          nil
      end

    Logger.warning("Client sent a LiveView event no handle_event/3 clause matches",
      live_module: inspect(module),
      event: event,
      domain: @own_domain
    )
  end

  defp event_name(event) when is_binary(event), do: String.slice(event, 0, @event_name_max_length)
  defp event_name(event), do: inspect(event, limit: 5, printable_limit: @event_name_max_length)

  # The crashing process's own ErrorTracker context (user, request, LiveView)
  # plus what identifies the process. Read here, in the crashing process,
  # because the offloaded task that reports has neither.
  defp crash_context(meta) do
    process = %{
      "process.registered_name" => registered_name(meta),
      "process.label" => process_label(),
      "process.initial_call" => initial_call()
    }

    process
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.merge(ErrorTracking.current_context())
  end

  defp registered_name(%{registered_name: name}) when is_atom(name), do: inspect(name)

  defp registered_name(_meta) do
    case Process.info(self(), :registered_name) do
      {:registered_name, name} when is_atom(name) -> inspect(name)
      _none -> nil
    end
  end

  defp process_label do
    case :proc_lib.get_label(self()) do
      :undefined -> nil
      label -> inspect(label)
    end
  end

  defp initial_call do
    case Process.get(:"$initial_call") do
      {module, function, arity} when is_integer(arity) ->
        Exception.format_mfa(module, function, arity)

      _other ->
        nil
    end
  end

  defp offload(kind, reason, stacktrace, context) do
    Task.Supervisor.start_child(Tymeslot.TaskSupervisor, fn ->
      try do
        ErrorTracker.report(exception(kind, reason), stacktrace, context)
      rescue
        exception ->
          # Logged under our own domain, which attach/0's own_logs filter
          # drops, so a failing report never loops back into this handler.
          Logger.error("CrashReporter failed to record a crash",
            error: inspect(exception.__struct__),
            domain: @own_domain
          )
      catch
        failure_kind, _failure ->
          Logger.error("CrashReporter failed to record a crash",
            error: inspect(failure_kind),
            domain: @own_domain
          )
      end
    end)

    :ok
  end

  defp exception(:error, reason) when is_exception(reason), do: reason
  defp exception(kind, reason), do: {kind, reason}
end
