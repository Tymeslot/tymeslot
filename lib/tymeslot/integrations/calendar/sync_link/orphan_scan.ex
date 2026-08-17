defmodule Tymeslot.Integrations.Calendar.SyncLink.OrphanScan do
  @moduledoc """
  Finds placeholders on a target that no mirror row claims.

  ## Why this cannot be answered by any existing path

  Every recovery mechanism in this feature is keyed on the mapping row.
  `Teardown` withdraws what the rows name, `SyncLinkReconcileWorker` compares
  sources against the rows, and loop prevention is a set *built from* the rows.
  A row lost while its placeholder survives is therefore invisible to all three
  at once: the busy block sits on the organiser's calendar blocking time, and
  nothing in the system knows it is there.

  Reaching that state takes a provider write landing, its row write failing,
  *and* `Engine.persist_or_compensate/5`'s compensating delete failing too — or
  a row removed outside the application, by a restore or by hand. It is narrow,
  which is why this reports rather than repairs.

  ## Why it reports and does not repair

  Rebuilding a row means deciding which source event a placeholder belonged to,
  and the evidence for that is exactly what was lost. Acting on a wrong answer
  writes to somebody's calendar — the failure this whole feature exists to
  avoid. Reporting costs nothing and answers the question that decides whether
  repair is worth writing at all: does this happen?

  ## Why candidates are derived forward rather than matched by prefix

  The obvious scan — look for cached events whose UID starts with
  `tymeslot-mirror-` — finds only the CalDAV family. Google does not keep the
  UID it is handed: `uuid_to_google_event_id/1` *hashes* ours (the prefix
  contains a hyphen, so it never takes the base32hex fast path), Google files
  the event under that hash, and the next inbound sync caches
  `{hash}@google.com`. Our prefix appears nowhere in it, and the hash cannot be
  reversed.

  So the identity is derived in the same direction the write derived it. For
  each link and each source event still cached, compute the UID that link would
  have given a placeholder and the provider id Google would have filed it
  under. Those are the identities to look for; anything found under one, with no
  mapping row claiming it, is unclaimed.

  That also bounds the scan to sources that still exist. A placeholder whose
  source is gone *and* whose row is gone leaves nothing to derive from — it
  needs the prefix scan, which works for CalDAV and cannot work for Google, so
  it is reported for the family where it is answerable rather than pretended at
  for both.

  ## The discriminator, and the one that must not be used

  Recognition keys on the derived identity, or on the `tymeslot-mirror-` prefix
  from `Engine.uid_prefix/0` — never on the `created_by_tymeslot` marker the
  provider event also carries. That marker means "Tymeslot wrote this", equally
  true of every booking the organiser has taken: scanning by it would report
  their own meetings as orphans, and a later repair pass would delete them. The
  same reasoning keeps it out of loop prevention; see `SyncLink.Eligibility`.
  """

  require Logger

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkQueries
  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorQueries
  alias Tymeslot.Integrations.Calendar.Google.EventMapper
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.SyncLink.Engine
  alias Tymeslot.Integrations.Calendar.SyncLink.OrphanScanQueries

  @typedoc """
  One placeholder nothing claims. Carries what an operator needs to find it on
  the provider — and what a future repair would need to act on it.
  """
  @type orphan :: %{
          target_integration_id: integer(),
          uid: String.t(),
          provider_event_id: String.t() | nil,
          summary: String.t() | nil,
          starts_at: DateTime.t() | Date.t() | nil
        }

  @doc """
  Every unclaimed placeholder across the user's calendar integrations.

  Answers `[]` for a user with no integrations rather than scanning nothing at
  cost, and is read-only throughout: it writes no row and calls no provider.
  """
  @spec orphans_for_user(integer()) :: [orphan()]
  def orphans_for_user(user_id) when is_integer(user_id) do
    # Every integration, not only the active ones: a placeholder stranded on a
    # calendar the organiser has since disconnected is exactly the case worth
    # reporting, and filtering to active would hide it.
    case CalendarIntegrationQueries.list_all_for_user(user_id) do
      [] ->
        []

      integrations ->
        integration_ids = Enum.map(integrations, & &1.id)
        claimed = CalendarSyncMirrorQueries.mirror_uids_for_integrations(integration_ids)
        links = CalendarSyncLinkQueries.list_for_user(user_id)

        (derived_candidates(links) ++
           OrphanScanQueries.list_by_uid_prefix(
             integration_ids,
             Engine.uid_prefix()
           ))
        |> Enum.uniq_by(&{&1.calendar_integration_id, &1.uid})
        |> Enum.reject(&claimed?(&1, claimed))
        |> Enum.map(&describe/1)
    end
  end

  # Every identity a link's placeholders could be cached under, looked up on the
  # target. Derived forward from the link and the sources it still holds,
  # because Google's is a hash of ours and cannot be recovered from the cache.
  defp derived_candidates(links) do
    Enum.flat_map(links, fn link ->
      link.source_integration_id
      |> OrphanScanQueries.list_uids_for_integration()
      |> Enum.flat_map(&candidates_for(link, &1))
    end)
  end

  defp candidates_for(link, source_uid) do
    target_uid = Engine.target_uid_for(link.id, source_uid)
    google_id = EventMapper.uuid_to_google_event_id(target_uid)

    [target_uid, google_id, google_id <> "@google.com"]
    |> Enum.uniq()
    |> Enum.flat_map(fn uid ->
      case ProviderCalendarEventQueries.get_by_uid(link.target_integration_id, uid) do
        {:ok, event} -> [event]
        {:error, :not_found} -> []
      end
    end)
  end

  @doc """
  Logs what `orphans_for_user/1` found, at a level that matches what it means.

  An empty result is worth recording too: a scan that reports nothing and a scan
  that did not run look identical afterwards, and knowing the difference is the
  point of running it before anything is automated.
  """
  @spec report_for_user(integer()) :: [orphan()]
  def report_for_user(user_id) when is_integer(user_id) do
    case orphans_for_user(user_id) do
      [] ->
        Logger.info("Mirror orphan scan found nothing", user_id: user_id)
        []

      orphans ->
        Logger.warning("Mirror orphan scan found unclaimed placeholders",
          user_id: user_id,
          count: length(orphans),
          orphans: Enum.map(orphans, &Map.take(&1, [:target_integration_id, :uid]))
        )

        orphans
    end
  end

  # The cached uid alone, because the set is already expanded on the other side:
  # `mirror_uids_for_integrations/1` adds the `@google.com` form of every
  # identity a row holds, which is exactly what the cache stores for a Google
  # placeholder. Matching the event's `provider_event_id` as well would be a
  # second spelling of the same question, and the redundancy reads as a
  # safeguard rather than the no-op it is.
  defp claimed?(event, claimed) when is_binary(event.uid),
    do: MapSet.member?(claimed, {event.calendar_integration_id, event.uid})

  defp claimed?(_event, _claimed), do: false

  defp describe(event) do
    %{
      target_integration_id: event.calendar_integration_id,
      uid: event.uid,
      provider_event_id: event.provider_event_id,
      summary: event.summary,
      starts_at: event.start_at || event.start_date
    }
  end
end
