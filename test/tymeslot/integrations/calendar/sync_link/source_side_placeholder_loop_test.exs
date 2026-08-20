defmodule Tymeslot.Integrations.Calendar.SyncLink.SourceSidePlaceholderLoopTest do
  @moduledoc """
  Reproduction: a placeholder cached on the SOURCE calendar is not recognised
  by loop prevention, so it is mirrored again.
  """
  use Tymeslot.DataCase, async: false
  @moduletag :calendar
  @moduletag :integrations

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorQueries
  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorSchema
  alias Tymeslot.Integrations.Calendar.Google.EventMapper
  alias Tymeslot.Integrations.Calendar.Runtime.BookingIntegrationResolver
  alias Tymeslot.Integrations.Calendar.Sync
  alias Tymeslot.Integrations.Calendar.SyncLink.Eligibility
  alias Tymeslot.Integrations.Calendar.SyncLink.Engine

  setup :verify_on_exit!
  setup :set_mox_from_context

  setup do
    user = insert(:user)
    source = insert(:calendar_integration, user: user, provider: "google", is_active: true)
    target = insert(:calendar_integration, user: user, provider: "google", is_active: true)

    link =
      insert(:calendar_sync_link,
        user_id: user.id,
        source_integration_id: source.id,
        target_integration_id: target.id
      )

    {:ok, user: user, source: source, target: target, link: link}
  end

  defp source_event(integration, uid) do
    %{
      uid: uid,
      calendar_integration_id: integration.id,
      summary: "Caíque <> Edgar",
      start_at: ~U[2026-08-25 20:00:00Z],
      end_at: ~U[2026-08-25 21:00:00Z],
      all_day: false,
      status: "confirmed"
    }
  end

  test "a placeholder cached on the SOURCE calendar is not recognised as a mirror",
       %{user: user, source: source, target: target, link: link} do
    target_uid = Engine.target_uid_for(link.id, "real-event-uid")
    google_id = EventMapper.uuid_to_google_event_id(target_uid)

    expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
      {:ok, %{uid: google_id}}
    end)

    assert :ok == Engine.mirror(link, source_event(source, "real-event-uid"), user.id)

    # The guard as the inbound sync of each calendar asks it.
    mirrors_target = CalendarSyncMirrorQueries.mirror_uids_for_integrations([target.id])
    mirrors_source = CalendarSyncMirrorQueries.mirror_uids_for_integrations([source.id])

    cached_uid = "#{google_id}@google.com"

    on_target = %{calendar_integration_id: target.id, uid: cached_uid}
    on_source = %{calendar_integration_id: source.id, uid: cached_uid}

    IO.puts("PROBE mirrors_for_target=#{inspect(MapSet.to_list(mirrors_target))}")
    IO.puts("PROBE mirrors_for_source=#{inspect(MapSet.to_list(mirrors_source))}")

    IO.puts(
      "PROBE recognised_on_target=#{not Eligibility.worth_enqueueing?(on_target, mirrors_target)}"
    )

    IO.puts(
      "PROBE recognised_on_source=#{not Eligibility.worth_enqueueing?(on_source, mirrors_source)}"
    )

    # Established behaviour: on its own target calendar the placeholder is known.
    refute Eligibility.worth_enqueueing?(on_target, mirrors_target),
           "a placeholder on its target calendar must be recognised"

    # The narrow lookup is keyed on the mirror's target, so it cannot see a
    # placeholder that landed on the source — pinned here because it is still
    # the right answer for the calendar grid and the agenda, which ask "which
    # rows on *this* calendar are placeholders".
    assert Eligibility.worth_enqueueing?(on_source, mirrors_source),
           "mirror_uids_for_integrations/1 unexpectedly covers the source; " <>
             "if it now does, mirror_uids_for_sync/1 may be redundant"

    # What the inbound sync asks instead, which is keyed on the link.
    refute Eligibility.worth_enqueueing?(
             on_source,
             CalendarSyncMirrorQueries.mirror_uids_for_sync(source.id)
           ),
           "a placeholder cached on the SOURCE calendar was treated as a fresh source event"
  end

  # THE DELIVERY MECHANISM. How a placeholder reaches the source calendar at all,
  # which the loop guard alone does not explain.
  #
  # `BookingIntegrationResolver.resolve/1` answers a `{integration_id, user_id}`
  # context by loading that integration — and when it is *inactive* it falls
  # through to `resolve(user_id)`, which returns the organiser's **primary**
  # calendar. For a link whose target is the deactivated one and whose source is
  # primary, that fallback hands the mirror write the source's own credentials.
  # The placeholder is then created on the source calendar, organised by the
  # source account, which is exactly what the live rows show: four "Busy" blocks
  # on the primary calendar organised by the source address, while the correct
  # mirrors on the target are organised by the target address.
  #
  # The fallback is right for a booking, which must land somewhere the organiser
  # owns. It is wrong for a mirror, whose whole purpose is to occupy one
  # specific other calendar: writing it to the source both fails to block the
  # target and creates an event the source's own sync reads back as new.
  test "an inactive target sends the mirror write to the source's own calendar", %{
    user: user,
    source: source,
    target: target,
    link: link
  } do
    # The target loses its authorisation, exactly as both Google accounts did.
    {1, _updated} =
      Repo.update_all(
        from(i in CalendarIntegrationSchema, where: i.id == ^target.id),
        set: [is_active: false, needs_reauth: true]
      )

    # Make the source the organiser's primary, as integration 1 is live.
    profile = insert(:profile, user: user, primary_calendar_integration_id: source.id)
    assert profile.primary_calendar_integration_id == source.id

    resolved = BookingIntegrationResolver.resolve({link.target_integration_id, user.id})

    # The resolver still substitutes, and deliberately so: a *booking* must land
    # on some calendar the organiser owns. This test pins that it does, so the
    # reason the mirror path is now safe is visible as a property of the mirror
    # path rather than as an accident of the resolver.
    assert resolved.id == source.id,
           "the resolver no longer falls back to the primary; " <>
             "Engine's own guard may have become the only thing standing between " <>
             "a mirror and the wrong calendar"

    # What protects the mirror is the engine refusing first, so the substituted
    # integration is never reached.
    assert {:discard, :target_unavailable} ==
             Engine.mirror(link, source_event(source, "real-event-uid"), user.id)

    assert 0 == Repo.aggregate(CalendarSyncMirrorSchema, :count)
  end

  # The behaviour the fix must produce: no write at all. A mirror exists to
  # occupy one specific calendar, so a target that cannot receive it has no
  # substitute — writing anywhere else neither blocks the target nor leaves
  # something the next sync can recognise.
  test "a mirror for an inactive target is refused rather than redirected", %{
    user: user,
    source: source,
    target: target,
    link: link
  } do
    {1, _updated} =
      Repo.update_all(
        from(i in CalendarIntegrationSchema, where: i.id == ^target.id),
        set: [is_active: false, needs_reauth: true]
      )

    insert(:profile, user: user, primary_calendar_integration_id: source.id)

    # No provider call may happen: `verify_on_exit!` fails the test if the
    # engine reaches a client at all.
    result = Engine.mirror(link, source_event(source, "real-event-uid"), user.id)

    IO.puts("PROBE inactive_target_result=#{inspect(result)}")

    assert {:discard, :target_unavailable} == result,
           "mirroring onto an inactive target returned #{inspect(result)}; " <>
             "it must refuse rather than write somewhere else"

    assert 0 == Repo.aggregate(CalendarSyncMirrorSchema, :count),
           "a mirror row was recorded for a write that must not have happened"
  end

  # Does widening the lookup to both ends of the link actually close it? Asked
  # before proposing a fix, because a guard keyed on the pair is only useful if
  # the identifiers it already stores are enough to match a source-side row.
  test "the same placeholder IS recognised when the lookup covers both ends", %{
    user: user,
    source: source,
    target: target,
    link: link
  } do
    target_uid = Engine.target_uid_for(link.id, "real-event-uid")
    google_id = EventMapper.uuid_to_google_event_id(target_uid)

    expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
      {:ok, %{uid: google_id}}
    end)

    assert :ok == Engine.mirror(link, source_event(source, "real-event-uid"), user.id)

    cached_uid = "#{google_id}@google.com"
    on_source = %{calendar_integration_id: source.id, uid: cached_uid}

    # The identifiers the mirrors table holds, re-keyed onto the calendar the
    # placeholder was actually found on.
    widened =
      [target.id]
      |> CalendarSyncMirrorQueries.mirror_uids_for_integrations()
      |> Enum.map(fn {_int, uid} -> {source.id, uid} end)
      |> MapSet.new()

    IO.puts(
      "PROBE widened_recognises_source=#{not Eligibility.worth_enqueueing?(on_source, widened)}"
    )

    refute Eligibility.worth_enqueueing?(on_source, widened),
           "widening the lookup to the link's other end should recognise the placeholder"
  end

  # The guard the inbound sync actually asks, after the fix: a placeholder is
  # Tymeslot's wherever it is cached, so recognition must not depend on which
  # calendar it was found on.
  #
  # Keyed to the calendar being synced rather than to the mirror's target,
  # because that is the key `Eligibility.already_a_mirror?/2` tests against and
  # the two must agree. Restricted to the *organiser's own* links so one
  # organiser's placeholders can never mask another's real events.
  test "the sync guard recognises a placeholder found on any of the link's calendars", %{
    user: user,
    source: source,
    target: target,
    link: link
  } do
    target_uid = Engine.target_uid_for(link.id, "real-event-uid")
    google_id = EventMapper.uuid_to_google_event_id(target_uid)

    expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
      {:ok, %{uid: google_id}}
    end)

    assert :ok == Engine.mirror(link, source_event(source, "real-event-uid"), user.id)

    cached_uid = "#{google_id}@google.com"

    for integration <- [source, target] do
      mirrors = CalendarSyncMirrorQueries.mirror_uids_for_sync(integration.id)
      event = %{calendar_integration_id: integration.id, uid: cached_uid}

      refute Eligibility.worth_enqueueing?(event, mirrors),
             "a placeholder cached on integration #{integration.id} was not recognised"
    end
  end

  # The wiring, not just the query. The inbound sync must ask the link-scoped
  # question: asking the target-scoped one is precisely what let a source-side
  # placeholder through. Exercised through `Sync.filter_mirrorable/2`, the
  # seam `enqueue_mirror_write_backs/3` uses, so this pins behaviour rather
  # than the shape of a private function.
  test "the inbound sync drops a placeholder found on the link's source", %{
    user: user,
    source: source,
    link: link
  } do
    target_uid = Engine.target_uid_for(link.id, "real-event-uid")
    google_id = EventMapper.uuid_to_google_event_id(target_uid)

    expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
      {:ok, %{uid: google_id}}
    end)

    assert :ok == Engine.mirror(link, source_event(source, "real-event-uid"), user.id)

    placeholder = %{
      calendar_integration_id: source.id,
      uid: "#{google_id}@google.com"
    }

    real_event = %{calendar_integration_id: source.id, uid: "an-ordinary-event"}

    kept = Sync.filter_mirrorable(source.id, [placeholder, real_event])

    IO.puts("PROBE kept=#{inspect(Enum.map(kept, & &1.uid))}")

    assert Enum.map(kept, & &1.uid) == ["an-ordinary-event"],
           "the placeholder on the link's source survived the inbound filter " <>
             "and would have been mirrored again"
  end

  # The consequence, end to end: feed the placeholder back in as a source event
  # exactly as the inbound sync of the source calendar would, and watch a second
  # placeholder be written for it. That second row is the first generation of
  # the chain seen live, where one real event grew copies three deep.
  test "mirroring the placeholder again writes a second placeholder", %{
    user: user,
    source: source,
    target: target,
    link: link
  } do
    first_uid = Engine.target_uid_for(link.id, "real-event-uid")
    first_google_id = EventMapper.uuid_to_google_event_id(first_uid)

    expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
      {:ok, %{uid: first_google_id}}
    end)

    assert :ok == Engine.mirror(link, source_event(source, "real-event-uid"), user.id)
    assert 1 == Repo.aggregate(CalendarSyncMirrorSchema, :count)

    # What the source calendar's own sync caches for that placeholder.
    placeholder_as_source = source_event(source, "#{first_google_id}@google.com")

    second_uid = Engine.target_uid_for(link.id, placeholder_as_source.uid)
    second_google_id = EventMapper.uuid_to_google_event_id(second_uid)

    expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
      {:ok, %{uid: second_google_id}}
    end)

    assert :ok == Engine.mirror(link, placeholder_as_source, user.id)

    rows =
      CalendarSyncMirrorSchema
      |> Repo.all()
      |> Enum.map(&{&1.source_uid, &1.target_provider_event_id})

    IO.puts("PROBE mirror_rows=#{inspect(rows)}")

    # Two mirror rows now exist for one real event, and the second names the
    # first's output as its source — the signature the live database showed.
    assert 2 == Repo.aggregate(CalendarSyncMirrorSchema, :count),
           "the placeholder was mirrored again: one real event, two placeholders"

    assert Enum.any?(rows, fn {src, _pid} -> src == "#{first_google_id}@google.com" end),
           "the second mirror should name the first placeholder as its source"
  end
end
