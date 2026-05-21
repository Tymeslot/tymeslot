defmodule TymeslotWeb.OnboardingLive.HandlersTest do
  use TymeslotWeb.ConnCase, async: false

  @moduletag :utils

  import Tymeslot.Factory

  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.OnboardingLive.TimezoneHandlers

  describe "timezone handlers" do
    test "handle_toggle_timezone_dropdown toggles state" do
      socket = %Socket{assigns: %{__changed__: %{}, timezone_dropdown_open: false}}
      {:noreply, updated} = TimezoneHandlers.handle_toggle_timezone_dropdown(socket)
      assert updated.assigns.timezone_dropdown_open == true

      {:noreply, updated_again} = TimezoneHandlers.handle_toggle_timezone_dropdown(updated)
      assert updated_again.assigns.timezone_dropdown_open == false
    end

    test "handle_close_timezone_dropdown closes dropdown" do
      socket = %Socket{assigns: %{__changed__: %{}, timezone_dropdown_open: true}}
      {:noreply, updated} = TimezoneHandlers.handle_close_timezone_dropdown(socket)
      assert updated.assigns.timezone_dropdown_open == false
    end

    test "handle_search_timezone updates search term" do
      socket = %Socket{assigns: %{__changed__: %{}}}
      {:noreply, updated} = TimezoneHandlers.handle_search_timezone("New York", socket)
      assert updated.assigns.timezone_search == "New York"
    end
  end

  describe "handle_change_timezone/2" do
    test "persists a valid timezone to the user's profile" do
      user = insert(:user)
      profile = insert(:profile, user: user, timezone: "Europe/Tallinn")

      socket = %Socket{
        assigns: %{
          __changed__: %{},
          profile: profile,
          timezone_dropdown_open: true,
          timezone_search: "Sydney"
        }
      }

      {:noreply, updated} =
        TimezoneHandlers.handle_change_timezone("Australia/Sydney", socket)

      assert updated.assigns.profile.timezone == "Australia/Sydney"
      assert updated.assigns.timezone_dropdown_open == false
      assert updated.assigns.timezone_search == ""
      assert updated.assigns.form_errors == %{}
    end

    test "rejects an unknown timezone without touching the database" do
      user = insert(:user)
      profile = insert(:profile, user: user, timezone: "Europe/Tallinn")

      socket = %Socket{
        assigns: %{
          __changed__: %{},
          profile: profile,
          timezone_dropdown_open: true,
          timezone_search: ""
        }
      }

      {:noreply, updated} =
        TimezoneHandlers.handle_change_timezone("Not/A_Real_Timezone", socket)

      assert updated.assigns.form_errors == %{timezone: "Invalid timezone"}
      # Profile timezone is unchanged on the assigns
      assert updated.assigns.profile.timezone == "Europe/Tallinn"
    end

    test "rejects a non-binary timezone input" do
      profile = insert(:profile, timezone: "Europe/Tallinn")

      socket = %Socket{
        assigns: %{
          __changed__: %{},
          profile: profile,
          timezone_dropdown_open: false,
          timezone_search: ""
        }
      }

      {:noreply, updated} = TimezoneHandlers.handle_change_timezone(nil, socket)

      assert %{timezone: _message} = updated.assigns.form_errors
    end
  end
end
