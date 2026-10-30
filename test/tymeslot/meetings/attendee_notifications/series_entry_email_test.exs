defmodule Tymeslot.Meetings.AttendeeNotifications.SeriesEntryEmailTest do
  @moduledoc """
  Which entry in a guest's calendar an email about an occurrence of a
  series changes, carried to the delivered attachment
  (`Tymeslot.Test.AttendeeEmailDelivery`).

  The invitation the grid sends for a new series is a single event, the
  series' first occurrence, under the series' UID; the cache files that
  occurrence under a uid of its own. An email about the first occurrence
  must change the invitation's entry, not add one beside it, and an email
  about the whole series sent from a later occurrence must change it too.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integration
  @moduletag :meetings
  @moduletag :notifications
  @moduletag :emails

  import Tymeslot.Factory
  import Tymeslot.Test.AttendeeEmailDelivery

  alias Ecto.Changeset
  alias Tymeslot.Integrations.Calendar.SeriesRuleQueries
  alias Tymeslot.Meetings.AttendeeNotifications
  alias Tymeslot.Meetings.AttendeeNotifications.LastNotifiedState
  alias Tymeslot.Workers.EmailWorker
  alias TymeslotWeb.RepeatSeriesFixtures

  @first ~U[2026-11-03 09:30:00.000000Z]
  @second ~U[2026-11-10 09:30:00.000000Z]

  setup do
    Application.put_env(:tymeslot, :email_service_module, Tymeslot.Emails.EmailService)
    Application.put_env(:swoosh, :shared_test_process, self())

    on_exit(fn ->
      Application.put_env(:tymeslot, :email_service_module, Tymeslot.EmailServiceMock)
      Application.delete_env(:swoosh, :shared_test_process)
    end)

    user = insert(:user, name: "Olive Organiser")
    %{user: user}
  end

  describe "a Google series" do
    setup %{user: user} do
      integration = insert(:calendar_integration, user: user, provider: "google")
      cache_rule(integration, "master-g", nil)
      %{integration: integration}
    end

    test "an update of its first occurrence changes the invitation's entry", %{
      integration: integration
    } do
      event = google_occurrence(integration, @first, last_notified_state: baseline(@first))

      email = run_update_to_delivery(moved(event))

      assert entry_uids(email) == ["series-g"]
    end

    test "an update of a later occurrence changes that occurrence's own entry", %{
      integration: integration
    } do
      event = google_occurrence(integration, @second, last_notified_state: baseline(@second))

      email = run_update_to_delivery(moved(event))

      assert entry_uids(email) == ["series-g_20261110T093000Z"]
    end

    test "cancelling every occurrence from a later one cancels the invitation's entry too", %{
      user: user,
      integration: integration
    } do
      event = google_occurrence(integration, @second)

      assert {:ok, :sent} = AttendeeNotifications.event_deleted_confirm(event, user.id, :series)
      [email] = deliver_all("send_calendar_invitation")

      ics = calendar_attachment(email).data
      assert entry_uids(email) == ["series-g_20261110T093000Z", "series-g"]
      assert length(String.split(ics, "STATUS:CANCELLED")) == 3
      assert ics =~ "DTSTART:20261103T093000Z"
    end

    test "cancelling every occurrence cancels each one the guest was emailed about too", %{
      user: user,
      integration: integration
    } do
      third = ~U[2026-11-17 09:30:00.000000Z]
      emailed = google_occurrence(integration, @second, last_notified_state: baseline(@second))
      _never_emailed = google_occurrence(integration, ~U[2026-11-24 09:30:00.000000Z])
      event = google_occurrence(integration, third)

      assert {:ok, :sent} = AttendeeNotifications.event_deleted_confirm(event, user.id, :series)
      [email] = deliver_all("send_calendar_invitation")

      ics = calendar_attachment(email).data

      assert entry_uids(email) == [
               "series-g_20261117T093000Z",
               "series-g",
               "series-g_20261110T093000Z"
             ]

      assert emailed.uid == "series-g_20261110T093000Z"
      assert length(String.split(ics, "STATUS:CANCELLED")) == 4
      assert ics =~ "DTSTART:20261110T093000Z"
    end

    test "cancelling one later occurrence leaves the invitation's entry alone", %{
      user: user,
      integration: integration
    } do
      event = google_occurrence(integration, @second)

      assert {:ok, :sent} =
               AttendeeNotifications.event_deleted_confirm(event, user.id, :occurrence)

      [email] = deliver_all("send_calendar_invitation")
      assert entry_uids(email) == ["series-g_20261110T093000Z"]
    end

    test "an edit of all occurrences from a later one moves the invitation's entry as far", %{
      user: user,
      integration: integration
    } do
      original = google_occurrence(integration, @second)

      updated = %{
        original
        | start_at: DateTime.add(@second, 1, :hour),
          end_at: DateTime.add(@second, 2, :hour)
      }

      assert {:ok, :sent} =
               AttendeeNotifications.series_updated_confirm(original, updated, user.id, :all)

      [email] = deliver_all("send_event_update_notification")
      ics = calendar_attachment(email).data

      assert entry_uids(email) == ["series-g_20261110T093000Z", "series-g"]
      assert ics =~ "DTSTART:20261103T103000Z"
      assert ics =~ "DTEND:20261103T113000Z"
    end
  end

  # A client ignores a VEVENT whose SEQUENCE is below the one it holds for
  # that UID, so each entry goes out above the revision its guest was sent.
  describe "the SEQUENCE of each entry" do
    setup %{user: user} do
      integration = insert(:calendar_integration, user: user, provider: "google")
      cache_rule(integration, "master-g", nil)
      %{integration: integration}
    end

    test "cancelling every occurrence from the first sends an occurrence emailed twice above it",
         %{user: user, integration: integration} do
      first = google_occurrence(integration, @first)

      _emailed_twice =
        google_occurrence(integration, @second,
          last_notified_state: baseline(@second),
          ical_sequence: 2
        )

      assert {:ok, :sent} = AttendeeNotifications.event_deleted_confirm(first, user.id, :series)
      [email] = deliver_all("send_calendar_invitation")

      assert entry_sequences(email) == [{"series-g", 1}, {"series-g_20261110T093000Z", 3}]
    end

    test "cancelling every occurrence from a later one sends the invitation's entry above " <>
           "the revision its first occurrence was sent at",
         %{user: user, integration: integration} do
      _first =
        google_occurrence(integration, @first,
          last_notified_state: baseline(@first),
          ical_sequence: 4
        )

      event = google_occurrence(integration, @second)

      assert {:ok, :sent} = AttendeeNotifications.event_deleted_confirm(event, user.id, :series)
      [email] = deliver_all("send_calendar_invitation")

      assert entry_sequences(email) == [{"series-g_20261110T093000Z", 1}, {"series-g", 5}]
    end

    test "an edit of all occurrences from a later one sends the invitation's entry above " <>
           "the revision its first occurrence was sent at",
         %{user: user, integration: integration} do
      _first =
        google_occurrence(integration, @first,
          last_notified_state: baseline(@first),
          ical_sequence: 3
        )

      original = google_occurrence(integration, @second)
      updated = %{original | summary: "Weekly sync (moved room)"}

      assert {:ok, :sent} =
               AttendeeNotifications.series_updated_confirm(original, updated, user.id, :all)

      [email] = deliver_all("send_event_update_notification")

      assert entry_sequences(email) == [{"series-g_20261110T093000Z", 1}, {"series-g", 4}]
    end

    test "an entry of a job queued before entries carried their own is sent at the email's",
         %{user: user, integration: integration} do
      first = google_occurrence(integration, @first)

      _emailed_twice =
        google_occurrence(integration, @second,
          last_notified_state: baseline(@second),
          ical_sequence: 2
        )

      assert {:ok, :sent} = AttendeeNotifications.event_deleted_confirm(first, user.id, :series)
      assert [job] = enqueued_jobs("send_calendar_invitation")

      legacy_args =
        Map.update!(job.args, "other_entries", fn entries ->
          Enum.map(entries, &Map.delete(&1, "sequence"))
        end)

      assert :ok = perform_job(EmailWorker, legacy_args)
      assert_received {:email, email}

      assert entry_sequences(email) == [{"series-g", 1}, {"series-g_20261110T093000Z", 1}]
    end
  end

  describe "an Outlook series" do
    setup %{user: user} do
      integration = insert(:calendar_integration, user: user, provider: "outlook")
      %{integration: integration}
    end

    test "its first occurrence is addressed by the master's iCalUId", %{integration: integration} do
      cache_rule(integration, "master-o", "outlook-series")
      event = outlook_occurrence(integration, @first)

      email = run_update_to_delivery(moved(event))

      assert entry_uids(email) == ["outlook-series"]
    end

    test "keeps the occurrence's own uid while the master's is not known", %{
      integration: integration
    } do
      cache_rule(integration, "master-o", nil)
      event = outlook_occurrence(integration, @first)

      email = run_update_to_delivery(moved(event))

      assert entry_uids(email) == ["outlook-occurrence-1"]
    end
  end

  describe "a CalDAV series" do
    test "its first occurrence is addressed by the resource's UID", %{user: user} do
      integration = RepeatSeriesFixtures.caldav_integration(user)
      first = ~U[2026-09-30 09:00:00.000000Z]

      event =
        RepeatSeriesFixtures.caldav_occurrence(integration, %{
          uid: "weekly-standup_20260930T090000",
          start_at: first,
          end_at: DateTime.add(first, 1, :hour),
          attendees: [%{"email" => "guest@example.com"}],
          last_notified_state: baseline(first)
        })

      email = run_update_to_delivery(moved(event))

      assert entry_uids(email) == ["weekly-standup"]
    end
  end

  test "a single event keeps its own uid", %{user: user} do
    integration = insert(:calendar_integration, user: user, provider: "google")

    event =
      insert_timed_event(integration,
        uid: "one-off",
        start_at: @first,
        end_at: DateTime.add(@first, 1, :hour),
        last_notified_state: baseline(@first)
      )

    assert entry_uids(run_update_to_delivery(moved(event))) == ["one-off"]
  end

  defp cache_rule(integration, master_id, ical_uid) do
    {:ok, _row} =
      SeriesRuleQueries.put(integration.id, master_id, %{
        rule: "FREQ=WEEKLY;BYDAY=TU",
        master_start: @first,
        ical_uid: ical_uid,
        fetched_at: DateTime.utc_now()
      })
  end

  # Google files an occurrence under the series' iCalUID and its original
  # start in UTC, and keeps the iCalUID in its raw event.
  defp google_occurrence(integration, start, attrs \\ []) do
    stamp = Calendar.strftime(start, "%Y%m%dT%H%M%SZ")

    insert_timed_event(
      integration,
      Keyword.merge(
        [
          provider: "google",
          uid: "series-g_#{stamp}",
          provider_event_id: "master-g_#{stamp}",
          recurring_event_id: "master-g",
          recurrence_rule: "FREQ=WEEKLY;BYDAY=TU",
          provider_metadata: %{"iCalUID" => "series-g", "recurringEventId" => "master-g"},
          start_at: start,
          end_at: DateTime.add(start, 1, :hour)
        ],
        attrs
      )
    )
  end

  defp outlook_occurrence(integration, start) do
    insert_timed_event(integration,
      provider: "outlook",
      uid: "outlook-occurrence-1",
      provider_event_id: "occ-1",
      recurring_event_id: "master-o",
      recurrence_rule: "FREQ=WEEKLY;BYDAY=TU",
      provider_metadata: %{"type" => "occurrence", "seriesMasterId" => "master-o"},
      start_at: start,
      end_at: DateTime.add(start, 1, :hour),
      last_notified_state: baseline(start)
    )
  end

  defp baseline(start) do
    LastNotifiedState.serialise(
      %{
        title: "Weekly sync",
        starts_at: start,
        ends_at: DateTime.add(start, 1, :hour),
        location: "",
        description: ""
      },
      [%{email: "guest@example.com"}]
    )
  end

  # The occurrence retitled since it was last announced, so the worker has a
  # change to send.
  defp moved(event) do
    event
    |> Changeset.change(summary: "Weekly sync (moved room)")
    |> Repo.update!()
  end

  # The UID and SEQUENCE of every VEVENT in the email's attachment, the UID
  # without the domain every Tymeslot UID ends in.
  defp entry_sequences(email) do
    email
    |> calendar_attachment()
    |> Map.fetch!(:data)
    |> String.split("BEGIN:VEVENT")
    |> tl()
    |> Enum.map(fn vevent ->
      [_all, uid] = Regex.run(~r/\r\nUID:([^@\r]+)@/, vevent)
      [_all, sequence] = Regex.run(~r/\r\nSEQUENCE:(\d+)\r\n/, vevent)
      {uid, String.to_integer(sequence)}
    end)
  end

  # The UID of every VEVENT in the email's attachment, without the domain
  # every Tymeslot UID ends in.
  defp entry_uids(email) do
    email
    |> calendar_attachment()
    |> Map.fetch!(:data)
    |> String.split("\r\n")
    |> Enum.flat_map(fn
      "UID:" <> uid -> [uid |> String.split("@") |> hd()]
      _other -> []
    end)
  end
end
