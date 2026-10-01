defmodule Tymeslot.CalendarGrid.EventVideoRoomPresenceTest do
  @moduledoc """
  The nightly scan's search for grid events deleted in a calendar client
  rather than through the grid, whatever their end, and the job's last word
  before it deletes such an event's Talk conversation.

  Each test runs the real nightly worker and drains the room jobs it queues.
  An event is judged gone only once it has been seen in the calendar cache,
  then missed by every sync for two days, and then denied by the calendar
  provider itself, in every calendar of the organiser's account it can write
  to, since the event may have moved to one the organiser did not select
  (a cancelled copy of the event counts for nothing); anything short
  of that keeps the conversation, and so does another event still carrying
  its link, which takes it over. Nextcloud
  (Talk and CalDAV) is played by the HTTP client, Google at its API boundary.
  """

  # Not async: the calendar providers' circuit breakers are VM-wide.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :video
  @moduletag :integration

  import Mox

  alias Ecto.Changeset
  alias Tymeslot.CalendarGrid.EventVideoRoomQueries
  alias Tymeslot.CalendarGrid.EventVideoRoomSchema
  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Test.CalDAVAccountStub
  alias Tymeslot.Workers.ExpiredVideoRoomCleanupWorker

  @day 86_400
  @talk_rooms "/ocs/v2.php/apps/spreed/api/v4/room"
  @team_calendar "team@group.calendar.google.com"
  @colleague_dav "/calendars/bob/team/"
  @colleague "bob@example.com"

  setup :verify_on_exit!

  setup do
    user = insert(:user)
    talk_host = "talk-#{System.unique_integer([:positive])}.example.com"
    answer_requests(%{})

    %{user: user, talk: insert_talk_integration(user, talk_host), talk_host: talk_host}
  end

  describe "an endless series on a CalDAV calendar" do
    setup :caldav_calendar

    test "deletes the conversation of a series deleted in the calendar client", ctx do
      room = series_room(ctx, "grid-series-1")
      occurrence = cache_occurrence(ctx, "grid-series-1")

      run_nightly_scan()
      assert %{event_seen_at: %DateTime{}} = Repo.reload!(room)

      deleted_in_client(occurrence, room, ctx.calendar)
      url = expect_dav_get(ctx, "grid-series-1", {404, ""})

      run_nightly_scan()

      assert_received {:dav_get, ^url}
      # Nor has any calendar of the account, the unselected one included. The
      # colleague's, which it can only read, cannot have been moved into.
      assert_received {:dav_report, "/calendars/alice/private/", "grid-series-1"}
      refute_received {:dav_report, @colleague_dav, _uid}
      assert_talk_deleted(ctx, room)
    end

    test "deletes the conversation of a series cancelled in the calendar client", ctx do
      room = series_room(ctx, "grid-series-5")
      occurrence = cache_occurrence(ctx, "grid-series-5")
      run_nightly_scan()

      deleted_in_client(occurrence, room, ctx.calendar)
      start = DateTime.add(DateTime.utc_now(:second), 2 * @day, :second)

      cancelled =
        String.replace(
          ical_event("grid-series-5", start),
          "END:VEVENT",
          "STATUS:CANCELLED\r\nEND:VEVENT"
        )

      url = expect_dav_get(ctx, "grid-series-5", {200, cancelled})

      run_nightly_scan()

      assert_received {:dav_get, ^url}
      assert_talk_deleted(ctx, room)
    end

    # Moved in the calendar client to a calendar the organiser did not select,
    # under a resource name of the client's choosing.
    test "keeps the conversation of a series moved to another calendar", ctx do
      room = series_room(ctx, "grid-series-4")
      occurrence = cache_occurrence(ctx, "grid-series-4")
      run_nightly_scan()

      deleted_in_client(occurrence, room, ctx.calendar)
      url = expect_dav_get(ctx, "grid-series-4", {404, ""})
      start = DateTime.add(DateTime.utc_now(:second), 2 * @day, :second)

      answer_requests(
        Map.put(ctx.account, :resources, %{
          "/calendars/alice/private/" => [
            {"/calendars/alice/private/0A9C.ics", ical_event("grid-series-4", start)}
          ]
        })
      )

      run_nightly_scan()

      assert_received {:dav_get, ^url}
      assert_kept(room)
      assert DateTime.diff(DateTime.utc_now(), Repo.reload!(room).event_seen_at) < 60
    end

    test "keeps the conversation while the server cannot answer", ctx do
      room = series_room(ctx, "grid-series-2")
      occurrence = cache_occurrence(ctx, "grid-series-2")
      run_nightly_scan()

      deleted_in_client(occurrence, room, ctx.calendar)
      url = expect_dav_get(ctx, "grid-series-2", {500, "Internal Server Error"})

      run_nightly_scan()

      assert_received {:dav_get, ^url}
      assert_kept(room)
    end

    test "keeps the conversation of a series the server still has", ctx do
      room = series_room(ctx, "grid-series-3")
      occurrence = cache_occurrence(ctx, "grid-series-3")
      run_nightly_scan()

      deleted_in_client(occurrence, room, ctx.calendar)
      # Still in its calendar, where the cache does not reach.
      start = DateTime.add(DateTime.utc_now(:second), 2 * @day, :second)
      url = expect_dav_get(ctx, "grid-series-3", {200, ical_event("grid-series-3", start)})

      run_nightly_scan()

      assert_received {:dav_get, ^url}
      assert_kept(room)
      # Found where the cache does not reach: the clock starts again.
      assert DateTime.diff(DateTime.utc_now(), Repo.reload!(room).event_seen_at) < 60
    end

    test "never asks about an event it has never seen in the cache", ctx do
      room = series_room(ctx, "grid-series-4")
      calendar_synced(ctx.calendar, DateTime.utc_now(:second))

      run_nightly_scan()
      run_nightly_scan()

      refute_received {:dav_get, _url}
      assert_kept(room)
      assert Repo.reload!(room).event_seen_at == nil
    end

    test "waits two days of syncs before asking", ctx do
      room = series_room(ctx, "grid-series-5")
      occurrence = cache_occurrence(ctx, "grid-series-5")
      run_nightly_scan()

      Repo.delete!(occurrence)
      seen_at = DateTime.add(DateTime.utc_now(:second), -3 * @day, :second)
      set_seen_at(room, seen_at)
      # The calendar last synced a day after the event was seen, not two.
      calendar_synced(ctx.calendar, DateTime.add(seen_at, @day, :second))

      run_nightly_scan()

      refute_received {:dav_get, _url}
      assert_kept(room)
    end

    test "restarts the clock when the event reappears in the cache", ctx do
      room = series_room(ctx, "grid-series-6")
      cache_occurrence(ctx, "grid-series-6")

      set_seen_at(room, DateTime.add(DateTime.utc_now(:second), -3 * @day, :second))
      calendar_synced(ctx.calendar, DateTime.utc_now(:second))

      run_nightly_scan()

      refute_received {:dav_get, _url}
      assert_kept(room)
      assert DateTime.diff(DateTime.utc_now(), Repo.reload!(room).event_seen_at) < 60
    end
  end

  describe "the later half of a split CalDAV series, deleted in the calendar client" do
    # The room moved to the later series, `grid-tail`, on the split, while
    # the earlier one, `grid-head`, may keep occurrences linking to it.
    setup :caldav_calendar

    test "hands the conversation to the earlier half still linking to it", ctx do
      room = series_room(ctx, "grid-tail")
      link = talk_link(ctx, room)

      tail =
        cache_occurrence(ctx, "grid-tail", video_link: link, video_integration_id: ctx.talk.id)

      # Only in its description: its cached link waits for the sync.
      cache_occurrence(ctx, "grid-head", description: "Agenda\n\nJoin video call: #{link}")

      run_nightly_scan()
      assert %{join_link: ^link} = Repo.reload!(room)

      deleted_in_client(tail, room, ctx.calendar)
      url = expect_dav_get(ctx, "grid-tail", {404, ""})

      run_nightly_scan()

      assert_received {:dav_get, ^url}
      assert_kept(room)
      assert %{event_uid: "grid-head", event_seen_at: nil} = Repo.reload!(room)

      # Judged from now on by the earlier half, which the next scan finds.
      run_nightly_scan()

      refute_received {:dav_get, _url}
      assert_kept(room)
      assert %{event_seen_at: %DateTime{}} = Repo.reload!(room)
    end

    test "deletes the conversation when no other event carries its link", ctx do
      room = series_room(ctx, "grid-tail")

      tail =
        cache_occurrence(ctx, "grid-tail",
          video_link: talk_link(ctx, room),
          video_integration_id: ctx.talk.id
        )

      cache_occurrence(ctx, "grid-head", video_link: "https://#{ctx.talk_host}/call/other")

      run_nightly_scan()
      deleted_in_client(tail, room, ctx.calendar)
      url = expect_dav_get(ctx, "grid-tail", {404, ""})

      run_nightly_scan()

      assert_received {:dav_get, ^url}
      assert_talk_deleted(ctx, room)
    end
  end

  describe "the join link a series room is seen with" do
    setup :caldav_calendar

    test "is the room's own, not that of an occurrence with a video of its own", ctx do
      room = series_room(ctx, "grid-series-7")
      link = talk_link(ctx, room)
      other_talk = insert_talk_integration(ctx.user, "other-#{ctx.talk_host}")

      # Cached first, so the first link found would be this one.
      cache_occurrence(ctx, "grid-series-7",
        in_days: 2,
        video_link: "https://other-#{ctx.talk_host}/call/own-room",
        video_integration_id: other_talk.id
      )

      cache_occurrence(ctx, "grid-series-7",
        in_days: 9,
        video_link: link,
        video_integration_id: ctx.talk.id
      )

      run_nightly_scan()

      assert %{join_link: ^link} = Repo.reload!(room)
    end

    test "is the one most occurrences carry among the room's integration's links", ctx do
      room = series_room(ctx, "grid-series-8")
      link = talk_link(ctx, room)

      cache_occurrence(ctx, "grid-series-8",
        in_days: 2,
        video_link: "https://#{ctx.talk_host}/call/another-room",
        video_integration_id: ctx.talk.id
      )

      for in_days <- [9, 16] do
        cache_occurrence(ctx, "grid-series-8",
          in_days: in_days,
          video_link: link,
          video_integration_id: ctx.talk.id
        )
      end

      run_nightly_scan()

      assert %{join_link: ^link} = Repo.reload!(room)
    end
  end

  describe "an event on a Google calendar" do
    setup %{user: user} do
      calendar =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          oauth_scope: "https://www.googleapis.com/auth/calendar",
          default_booking_calendar_id: "primary",
          last_external_sync_at: DateTime.utc_now(:second)
        )

      %{calendar: calendar}
    end

    # Its end is still ahead, so the ended-room clean-up never reaches it.
    test "deletes the conversation of an upcoming event deleted in the calendar client", ctx do
      room = upcoming_room(ctx, provider_event_id: "googlehex9", provider_calendar_id: "primary")
      seen_then_deleted(ctx, room)

      answer_google(%{"primary" => :cancelled, @team_calendar => :not_found})

      run_nightly_scan()

      assert_received {:asked, "primary", "googlehex9"}
      assert_received {:asked, @team_calendar, "googlehex9"}
      # The primary calendar is asked once, under its alias, and the
      # colleague's calendars, which refuse, cannot have been moved into.
      refute_received {:asked, "alice@example.com", _event_id}
      refute_received {:asked, @colleague, _event_id}
      refute_received {:asked, "carol@example.com", _event_id}
      assert_talk_deleted(ctx, room)
    end

    test "keeps the conversation of an event moved to another calendar", ctx do
      room = upcoming_room(ctx, provider_event_id: "googlehex8", provider_calendar_id: "primary")
      seen_then_deleted(ctx, room)

      answer_google(%{
        "primary" => :not_found,
        @team_calendar => google_event("googlehex8", room.lobby_opens_at)
      })

      run_nightly_scan()

      assert_received {:asked, @team_calendar, "googlehex8"}
      assert_kept(room)
      assert DateTime.diff(DateTime.utc_now(), Repo.reload!(room).event_seen_at) < 60
    end

    # A series keeps its master's id when it moves.
    test "keeps the conversation of a series moved to another calendar", ctx do
      room =
        upcoming_room(ctx,
          provider_event_id: "googleseries7",
          provider_calendar_id: "primary",
          ends_at: nil
        )

      seen_then_deleted(ctx, room)

      series =
        "googleseries7"
        |> google_event(room.lobby_opens_at)
        |> Map.put("recurrence", ["RRULE:FREQ=WEEKLY"])

      answer_google(%{"primary" => :cancelled, @team_calendar => series})

      run_nightly_scan()

      assert_received {:asked, @team_calendar, "googleseries7"}
      assert_kept(room)
      assert DateTime.diff(DateTime.utc_now(), Repo.reload!(room).event_seen_at) < 60
    end

    test "keeps the conversation while the account's calendars cannot be listed", ctx do
      room = upcoming_room(ctx, provider_event_id: "googlehex7", provider_calendar_id: "primary")
      seen_then_deleted(ctx, room)
      test = self()

      expect(GoogleCalendarAPIMock, :get_event, fn _integration, calendar_id, event_id ->
        send(test, {:asked, calendar_id, event_id})
        {:error, :not_found, "Not Found"}
      end)

      expect(GoogleCalendarAPIMock, :list_calendars, fn _integration ->
        {:error, :network_error, "Network error: :timeout"}
      end)

      run_nightly_scan()

      assert_received {:asked, "primary", "googlehex7"}
      assert_kept(room)
    end
  end

  defp caldav_calendar(%{user: user}) do
    host = "dav-#{System.unique_integer([:positive])}.example.com"

    calendar =
      insert(:calendar_integration,
        user: user,
        provider: "caldav",
        base_url: "https://#{host}",
        username_encrypted: Encryption.encrypt("alice"),
        password_encrypted: Encryption.encrypt("s3cret"),
        calendar_paths: ["/calendars/alice/work/"],
        last_external_sync_at: DateTime.utc_now(:second)
      )

    # Any question to the server the test did not expect is seen, not raised
    # into the job, where the job's failure would pass for keeping the room.
    test = self()

    stub(HTTPClientMock, :get, fn url, _headers, _opts ->
      send(test, {:dav_get, url})
      {:ok, %Req.Response{status: 404, body: ""}}
    end)

    # The account also holds a calendar the organiser did not select, and a
    # colleague's shared read-only, which refuses a search.
    account = %{
      calendars: ["/calendars/alice/work/", "/calendars/alice/private/", @colleague_dav],
      read_only: [@colleague_dav],
      failing: %{@colleague_dav => 403},
      notify: test
    }

    answer_requests(account)

    %{calendar: calendar, dav_host: host, account: account}
  end

  # Plays the organiser's Nextcloud: every conversation deleted reaches the
  # test, and the CalDAV account answers the search for a moved event.
  defp answer_requests(account) do
    test = self()

    stub(HTTPClientMock, :request, fn
      :delete, url, _body, _headers, _opts ->
        send(test, {:talk_deleted, url})
        {:ok, %Req.Response{status: 200, body: ocs(nil)}}

      method, url, body, _headers, _opts ->
        CalDAVAccountStub.answer(account, method, url, body)
    end)
  end

  # A Google event the scan has seen in the cache, then missed for two days.
  defp seen_then_deleted(ctx, room) do
    row =
      insert(:provider_calendar_event,
        calendar_integration: ctx.calendar,
        provider: "google",
        uid: room.provider_event_id <> "@google.com",
        provider_event_id: room.provider_event_id,
        start_at: room.lobby_opens_at,
        end_at: DateTime.add(room.lobby_opens_at, 1800, :second)
      )

    run_nightly_scan()
    assert %{event_seen_at: %DateTime{}} = Repo.reload!(room)
    deleted_in_client(row, room, ctx.calendar)
  end

  # Google's answer for the event in each calendar of an account whose
  # primary calendar is alice@example.com: `:not_found`, `:cancelled`, or the
  # event itself. Colleagues' calendars it can only read, or only see as
  # busy, refuse.
  defp answer_google(answers) do
    test = self()

    stub(GoogleCalendarAPIMock, :list_calendars, fn _integration ->
      {:ok,
       [
         %{"id" => "alice@example.com", "primary" => true, "accessRole" => "owner"},
         %{"id" => @team_calendar, "accessRole" => "writer"},
         %{"id" => @colleague, "accessRole" => "reader"},
         %{"id" => "carol@example.com", "accessRole" => "freeBusyReader"}
       ]}
    end)

    answers = Map.merge(%{@colleague => :forbidden, "carol@example.com" => :forbidden}, answers)

    stub(GoogleCalendarAPIMock, :get_event, fn _integration, calendar_id, event_id ->
      send(test, {:asked, calendar_id, event_id})

      case Map.get(answers, calendar_id, :not_found) do
        :not_found -> {:error, :not_found, "Not Found"}
        :cancelled -> {:ok, %{"id" => event_id, "status" => "cancelled"}}
        :forbidden -> {:error, :unauthorized, "Forbidden"}
        %{"id" => ^event_id} = event -> {:ok, event}
      end
    end)
  end

  defp google_event(id, start),
    do: %{
      "id" => id,
      "iCalUID" => id <> "@google.com",
      "status" => "confirmed",
      "summary" => "Planning",
      "start" => %{"dateTime" => DateTime.to_iso8601(start)},
      "end" => %{"dateTime" => DateTime.to_iso8601(DateTime.add(start, 1800, :second))}
    }

  defp run_nightly_scan do
    assert :ok = perform_job(ExpiredVideoRoomCleanupWorker, %{})
    Oban.drain_queue(queue: :video_rooms, with_recursion: true)
  end

  # The event leaves the cache, and the calendar has synced for two days and
  # more since the scan last saw it.
  defp deleted_in_client(cached_row, room, calendar) do
    Repo.delete!(cached_row)
    set_seen_at(room, DateTime.add(DateTime.utc_now(:second), -3 * @day, :second))
    calendar_synced(calendar, DateTime.utc_now(:second))
  end

  defp set_seen_at(room, seen_at) do
    room |> Changeset.change(event_seen_at: seen_at) |> Repo.update!()
  end

  defp calendar_synced(calendar, at) do
    calendar |> Changeset.change(last_external_sync_at: at) |> Repo.update!()
  end

  defp assert_talk_deleted(ctx, room) do
    assert_received {:talk_deleted, url}
    assert url == "https://#{ctx.talk_host}#{@talk_rooms}/#{room.room_id}"
    assert Repo.get(EventVideoRoomSchema, room.id) == nil
  end

  defp assert_kept(room) do
    refute_received {:talk_deleted, _url}
    assert Repo.get(EventVideoRoomSchema, room.id)
  end

  # A series with no known end, as the grid records it.
  defp series_room(ctx, uid) do
    lobby = DateTime.add(DateTime.utc_now(:second), -30 * @day, :second)
    insert_room(ctx, %{event_uid: uid, lobby_opens_at: lobby, ends_at: nil})
  end

  defp upcoming_room(ctx, attrs) do
    start = DateTime.add(DateTime.utc_now(:second), 5 * @day, :second)

    insert_room(
      ctx,
      Map.merge(
        %{lobby_opens_at: start, ends_at: DateTime.add(start, 1800, :second)},
        Map.new(attrs)
      )
    )
  end

  defp insert_room(ctx, attrs) do
    {:ok, room} =
      EventVideoRoomQueries.insert(
        Map.merge(
          %{
            user_id: ctx.user.id,
            video_integration_id: ctx.talk.id,
            provider: "nextcloud_talk",
            calendar_integration_id: ctx.calendar.id,
            event_uid: "grid-#{System.unique_integer([:positive])}",
            room_id: "room#{System.unique_integer([:positive])}"
          },
          attrs
        )
      )

    room
  end

  # A CalDAV occurrence, cached under the series uid and its start.
  defp cache_occurrence(ctx, series_uid, attrs \\ []) do
    {in_days, attrs} = Keyword.pop(attrs, :in_days, 2)
    start = DateTime.add(DateTime.utc_now(:second), in_days * @day, :second)

    insert(
      :provider_calendar_event,
      [
        calendar_integration: ctx.calendar,
        provider: "caldav",
        uid: series_uid <> "_" <> Calendar.strftime(start, "%Y%m%dT%H%M%SZ"),
        start_at: start,
        end_at: DateTime.add(start, 1800, :second)
      ] ++ attrs
    )
  end

  # The link the grid published for a room.
  defp talk_link(ctx, room), do: "https://#{ctx.talk_host}/call/#{room.room_id}"

  defp expect_dav_get(ctx, uid, {status, body}) do
    test = self()

    expect(HTTPClientMock, :get, fn url, _headers, _opts ->
      send(test, {:dav_get, url})
      {:ok, %Req.Response{status: status, body: body}}
    end)

    "https://#{ctx.dav_host}/calendars/alice/work/#{uid}.ics"
  end

  defp ical_event(uid, start) do
    stamp = &Calendar.strftime(&1, "%Y%m%dT%H%M%SZ")

    """
    BEGIN:VCALENDAR\r
    VERSION:2.0\r
    PRODID:-//Tymeslot//EN\r
    BEGIN:VEVENT\r
    UID:#{uid}\r
    DTSTAMP:#{stamp.(DateTime.utc_now())}\r
    DTSTART:#{stamp.(start)}\r
    DTEND:#{stamp.(DateTime.add(start, 1800, :second))}\r
    RRULE:FREQ=WEEKLY\r
    SUMMARY:Planning\r
    END:VEVENT\r
    END:VCALENDAR\r
    """
  end

  defp insert_talk_integration(user, host) do
    base_url = "https://" <> host

    insert(:video_integration,
      user: user,
      provider: "nextcloud_talk",
      base_url: base_url,
      client_id_encrypted: Encryption.encrypt("organiser"),
      client_secret_encrypted: Encryption.encrypt("Abcde-Fghij-Klmno-Pqrst-Uvwxy"),
      provider_account_id: base_url <> "||organiser"
    )
  end

  defp ocs(data), do: Jason.encode!(%{"ocs" => %{"meta" => %{"status" => "ok"}, "data" => data}})
end
