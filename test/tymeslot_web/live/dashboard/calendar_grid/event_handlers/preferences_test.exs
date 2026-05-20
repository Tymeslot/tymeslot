defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.PreferencesTest do
  @moduledoc """
  Covers the calendar-grid preferences panel handler: toggle settings drawer,
  switch default view, change week start, toggle weekends/week numbers.

  These unit tests bypass the LiveComponent harness and drive the handlers
  directly against a synthetic socket, mirroring the pattern in
  `EventHandlers.EventCreateTest`.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.Factory

  alias Tymeslot.CalendarGrid
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Preferences

  defp build_socket(user, prefs_overrides \\ %{}) do
    profile = insert(:profile, user: user, timezone: "Europe/Tallinn")

    preferences =
      Map.merge(
        %{
          week_start_day: "monday",
          time_format: "24h",
          default_view: "week",
          show_week_numbers: false,
          show_weekends: true
        },
        prefs_overrides
      )

    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        current_user: user,
        profile: profile,
        preferences: preferences,
        events: [],
        hidden_integration_ids: MapSet.new(),
        view: :week,
        date: ~D[2026-04-13],
        show_settings: false,
        show_calendar_list: true,
        show_view_menu: true
      }
    }
  end

  describe "handle_toggle_settings/2" do
    test "flips show_settings and closes the other dropdowns" do
      user = insert(:user)
      socket = build_socket(user)

      {:noreply, updated} = Preferences.handle_toggle_settings(%{}, socket)

      assert updated.assigns.show_settings == true
      assert updated.assigns.show_calendar_list == false
      assert updated.assigns.show_view_menu == false
    end
  end

  describe "handle_close_settings/2" do
    test "sets show_settings to false" do
      user = insert(:user)
      socket = put_in(build_socket(user, %{}), [Access.key(:assigns), :show_settings], true)

      {:noreply, updated} = Preferences.handle_close_settings(%{}, socket)

      assert updated.assigns.show_settings == false
    end
  end

  describe "handle_update_default_view/2" do
    test "persists the new default view and switches the grid instantly" do
      user = insert(:user)
      socket = build_socket(user, %{default_view: "week"})

      {:noreply, updated} =
        Preferences.handle_update_default_view(%{"option" => "month"}, socket)

      assert updated.assigns.view == :month
      assert updated.assigns.preferences.default_view == "month"

      persisted = CalendarGrid.get_or_create_preferences(user.id)
      assert persisted.default_view == "month"
    end

    test "raises FunctionClauseError on a value outside day/week/month" do
      # The handler intentionally has no fallback clause — invalid values never
      # reach it in production because the template only emits day/week/month.
      # Asserting the raise documents that contract.
      user = insert(:user)
      socket = build_socket(user)

      assert_raise FunctionClauseError, fn ->
        Preferences.handle_update_default_view(%{"option" => "year"}, socket)
      end
    end
  end

  describe "handle_update_preference/3" do
    test "saves a recognised key to the DB and reflects it in assigns" do
      user = insert(:user)
      socket = build_socket(user, %{week_start_day: "monday"})

      {:noreply, updated} =
        Preferences.handle_update_preference(%{"option" => "sunday"}, socket, :week_start_day)

      assert updated.assigns.preferences.week_start_day == "sunday"

      persisted = CalendarGrid.get_or_create_preferences(user.id)
      assert persisted.week_start_day == "sunday"
    end

    test "ignores unknown preference keys" do
      user = insert(:user)
      socket = build_socket(user)

      {:noreply, updated} =
        Preferences.handle_update_preference(%{"option" => "value"}, socket, :unknown_key)

      assert updated.assigns.preferences == socket.assigns.preferences
    end
  end

  describe "handle_toggle_preference/3" do
    test "flips show_weekends and persists the new boolean" do
      user = insert(:user)
      socket = build_socket(user, %{show_weekends: true})

      {:noreply, updated} =
        Preferences.handle_toggle_preference(%{}, socket, :show_weekends)

      assert updated.assigns.preferences.show_weekends == false

      persisted = CalendarGrid.get_or_create_preferences(user.id)
      assert persisted.show_weekends == false
    end

    test "flips show_week_numbers and persists the new boolean" do
      user = insert(:user)
      socket = build_socket(user, %{show_week_numbers: false})

      {:noreply, updated} =
        Preferences.handle_toggle_preference(%{}, socket, :show_week_numbers)

      assert updated.assigns.preferences.show_week_numbers == true

      persisted = CalendarGrid.get_or_create_preferences(user.id)
      assert persisted.show_week_numbers == true
    end

    test "ignores unknown preference keys" do
      user = insert(:user)
      socket = build_socket(user)

      {:noreply, updated} =
        Preferences.handle_toggle_preference(%{}, socket, :totally_made_up)

      assert updated.assigns.preferences == socket.assigns.preferences
    end
  end
end
