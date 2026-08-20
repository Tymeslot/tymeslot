defmodule Tymeslot.SeriesDeletionTraceHelpers do
  @moduledoc """
  The fixture world both halves of the deleted-series trace are driven against:
  a Google source calendar mirrored onto a Google target, a recurring series
  already cached under the uid Google's convention gives it, and a placeholder
  mapping naming the mirror that series produced.

  It exists because the trace is split across two modules — `SeriesDeletionTraceTest`
  for the per-hop mechanics and `SeriesDeletionBatchTraceTest` for the
  batch-level questions — and both must be reading the *same* world. Duplicating
  the setup is how the two halves quietly start describing different series and
  their findings stop composing.

  The one value worth stating explicitly is the cached row's `provider_event_id`:
  it is the **last** occurrence's instance id, because `upsert_batch/1`
  deduplicates a series to one row keeping the last entry. Hop C turns on that
  exact fact — a deletion ref carrying only an instance id reaches this row by
  luck when the batch happens to contain that instance, and not otherwise.
  """

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Repo

  @master_id "t6cifbq57so03uunemf5rb6238"
  @series_uid "t6cifbq57so03uunemf5rb6238@google.com"
  @last_occurrence_event_id "t6cifbq57so03uunemf5rb6238_20260907T090000Z"

  @doc "The master id of the captured series."
  @spec master_id() :: String.t()
  def master_id, do: @master_id

  @doc "The uid every occurrence of the captured series shares."
  @spec series_uid() :: String.t()
  def series_uid, do: @series_uid

  @doc """
  The three occurrence instants the captured `FREQ=WEEKLY;COUNT=3` series had,
  in the order Google emitted their tombstones.
  """
  @spec occurrences() :: [String.t()]
  def occurrences, do: ["2026-08-24T09:00:00Z", "2026-08-31T09:00:00Z", "2026-09-07T09:00:00Z"]

  @doc """
  A user with a Google source calendar, a Google target, and an enabled link
  between them. Returned as the map an ExUnit `setup` merges into the context.

  The source carries a sync token because every test here drives
  `list_events_incremental` — an integration without one takes the full-sync
  branch instead and never reaches the delta path being traced.
  """
  @spec sync_link_world() :: map()
  def sync_link_world do
    user = insert(:user)
    source = google_integration(user, google_sync_token: "valid-token")
    target = google_integration(user, [])

    link =
      insert(:calendar_sync_link,
        user_id: user.id,
        source_integration_id: source.id,
        target_integration_id: target.id
      )

    %{user: user, source: source, target: target, link: link}
  end

  defp google_integration(user, overrides),
    do: insert(:calendar_integration, [user: user, provider: "google"] ++ overrides)

  @doc """
  The single cache row a synced Google series leaves behind: keyed by the series
  uid, carrying the master id, and stamped with the **last** occurrence's
  instance id and timing.
  """
  @spec cache_the_series(struct()) :: struct()
  def cache_the_series(source) do
    insert(:provider_calendar_event,
      calendar_integration: source,
      uid: @series_uid,
      provider: "google",
      provider_calendar_id: "primary",
      provider_event_id: @last_occurrence_event_id,
      recurring_event_id: @master_id,
      status: "confirmed",
      start_at: ~U[2026-09-07 09:00:00Z],
      end_at: ~U[2026-09-07 10:00:00Z]
    )
  end

  @doc "The mapping row naming the placeholder the series produced on the target."
  @spec mirror_the_series(struct()) :: struct()
  def mirror_the_series(link) do
    mirror_for_link(link,
      source_uid: @series_uid,
      target_uid: "tymeslot-mirror-#{@master_id}",
      target_provider_event_id: "google-target-event-id"
    )
  end

  @doc "Every cached row belonging to `source`, unordered."
  @spec cached_rows(struct()) :: [ProviderCalendarEventSchema.t()]
  def cached_rows(source) do
    ProviderCalendarEventSchema
    |> Repo.all()
    |> Enum.filter(&(&1.calendar_integration_id == source.id))
  end
end
