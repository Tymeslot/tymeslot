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

  ErrorTracker offers no hook on the message before the insert, so this
  rewrite is the only guard for the reports its integrations make. Our own
  reports go further: `scrub_exception/1` redacts the exception before it is
  handed to `ErrorTracker.report/3`, so the message written first is already
  masked wherever it can be, and the rewrite here is the backstop.

  Telemetry detaches a handler that raises, which would leave every later
  message unmasked until the next restart, so `handle_event/4` never raises:
  a failure is logged, naming only its module, and dropped.
  """

  alias ErrorTracker.Error
  alias ErrorTracker.Occurrence
  alias Tymeslot.Infrastructure.AdminAlerts.PIIScrubber
  alias Tymeslot.Infrastructure.ErrorTracking.ErrorTrackingQueries
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Infrastructure.Logging.MetadataRedactor
  alias Tymeslot.Infrastructure.Logging.Redactor

  require Logger

  @handler_id "tymeslot-error-tracking-reason-scrubber"
  @event [:error_tracker, :occurrence, :new]
  @rescrub_batch_size 500

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

  @doc """
  Returns `exception` ready for `ErrorTracker.report/3`: the values of its
  sensitive fields redacted by `MetadataRedactor.redact/1`, and a `:message`
  field, where it has one, scrubbed by `scrub/1`.

  A message computed from other fields (`KeyError`,
  `Ecto.InvalidChangesetError`) is then computed from redacted ones, so it
  loses what sits under a sensitive key; an address or token elsewhere in it
  is left for the telemetry handler to mask after the insert. The exception's
  module is unchanged, so its error groups as before. Should the redacted
  copy fail to produce a message, `exception` is returned as given: a garbled
  message would cost the report more than the handler's rewrite saves.
  """
  @spec scrub_exception(Exception.t()) :: Exception.t()
  def scrub_exception(%module{} = exception) when is_exception(exception) do
    redacted = exception |> MetadataRedactor.redact() |> scrub_message_field()
    _message = module.message(redacted)
    redacted
  rescue
    failure -> unredacted(exception, failure.__struct__)
  catch
    kind, _reason -> unredacted(exception, kind)
  end

  @doc """
  As `scrub_exception/1`, for either form `ErrorTracker.report/3` accepts: an
  exception, or a `{kind, payload}` pair such as a throw or an exit.

  A pair is normalised the way ErrorTracker normalises it, with `stacktrace`.
  One that normalises to an exception is returned as that exception,
  scrubbed; any other is returned as `{kind, text}`, where `text` is the
  message ErrorTracker would have stored, computed from the payload with its
  sensitive values redacted and then scrubbed. Either way the stored kind is
  unchanged, so the error groups as before. A pair that cannot be rendered is
  returned as given, for ErrorTracker to render as it would have.
  """
  @spec scrub_exception(Exception.t() | {atom(), term()}, Exception.stacktrace()) ::
          Exception.t() | {atom(), term()}
  def scrub_exception(exception, _stacktrace) when is_exception(exception),
    do: scrub_exception(exception)

  def scrub_exception({kind, payload} = pair, stacktrace) do
    case Exception.normalize(kind, payload, stacktrace) do
      exception when is_exception(exception) -> scrub_exception(exception)
      payload -> {kind, payload |> MetadataRedactor.redact() |> payload_text() |> scrub()}
    end
  rescue
    # credo:disable-for-next-line CredoChecks.NoSwallowedException
    _failure -> pair
  end

  # ErrorTracker's own rendering of a payload that is not an exception.
  defp payload_text(payload) do
    to_string(payload)
  rescue
    # Not a failure: a payload without `String.Chars` is inspected instead.
    # credo:disable-for-next-line CredoChecks.NoSwallowedException
    Protocol.UndefinedError -> inspect(payload)
  end

  defp unredacted(%module{} = exception, error) do
    Logger.warning("Could not redact an exception before recording it",
      exception_module: LogFormat.reason(module),
      error: LogFormat.reason(error)
    )

    exception
  end

  defp scrub_message_field(%{message: message} = exception) when is_binary(message),
    do: %{exception | message: scrub(message)}

  defp scrub_message_field(exception), do: exception

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
    _rewritten = rescrub(id, reason, replace)
    :ok
  end

  defp scrub_row(_row, _replace), do: :ok

  @doc """
  Masks the stored reasons the telemetry handler should have masked but did
  not, and returns how many it rewrote: those of every error last seen at or
  after `since`, and of each such error's occurrences inserted since then.

  The handler's rewrite is a second write after the insert, and nothing
  retries it should it fail, so an unmasked reason would otherwise be kept
  for as long as the row. Run daily over a window longer than a day, this
  bounds that to the next run. Errors and occurrences are both walked, since
  each occurrence stores its own reason and an error's is its first
  occurrence's.

  Reads a page at a time (`:batch_size`, default #{@rescrub_batch_size}) and
  writes only the rows whose reason changes, through the same conditional
  update the handler uses. How many occurrences an error has in the window
  is bounded by `ReportThrottle`'s budget and, once the daily trim has run,
  by its per-error cap.
  """
  @spec rescrub_since(DateTime.t(), keyword()) :: non_neg_integer()
  def rescrub_since(%DateTime{} = since, opts \\ []) do
    rescrub_errors(since, Keyword.get(opts, :batch_size, @rescrub_batch_size), 0, 0)
  end

  defp rescrub_errors(since, batch_size, after_id, total) do
    case ErrorTrackingQueries.error_reasons_seen_since(since, after_id, batch_size) do
      [] ->
        total

      errors ->
        total =
          Enum.reduce(errors, total, fn {id, reason}, total ->
            total + rescrub(id, reason, &ErrorTrackingQueries.replace_error_reason/3) +
              rescrub_occurrences(id, since, batch_size, 0, 0)
          end)

        {last_id, _reason} = List.last(errors)
        rescrub_errors(since, batch_size, last_id, total)
    end
  end

  defp rescrub_occurrences(error_id, since, batch_size, after_id, total) do
    occurrences =
      ErrorTrackingQueries.occurrence_reasons_since(error_id, since, after_id, batch_size)

    total =
      total +
        Enum.sum_by(occurrences, fn {id, reason} ->
          rescrub(id, reason, &ErrorTrackingQueries.replace_occurrence_reason/3)
        end)

    case occurrences do
      page when length(page) < batch_size ->
        total

      page ->
        {last_id, _reason} = List.last(page)
        rescrub_occurrences(error_id, since, batch_size, last_id, total)
    end
  end

  # 1 when the reason needed masking and the conditional update was issued.
  defp rescrub(id, reason, replace) when is_binary(reason) do
    case scrub(reason) do
      ^reason ->
        0

      scrubbed ->
        :ok = replace.(id, reason, scrubbed)
        1
    end
  end

  defp rescrub(_id, _reason, _replace), do: 0

  defp log_failure(error) do
    Logger.error("Failed to mask a stored error message", error: error)
    :ok
  end
end
