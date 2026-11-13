defmodule TymeslotWeb.Dashboard.MeetingTypeFormEmailVerificationTest do
  @moduledoc """
  The toggle that asks invitees to confirm their email. It excludes payments
  and group bookings: the control renders disabled with the reason, and a
  forged event must not get past the server-side guard either.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :meeting_types
  @moduletag :bookings
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.MeetingTypes

  setup :setup_dashboard_user

  defp open_form(conn, meeting_type) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

    view
    |> element("button[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
    |> render_click()

    view
  end

  defp wrapper(meeting_type),
    do: "#meeting-type-form-wrapper-meeting-type-form-edit-#{meeting_type.id}"

  defp saved(meeting_type),
    do: MeetingTypes.get_meeting_type(meeting_type.id, meeting_type.user_id)

  defp forge_toggle(view, meeting_type) do
    view
    |> with_target(wrapper(meeting_type))
    |> render_click("toggle_requires_email_verification", %{})
  end

  test "turning email verification on autosaves it", %{conn: conn, user: user} do
    meeting_type = insert(:meeting_type, user: user)
    view = open_form(conn, meeting_type)

    assert has_element?(
             view,
             "#meeting-type-form-tabs-panel-booking [data-testid='requires-email-verification-toggle']"
           )

    view |> element("[data-testid='requires-email-verification-toggle']") |> render_click()

    assert saved(meeting_type).requires_email_verification == true
  end

  test "the toggle is disabled while payments are required", %{conn: conn, user: user} do
    meeting_type = insert(:meeting_type, user: user, payment_required: true, price_cents: 2500)
    view = open_form(conn, meeting_type)

    assert has_element?(view, "[data-testid='requires-email-verification-toggle'][disabled]")
    assert render(view) =~ "Turn off payments to ask invitees to confirm their email."

    forge_toggle(view, meeting_type)

    refute saved(meeting_type).requires_email_verification
  end

  test "the toggle is disabled for group types", %{conn: conn, user: user} do
    meeting_type = insert(:meeting_type, user: user, max_participants: 3)
    view = open_form(conn, meeting_type)

    assert has_element?(view, "[data-testid='requires-email-verification-toggle'][disabled]")
    assert render(view) =~ "Turn off group bookings to ask invitees to confirm their email."

    forge_toggle(view, meeting_type)

    refute saved(meeting_type).requires_email_verification
  end

  test "turning verification off is always allowed", %{conn: conn, user: user} do
    # Both settings at once: a factory insert skips the changeset rule.
    venue = insert(:venue, user: user, name: "Main Hall")

    meeting_type =
      insert(:meeting_type,
        user: user,
        max_participants: 3,
        requires_email_verification: true,
        locations: [in_person_location([venue])]
      )

    view = open_form(conn, meeting_type)

    refute has_element?(view, "[data-testid='requires-email-verification-toggle'][disabled]")

    view |> element("[data-testid='requires-email-verification-toggle']") |> render_click()

    refute saved(meeting_type).requires_email_verification
  end
end
