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

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Security.Encryption

  setup :verify_on_exit!

  @new_url "https://video.example.com/join/room-123"
  @old_url "https://video.example.com/join/old-room"
  @reminders [%{"method" => "popup", "minutes_before" => 15}]
  @rrule "FREQ=WEEKLY;BYDAY=MO"

  setup do
    user = insert(:user)

    # Google, so that the repeating fixture below stays editable: a CalDAV
    # series is written through its master VEVENT and every edit of one
    # occurrence is refused (`CalendarGrid.ensure_editable/1`). The one test
    # that needs CalDAV's offline queue brings its own integration.
    integration = insert(:calendar_integration, user: user, provider: "google")

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
      video_integration: video_integration
    } do
      # The offline queue is the CalDAV family's, and a one-off event so the
      # series guard does not refuse the write before it can be queued.
      caldav =
        insert(:calendar_integration, user: user, provider: "caldav", calendar_paths: ["/cal/"])

      event =
        insert_event(caldav, %{
          provider: "caldav",
          recurrence_rule: nil,
          recurring_event_id: nil
        })

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
end
