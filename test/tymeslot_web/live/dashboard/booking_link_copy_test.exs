defmodule TymeslotWeb.Dashboard.BookingLinkCopyTest do
  @moduledoc """
  Every dashboard button that copies the host's own booking link also tells the
  server, which remembers the first share on the profile.
  """
  use TymeslotWeb.ConnCase, async: true

  @moduletag :live
  @moduletag :profiles

  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.MeetingTypes.OneOffEvents
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  setup %{conn: conn} do
    TestMocks.setup_all_mocks()
    user = insert(:user, onboarding_completed_at: DateTime.utc_now(:second))

    profile =
      insert(:profile, user: user, username: "sharer", booking_link_first_shared_at: nil)

    insert(:calendar_integration, user: user)

    %{conn: log_in_user(conn, user), user: user, profile: profile}
  end

  defp shared_at(profile), do: Repo.reload!(profile).booking_link_first_shared_at

  test "the meeting type editor's copy button stamps the profile", %{
    conn: conn,
    user: user,
    profile: profile
  } do
    type = insert(:meeting_type, user: user)
    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

    view |> element("[phx-click=edit_type][phx-value-id='#{type.id}']") |> render_click()
    assert is_nil(shared_at(profile))

    assert has_element?(view, ~s{#copy-booking-link-#{type.id}[phx-hook="CopyOnClick"]})
    view |> element("#copy-booking-link-#{type.id}") |> render_click()

    assert %DateTime{} = shared_at(profile)

    assert_push_event view, "ts:analytics", %{
      name: "booking_link_shared",
      props: %{channel: "settings"}
    }
  end

  test "an event row's copy button stamps the profile", %{
    user: user,
    conn: conn,
    profile: profile
  } do
    venue = insert(:venue, user: user)

    {:ok, %{meeting_type: event}} =
      OneOffEvents.create(%{
        user_id: user.id,
        name: "Introduction to X",
        starts_at: DateTime.add(DateTime.utc_now(:second), 7 * 86_400),
        duration_minutes: 60,
        max_participants: 12,
        location: {:venue, venue.id}
      })

    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")
    assert is_nil(shared_at(profile))

    assert has_element?(view, ~s{#copy-event-link-#{event.id}[phx-hook="CopyOnClick"]})
    view |> element("#copy-event-link-#{event.id}") |> render_click()

    assert %DateTime{} = shared_at(profile)

    assert_push_event view, "ts:analytics", %{
      name: "booking_link_shared",
      props: %{channel: "settings"}
    }
  end

  test "copying the embed code stamps the profile", %{conn: conn, profile: profile} do
    {:ok, view, _html} = live(conn, ~p"/dashboard/embed")
    assert is_nil(shared_at(profile))

    view |> element("button[phx-click='copy_code'][phx-value-type='inline']") |> render_click()

    assert %DateTime{} = shared_at(profile)

    assert_push_event view, "ts:analytics", %{
      name: "booking_link_shared",
      props: %{channel: "embed"}
    }
  end

  test "the sidebar's copy button stamps the profile", %{conn: conn, profile: profile} do
    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")
    assert is_nil(shared_at(profile))

    assert has_element?(view, ~s{#copy-scheduling-link[phx-hook="CopyOnClick"]})
    view |> element("#copy-scheduling-link") |> render_click()

    assert %DateTime{} = shared_at(profile)

    assert_push_event view, "ts:analytics", %{
      name: "booking_link_shared",
      props: %{channel: "sidebar"}
    }
  end

  test "the sidebar's copy button also works on the analytics page", %{
    conn: conn,
    profile: profile
  } do
    {:ok, view, _html} = live(conn, ~p"/dashboard/analytics")
    assert is_nil(shared_at(profile))

    assert has_element?(view, ~s{#copy-scheduling-link[phx-hook="CopyOnClick"]})
    view |> element("#copy-scheduling-link") |> render_click()

    assert %DateTime{} = shared_at(profile)
  end

  test "a channel the buttons do not use is ignored", %{conn: conn, profile: profile} do
    {:ok, view, _html} = live(conn, ~p"/dashboard/overview")

    render_click(view, "booking_link_copied", %{"channel" => "user@example.com"})
    # The setup checklist no longer copies the link.
    render_click(view, "booking_link_copied", %{"channel" => "checklist"})
    render_click(view, "booking_link_copied", %{})

    assert is_nil(shared_at(profile))
    refute_push_event view, "ts:analytics", %{name: "booking_link_shared"}
  end
end
