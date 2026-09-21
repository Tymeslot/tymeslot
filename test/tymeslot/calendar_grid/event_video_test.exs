defmodule Tymeslot.CalendarGrid.EventVideoTest do
  @moduledoc """
  `CalendarGrid.change_event_video/3` gives a calendar-grid event a room on
  one of the organiser's video integrations, or removes its link, on both the
  provider event and the cached row.

  The video provider is reached through its real adapter with HTTP stubbed at
  `Tymeslot.HTTPClientMock` (MiroTalk for creation, Zoom where a room has to
  be deleted); the calendar write is stubbed at `Tymeslot.CalendarMock`.
  """

  # Not async: provider failures here are witnessed by the application-wide
  # video circuit breakers, which DataCase only resets between non-async modules.
  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :video
  @moduletag :integration

  import Mox

  alias Joken.Signer
  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.EventVideo
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Video.Providers.LinkRoom
  alias Tymeslot.Security.Encryption

  setup :verify_on_exit!

  @new_url "https://video.example.com/join/room-123"
  @old_url "https://video.example.com/join/old-room"
  @reminders [%{"method" => "popup", "minutes_before" => 15}]
  @rrule "FREQ=WEEKLY;BYDAY=MO"
  @app_id "tymeslot"
  @secret "grid-shared-secret-of-at-least-32-bytes-long"
  @jitsi_server "https://meet.example.com"

  setup do
    user = insert(:user)

    integration =
      insert(:calendar_integration, user: user, provider: "caldav", calendar_paths: ["/cal/"])

    video_integration = insert(:video_integration, user: user, provider: "mirotalk")

    %{user: user, integration: integration, video_integration: video_integration}
  end

  describe "change_event_video/3 choosing a video integration" do
    test "saves the new link and integration on the row and keeps its other columns", %{
      user: user,
      integration: integration,
      video_integration: video_integration
    } do
      event = insert_event(integration)
      stub_room_created()
      expect_provider_update(:ok)

      assert {:ok, @new_url} =
               CalendarGrid.change_event_video(user.id, event, video_integration.id)

      row = reload(event)
      assert row.video_link == @new_url
      assert row.video_integration_id == video_integration.id
      assert row.colour == "tomato"
      assert row.reminders == @reminders
      assert row.recurrence_rule == @rrule
      assert row.recurring_event_id == "series-1"
    end

    test "writes the join link into the event's description on the calendar", %{
      user: user,
      integration: integration,
      video_integration: video_integration
    } do
      event = insert_event(integration)
      stub_room_created()
      expect_provider_update(:ok)

      assert {:ok, @new_url} =
               CalendarGrid.change_event_video(user.id, event, video_integration.id)

      assert_received {:provider_update, uid, payload}
      assert uid == event.uid
      assert payload.description == "Agenda\n\nJoin video call: #{@new_url}"
      assert payload.recurrence_rule == @rrule
      assert reload(event).description == payload.description
    end

    test "replaces the previous join link rather than adding a second one", %{
      user: user,
      integration: integration,
      video_integration: video_integration
    } do
      event =
        insert_event(integration, %{
          description: "Agenda\n\nJoin video call: #{@old_url}",
          video_link: @old_url
        })

      stub_room_created()
      expect_provider_update(:ok)

      assert {:ok, @new_url} =
               CalendarGrid.change_event_video(user.id, event, video_integration.id)

      assert_received {:provider_update, _uid, payload}
      assert payload.description == "Agenda\n\nJoin video call: #{@new_url}"
    end

    test "keeps the change when the calendar write is queued for retry", %{
      user: user,
      integration: integration,
      video_integration: video_integration
    } do
      event = insert_event(integration)
      stub_room_created()
      expect_provider_update({:error, :server_error})

      assert {:ok, @new_url} =
               CalendarGrid.change_event_video(user.id, event, video_integration.id)

      row = reload(event)
      assert row.video_link == @new_url
      assert row.sync_state == "locally_modified"
    end

    test "changes nothing when the calendar rejects the write", %{
      user: user,
      integration: integration,
      video_integration: video_integration
    } do
      event = insert_event(integration, %{video_link: @old_url})
      stub_room_created()
      expect_provider_update({:error, :unauthorized})

      assert {:error, :unauthorized} =
               CalendarGrid.change_event_video(user.id, event, video_integration.id)

      row = reload(event)
      assert row.video_link == @old_url
      assert row.video_integration_id == nil
    end

    test "keeps the current link when the provider's room has no join URL", %{
      user: user,
      integration: integration,
      video_integration: video_integration
    } do
      event = insert_event(integration, %{video_link: @old_url})

      stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"room_id" => "room-123"})}}
      end)

      assert {:error, :missing_meeting_url} =
               CalendarGrid.change_event_video(user.id, event, video_integration.id)

      row = reload(event)
      assert row.video_link == @old_url
      assert row.video_integration_id == nil
      assert row.description == "Agenda"
    end

    test "changes nothing when the room cannot be created", %{
      user: user,
      integration: integration,
      video_integration: video_integration
    } do
      event = insert_event(integration, %{video_link: @old_url})

      stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 500, body: "down"}}
      end)

      assert {:error, _reason} =
               CalendarGrid.change_event_video(user.id, event, video_integration.id)

      assert reload(event).video_link == @old_url
    end

    test "derives a templated custom link's room from the event's own uid", %{
      user: user,
      integration: integration
    } do
      # The real `CustomProvider` path, no HTTP: a template URL has no room to
      # create, only a slug to derive, and it derives it from the `meeting_id`
      # it is given. Passing the event's uid is what makes the room the same
      # whether video was picked when the event was made or switched on here.
      video_integration =
        insert(:video_integration,
          user: user,
          provider: "custom",
          custom_meeting_url: "https://meet.example.com/{{meeting_id}}"
        )

      event = insert_event(integration)
      expect_provider_update(:ok)

      assert {:ok, url} = CalendarGrid.change_event_video(user.id, event, video_integration.id)

      assert {:ok, slug} = LinkRoom.slug(event.uid)
      assert url == "https://meet.example.com/#{slug}"
    end

    test "refuses a video integration that belongs to another organiser", %{
      user: user,
      integration: integration
    } do
      foreign = insert(:video_integration, user: insert(:user), provider: "mirotalk")
      event = insert_event(integration)

      assert {:error, :not_found} = CalendarGrid.change_event_video(user.id, event, foreign.id)

      row = reload(event)
      assert row.video_link == nil
      assert row.video_integration_id == nil
    end

    test "reports the choice as unchanged when the event already has a link from it", %{
      user: user,
      integration: integration,
      video_integration: video_integration
    } do
      event =
        insert_event(integration, %{
          video_link: @old_url,
          video_integration_id: video_integration.id
        })

      assert {:ok, :unchanged} =
               CalendarGrid.change_event_video(user.id, event, video_integration.id)
    end

    test "still provisions a room when the integration is set but its link is missing", %{
      user: user,
      integration: integration,
      video_integration: video_integration
    } do
      event =
        insert_event(integration, %{
          video_link: nil,
          video_integration_id: video_integration.id
        })

      stub_room_created()
      expect_provider_update(:ok)

      assert {:ok, @new_url} =
               CalendarGrid.change_event_video(user.id, event, video_integration.id)

      assert reload(event).video_link == @new_url
    end
  end

  describe "change_event_video/3 removing the video link" do
    test "reports the choice as unchanged when the event has no video to remove", %{
      user: user,
      integration: integration
    } do
      event = insert_event(integration)

      assert {:ok, :unchanged} = CalendarGrid.change_event_video(user.id, event, nil)
    end

    test "clears the link and integration, and takes the join line out of the description", %{
      user: user,
      integration: integration,
      video_integration: video_integration
    } do
      event =
        insert_event(integration, %{
          description: "Agenda\n\nJoin video call: #{@old_url}",
          video_link: @old_url,
          video_integration_id: video_integration.id
        })

      expect_provider_update(:ok)

      assert {:ok, nil} = CalendarGrid.change_event_video(user.id, event, nil)

      assert_received {:provider_update, _uid, payload}
      assert payload.description == "Agenda"

      row = reload(event)
      assert row.video_link == nil
      assert row.video_integration_id == nil
      assert row.colour == "tomato"
    end

    test "deletes the room it no longer uses", %{user: user, integration: integration} do
      zoom = insert_zoom_integration(user)
      zoom_url = "https://zoom.us/j/86360699337"

      event =
        insert_event(integration, %{
          description: "Join video call: #{zoom_url}",
          video_link: zoom_url,
          video_integration_id: zoom.id
        })

      expect_provider_update(:ok)
      stub(Tymeslot.ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      expect(Tymeslot.HTTPClientMock, :request, fn :delete, url, _body, _headers, _opts ->
        assert url == "https://api.zoom.us/v2/meetings/86360699337"
        {:ok, %Req.Response{status: 204, body: ""}}
      end)

      assert {:ok, nil} = CalendarGrid.change_event_video(user.id, event, nil)
      assert_received {:provider_update, _uid, %{description: ""}}
    end

    test "deletes nothing when no provider recognises the link it drops", %{
      user: user,
      integration: integration
    } do
      zoom = insert_zoom_integration(user)

      # A Nextcloud Talk link. Its host contains "talk.", which MiroTalk's URL
      # patterns used to claim, so the room id came back as MiroTalk's last
      # path segment and the removal fired a delete for it against the event's
      # own provider, leaving the real room behind.
      link = "https://talk.example.org/call/abc123"

      event =
        insert_event(integration, %{
          description: "Join video call: #{link}",
          video_link: link,
          video_integration_id: zoom.id
        })

      expect_provider_update(:ok)
      stub(Tymeslot.ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      test_pid = self()

      stub(Tymeslot.HTTPClientMock, :request, fn :delete, url, _body, _headers, _opts ->
        send(test_pid, {:room_deleted, url})
        {:ok, %Req.Response{status: 204, body: ""}}
      end)

      assert {:ok, nil} = CalendarGrid.change_event_video(user.id, event, nil)
      refute_received {:room_deleted, _url}
      assert reload(event).video_link == nil
    end
  end

  defp insert_event(integration, attrs \\ %{}) do
    defaults = %{
      calendar_integration: integration,
      summary: "Weekly sync",
      description: "Agenda",
      provider: "caldav",
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

  defp insert_zoom_integration(user) do
    insert(:video_integration,
      user: user,
      name: "Zoom",
      provider: "zoom",
      base_url: nil,
      api_key_encrypted: nil,
      tenant_id_encrypted: nil,
      client_id_encrypted: nil,
      client_secret_encrypted: nil,
      teams_user_id_encrypted: nil,
      access_token_encrypted: Encryption.encrypt("access-token"),
      refresh_token_encrypted: Encryption.encrypt("refresh-token"),
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      oauth_scope: "meeting:write:meeting meeting:delete:meeting",
      provider_account_id: nil
    )
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
