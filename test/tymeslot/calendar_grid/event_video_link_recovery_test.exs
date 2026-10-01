defmodule Tymeslot.CalendarGrid.EventVideoLinkRecoveryTest do
  @moduledoc """
  `CalendarGrid.change_event_video/3`: the link a provider whose room URL
  carries an access token publishes, and a series recovering the video room
  it already has after its cached row lost the link; plus `put_join_link/3`,
  the helper that writes and removes the join line in an event's
  description, which both of those paths and ordinary choosing and removing
  rely on. Choosing and removing a video integration are covered by the
  sibling `EventVideoTest`.

  The video provider is reached through its real adapter with HTTP stubbed at
  `Tymeslot.HTTPClientMock`; the calendar write is stubbed at
  `Tymeslot.CalendarMock`.
  """

  # Not async: provider failures here are witnessed by the application-wide
  # video circuit breakers, which DataCase only resets between non-async modules.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :video
  @moduletag :integration

  import Mox

  alias Joken.Signer
  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.EventVideo
  alias Tymeslot.CalendarGrid.EventVideoRoomQueries
  alias Tymeslot.CalendarGrid.EventVideoRoomSchema
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Video.Providers.LinkRoom
  alias Tymeslot.Security.Encryption

  setup :verify_on_exit!

  @new_url "https://video.example.com/join/room-123"
  @reminders [%{"method" => "popup", "minutes_before" => 15}]
  @rrule "FREQ=WEEKLY;BYDAY=MO"
  @app_id "tymeslot"
  @secret "grid-shared-secret-of-at-least-32-bytes-long"
  @jitsi_server "https://meet.example.com"

  setup do
    user = insert(:user)

    # Google, so that the repeating fixture below takes the ordinary write: an
    # occurrence of a CalDAV series is written as an override of its own
    # (`Tymeslot.CalendarGrid.SeriesEdit`). The one test that needs CalDAV's
    # offline queue brings its own integration.
    integration = insert(:calendar_integration, user: user, provider: "google")

    video_integration = insert(:video_integration, user: user, provider: "mirotalk")

    %{user: user, integration: integration, video_integration: video_integration}
  end

  # A grid event mints no per-participant link: the description is one piece
  # of text every reader of the event shares. Handed the bare room URL, a
  # Jitsi server enforcing tokens refuses everybody the event reaches, the
  # organiser included, so the link published here carries a token instead —
  # one that names nobody and confers no moderator rights.
  describe "change_event_video/3 on a provider whose links carry a token" do
    test "publishes a tokenised link in the description and on the cached row", %{
      user: user,
      integration: integration
    } do
      event = insert_event(integration)
      jitsi = insert_jitsi_integration(user)
      expect_provider_update(:ok)

      assert {:ok, url} = CalendarGrid.change_event_video(user.id, event, jitsi.id)

      {:ok, room_id} = LinkRoom.slug(event.uid)
      assert String.starts_with?(url, @jitsi_server <> "/" <> room_id <> "?jwt=")

      assert reload(event).video_link == url

      assert_received {:provider_update, _uid, payload}
      assert payload.description =~ "Join video call: " <> url
    end

    test "publishes a token naming nobody, scoped to the room and not a moderator", %{
      user: user,
      integration: integration
    } do
      event = insert_event(integration)
      jitsi = insert_jitsi_integration(user)
      expect_provider_update(:ok)

      assert {:ok, url} = CalendarGrid.change_event_video(user.id, event, jitsi.id)

      {:ok, room_id} = LinkRoom.slug(event.uid)
      claims = verified_claims(url)

      assert claims["context"]["user"] == %{"moderator" => false}
      assert claims["room"] == room_id
      assert claims["exp"] == DateTime.to_unix(event.start_at) + 4 * 60 * 60
    end
  end

  describe "change_event_video/3 on a series whose row lost its link" do
    # A sync brought the series back before its video was given to it again
    # (`Tymeslot.CalendarGrid.SeriesCarry`), while its Talk room is recorded.
    @talk_url "https://talk.example.org/call/room-weekly-sync"

    setup %{user: user, integration: integration} do
      talk = insert(:video_integration, user: user, provider: "nextcloud_talk")

      {:ok, room} =
        EventVideoRoomQueries.insert(%{
          user_id: user.id,
          video_integration_id: talk.id,
          provider: "nextcloud_talk",
          calendar_integration_id: integration.id,
          event_uid: "series-1@google.com",
          provider_event_id: "series-1",
          room_id: "room-weekly-sync",
          lobby_opens_at: ~U[2026-06-01 08:45:00Z],
          ends_at: ~U[2026-12-01 10:00:00Z]
        })

      %{talk: talk, room: room}
    end

    # Under `verify_on_exit!` a room created or a calendar write would fail
    # the test: neither is expected.
    test "choosing the series' integration again makes no second room, and restores the link", %{
      user: user,
      integration: integration,
      talk: talk,
      room: room
    } do
      event =
        insert_event(integration, %{description: "Agenda\n\nJoin video call: #{@talk_url}"})

      assert {:ok, :unchanged} = CalendarGrid.change_event_video(user.id, event, talk.id)

      row = reload(event)
      assert {row.video_integration_id, row.video_link} == {talk.id, @talk_url}
      assert [%{id: room_id}] = Repo.all(EventVideoRoomSchema)
      assert room_id == room.id
    end

    # Unlike the case above, this occurrence's own join line was deliberately
    # removed (its video was set to "None"): the series' room survives
    # because another occurrence still carries it, but this row's own
    # description has nothing to restore, so re-picking the integration must
    # provision a real room rather than silently reporting success with no
    # join link written anywhere.
    test "re-picking the integration after this occurrence's own video was removed provisions a room",
         %{
           user: user,
           integration: integration,
           video_integration: video_integration
         } do
      {:ok, _room} =
        EventVideoRoomQueries.insert(%{
          user_id: user.id,
          video_integration_id: video_integration.id,
          provider: "mirotalk",
          calendar_integration_id: integration.id,
          event_uid: "series-1@google.com",
          provider_event_id: "series-1",
          room_id: "room-weekly-mirotalk",
          lobby_opens_at: ~U[2026-06-01 08:45:00Z],
          ends_at: ~U[2026-12-01 10:00:00Z]
        })

      event = insert_event(integration)

      stub_room_created()
      expect_provider_update(:ok)

      assert {:ok, @new_url} =
               CalendarGrid.change_event_video(user.id, event, video_integration.id)

      assert_received {:provider_update, _uid, payload}
      assert payload.description == "Agenda\n\nJoin video call: #{@new_url}"

      row = reload(event)
      assert row.video_link == @new_url
      assert row.video_integration_id == video_integration.id
    end
  end

  describe "put_join_link/3" do
    test "names the link on an event that had none" do
      assert EventVideo.put_join_link("Agenda", nil, "https://v.example/a") ==
               "Agenda\n\nJoin video call: https://v.example/a"
    end

    test "is the whole description when the event had none" do
      for empty <- [nil, ""] do
        assert EventVideo.put_join_link(empty, nil, "https://v.example/a") ==
                 "Join video call: https://v.example/a"
      end
    end

    test "replaces the previous link rather than stacking a second one" do
      description = "Agenda\n\nJoin video call: https://old.example/a"

      assert EventVideo.put_join_link(
               description,
               "https://old.example/a",
               "https://new.example/b"
             ) ==
               "Agenda\n\nJoin video call: https://new.example/b"
    end

    test "takes the line out of the middle of the organiser's own text" do
      description = "Agenda\n\nJoin video call: https://old.example/a\n\nBring notes"

      assert EventVideo.put_join_link(description, "https://old.example/a", nil) ==
               "Agenda\n\nBring notes"
    end

    test "leaves the description alone when removing a link it never named" do
      assert EventVideo.put_join_link("Agenda", "https://old.example/a", nil) == "Agenda"
    end

    test "leaves nothing behind when the line was the whole description" do
      assert EventVideo.put_join_link(
               "Join video call: https://old.example/a",
               "https://old.example/a",
               nil
             ) == ""
    end

    test "does not treat a link the organiser wrote themselves as ours" do
      description = "Agenda\n\nSee https://old.example/a for the room"

      assert EventVideo.put_join_link(description, "https://old.example/a", nil) == description
    end
  end

  defp insert_event(integration, attrs \\ %{}) do
    defaults = %{
      calendar_integration: integration,
      summary: "Weekly sync",
      description: "Agenda",
      provider: "google",
      provider_calendar_id: "team-calendar",
      provider_event_id: "/cal/weekly-sync.ics",
      start_at: ~U[2026-06-01 09:00:00.000000Z],
      end_at: ~U[2026-06-01 10:00:00.000000Z],
      all_day: false,
      reminders: @reminders,
      recurrence_rule: @rrule,
      recurring_event_id: "series-1",
      colour: "tomato",
      video_link: nil,
      video_integration_id: nil,
      sync_state: "synced"
    }

    insert(:provider_calendar_event, Map.merge(defaults, attrs))
  end

  defp reload(event) do
    {:ok, row} = ProviderCalendarEventQueries.get_by_uid(event.calendar_integration_id, event.uid)
    row
  end

  defp stub_room_created do
    body = Jason.encode!(%{"room_id" => "room-123", "meeting_url" => @new_url})

    stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
      {:ok, %Req.Response{status: 200, body: body}}
    end)
  end

  defp expect_provider_update(result) do
    test_pid = self()

    expect(Tymeslot.CalendarMock, :update_event, fn uid, payload, _context ->
      send(test_pid, {:provider_update, uid, payload})
      result
    end)
  end

  defp insert_jitsi_integration(user) do
    insert(:video_integration,
      user: user,
      name: "Our Jitsi",
      provider: "jitsi",
      base_url: @jitsi_server,
      client_id_encrypted: Encryption.encrypt(@app_id),
      client_secret_encrypted: Encryption.encrypt(@secret)
    )
  end

  # Verifying against the configured secret, rather than only decoding the
  # payload, also proves the token is signed with it.
  defp verified_claims(url) do
    %URI{query: query} = URI.parse(url)
    %{"jwt" => token} = URI.decode_query(query)

    assert {:ok, claims} = Joken.verify(token, Signer.create("HS256", @secret))
    claims
  end
end
