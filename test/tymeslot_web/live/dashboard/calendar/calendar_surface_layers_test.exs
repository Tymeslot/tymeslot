defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceLayersTest do
  @moduledoc """
  The rail's Layers section: the bookable-times switch (and B, which sends
  the same event from the hook), the meeting type it shows, and what the
  rail offers when there is no meeting type to show.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.Factory
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Phoenix.HTML
  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries
  alias Tymeslot.Security.RateLimiter

  setup %{conn: conn}, do: owner(conn)

  defp preferences(user), do: CalendarPreferencesQueries.get_or_create(user.id)

  defp escaped(message), do: message |> HTML.html_escape() |> HTML.safe_to_string()

  test "the keyboard hint names B", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    assert has_element?(lv, "#calendar-keys-hint", "Press B to show or hide your bookable times.")
  end

  test "the canvas carries the layer's copy for the hook", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/dashboard/calendar")

    assert html =~ "Next bookable time: %{when}"
    assert html =~ "%{date}: bookable times for %{meeting_type}. Show what this means"
  end

  describe "with meeting types" do
    setup %{user: user} do
      intro = insert(:meeting_type, user: user, name: "Intro call", sort_order: 0)
      workshop = insert(:meeting_type, user: user, name: "Workshop", sort_order: 1)
      %{intro: intro, workshop: workshop}
    end

    test "shows the switch on and the first meeting type chosen", %{conn: conn, intro: intro} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      assert has_element?(lv, "#calendar-rail-layers h2", "Layers")
      assert has_element?(lv, "#calendar-rail-bookable[role='switch'][aria-checked='true']")
      assert has_element?(lv, "#calendar-rail-bookable[aria-keyshortcuts='b']")
      assert has_element?(lv, "#calendar-rail-bookable-type option[selected]", "Intro call")
      assert has_element?(lv, "#calendar-rail-bookable-type option[value='#{intro.id}']")
      assert has_element?(lv, "#calendar-rail-bookable-type option", "Workshop")
    end

    test "the switch hides the layer and remembers", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv |> element("#calendar-rail-bookable") |> render_click()

      assert has_element?(lv, "#calendar-rail-bookable[aria-checked='false']")
      refute preferences(user).bookable_layer

      lv |> element("#calendar-rail-bookable") |> render_click()

      assert has_element?(lv, "#calendar-rail-bookable[aria-checked='true']")
      assert preferences(user).bookable_layer
    end

    test "B, from the hook, does what the switch does", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv |> element("#calendar-canvas") |> render_hook("calendar:bookable_toggle", %{})

      assert has_element?(lv, "#calendar-rail-bookable[aria-checked='false']")
      refute preferences(user).bookable_layer
    end

    test "B sets the state the hook names, so a repeated press does not flip it back", %{
      conn: conn,
      user: user
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      canvas = element(lv, "#calendar-canvas")

      render_hook(canvas, "calendar:bookable_toggle", %{"on" => false})
      render_hook(canvas, "calendar:bookable_toggle", %{"on" => false})

      assert has_element?(lv, "#calendar-rail-bookable[aria-checked='false']")
      refute preferences(user).bookable_layer

      render_hook(canvas, "calendar:bookable_toggle", %{"on" => true})

      assert has_element?(lv, "#calendar-rail-bookable[aria-checked='true']")
      assert preferences(user).bookable_layer
    end

    test "the switch names the state it turns to", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      assert has_element?(lv, "#calendar-rail-bookable[phx-value-on='false']")
      lv |> element("#calendar-rail-bookable") |> render_click()
      assert has_element?(lv, "#calendar-rail-bookable[phx-value-on='true']")
    end

    test "a refused B pushes the layer as it stands, so the grid goes back", %{
      conn: conn,
      user: user
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      render_async(lv)
      assert_push_event(lv, "calendar:bookable", %{on: true})

      Enum.find(
        Stream.repeatedly(fn -> RateLimiter.check(:calendar_visibility, user.id) end),
        &match?({:error, :rate_limited, _message}, &1)
      )

      lv
      |> element("#calendar-canvas")
      |> render_hook("calendar:bookable_toggle", %{"on" => false})

      assert_push_event(lv, "calendar:bookable", %{on: true})
      assert preferences(user).bookable_layer
    end

    test "choosing a meeting type shows it and remembers", %{
      conn: conn,
      user: user,
      workshop: workshop
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv
      |> form("#calendar-rail-bookable-form")
      |> render_change(%{"id" => to_string(workshop.id)})

      assert has_element?(lv, "#calendar-rail-bookable-type option[selected]", "Workshop")
      assert preferences(user).bookable_meeting_type_id == workshop.id
    end

    test "another organiser's meeting type is refused", %{conn: conn, user: user} do
      theirs = insert(:meeting_type, name: "Theirs")
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv
      |> element("#calendar-canvas")
      |> render_hook("calendar:bookable_type", %{"id" => to_string(theirs.id)})

      assert has_element?(lv, "#calendar-rail-bookable-type option[selected]", "Intro call")
      assert preferences(user).bookable_meeting_type_id == nil
    end

    test "archived and inactive meeting types are not offered", %{conn: conn, user: user} do
      insert(:meeting_type, user: user, name: "Old talk", is_archived: true)
      insert(:meeting_type, user: user, name: "Paused talk", is_active: false)
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      refute has_element?(lv, "#calendar-rail-bookable-type option", "Old talk")
      refute has_element?(lv, "#calendar-rail-bookable-type option", "Paused talk")
    end

    test "a switch past the rate limit is refused and says why", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      {:error, :rate_limited, message} =
        Enum.find(
          Stream.repeatedly(fn -> RateLimiter.check(:calendar_visibility, user.id) end),
          &match?({:error, :rate_limited, _message}, &1)
        )

      lv |> element("#calendar-rail-bookable") |> render_click()

      assert render(lv) =~ escaped(message)
      assert preferences(user).bookable_layer
    end
  end

  describe "with no meeting type to show" do
    test "offers to add one instead of the switch", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      assert has_element?(
               lv,
               "#calendar-rail-layers",
               "No active meeting types, so there are no bookable times to show."
             )

      assert has_element?(
               lv,
               "#calendar-rail-layers a[href='/dashboard/meeting-settings']",
               "Add a meeting type"
             )

      refute has_element?(lv, "#calendar-rail-bookable")
    end

    test "B changes nothing", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv |> element("#calendar-canvas") |> render_hook("calendar:bookable_toggle", %{})

      assert preferences(user).bookable_layer
    end
  end
end
