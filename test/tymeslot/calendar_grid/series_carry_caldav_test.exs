defmodule Tymeslot.CalendarGrid.SeriesCarryCalDAVTest do
  @moduledoc """
  What a CalDAV series keeps of what only Tymeslot knows about it (its video
  and the organiser's colour overrides) through an edit of every occurrence
  and a split, both of which drop its cached rows for a full sync to bring
  back, and through its first sync after being created from the grid.

  The edit travels down to the HTTP client, as in
  `Tymeslot.CalendarGrid.EventEditCalDAVSplitTest`. The sync is simulated as
  there, by inserting the rows it caches; `Tymeslot.Workers.SeriesVideoWorker`
  is then run as Oban would run it.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :video
  @moduletag :integration

  import Mox

  alias Ecto.Changeset
  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.ColourOverrideQueries
  alias Tymeslot.Integrations.Calendar.ICalBuilder.LineFolder
  alias Tymeslot.Integrations.Calendar.Operations
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Workers.SeriesVideoWorker

  setup :verify_on_exit!

  @series_href "/cal/weekly-standup.ics"
  @link "https://video.example.com/join/weekly-standup"
  @series_ical Enum.join(
                 [
                   "BEGIN:VCALENDAR",
                   "VERSION:2.0",
                   "BEGIN:VEVENT",
                   "UID:weekly-standup",
                   "DTSTAMP:20260901T090000Z",
                   "DTSTART;TZID=Europe/Berlin:20260908T090000",
                   "DTEND;TZID=Europe/Berlin:20260908T091500",
                   "RRULE:FREQ=WEEKLY;BYDAY=TU",
                   "SUMMARY:Weekly standup",
                   "DESCRIPTION:Join video call: #{@link}",
                   "END:VEVENT",
                   "END:VCALENDAR"
                 ],
                 "\r\n"
               ) <> "\r\n"

  setup do
    previous_module = Application.get_env(:tymeslot, :calendar_module)
    Application.put_env(:tymeslot, :calendar_module, Operations)

    on_exit(fn ->
      if previous_module,
        do: Application.put_env(:tymeslot, :calendar_module, previous_module),
        else: Application.delete_env(:tymeslot, :calendar_module)
    end)

    user = insert(:user)

    integration =
      insert(:calendar_integration,
        user: user,
        provider: "caldav",
        base_url: "https://caldav.example.com",
        calendar_paths: ["/cal/"]
      )

    video = insert(:video_integration, user: user, provider: "mirotalk")

    %{user: user, integration: integration, video: video}
  end

  # A row of the series as the sync caches it, carrying the series' video
  # unless told otherwise.
  defp series_row(integration, video, key, start_at, attrs \\ %{}) do
    insert(
      :provider_calendar_event,
      Map.merge(
        %{
          calendar_integration: integration,
          uid: "weekly-standup_#{key}",
          provider: "caldav",
          provider_calendar_id: "/cal/",
          provider_event_id: @series_href,
          summary: "Weekly standup",
          description: "Join video call: #{@link}",
          start_at: start_at,
          end_at: DateTime.add(start_at, 15, :minute),
          all_day: false,
          timezone: "Europe/Berlin",
          recurrence_rule: "FREQ=WEEKLY;BYDAY=TU",
          provider_metadata: %{"uid" => "weekly-standup"},
          etag: "\"etag-1\"",
          raw_ical: @series_ical,
          video_link: @link,
          video_integration_id: video.id,
          sync_state: "synced"
        },
        attrs
      )
    )
  end

  # A row the requested sync caches, which never carries a video.
  defp synced_row(integration, uid, href, start_at) do
    insert(:provider_calendar_event,
      calendar_integration: integration,
      uid: uid,
      provider: "caldav",
      provider_calendar_id: "/cal/",
      provider_event_id: href,
      summary: "Weekly standup",
      start_at: start_at,
      end_at: DateTime.add(start_at, 15, :minute),
      all_day: false,
      timezone: "Europe/Berlin",
      recurrence_rule: "FREQ=WEEKLY;BYDAY=TU",
      sync_state: "synced"
    )
  end

  defp expect_puts(count) do
    test_pid = self()

    expect(Tymeslot.HTTPClientMock, :put, count, fn url, body, _headers, _opts ->
      send(test_pid, {:put, url, body})
      {:ok, %Req.Response{status: 201, body: "", headers: %{}}}
    end)
  end

  defp tail_uid do
    assert_received {:put, "https://caldav.example.com/cal/" <> _name, body}

    body
    |> LineFolder.unfold_lines()
    |> Enum.find_value(fn
      "UID:" <> uid -> uid
      _line -> nil
    end)
  end

  defp run_video_jobs do
    [worker: SeriesVideoWorker]
    |> all_enqueued()
    |> Enum.map(&perform_job(SeriesVideoWorker, &1.args))
  end

  defp video_of(integration, uid) do
    {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, uid)
    {row.video_integration_id, row.video_link}
  end

  defp colours(user), do: Calendar.overrides_for(user.id)

  # Two hours later, 11:00 in Berlin on 15 September.
  @two_hours_later %{
    start_at: ~U[2026-09-15 09:00:00.000000Z],
    end_at: ~U[2026-09-15 09:15:00.000000Z]
  }

  describe "an edit of every occurrence that moves the series" do
    setup %{integration: integration, video: video} do
      %{
        occurrence: series_row(integration, video, "20260915T090000", ~U[2026-09-15 07:00:00Z]),
        sibling: series_row(integration, video, "20260922T090000", ~U[2026-09-22 07:00:00Z])
      }
    end

    test "the synced occurrences come back with the series' video", %{
      user: user,
      integration: integration,
      video: video,
      occurrence: occurrence
    } do
      expect_puts(1)

      assert {:ok, _updated} =
               CalendarGrid.update_event(user.id, occurrence, @two_hours_later,
                 recurrence_scope: :all
               )

      # Before the sync: nothing to give the video to yet, so the job waits.
      assert [{:snooze, _seconds}] = run_video_jobs()

      for key <- ["20260915T110000", "20260922T110000"] do
        synced_row(integration, "weekly-standup_#{key}", @series_href, ~U[2026-09-15 09:00:00Z])
      end

      assert [:ok] = run_video_jobs()

      for key <- ["20260915T110000", "20260922T110000"] do
        assert video_of(integration, "weekly-standup_#{key}") == {video.id, @link}
      end
    end

    test "an occurrence's colour follows it to the slot the series moved it to", %{
      user: user,
      integration: integration,
      occurrence: occurrence,
      sibling: sibling
    } do
      {:ok, _override} =
        ColourOverrideQueries.set_external(user.id, integration.id, sibling.uid, "grape")

      expect_puts(1)

      assert {:ok, _updated} =
               CalendarGrid.update_event(user.id, occurrence, @two_hours_later,
                 recurrence_scope: :all
               )

      assert colours(user) == %{
               {:external, integration.id, "weekly-standup_20260922T110000"} => "grape"
             }
    end

    test "a video one occurrence was given on its own is not spread to the series", %{
      user: user,
      integration: integration,
      video: video,
      occurrence: occurrence,
      sibling: sibling
    } do
      sibling
      |> Changeset.change(video_link: nil, video_integration_id: nil)
      |> Repo.update!()

      other = insert(:video_integration, user: user, provider: "mirotalk")

      occurrence
      |> Changeset.change(video_integration_id: other.id)
      |> Repo.update!()

      _third =
        series_row(integration, video, "20260929T090000", ~U[2026-09-29 07:00:00Z], %{
          video_link: nil,
          video_integration_id: nil
        })

      expect_puts(1)

      assert {:ok, _updated} =
               CalendarGrid.update_event(user.id, occurrence, %{summary: "Standup"},
                 recurrence_scope: :all
               )

      refute_enqueued(worker: SeriesVideoWorker)
    end
  end

  describe "a split for an edit of one occurrence and every following one" do
    setup %{integration: integration, video: video} do
      %{
        first: series_row(integration, video, "20260908T090000", ~U[2026-09-08 07:00:00Z]),
        occurrence: series_row(integration, video, "20260915T090000", ~U[2026-09-15 07:00:00Z]),
        sibling: series_row(integration, video, "20260922T090000", ~U[2026-09-22 07:00:00Z])
      }
    end

    test "both halves come back with the series' video", %{
      user: user,
      integration: integration,
      video: video,
      occurrence: occurrence
    } do
      expect_puts(2)

      assert {:ok, _updated} =
               CalendarGrid.update_event(user.id, occurrence, @two_hours_later,
                 recurrence_scope: :following
               )

      uid = tail_uid()

      head =
        synced_row(
          integration,
          "weekly-standup_20260908T090000",
          @series_href,
          ~U[2026-09-08 07:00:00Z]
        )

      tail =
        synced_row(
          integration,
          "#{uid}_20260922T110000",
          "/cal/#{uid}.ics",
          ~U[2026-09-22 09:00:00Z]
        )

      assert [:ok, :ok] = run_video_jobs()
      assert video_of(integration, head.uid) == {video.id, @link}
      assert video_of(integration, tail.uid) == {video.id, @link}
    end

    test "colours of the following occurrences move to the new series; earlier ones stay", %{
      user: user,
      integration: integration,
      first: first,
      occurrence: occurrence,
      sibling: sibling
    } do
      for {row, colour} <- [{first, "sage"}, {occurrence, "grape"}, {sibling, "banana"}] do
        {:ok, _override} =
          ColourOverrideQueries.set_external(user.id, integration.id, row.uid, colour)
      end

      expect_puts(2)

      assert {:ok, _updated} =
               CalendarGrid.update_event(user.id, occurrence, @two_hours_later,
                 recurrence_scope: :following
               )

      uid = tail_uid()

      assert colours(user) == %{
               {:external, integration.id, first.uid} => "sage",
               {:external, integration.id, "#{uid}_20260915T110000"} => "grape",
               {:external, integration.id, "#{uid}_20260922T110000"} => "banana"
             }
    end
  end

  describe "a series created from the grid with a video" do
    test "its first sync's occurrences take the video", %{
      integration: integration,
      video: video
    } do
      :ok =
        CalendarGrid.cache_created_event(%{
          uid: "new-series",
          calendar_integration_id: integration.id,
          provider: "caldav",
          provider_calendar_id: "/cal/",
          provider_event_id: "/cal/new-series.ics",
          summary: "Weekly standup",
          description: "Join video call: #{@link}",
          start_at: ~U[2026-09-15 07:00:00Z],
          end_at: ~U[2026-09-15 07:15:00Z],
          all_day: false,
          recurrence_rule: "FREQ=WEEKLY;BYDAY=TU",
          video_link: @link,
          video_integration_id: video.id
        })

      # Only the row standing for the series is cached until the sync.
      assert [{:snooze, _seconds}] = run_video_jobs()

      occurrence =
        synced_row(
          integration,
          "new-series_20260922T090000",
          "/cal/new-series.ics",
          ~U[2026-09-22 07:00:00Z]
        )

      assert [:ok] = run_video_jobs()
      assert video_of(integration, occurrence.uid) == {video.id, @link}
    end
  end
end
