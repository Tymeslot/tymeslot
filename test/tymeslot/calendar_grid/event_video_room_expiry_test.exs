defmodule Tymeslot.CalendarGrid.EventVideoRoomExpiryTest do
  @moduledoc """
  The expire job's last word before it deletes a calendar grid event's Talk
  conversation: it asks the calendar provider for the event itself, since the
  cache holds only a year either side of today. Each provider family is played
  at its API boundary, and Nextcloud by the HTTP client. A conversation is
  deleted only when the provider says the event is gone or over; anything the
  job cannot find out keeps it.
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
  alias Tymeslot.Workers.VideoSyncWorker

  @day 86_400
  @talk_rooms "/ocs/v2.php/apps/spreed/api/v4/room"

  setup :verify_on_exit!

  setup do
    user = insert(:user)
    talk_host = "talk-#{System.unique_integer([:positive])}.example.com"
    test = self()

    # Plays the organiser's Nextcloud server: every conversation deleted
    # reaches the test.
    stub(HTTPClientMock, :request, fn :delete, url, _body, _headers, _opts ->
      send(test, {:talk_deleted, url})
      {:ok, %Req.Response{status: 200, body: ocs(nil)}}
    end)

    %{user: user, talk: insert_talk_integration(user, talk_host), talk_host: talk_host}
  end

  describe "a Google calendar" do
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

    # Moved more than a year ahead: gone from the cache, not from Google.
    test "keeps the conversation of an event moved beyond the cache, and follows it", ctx do
      room = ended_room(ctx, provider_event_id: "googlehex1", provider_calendar_id: "work")
      new_start = DateTime.add(DateTime.utc_now(:second), 400 * @day, :second)

      test = self()

      expect(GoogleCalendarAPIMock, :get_event, fn _integration, calendar_id, event_id ->
        send(test, {:asked, calendar_id, event_id})
        {:ok, google_event("googlehex1", new_start)}
      end)

      assert :ok = expire(room)
      assert_received {:asked, "work", "googlehex1"}

      refute_received {:talk_deleted, _url}
      assert Repo.reload!(room).ends_at == DateTime.add(new_start, 1800, :second)
    end

    test "deletes the conversation of an event Google no longer has", ctx do
      room = ended_room(ctx, provider_event_id: "googlehex2", provider_calendar_id: "primary")

      test = self()

      expect(GoogleCalendarAPIMock, :get_event, fn _integration, calendar_id, event_id ->
        send(test, {:asked, calendar_id, event_id})
        {:error, :not_found, "Event not found"}
      end)

      assert :ok = expire(room)
      assert_received {:asked, "primary", "googlehex2"}

      assert_talk_deleted(ctx, room)
    end

    test "deletes the conversation of an event Google reports cancelled", ctx do
      room = ended_room(ctx, provider_event_id: "googlehex3", provider_calendar_id: "primary")
      cancelled = Map.put(google_event("googlehex3", DateTime.utc_now()), "status", "cancelled")

      test = self()

      expect(GoogleCalendarAPIMock, :get_event, fn _integration, calendar_id, event_id ->
        send(test, {:asked, calendar_id, event_id})
        {:ok, cancelled}
      end)

      assert :ok = expire(room)
      assert_received {:asked, "primary", "googlehex3"}

      assert_talk_deleted(ctx, room)
    end

    test "keeps the conversation when Google cannot be asked", ctx do
      room = ended_room(ctx, provider_event_id: "googlehex4", provider_calendar_id: "primary")

      test = self()

      expect(GoogleCalendarAPIMock, :get_event, fn _integration, calendar_id, event_id ->
        send(test, {:asked, calendar_id, event_id})
        {:error, :network_error, "Network error: :timeout"}
      end)

      assert :ok = expire(room)
      assert_received {:asked, "primary", "googlehex4"}

      refute_received {:talk_deleted, _url}
      assert Repo.get(EventVideoRoomSchema, room.id)
    end

    # Google addresses an event only within its calendar.
    test "keeps the conversation of an event it cannot address", ctx do
      room = ended_room(ctx, provider_event_id: "googlehex5", provider_calendar_id: nil)

      assert :ok = expire(room)

      refute_received {:talk_deleted, _url}
      assert Repo.get(EventVideoRoomSchema, room.id)
    end
  end

  describe "an Outlook calendar" do
    setup %{user: user} do
      calendar =
        insert(:calendar_integration,
          user: user,
          provider: "outlook",
          oauth_scope: "Calendars.ReadWrite",
          last_external_sync_at: DateTime.utc_now(:second)
        )

      %{calendar: calendar}
    end

    test "keeps the conversation of an event moved beyond the cache, and follows it", ctx do
      room = ended_room(ctx, provider_event_id: "outlookid1")
      new_start = DateTime.add(DateTime.utc_now(:second), 400 * @day, :second)

      test = self()

      expect(OutlookCalendarAPIMock, :get_event, fn _integration, event_id ->
        send(test, {:asked, event_id})
        {:ok, outlook_event("outlookid1", new_start)}
      end)

      assert :ok = expire(room)
      assert_received {:asked, "outlookid1"}

      refute_received {:talk_deleted, _url}
      assert Repo.reload!(room).ends_at == DateTime.add(new_start, 1800, :second)
    end

    test "deletes the conversation of an event Outlook no longer has", ctx do
      room =
        ctx
        |> ended_room(provider_event_id: "outlookid2")
        |> Changeset.change(event_ical_uid: "outlookid2-ical")
        |> Repo.update!()

      test = self()

      expect(OutlookCalendarAPIMock, :get_event, fn _integration, event_id ->
        send(test, {:asked, event_id})
        {:error, :not_found, "Event not found"}
      end)

      expect(OutlookCalendarAPIMock, :find_events_by_ical_uid, fn _integration, ical_uid ->
        send(test, {:searched, ical_uid})
        {:ok, []}
      end)

      assert :ok = expire(room)
      assert_received {:asked, "outlookid2"}
      assert_received {:searched, "outlookid2-ical"}

      assert_talk_deleted(ctx, room)
    end

    # A 404 by id is also what an event moved to another calendar answers.
    test "keeps and follows the conversation of an event moved to another calendar", ctx do
      room =
        ctx
        |> ended_room(provider_event_id: "outlookid4")
        |> Changeset.change(event_ical_uid: "outlookid4-ical")
        |> Repo.update!()

      new_start = DateTime.add(DateTime.utc_now(:second), 400 * @day, :second)

      expect(OutlookCalendarAPIMock, :get_event, fn _integration, "outlookid4" ->
        {:error, :not_found, "Event not found"}
      end)

      expect(OutlookCalendarAPIMock, :find_events_by_ical_uid, fn _integration,
                                                                  "outlookid4-ical" ->
        {:ok, [%{"id" => "outlookid4-moved", "iCalUId" => "outlookid4-ical"}]}
      end)

      expect(OutlookCalendarAPIMock, :get_event, fn _integration, "outlookid4-moved" ->
        {:ok, outlook_event("outlookid4-moved", new_start)}
      end)

      assert :ok = expire(room)

      refute_received {:talk_deleted, _url}
      assert Repo.reload!(room).ends_at == DateTime.add(new_start, 1800, :second)
    end

    test "keeps the conversation when the event's iCalendar UID is unknown", ctx do
      room = ended_room(ctx, provider_event_id: "outlookid5")

      expect(OutlookCalendarAPIMock, :get_event, fn _integration, "outlookid5" ->
        {:error, :not_found, "Event not found"}
      end)

      assert :ok = expire(room)

      refute_received {:talk_deleted, _url}
      assert Repo.get(EventVideoRoomSchema, room.id)
    end

    test "keeps the conversation when Outlook refuses the credentials", ctx do
      room = ended_room(ctx, provider_event_id: "outlookid3")

      test = self()

      expect(OutlookCalendarAPIMock, :get_event, fn _integration, event_id ->
        send(test, {:asked, event_id})
        {:error, :unauthorized, "Token expired or invalid"}
      end)

      assert :ok = expire(room)
      assert_received {:asked, "outlookid3"}

      refute_received {:talk_deleted, _url}
      assert Repo.get(EventVideoRoomSchema, room.id)
    end
  end

  describe "a CalDAV calendar" do
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

      %{calendar: calendar, dav_host: host}
    end

    test "keeps the conversation of an event moved beyond the cache, and follows it", ctx do
      room = ended_room(ctx, event_uid: "grid-dav-1")
      new_start = DateTime.add(DateTime.utc_now(:second), 400 * @day, :second)

      url = expect_dav_get(ctx, "grid-dav-1", {200, ical_event("grid-dav-1", new_start)})

      assert :ok = expire(room)
      assert_received {:dav_get, ^url}

      refute_received {:talk_deleted, _url}
      assert Repo.reload!(room).ends_at == DateTime.add(new_start, 1800, :second)
    end

    test "deletes the conversation of an event the server no longer has", ctx do
      room = ended_room(ctx, event_uid: "grid-dav-2")

      url = expect_dav_get(ctx, "grid-dav-2", {404, ""})

      assert :ok = expire(room)
      assert_received {:dav_get, ^url}

      assert_talk_deleted(ctx, room)
    end

    test "keeps the conversation when the server fails", ctx do
      room = ended_room(ctx, event_uid: "grid-dav-3")

      url = expect_dav_get(ctx, "grid-dav-3", {500, "Internal Server Error"})

      assert :ok = expire(room)
      assert_received {:dav_get, ^url}

      refute_received {:talk_deleted, _url}
      assert Repo.get(EventVideoRoomSchema, room.id)
    end
  end

  # Exchange has no single-event fetch.
  describe "a calendar that cannot fetch one event" do
    setup %{user: user} do
      calendar =
        insert(:calendar_integration,
          user: user,
          provider: "exchange",
          last_external_sync_at: DateTime.utc_now(:second)
        )

      %{calendar: calendar}
    end

    test "keeps the conversation of an event absent from the cache", ctx do
      room = ended_room(ctx, event_uid: "grid-ews-1")

      assert :ok = expire(room)

      refute_received {:talk_deleted, _url}
      assert Repo.get(EventVideoRoomSchema, room.id)
    end

    test "deletes the conversation of an event the cache still holds as over", ctx do
      room = ended_room(ctx, event_uid: "grid-ews-2")

      insert(:provider_calendar_event,
        calendar_integration: ctx.calendar,
        provider: "exchange",
        uid: "grid-ews-2",
        start_at: DateTime.add(room.ends_at, -1800, :second),
        end_at: room.ends_at
      )

      assert :ok = expire(room)

      assert_talk_deleted(ctx, room)
    end
  end

  defp expire(room),
    do: perform_job(VideoSyncWorker, %{"event_room_id" => room.id, "action" => "expire"})

  defp assert_talk_deleted(ctx, room) do
    assert_received {:talk_deleted, url}
    assert url == "https://#{ctx.talk_host}#{@talk_rooms}/#{room.room_id}"
    assert Repo.get(EventVideoRoomSchema, room.id) == nil
  end

  # A conversation whose event ended eight days ago and is absent from a
  # calendar synced since: the cache alone would let it go.
  defp ended_room(ctx, attrs) do
    ends_at = DateTime.add(DateTime.utc_now(:second), -8 * @day, :second)

    {:ok, room} =
      EventVideoRoomQueries.insert(
        Map.merge(
          %{
            user_id: ctx.user.id,
            video_integration_id: ctx.talk.id,
            provider: "nextcloud_talk",
            calendar_integration_id: ctx.calendar.id,
            event_uid: "grid-#{System.unique_integer([:positive])}",
            room_id: "room#{System.unique_integer([:positive])}",
            lobby_opens_at: DateTime.add(ends_at, -1800, :second),
            ends_at: ends_at
          },
          Map.new(attrs)
        )
      )

    room
  end

  defp expect_dav_get(ctx, uid, {status, body}) do
    test = self()

    expect(HTTPClientMock, :get, fn url, _headers, _opts ->
      send(test, {:dav_get, url})
      {:ok, %Req.Response{status: status, body: body}}
    end)

    "https://#{ctx.dav_host}/calendars/alice/work/#{uid}.ics"
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

  defp outlook_event(id, start),
    do: %{
      "id" => id,
      "iCalUId" => id <> "-ical",
      "subject" => "Planning",
      "isAllDay" => false,
      "start" => %{"dateTime" => DateTime.to_iso8601(start), "timeZone" => "UTC"},
      "end" => %{
        "dateTime" => DateTime.to_iso8601(DateTime.add(start, 1800, :second)),
        "timeZone" => "UTC"
      }
    }

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
