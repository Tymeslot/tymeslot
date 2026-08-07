defmodule TymeslotWeb.Dashboard.DashboardAgendaColourTest do
  @moduledoc """
  End-to-end journey for setting a per-event colour from the dashboard agenda:
  open an event's detail modal, pick a colour, and see it persist as a durable
  override and render on the agenda.
  """
  use TymeslotWeb.ConnCase, async: true

  @moduletag :live
  @moduletag :calendar

  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.EventColour

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now(:second))
    _profile = insert(:profile, user: user, timezone: "Etc/UTC")
    {:ok, conn: log_in_user(conn, user), user: user}
  end

  defp all_day_event(user, uid) do
    today = Date.utc_today()
    integration = insert(:calendar_integration, user: user)

    insert(:provider_calendar_event,
      calendar_integration: integration,
      summary: "Company offsite",
      uid: uid,
      all_day: true,
      start_date: today,
      end_date: Date.add(today, 1),
      start_at: nil,
      end_at: nil
    )

    integration
  end

  test "user colours an agenda event and it persists", %{conn: conn, user: user} do
    integration = all_day_event(user, "uid-colour-journey")

    {:ok, view, _html} = live(conn, ~p"/dashboard")

    # Open the event's detail modal from its all-day pill.
    view |> element("button", "Company offsite") |> render_click()

    # Pick "blueberry" from the colour swatches.
    html =
      view
      |> element(~s{button[phx-click="set_entry_colour"][phx-value-colour="blueberry"]})
      |> render_click()

    # Persisted as a durable override, keyed on the stable (integration, uid).
    assert Calendar.overrides_for(user.id) ==
             %{{:external, integration.id, "uid-colour-journey"} => "blueberry"}

    # And the agenda re-renders in that palette colour.
    assert html =~ EventColour.tailwind_class("blueberry")
  end

  test "user clears a colour override", %{conn: conn, user: user} do
    integration = all_day_event(user, "uid-colour-clear")

    {:ok, _override} =
      Calendar.set_event_colour(
        user.id,
        {:external, integration.id, "uid-colour-clear"},
        "blueberry"
      )

    {:ok, view, _html} = live(conn, ~p"/dashboard")

    view |> element("button", "Company offsite") |> render_click()
    view |> element(~s{button[phx-click="clear_entry_colour"]}) |> render_click()

    assert Calendar.overrides_for(user.id) == %{}
  end

  test "user colours a booking entry via the {:meeting, id} target", %{conn: conn, user: user} do
    tomorrow = Date.add(Date.utc_today(), 1)
    start = DateTime.new!(tomorrow, ~T[12:00:00], "Etc/UTC")

    meeting =
      insert(:meeting,
        organizer_email: user.email,
        start_time: start,
        end_time: DateTime.add(start, 3600, :second),
        status: "confirmed",
        title: "Quarterly review"
      )

    {:ok, view, _html} = live(conn, ~p"/dashboard")

    view
    |> element(~s([aria-label="View details for Quarterly review"]))
    |> render_click()

    html =
      view
      |> element(~s{button[phx-click="set_entry_colour"][phx-value-colour="blueberry"]})
      |> render_click()

    # Persisted as a durable override, keyed on the meeting id.
    assert Calendar.overrides_for(user.id) == %{{:meeting, meeting.id} => "blueberry"}

    # And the agenda re-renders in that palette colour.
    assert html =~ EventColour.tailwind_class("blueberry")
  end

  test "malformed colour targets are ignored without crashing the LiveView",
       %{conn: conn, user: user} do
    all_day_event(user, "uid-malformed-target")

    {:ok, view, _html} = live(conn, ~p"/dashboard")

    view |> element("button", "Company offsite") |> render_click()

    for target <- ["foo", "external:5", "external:abc:uid"] do
      html =
        view
        |> element(~s{button[phx-click="set_entry_colour"][phx-value-colour="blueberry"]})
        |> render_click(%{"target" => target})

      # A tampered target is silently ignored — the modal stays open, no crash.
      assert html =~ "Company offsite"
    end

    html =
      view
      |> element(~s{button[phx-click="clear_entry_colour"]})
      |> render_click(%{"target" => "foo"})

    assert html =~ "Company offsite"

    # Nothing was ever persisted, and the LiveView process survived throughout.
    assert Calendar.overrides_for(user.id) == %{}
    assert Process.alive?(view.pid)
  end
end
