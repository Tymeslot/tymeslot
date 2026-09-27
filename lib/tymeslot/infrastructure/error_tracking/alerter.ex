defmodule Tymeslot.Infrastructure.ErrorTracking.Alerter do
  @moduledoc """
  Raises an admin alert when ErrorTracker sees a new error, or an error it
  had marked resolved happens again.

  Listens to two ErrorTracker telemetry events, emitted in the process that
  reported the exception:

    * `[:error_tracker, :error, :new]`: the first occurrence of an error
      (a fingerprint never seen before) raises `:new_error`.
    * `[:error_tracker, :error, :unresolved]` with an occurrence: a resolved
      error happened again and raises `:error_regression`. The same event
      without an occurrence is someone unresolving the error by hand, which
      is not news to anyone.

  Further occurrences of an unresolved error raise nothing: the error is
  already in front of the operator. A muted error raises nothing at all.

  The alert carries the error's identity (id, kind, reason, source) and
  what the occurrence context says about where it happened: the user and
  correlation id, the request, the LiveView or the job. The context is read
  as stored, after `Tymeslot.Infrastructure.ErrorTracking.Filter` has
  redacted it, so a meeting uid or link token in the request path reaches
  the alert as `:id`. The reason is masked by
  `Tymeslot.Infrastructure.ErrorTracking.ReasonScrubber.scrub/1`. Every value is a
  scalar, since the alert email renders the metadata as a table.

  Telemetry detaches a handler that raises, which would switch alerting off
  until the next restart, so `handle_event/4` never raises: a malformed
  event or a failure building the alert is logged and dropped.
  """

  alias ErrorTracker.Error
  alias ErrorTracker.Occurrence
  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Infrastructure.ErrorTracking.ReasonScrubber
  alias Tymeslot.Infrastructure.Logging.LogFormat

  require Logger

  @handler_id "tymeslot-error-tracking-alerter"

  @events [
    [:error_tracker, :error, :new],
    [:error_tracker, :error, :unresolved]
  ]

  @max_value_length 200

  # Occurrence context key => alert metadata key.
  @context_keys [
    {"user_id", :user_id},
    {"correlation_id", :correlation_id},
    {"request.method", :request_method},
    {"request.path", :request_path},
    {"live_view.view", :live_view},
    {"live_view.event", :live_view_event},
    {"job.worker", :job_worker},
    {"job.queue", :job_queue},
    {"job.id", :job_id},
    {"job.attempt", :job_attempt},
    {"job.max_attempts", :job_max_attempts}
  ]

  @doc """
  Attaches the telemetry handler. Idempotent, so safe to call on
  application restart inside the same BEAM.
  """
  @spec attach() :: :ok | {:error, :already_exists}
  def attach do
    _detached = :telemetry.detach(@handler_id)
    :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil)
  end

  @doc false
  @spec handle_event([atom()], map(), map(), term()) :: :ok
  def handle_event(event, _measurements, metadata, _config) do
    case alert_type(event, metadata) do
      nil -> :ok
      type -> report(type, metadata.error, metadata.occurrence)
    end

    :ok
  rescue
    exception ->
      Logger.error("Error tracking alerter failed to raise an alert",
        error: LogFormat.reason(exception.__struct__)
      )

      :ok
  catch
    kind, _reason ->
      Logger.error("Error tracking alerter failed to raise an alert",
        error: LogFormat.reason(kind)
      )

      :ok
  end

  defp alert_type(_event, %{error: %Error{muted: true}}), do: nil

  defp alert_type([:error_tracker, :error, :new], %{error: %Error{}, occurrence: %Occurrence{}}),
    do: :new_error

  defp alert_type([:error_tracker, :error, :unresolved], %{
         error: %Error{},
         occurrence: %Occurrence{}
       }),
       do: :error_regression

  defp alert_type(_event, _metadata), do: nil

  defp report(type, %Error{} = error, %Occurrence{} = occurrence) do
    context = if is_map(occurrence.context), do: occurrence.context, else: %{}

    AdminAlerts.report(type,
      summary: summary(type),
      reason: alert_reason(occurrence.reason || error.reason),
      context:
        Map.merge(occurrence_context(context), %{
          error_id: error.id,
          occurrence_id: occurrence.id,
          kind: error.kind,
          source_function: error.source_function,
          source_line: error.source_line
        })
    )
  end

  # The alert is raised before `ReasonScrubber` rewrites the stored rows, so
  # the reason it quotes is masked here by the same rule.
  defp alert_reason(reason) when is_binary(reason), do: ReasonScrubber.scrub(reason)
  defp alert_reason(reason), do: reason

  defp summary(:new_error), do: "New error"
  defp summary(:error_regression), do: "Resolved error happened again"

  defp occurrence_context(context) do
    @context_keys
    |> Enum.map(fn {source, key} -> {key, scalar(Map.get(context, source))} end)
    |> Enum.concat([{:job_action, job_action(context)}, {:job_state, job_state(context)}])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  # The EmailWorker action names what the job was doing (`send_admin_alert`),
  # which the admin alert notifier needs to recognise an alert it could never
  # deliver. Read after the Filter's redaction, which keeps `action`.
  defp job_action(%{"job.args" => %{"action" => action}}), do: scalar(action)
  defp job_action(_context), do: nil

  # ErrorTracker's Oban integration records the attempt's outcome as `state`:
  # `:failure` while retries remain, `:discard` once they are exhausted.
  defp job_state(%{state: state}) when state in [:failure, :discard], do: Atom.to_string(state)
  defp job_state(_context), do: nil

  defp scalar(nil), do: nil
  defp scalar(value) when is_integer(value) or is_boolean(value), do: value
  defp scalar(value) when is_binary(value), do: String.slice(value, 0, @max_value_length)
  defp scalar(value) when is_atom(value), do: inspect(value)
  defp scalar(_value), do: nil
end
