defmodule Tymeslot.Infrastructure.ErrorTracking.ReasonScrubber do
  @moduledoc """
  Masks email addresses and credentials in the exception messages
  ErrorTracker stores.

  ErrorTracker runs the occurrence context through
  `Tymeslot.Infrastructure.ErrorTracking.Filter`, but stores the exception's
  message (the `reason` of the error and of each occurrence) exactly as the
  exception gave it, and many messages quote the term that failed. This
  handler listens to `[:error_tracker, :occurrence, :new]`, emitted once both
  rows are written, and rewrites either reason whose masked form differs:
  `PIIScrubber.mask_emails/1` for email addresses,
  `Tymeslot.Infrastructure.Logging.Redactor` for tokens and secrets.

  Rewriting the reason is safe for grouping: an error's fingerprint is its
  kind and source, never its reason.

  Telemetry detaches a handler that raises, which would leave every later
  message unmasked until the next restart, so `handle_event/4` never raises:
  a failure is logged, naming only its module, and dropped.
  """

  alias ErrorTracker.Error
  alias ErrorTracker.Occurrence
  alias Tymeslot.Infrastructure.AdminAlerts.PIIScrubber
  alias Tymeslot.Infrastructure.ErrorTracking.ErrorTrackingQueries
  alias Tymeslot.Infrastructure.Logging.Redactor

  require Logger

  @handler_id "tymeslot-error-tracking-reason-scrubber"
  @event [:error_tracker, :occurrence, :new]

  @doc """
  Attaches the telemetry handler. Idempotent, so safe to call on
  application restart inside the same BEAM.
  """
  @spec attach() :: :ok | {:error, :already_exists}
  def attach do
    _detached = :telemetry.detach(@handler_id)
    :telemetry.attach(@handler_id, @event, &__MODULE__.handle_event/4, nil)
  end

  @doc "Masks email addresses and credentials in `text`."
  @spec scrub(String.t()) :: String.t()
  def scrub(text) when is_binary(text), do: text |> PIIScrubber.mask_emails() |> Redactor.redact()

  @doc false
  @spec handle_event([atom()], map(), map(), term()) :: :ok
  def handle_event(_event, _measurements, %{occurrence: %Occurrence{} = occurrence}, _config) do
    scrub_row(occurrence, &ErrorTrackingQueries.replace_occurrence_reason/3)

    case occurrence.error do
      %Error{} = error -> scrub_row(error, &ErrorTrackingQueries.replace_error_reason/3)
      _not_loaded -> :ok
    end

    :ok
  rescue
    exception -> log_failure(inspect(exception.__struct__))
  catch
    kind, _reason -> log_failure(inspect(kind))
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  defp scrub_row(%{id: id, reason: reason}, replace) when is_binary(reason) do
    case scrub(reason) do
      ^reason -> :ok
      scrubbed -> replace.(id, reason, scrubbed)
    end
  end

  defp scrub_row(_row, _replace), do: :ok

  defp log_failure(error) do
    Logger.error("Failed to mask a stored error message", error: error)
    :ok
  end
end
