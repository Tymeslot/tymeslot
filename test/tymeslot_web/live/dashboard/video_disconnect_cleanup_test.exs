defmodule TymeslotWeb.Dashboard.VideoDisconnectCleanupTest do
  @moduledoc """
  Drives the disconnect modal's optional provider-room cleanup end to end:
  opening it counts the affected bookings, ticking the box routes the request
  through the drain worker, and leaving it untouched keeps existing rooms alive.
  """

  use TymeslotWeb.LiveCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integrations

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory
  import Tymeslot.MeetingTestHelpers

  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Repo
  alias Tymeslot.Workers.VideoIntegrationDisconnectWorker

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
end
