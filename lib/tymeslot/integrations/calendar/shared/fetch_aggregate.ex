defmodule Tymeslot.Integrations.Calendar.Shared.FetchAggregate do
  @moduledoc """
  Shared aggregation policy for "fetch from several calendar sources and
  merge the results", used at every level of the calendar fetch stack
  (calendars within one integration, integrations for one user).

  A calendar we failed to read from is not a calendar with no events: its
  busy time is simply unknown. This module is the single place that says
  so, instead of each level re-deriving its own, subtly different, cond
  ladder.

  `collect/3` classifies every raw per-source result via a caller-supplied
  function and returns an `Outcome`. Callers then apply `require_complete/1`
  to it: fail-closed availability semantics, where any hard failure refuses
  to serve a result. Offering slots built only from the sources that
  happened to respond would silently hide conflicts sitting in the ones
  that didn't. A source with no hard failures at all — including one where
  every source was confirmed absent, or none was attempted — is a genuinely
  known-empty result, not a gap, so it returns its (possibly empty) events.
  """

  require Logger

  alias Tymeslot.Infrastructure.Logging.Redactor

  defmodule Outcome do
    @moduledoc """
    The result of aggregating one round of per-source fetches.
    """

    @enforce_keys [:events, :attempted, :succeeded, :failed]
    defstruct [:events, :attempted, :succeeded, :failed]

    @type failure :: %{source: term(), reason: term()}

    @type t :: %__MODULE__{
            events: list(),
            attempted: non_neg_integer(),
            succeeded: non_neg_integer(),
            failed: [failure()]
          }
  end

  @type classification ::
          {:ok, list()} | :absent | {:error, term(), term()} | {:aggregate, Outcome.t()}

  @doc """
  Classifies every item in `results` via `classify_fun` and aggregates them
  into an `Outcome`.

  `classify_fun` receives one raw result and must return:

    * `{:ok, events}` — a genuine success, contributing its events
    * `:absent` — a confirmed-absent source (e.g. a 404'd calendar):
      contributes no events but is not a failure
    * `{:error, source, reason}` — a hard failure whose busy time is
      unknown
    * `{:aggregate, outcome}` — a nested `Outcome` from a lower level of the
      fetch stack (e.g. one integration's own multi-calendar fetch). Its
      `events`/`attempted`/`succeeded`/`failed` are merged into the parent
      outcome instead of being counted as a single opaque source, so a
      failure two levels down (which calendar, which reason) survives all
      the way to the outermost caller.

  Failures are logged once here, redacted via `Redactor.redact_and_truncate/1`.
  `log_context` is merged into that log call so callers can attach their
  own identifying metadata (e.g. `user_id:`, `calendar_integration_id:`).
  """
  @spec collect([term()], (term() -> classification()), keyword()) :: Outcome.t()
  def collect(results, classify_fun, log_context \\ []) do
    {events, attempted, succeeded, failed} =
      results
      |> Enum.map(classify_fun)
      |> Enum.reduce({[], 0, 0, []}, &accumulate/2)

    failed = Enum.reverse(failed)
    log_failures(failed, log_context)

    %Outcome{events: events, attempted: attempted, succeeded: succeeded, failed: failed}
  end

  defp accumulate({:ok, evs}, {events_acc, attempted_acc, succeeded_acc, failed_acc}) do
    {events_acc ++ evs, attempted_acc + 1, succeeded_acc + 1, failed_acc}
  end

  defp accumulate(:absent, {events_acc, attempted_acc, succeeded_acc, failed_acc}) do
    {events_acc, attempted_acc + 1, succeeded_acc, failed_acc}
  end

  defp accumulate(
         {:error, source, reason},
         {events_acc, attempted_acc, succeeded_acc, failed_acc}
       ) do
    {events_acc, attempted_acc + 1, succeeded_acc,
     [%{source: source, reason: reason} | failed_acc]}
  end

  defp accumulate(
         {:aggregate, %Outcome{} = outcome},
         {events_acc, attempted_acc, succeeded_acc, failed_acc}
       ) do
    {events_acc ++ outcome.events, attempted_acc + outcome.attempted,
     succeeded_acc + outcome.succeeded, Enum.reverse(outcome.failed) ++ failed_acc}
  end

  @doc """
  Fail-closed availability semantics: a clean outcome (no hard failures —
  whether every source succeeded, every source was confirmed absent, or none
  was attempted at all) returns its events, which is `[]` for the absent/
  nothing-attempted cases rather than an error: a source we know to be empty
  is not a source we failed to read. Any hard failure with no successful
  source at all fails closed as `:all_calendars_unavailable`; any other hard
  failure fails closed as `:some_calendars_unavailable`.
  """
  @spec require_complete(Outcome.t()) ::
          {:ok, list()}
          | {:error, :all_calendars_unavailable}
          | {:error, :some_calendars_unavailable}
  def require_complete(%Outcome{failed: []} = outcome), do: {:ok, outcome.events}
  def require_complete(%Outcome{succeeded: 0}), do: {:error, :all_calendars_unavailable}
  def require_complete(%Outcome{}), do: {:error, :some_calendars_unavailable}

  defp log_failures([], _log_context), do: :ok

  defp log_failures(failed, log_context) do
    Logger.warning(
      "Some calendar fetches failed",
      Keyword.merge(log_context,
        failed_count: length(failed),
        errors:
          Enum.map(failed, fn %{source: source, reason: reason} ->
            %{source: source, reason: Redactor.redact_and_truncate(reason)}
          end)
      )
    )
  end
end
