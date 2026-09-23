defmodule Tymeslot.CalendarGrid.EventVideoDiscardTest do
  @moduledoc """
  What happens to the video room a calendar grid event stops using, when its
  video is changed or the event is deleted: the delete is queued on
  `Tymeslot.Workers.VideoSyncWorker`, by the room's record where one exists and
  otherwise by the meeting id in a Zoom link, and never for a provider whose
  link names no deletable room.

  The calendar writes are stubbed at `Tymeslot.CalendarMock`; the new room of
  a video change is a MiroTalk one, created with HTTP stubbed at
  `Tymeslot.HTTPClientMock`.
  """

  # Not async: provider failures are witnessed by the application-wide video
  # circuit breakers, which DataCase only resets between non-async modules.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :video
  @moduletag :integration

  import Mox

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.EventVideoRoomQueries
  alias Tymeslot.Infrastructure.Logging.Redactor
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Test.LogCapture
  alias Tymeslot.Workers.VideoSyncWorker

  setup :verify_on_exit!

  @zoom_url "https://us02web.zoom.us/j/86360699337?pwd=secret"
  @new_url "https://video.example.com/join/room-123"

  setup do
    user = insert(:user)

    caldav =
      insert(:calendar_integration, user: user, provider: "caldav", calendar_paths: ["/cal/"])

    mirotalk = insert(:video_integration, user: user, provider: "mirotalk")
    %{user: user, caldav: caldav, mirotalk: mirotalk, zoom: insert_zoom_integration(user)}
  end

  describe "changing a grid event's video" do
    test "queues the delete of a replaced Zoom room by its meeting id", ctx do
      event = insert_event(ctx.caldav, video(ctx.zoom, @zoom_url))
      replace_video(ctx, event)

      assert_enqueued(
        worker: VideoSyncWorker,
        args: %{
          "user_id" => ctx.user.id,
          "video_integration_id" => ctx.zoom.id,
          "room_id" => "86360699337",
          "action" => "delete"
        }
      )
    end

    for {provider, link} <- [
          {"google_meet", "https://meet.google.com/abc-defg-hij"},
          {"teams", "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0"}
        ] do
      test "queues nothing for a replaced #{provider} room, and logs only a fingerprint", ctx do
        old = insert(:video_integration, user: ctx.user, provider: unquote(provider))
        event = insert_event(ctx.caldav, video(old, unquote(link)))

        log_event =
          LogCapture.with_capture([logger_level: :info], fn ->
            replace_video(ctx, event)
            LogCapture.await_log("Video room left in place")
          end)

        meta = LogCapture.user_metadata(log_event)
        assert meta.room_ref == Redactor.fingerprint(unquote(link))
        refute_enqueued(worker: VideoSyncWorker, args: %{"action" => "delete"})
      end
    end

    test "queues the delete of a recorded room by its record, not by its link", ctx do
      talk = insert(:video_integration, user: ctx.user, provider: "nextcloud_talk")
      link = "https://cloud.example.com/call/talktoken1"
      event = insert_event(ctx.caldav, video(talk, link))

      {:ok, room} =
        EventVideoRoomQueries.insert(%{
          user_id: ctx.user.id,
          video_integration_id: talk.id,
          provider: "nextcloud_talk",
          calendar_integration_id: ctx.caldav.id,
          event_uid: event.uid,
          room_id: "talktoken1"
        })

      replace_video(ctx, event)

      assert_enqueued(
        worker: VideoSyncWorker,
        args: %{"event_room_id" => room.id, "action" => "delete"}
      )

      refute_enqueued(worker: VideoSyncWorker, args: %{"room_id" => "talktoken1"})
    end
  end

  describe "deleting a grid event" do
    test "queues the delete of its Zoom room once the calendar has deleted it", ctx do
      event = insert_event(ctx.caldav, video(ctx.zoom, @zoom_url))
      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts -> :ok end)

      assert {:ok, _deleted} = CalendarGrid.delete_event(ctx.user.id, address(event))

      assert_enqueued(
        worker: VideoSyncWorker,
        args: %{"video_integration_id" => ctx.zoom.id, "room_id" => "86360699337"}
      )
    end

    test "queues nothing while the delete is only queued for the next sync", ctx do
      event = insert_event(ctx.caldav, video(ctx.zoom, @zoom_url))

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts ->
        {:error, :network_error}
      end)

      assert {:error, %{retry: :queued}} = CalendarGrid.delete_event(ctx.user.id, address(event))
      refute_enqueued(worker: VideoSyncWorker)
    end
  end

  describe "the queued delete of a room no record holds" do
    setup ctx do
      stub(Tymeslot.ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      args = %{
        "user_id" => ctx.user.id,
        "video_integration_id" => ctx.zoom.id,
        "room_id" => "86360699337",
        "action" => "delete"
      }

      %{args: args}
    end

    test "treats a meeting Zoom no longer has as deleted", %{args: args} do
      expect_zoom_delete(404)
      assert :ok = perform_job(VideoSyncWorker, args)
    end

    test "retries a failure", %{args: args} do
      expect_zoom_delete(500)
      assert {:error, _reason} = perform_job(VideoSyncWorker, args)
    end

    test "is discarded once the integration has gone", %{args: args, zoom: zoom} do
      Repo.delete!(zoom)
      assert {:discard, _reason} = perform_job(VideoSyncWorker, args)
    end
  end

  defp replace_video(ctx, event) do
    body = Jason.encode!(%{"room_id" => "room-123", "meeting_url" => @new_url})

    stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
      {:ok, %Req.Response{status: 200, body: body}}
    end)

    expect(Tymeslot.CalendarMock, :update_event, fn _uid, _payload, _context -> :ok end)

    assert {:ok, @new_url} = CalendarGrid.change_event_video(ctx.user.id, event, ctx.mirotalk.id)
  end

  defp expect_zoom_delete(status) do
    expect(Tymeslot.HTTPClientMock, :request, fn :delete, url, _body, _headers, _opts ->
      assert url == "https://api.zoom.us/v2/meetings/86360699337"
      {:ok, %Req.Response{status: status, body: ""}}
    end)
  end

  defp video(integration, link),
    do: %{
      video_integration_id: integration.id,
      video_link: link,
      description: "Join video call: #{link}"
    }

  # What the grid hands a delete: only the fields that address the event.
  defp address(event),
    do: %{
      uid: event.uid,
      calendar_integration_id: event.calendar_integration_id,
      provider_event_id: event.provider_event_id,
      provider_calendar_id: event.provider_calendar_id
    }

  defp insert_event(integration, attrs) do
    defaults = %{
      calendar_integration: integration,
      uid: "event-#{System.unique_integer([:positive])}",
      summary: "Design review",
      provider: integration.provider,
      provider_calendar_id: "/cal/",
      provider_event_id: "/cal/design-review-#{System.unique_integer([:positive])}.ics",
      start_at: ~U[2026-06-01 09:00:00.000000Z],
      end_at: ~U[2026-06-01 10:00:00.000000Z],
      all_day: false,
      sync_state: "synced"
    }

    insert(:provider_calendar_event, Map.merge(defaults, attrs))
  end

  defp insert_zoom_integration(user) do
    insert(:video_integration,
      user: user,
      name: "Zoom",
      provider: "zoom",
      base_url: nil,
      access_token_encrypted: Encryption.encrypt("access-token"),
      refresh_token_encrypted: Encryption.encrypt("refresh-token"),
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      oauth_scope: "meeting:write:meeting meeting:delete:meeting"
    )
  end
end
