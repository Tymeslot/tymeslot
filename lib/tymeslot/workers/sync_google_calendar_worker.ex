defmodule Tymeslot.Workers.SyncGoogleCalendarWorker do
  @moduledoc """
  Oban worker that runs one sync cycle of a Google Calendar integration, on a
  push notification, a requested refresh or the fallback sweep.

  The cycle is `Tymeslot.Integrations.Calendar.Google.SyncCycle`; this worker
  turns its outcome into the job's verdict. Failures only the owner can fix
  (rejected credentials, a deleted booking calendar, an account without
  Google Calendar) flag the integration for reconnection and discard; an open
  breaker is waited out; anything else is retried. The job boundary
  (`Tymeslot.Workers.CalendarSyncJob`) bounds the waits and records the
  verdict against the integration's health state.
  """

  use Oban.Worker,
    queue: :calendar_events,
    max_attempts: 5,
    unique: [
      period: 300,
      keys: [:calendar_integration_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  use Gettext, backend: TymeslotWeb.Gettext

  # An open breaker is waited out with a snooze, which from
  # Oban 2.24 costs no attempt; without a bound a provider that never
  # recovers would keep this job snoozing for ever, with no alert.
  @max_unavailable_snoozes 12

  require Logger

  alias Tymeslot.Infrastructure.ExpectedJobOutcome
  alias Tymeslot.Integrations.Calendar.Google.SyncCycle
  alias Tymeslot.Integrations.Calendar.Management
  alias Tymeslot.Integrations.Shared.ReauthHandling
  alias Tymeslot.Workers.CalendarSyncJob
  alias Tymeslot.Workers.SyncRequest

  # The job arg asking a run to read the booking calendar in full.
  @list_booking_calendar "list_booking_calendar"

  @doc """
  Enqueues a sync of the Google integration `integration_id`, the one the
  dashboard's Refresh and a write of a whole series from the grid ask for.
  Besides the delta, it reads the booking calendar in full over the sync
  window and sweeps what the listing no longer returns: a delta only says
  what changed after the token it runs from, and a bootstrap that read a
  series before the grid rewrote it may have cached it again after the
  grid dropped its rows. A sync already waiting for the integration runs in
  its place, as such a sync; one already running runs again once it
  finishes, since it may have read Google before the request (see
  `Tymeslot.Workers.SyncRequest`).
  """
  @spec enqueue(pos_integer()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(integration_id),
    do:
      SyncRequest.insert(__MODULE__, %{
        "calendar_integration_id" => integration_id,
        @list_booking_calendar => true
      })

  @behaviour ExpectedJobOutcome

  # The integration is gone, or only its owner can fix it by reconnecting.
  # A sync past the pagination limit is recorded.
  @integration_gone "Integration not found"
  @calendar_gone "Booking calendar not found — user action required"
  @credentials_rejected "Google rejected credentials — reauthentication required"
  @calendar_disabled "Google Calendar not enabled for account: user action required"

  @impl ExpectedJobOutcome
  def expected_outcome?(reason),
    do:
      reason in [@integration_gone, @calendar_gone, @credentials_rejected, @calendar_disabled] or
        reason == ReauthHandling.discard_reason()

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    CalendarSyncJob.run(
      job,
      &sync(&1, args[@list_booking_calendar] == true),
      max_snoozes: @max_unavailable_snoozes,
      exhausted_reason: "Google Calendar did not recover within the maximum wait"
    )
  end

  defp sync(integration, list_booking_calendar?) do
    integration
    |> SyncCycle.run(list_booking_calendar: list_booking_calendar?)
    |> handle_result(integration)
  end

  defp handle_result(:ok, _integration), do: :ok

  defp handle_result({:error, :unauthorized}, integration),
    do: handle_credentials_rejected(integration)

  defp handle_result({:error, :booking_calendar_missing}, integration),
    do: handle_booking_calendar_missing(integration)

  defp handle_result({:error, :not_a_calendar_user}, integration),
    do: handle_calendar_not_enabled(integration)

  # Waited out; the job boundary bounds how long.
  defp handle_result({:error, :circuit_open}, _integration), do: {:snooze, 120}

  # A listing past the page limit is recorded rather than retried: the
  # next cycle meets the same calendar.
  defp handle_result({:error, {:too_many_pages, message}}, _integration), do: {:discard, message}

  defp handle_result({:error, _reason} = error, _integration), do: error

  # A 404 on the booking calendar itself means the calendar the user books
  # into was deleted on Google's side. Retrying cannot recover, and the
  # fallback sweep would re-enqueue the job forever — so flag the integration
  # for reconnection (which also removes it from the sweep) and discard.
  defp handle_booking_calendar_missing(integration) do
    Logger.warning(
      "Google Calendar booking calendar no longer exists; flagging integration for reconnection",
      calendar_integration_id: integration.id
    )

    Management.flag_for_reconnection(
      integration,
      dgettext_noop(
        "integrations_calendar",
        "The booking calendar no longer exists on Google. Please reconnect the integration and choose a different calendar."
      ),
      @calendar_gone
    )
  end

  # Google is refusing the credentials themselves: either the token refresh
  # failed, so the grant is gone, or a 403 named insufficient permissions.
  # Rate limiting and a Calendar-less account are classified ahead of this in
  # `Google.ApiStatus`, so nothing merely transient lands here
  # and no retry can re-authorise anything.
  #
  # The scheduled probe reaches the same verdict on its own cadence, but not
  # before the 15-minute sweep has re-queued this job repeatedly against a
  # credential Google has already rejected. Flagging here ends that on the
  # first refusal: the sweep's population excludes integrations awaiting
  # reconnection. Flagging twice is harmless — only the false-to-true
  # transition emails the owner.
  defp handle_credentials_rejected(integration) do
    Management.flag_for_reconnection(
      integration,
      dgettext_noop(
        "integrations_calendar",
        "Google rejected the stored credentials. Please reconnect the integration."
      ),
      @credentials_rejected
    )
  end

  # Google answers every call with 403 `notACalendarUser` when the connected
  # account has no Google Calendar (typically a Workspace account whose admin
  # has disabled the service). Retrying cannot recover, so treat it like a
  # missing booking calendar: flag for reconnection and discard.
  defp handle_calendar_not_enabled(integration) do
    Logger.warning(
      "Google account has no Google Calendar; flagging integration for reconnection",
      calendar_integration_id: integration.id
    )

    Management.flag_for_reconnection(
      integration,
      dgettext_noop(
        "integrations_calendar",
        "This Google account doesn't have Google Calendar enabled. Turn on Google Calendar for the account (a Google Workspace administrator may need to do this), or connect a different Google account."
      ),
      @calendar_disabled
    )
  end
end
