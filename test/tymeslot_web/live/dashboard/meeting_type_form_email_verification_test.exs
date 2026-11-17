defmodule TymeslotWeb.Dashboard.MeetingTypeFormEmailVerificationTest do
  @moduledoc """
  The toggle that asks invitees to confirm their email. It excludes payments,
  group bookings and series: the control renders disabled with the reason, and a
  forged event must not get past the server-side guard either.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :meeting_types
  @moduletag :bookings
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Meetings.EmailVerification
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

  # What only the server-side guard controls: the changeset would reject the
  # save as well, but without the guard the form flips its own state first,
  # so the toggle renders checked and enabled and the autosave reports a
  # failure.
  defp assert_forged_toggle_ignored(view) do
    assert has_element?(view, "[data-testid='requires-email-verification-toggle'][disabled]")
    refute has_element?(view, "[data-testid='requires-email-verification-toggle'][checked]")
    refute has_element?(view, "[aria-live='polite']", "Couldn't save changes")
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

  # The hold is capped at the meeting's start, so the hint promises no more
  # than its longest.
  test "the hint says how long the time is held", %{conn: conn, user: user} do
    view = open_form(conn, insert(:meeting_type, user: user))

    assert render(view) =~
             "Until then the time is held for up to #{EmailVerification.hold_minutes()} minutes"
  end

  test "the toggle is disabled while payments are required", %{conn: conn, user: user} do
    meeting_type = insert(:meeting_type, user: user, payment_required: true, price_cents: 2500)
    view = open_form(conn, meeting_type)

    assert has_element?(view, "[data-testid='requires-email-verification-toggle'][disabled]")
    assert render(view) =~ "Turn off payments to ask invitees to confirm their email."

    forge_toggle(view, meeting_type)

    assert_forged_toggle_ignored(view)
    refute saved(meeting_type).requires_email_verification
  end

  test "the toggle is disabled for group types", %{conn: conn, user: user} do
    meeting_type = insert(:meeting_type, user: user, max_participants: 3)
    view = open_form(conn, meeting_type)

    assert has_element?(view, "[data-testid='requires-email-verification-toggle'][disabled]")
    assert render(view) =~ "Turn off group bookings to ask invitees to confirm their email."

    forge_toggle(view, meeting_type)

    assert_forged_toggle_ignored(view)
    refute saved(meeting_type).requires_email_verification
  end

  test "the toggle is disabled while a series is on", %{conn: conn, user: user} do
    meeting_type =
      insert(:meeting_type,
        user: user,
        series_mode: :flexible,
        series_min_occurrences: 2,
        series_max_occurrences: 4
      )

    view = open_form(conn, meeting_type)

    assert has_element?(view, "[data-testid='requires-email-verification-toggle'][disabled]")
    assert render(view) =~ "Turn off series booking to ask invitees to confirm their email."

    forge_toggle(view, meeting_type)

    assert_forged_toggle_ignored(view)
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
