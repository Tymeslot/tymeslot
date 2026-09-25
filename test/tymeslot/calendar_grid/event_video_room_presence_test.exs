defmodule Tymeslot.CalendarGrid.EventVideoRoomPresenceTest do
  @moduledoc """
  The nightly scan's search for grid events deleted in a calendar client
  rather than through the grid, whatever their end, and the job's last word
  before it deletes such an event's Talk conversation.

  Each test runs the real nightly worker and drains the room jobs it queues.
  An event is judged gone only once it has been seen in the calendar cache,
  then missed by every sync for two days, and then denied by the calendar
  provider itself; anything short of that keeps the conversation. Nextcloud
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
  alias Tymeslot.Workers.ExpiredVideoRoomCleanupWorker

  @day 86_400
  @talk_rooms "/ocs/v2.php/apps/spreed/api/v4/room"

  setup :verify_on_exit!

  setup do
    user = insert(:user)
    talk_host = "talk-#{System.unique_integer([:positive])}.example.com"
    test = self()

    stub(HTTPClientMock, :request, fn :delete, url, _body, _headers, _opts ->
      send(test, {:talk_deleted, url})
      {:ok, %Req.Response{status: 200, body: ocs(nil)}}
    end)

    %{user: user, talk: insert_talk_integration(user, talk_host), talk_host: talk_host}
  end

  describe "an endless series on a CalDAV calendar" do
    setup %{user: user} do
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

      %{calendar: calendar, dav_host: host}
    end

    test "deletes the conversation of a series deleted in the calendar client", ctx do
      room = series_room(ctx, "grid-series-1")
      occurrence = cache_occurrence(ctx, "grid-series-1")

      run_nightly_scan()
      assert %{event_seen_at: %DateTime{}} = Repo.reload!(room)

      deleted_in_client(occurrence, room, ctx.calendar)
      url = expect_dav_get(ctx, "grid-series-1", {404, ""})

      run_nightly_scan()

      assert_received {:dav_get, ^url}
      assert_talk_deleted(ctx, room)
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
      # Moved to a calendar the organiser did not select.
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

  describe "a one-off event on a Google calendar" do
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

      row =
        insert(:provider_calendar_event,
          calendar_integration: ctx.calendar,
          provider: "google",
          uid: "googlehex9@google.com",
          provider_event_id: "googlehex9",
          start_at: room.lobby_opens_at,
          end_at: room.ends_at
        )

      run_nightly_scan()
      assert %{event_ical_uid: "googlehex9@google.com"} = Repo.reload!(room)

      deleted_in_client(row, room, ctx.calendar)
      test = self()

      expect(GoogleCalendarAPIMock, :get_event, fn _integration, calendar_id, event_id ->
        send(test, {:asked, calendar_id, event_id})
        {:ok, %{"id" => event_id, "status" => "cancelled"}}
      end)

      run_nightly_scan()

      assert_received {:asked, "primary", "googlehex9"}
      assert_talk_deleted(ctx, room)
    end
  end

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
  defp cache_occurrence(ctx, series_uid) do
    start = DateTime.add(DateTime.utc_now(:second), 2 * @day, :second)

    insert(:provider_calendar_event,
      calendar_integration: ctx.calendar,
      provider: "caldav",
      uid: series_uid <> "_" <> Calendar.strftime(start, "%Y%m%dT%H%M%SZ"),
      start_at: start,
      end_at: DateTime.add(start, 1800, :second)
    )
  end

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
