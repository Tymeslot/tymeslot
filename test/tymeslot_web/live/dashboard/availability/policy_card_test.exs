defmodule TymeslotWeb.Live.Dashboard.Availability.PolicyCardTest do
  @moduledoc """
  The scheduling policy (the two buffers, advance booking window, minimum
  notice) belongs to a named schedule, so it is edited on the availability
  page.
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

  describe "buffers" do
    test "renders a separate form for each buffer", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      assert has_element?(
               view,
               "form#buffer-before-form[phx-change='update_buffer_before_minutes']"
             )

      assert has_element?(
               view,
               "form#buffer-after-form[phx-change='update_buffer_after_minutes']"
             )

      assert render(view) =~ "Before each meeting"
      assert render(view) =~ "After each meeting"
    end

    test "each buffer's group and custom input are labelled by its own title", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      for {form_id, field, title} <- [
            {"buffer-before-form", "buffer_before_minutes", "Before each meeting"},
            {"buffer-after-form", "buffer_after_minutes", "After each meeting"}
          ] do
        label_id = "#{form_id}-label"

        assert view |> element("p##{label_id}") |> render() =~ title
        assert has_element?(view, "##{form_id} [role='group'][aria-labelledby='#{label_id}']")

        view
        |> element("##{form_id} button[phx-value-setting='#{field}']")
        |> render_click()

        assert has_element?(
                 view,
                 "##{form_id} input[name='#{field}'][aria-labelledby='#{label_id}']"
               )
      end
    end

    test "a before-buffer preset changes only the before-buffer", %{
      conn: conn,
      schedule: schedule
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view
      |> element(
        "[phx-click='update_buffer_before_minutes'][phx-value-buffer_before_minutes='30']"
      )
      |> render_click()

      assert render(view) =~ "Buffer before meetings updated to 30 minutes"
      schedule = Repo.reload!(schedule)
      assert {schedule.buffer_before_minutes, schedule.buffer_after_minutes} == {30, 15}
    end

    test "an after-buffer preset changes only the after-buffer", %{
      conn: conn,
      schedule: schedule
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view
      |> element("[phx-click='update_buffer_after_minutes'][phx-value-buffer_after_minutes='5']")
      |> render_click()

      assert render(view) =~ "Buffer after meetings updated to 5 minutes"
      schedule = Repo.reload!(schedule)
      assert {schedule.buffer_before_minutes, schedule.buffer_after_minutes} == {15, 5}
    end

    test "a custom value is saved from that buffer's own form", %{
      conn: conn,
      schedule: schedule
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view
      |> element("[phx-click='focus_custom_input'][phx-value-setting='buffer_after_minutes']")
      |> render_click()

      assert render(view) =~ "Buffer after meetings set to custom value"

      view
      |> form("form#buffer-after-form", %{"buffer_after_minutes" => "25"})
      |> render_change()

      schedule = Repo.reload!(schedule)
      assert {schedule.buffer_before_minutes, schedule.buffer_after_minutes} == {15, 25}
    end

    for {field, label} <- [
          {"buffer_before_minutes", "Buffer before"},
          {"buffer_after_minutes", "Buffer after"}
        ] do
      test "an out-of-range custom #{field} is rejected with a message", %{
        conn: conn,
        schedule: schedule
      } do
        field = unquote(field)
        {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

        view
        |> element("[phx-click='focus_custom_input'][phx-value-setting='#{field}']")
        |> render_click()

        persisted = Map.fetch!(Repo.reload!(schedule), String.to_existing_atom(field))

        view
        |> form("form[phx-change='update_#{field}']", %{field => "999"})
        |> render_change()

        assert Map.fetch!(Repo.reload!(schedule), String.to_existing_atom(field)) == persisted
        assert render(view) =~ "#{unquote(label)} cannot exceed 120"
      end
    end

    test "clicking a preset tag while in custom mode returns that buffer to preset mode", %{
      conn: conn,
      schedule: schedule
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view
      |> element("[phx-click='focus_custom_input'][phx-value-setting='buffer_before_minutes']")
      |> render_click()

      assert render(view) =~ ~s(name="buffer_before_minutes")

      refute has_element?(
               view,
               "[phx-click='focus_custom_input'][phx-value-setting='buffer_before_minutes']"
             )

      # The other buffer stays in preset mode throughout.
      assert has_element?(
               view,
               "[phx-click='focus_custom_input'][phx-value-setting='buffer_after_minutes']"
             )

      view
      |> element(
        "[phx-click='update_buffer_before_minutes'][phx-value-buffer_before_minutes='5']"
      )
      |> render_click()

      assert Repo.reload!(schedule).buffer_before_minutes == 5

      # A preset the validator does not recognise leaves custom mode on, so the
      # "Custom" button coming back is what proves the tag was accepted as one.
      assert has_element?(
               view,
               "[phx-click='focus_custom_input'][phx-value-setting='buffer_before_minutes']"
             )
    end
  end

  describe "booking window and notice" do
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
  end

  describe "preset tags against the list that validates a preset click" do
    # A `_preset` marker carrying a value `preset_value?/2` rejects is treated as
    # client tampering and leaves `custom_input_mode` untouched, so a tag the
    # card renders but the validator does not know about saves its value and
    # then strands the card in custom-input mode.

    test "every before-buffer tag is a value preset_value?/2 accepts" do
      assert_tags_validate(&PolicyCard.buffer_setting/1, :buffer_before_minutes, %{
        field: :buffer_before_minutes
      })
    end

    test "every after-buffer tag is a value preset_value?/2 accepts" do
      assert_tags_validate(&PolicyCard.buffer_setting/1, :buffer_after_minutes, %{
        field: :buffer_after_minutes
      })
    end

    test "every advance booking tag is a value preset_value?/2 accepts" do
      assert_tags_validate(&PolicyCard.advance_booking_days_setting/1, :advance_booking_days)
    end

    test "every minimum notice tag is a value preset_value?/2 accepts" do
      assert_tags_validate(&PolicyCard.min_advance_hours_setting/1, :min_advance_hours)
    end
  end

  defp assert_tags_validate(component, field, extra_assigns \\ %{}) do
    html =
      render_component(
        component,
        Map.merge(
          %{schedule: nil, myself: %Phoenix.LiveComponent.CID{cid: 1}, custom_mode: false},
          extra_assigns
        )
      )

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
