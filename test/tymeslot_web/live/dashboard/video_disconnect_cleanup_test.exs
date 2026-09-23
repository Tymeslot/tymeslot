defmodule TymeslotWeb.Dashboard.VideoDisconnectCleanupTest do
  @moduledoc """
  Drives the disconnect modal's optional provider-room cleanup end to end:
  opening it counts the affected bookings, ticking the box routes the request
  through the drain worker, and leaving it untouched keeps existing rooms alive.
  """

  use TymeslotWeb.LiveCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integrations

  import Mox
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory
  import Tymeslot.MeetingTestHelpers

  alias Tymeslot.CalendarGrid.EventVideoRoomQueries
  alias Tymeslot.CalendarGrid.EventVideoRoomSchema
  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.VideoIntegrationDisconnectWorker

  @day 86_400

  setup :verify_on_exit!
  setup :setup_dashboard_user

  # Drives the real trash-can button the user clicks, not the component directly.
  defp open_delete_modal(view, modal_id, integration_id) do
    view
    |> element("button[phx-target='##{modal_id}'][phx-value-id='#{integration_id}']")
    |> render_click()
  end

  defp confirm_delete(view, modal_id) do
    view
    |> element("##{modal_id} button.action-button--danger")
    |> render_click()
  end

  defp tick_delete_rooms(view, modal_id) do
    view
    |> element("##{modal_id} input[type='checkbox'][name='delete_rooms']")
    |> render_click()
  end

  test "the modal reports how many bookings the cleanup would affect", %{
    conn: conn,
    user: user
  } do
    integration = insert(:video_integration, user: user, provider: "zoom", is_active: true)

    insert_meeting_for_user(user, %{
      video_integration_id: integration.id,
      video_provider: "zoom",
      video_room_id: "111"
    })

    {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

    html = open_delete_modal(view, "delete-video-modal", integration.id)

    assert html =~ "1 upcoming booking still uses this integration"
    assert html =~ "Also delete their meeting rooms"
  end

  test "the cleanup option is hidden when nothing would be affected", %{
    conn: conn,
    user: user
  } do
    integration = insert(:video_integration, user: user, provider: "zoom", is_active: true)

    {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

    html = open_delete_modal(view, "delete-video-modal", integration.id)

    refute html =~ "Also delete their meeting rooms"
  end

  # Zoom rooms of past meetings expire on their own, so only upcoming bookings
  # are worth asking about.
  test "the cleanup option is hidden when a Zoom integration's meetings have all ended", %{
    conn: conn,
    user: user
  } do
    integration = insert(:video_integration, user: user, provider: "zoom", is_active: true)

    insert_meeting_for_user(user, %{
      start_offset: -2 * @day,
      duration: 1800,
      video_integration_id: integration.id,
      video_provider: "zoom",
      video_room_id: "555"
    })

    {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

    open_delete_modal(view, "delete-video-modal", integration.id)

    refute has_element?(view, "#delete-video-modal input[name='delete_rooms']")
  end

  # A Talk conversation stays on the organiser's server after its meeting, and
  # the disconnect is the last chance to delete it: once the row is purged
  # nothing holds the credentials any more.
  test "a Talk integration whose meetings have all ended still offers to delete their conversations",
       %{conn: conn, user: user} do
    host = "modal-ended.example.com"
    integration = insert_talk_integration(user, host)

    ended =
      for {offset, room_id} <- [{-2 * @day, "ended001"}, {-3 * @day, "ended002"}] do
        insert_meeting_for_user(user, %{
          start_offset: offset,
          duration: 1800,
          video_integration_id: integration.id,
          video_provider: "nextcloud_talk",
          video_room_id: room_id
        })
      end

    {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

    html = open_delete_modal(view, "delete-video-modal", integration.id)

    assert html =~ "2 conversations from this integration are still on your Nextcloud server"
    assert has_element?(view, "#delete-video-modal input[name='delete_rooms']")

    tick_delete_rooms(view, "delete-video-modal")
    confirm_delete(view, "delete-video-modal")

    expect(HTTPClientMock, :request, 2, fn :delete, url, _body, _headers, _opts ->
      assert url =~ ~r{^https://#{host}/ocs/v2\.php/apps/spreed/api/v4/room/ended00[12]$}
      {:ok, %Req.Response{status: 200, body: talk_ocs(nil)}}
    end)

    assert :ok =
             perform_job(VideoIntegrationDisconnectWorker, %{"integration_id" => integration.id})

    assert Enum.map(ended, &Repo.reload!(&1).video_room_id) == [nil, nil]
    assert {:error, :not_found} = VideoIntegrationQueries.get(integration.id)
  end

  # A conversation made with an event on the calendar grid has no booking, so
  # it is counted and drained from the grid's own record of it.
  test "a Talk conversation made with a calendar grid event is counted and deleted on disconnect",
       %{conn: conn, user: user} do
    host = "modal-grid.example.com"
    integration = insert_talk_integration(user, host)
    calendar = insert(:calendar_integration, user: user)

    {:ok, room} =
      EventVideoRoomQueries.insert(%{
        user_id: user.id,
        video_integration_id: integration.id,
        provider: "nextcloud_talk",
        calendar_integration_id: calendar.id,
        event_uid: "grid-event",
        room_id: "grid0001",
        lobby_opens_at: DateTime.add(DateTime.utc_now(:second), @day, :second),
        ends_at: DateTime.add(DateTime.utc_now(:second), @day + 1800, :second)
      })

    {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

    html = open_delete_modal(view, "delete-video-modal", integration.id)

    assert html =~ "1 conversation from this integration is still on your Nextcloud server"

    tick_delete_rooms(view, "delete-video-modal")
    confirm_delete(view, "delete-video-modal")

    expect(HTTPClientMock, :request, fn :delete, url, _body, _headers, _opts ->
      assert url == "https://#{host}/ocs/v2.php/apps/spreed/api/v4/room/grid0001"
      {:ok, %Req.Response{status: 200, body: talk_ocs(nil)}}
    end)

    assert :ok =
             perform_job(VideoIntegrationDisconnectWorker, %{"integration_id" => integration.id})

    assert Repo.get(EventVideoRoomSchema, room.id) == nil
    assert {:error, :not_found} = VideoIntegrationQueries.get(integration.id)
  end

  test "the cleanup option never appears for calendar integrations", %{
    conn: conn,
    user: user
  } do
    calendar = insert(:calendar_integration, user: user, provider: "google")

    {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

    html =
      open_delete_modal(view, "delete-calendar-modal", calendar.id)

    refute html =~ "Also delete their meeting rooms"
  end

  test "disconnecting without ticking the box leaves the rooms running", %{
    conn: conn,
    user: user
  } do
    integration = insert(:video_integration, user: user, provider: "zoom", is_active: true)

    meeting =
      insert_meeting_for_user(user, %{
        video_integration_id: integration.id,
        video_provider: "zoom",
        video_room_id: "222"
      })

    {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

    open_delete_modal(view, "delete-video-modal", integration.id)

    confirm_delete(view, "delete-video-modal")

    # The attendee's join link is already in their calendar invite, so the room
    # must survive a plain disconnect.
    refute_enqueued(worker: VideoIntegrationDisconnectWorker)
    assert Repo.reload!(meeting).video_room_id == "222"
    assert {:error, :not_found} = VideoIntegrationQueries.get(integration.id)
  end

  test "ticking the box shows the box as ticked", %{conn: conn, user: user} do
    integration = insert(:video_integration, user: user, provider: "zoom", is_active: true)

    insert_meeting_for_user(user, %{
      video_integration_id: integration.id,
      video_provider: "zoom",
      video_room_id: "444"
    })

    {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

    html = open_delete_modal(view, "delete-video-modal", integration.id)
    refute checked?(html)

    # The assign flipping is not enough: the input component derives its checked
    # state from `value`, so a `checked` attribute alone leaves the user ticking
    # a box that never appears ticked.
    html = tick_delete_rooms(view, "delete-video-modal")
    assert checked?(html)
  end

  defp checked?(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find(~s(input[name="delete_rooms"]))
    |> Floki.attribute("checked")
    |> Enum.any?()
  end

  test "ticking the box soft-deletes and schedules the drain", %{conn: conn, user: user} do
    integration = insert(:video_integration, user: user, provider: "zoom", is_active: true)

    insert_meeting_for_user(user, %{
      video_integration_id: integration.id,
      video_provider: "zoom",
      video_room_id: "333"
    })

    {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

    open_delete_modal(view, "delete-video-modal", integration.id)
    tick_delete_rooms(view, "delete-video-modal")
    confirm_delete(view, "delete-video-modal")

    assert_enqueued(
      worker: VideoIntegrationDisconnectWorker,
      args: %{"integration_id" => integration.id}
    )

    # Hidden from the user at once, but retained so the job can authenticate.
    assert {:ok, pending} = VideoIntegrationQueries.get(integration.id)
    assert pending.deleted_at
    assert VideoIntegrationQueries.list_all_for_user(user.id) == []
  end

  # Each test gets its own server, so no test's calls reach another test's
  # per-host circuit breaker.
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

  defp talk_ocs(data),
    do: Jason.encode!(%{"ocs" => %{"meta" => %{"status" => "ok"}, "data" => data}})
end
