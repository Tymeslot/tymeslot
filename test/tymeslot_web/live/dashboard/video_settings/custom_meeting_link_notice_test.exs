defmodule TymeslotWeb.Dashboard.VideoSettings.CustomMeetingLinkNoticeTest do
  @moduledoc """
  A custom video link saved before its `{{meeting_id}}` placeholder was
  validated, as the dashboard shows it: the integration's row says the
  placeholder is invalid and that bookings share one room, while a correctly
  written link is left alone.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :video
  @moduletag :integrations
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test

  @notice "The meeting link placeholder is invalid, so all bookings currently share one room."

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user)
    conn = conn |> Test.init_test_session(%{}) |> fetch_session() |> log_in_user(user)
    {:ok, conn: conn, user: user}
  end

  test "flags a stored custom link whose placeholder a save would refuse", %{
    conn: conn,
    user: user
  } do
    # Inserted straight into the table, as a link saved before the placeholder
    # was validated would be: the changeset would refuse it today.
    insert_custom(user, "Legacy Jitsi", "https://meet.jit.si/{meeting_id}")

    {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

    assert has_element?(view, "p.text-amber-700", @notice)
    assert has_element?(view, "p.text-amber-700", "Edit the integration to fix it.")
    assert has_element?(view, "span", "Invalid meeting link")
    refute has_element?(view, "span", "Healthy")
  end

  test "does not flag a stored custom link with a correct placeholder", %{
    conn: conn,
    user: user
  } do
    insert_custom(user, "Per-booking Jitsi", "https://meet.jit.si/{{meeting_id}}")

    {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

    assert has_element?(view, "h3", "Per-booking Jitsi")
    refute has_element?(view, "p.text-amber-700", @notice)
    refute has_element?(view, "span", "Invalid meeting link")
    assert has_element?(view, "span", "Healthy")
  end

  defp insert_custom(user, name, url) do
    insert(:video_integration,
      user: user,
      provider: "custom",
      name: name,
      provider_account_id: url,
      custom_meeting_url: url
    )
  end
end
