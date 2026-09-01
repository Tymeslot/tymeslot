defmodule TymeslotWeb.Live.Dashboard.Availability.PolicyCardTest do
  @moduledoc """
  The scheduling policy (buffer, advance booking window, minimum notice) belongs
  to a named schedule, so it is edited on the availability page. These tests
  moved here from the meeting settings page with the card itself.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :availability
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers

  alias Tymeslot.Availability.Schedules
  alias Tymeslot.Repo
  alias TymeslotWeb.CustomInputModeHelper
  alias TymeslotWeb.Dashboard.Availability.PolicyCard

  setup :setup_dashboard_user

  setup %{profile: profile} = ctx do
    {:ok, schedule} = Schedules.create_default(profile.id)

    Map.put(ctx, :schedule, schedule)
  end

  describe "Scheduling preferences" do
    test "selecting a buffer time preset updates the schedule", %{
      conn: conn,
      schedule: schedule
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view
      |> element("[phx-click='update_buffer_minutes'][phx-value-buffer_minutes='15']")
      |> render_click()

      assert render(view) =~ "Buffer time updated"
      assert Repo.reload!(schedule).buffer_minutes == 15
    end

    test "selecting an advance booking window preset updates the schedule", %{
      conn: conn,
      schedule: schedule
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view
      |> element("[phx-click='update_advance_booking_days'][phx-value-advance_booking_days='30']")
      |> render_click()

      assert render(view) =~ "Advance booking window updated"
      assert Repo.reload!(schedule).advance_booking_days == 30
    end

    test "selecting a minimum notice preset updates the schedule", %{
      conn: conn,
      schedule: schedule
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view
      |> element("[phx-click='update_min_advance_hours'][phx-value-min_advance_hours='6']")
      |> render_click()

      assert render(view) =~ "Minimum booking notice updated"
      assert Repo.reload!(schedule).min_advance_hours == 6
    end

    test "entering a custom buffer value outside the allowed range is rejected", %{
      conn: conn,
      schedule: schedule
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      # Enabling custom mode saves a default value; capture it before the invalid attempt
      view
      |> element("[phx-click='focus_custom_input'][phx-value-setting='buffer_minutes']")
      |> render_click()

      persisted_value = Repo.reload!(schedule).buffer_minutes

      # Now attempt an out-of-range update via form change
      view
      |> form("form[phx-change='update_buffer_minutes']", %{"buffer_minutes" => "999"})
      |> render_change()

      # The schedule value must not have changed to 999
      assert Repo.reload!(schedule).buffer_minutes == persisted_value

      # The user must also see an error message explaining the rejection
      assert render(view) =~ "Buffer minutes cannot exceed 120"
    end

    test "clicking a preset tag while in custom mode returns the card to preset mode", %{
      conn: conn,
      schedule: schedule
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view
      |> element("[phx-click='focus_custom_input'][phx-value-setting='buffer_minutes']")
      |> render_click()

      # In custom mode the number input replaces the "Custom" button.
      assert render(view) =~ ~s(name="buffer_minutes")

      refute has_element?(
               view,
               "[phx-click='focus_custom_input'][phx-value-setting='buffer_minutes']"
             )

      view
      |> element("[phx-click='update_buffer_minutes'][phx-value-buffer_minutes='5']")
      |> render_click()

      assert Repo.reload!(schedule).buffer_minutes == 5

      # A preset the validator does not recognise leaves custom mode on, so the
      # "Custom" button coming back is what proves the tag was accepted as one.
      assert has_element?(
               view,
               "[phx-click='focus_custom_input'][phx-value-setting='buffer_minutes']"
             )
    end
  end

  describe "preset tags against the list that validates a preset click" do
    # A `_preset` marker carrying a value `preset_value?/2` rejects is treated as
    # client tampering and leaves `custom_input_mode` untouched, so a tag the
    # card renders but the validator does not know about saves its value and
    # then strands the card in custom-input mode.

    test "every buffer tag is a value preset_value?/2 accepts" do
      assert_tags_validate(&PolicyCard.buffer_minutes_setting/1, :buffer_minutes)
    end

    test "every advance booking tag is a value preset_value?/2 accepts" do
      assert_tags_validate(&PolicyCard.advance_booking_days_setting/1, :advance_booking_days)
    end

    test "every minimum notice tag is a value preset_value?/2 accepts" do
      assert_tags_validate(&PolicyCard.min_advance_hours_setting/1, :min_advance_hours)
    end
  end

  defp assert_tags_validate(component, field) do
    html =
      render_component(component, %{
        schedule: nil,
        myself: %Phoenix.LiveComponent.CID{cid: 1},
        custom_mode: false
      })

    tags =
      ~r/phx-value-#{field}="(\d+)"[\s\S]*?>([\s\S]*?)<\/button>/
      |> Regex.scan(html)
      |> Enum.map(fn [_match, value, label] -> {String.to_integer(value), String.trim(label)} end)

    # Anchor: no tags at all would make the rejections below vacuous.
    refute Enum.empty?(tags)

    values = Enum.map(tags, fn {value, _label} -> value end)
    assert values == CustomInputModeHelper.presets(field)
    assert Enum.reject(values, &CustomInputModeHelper.preset_value?(field, &1)) == []

    # Every tag must also carry a label, not render as an empty button.
    assert Enum.reject(tags, fn {_value, label} -> label != "" end) == []
  end
end
