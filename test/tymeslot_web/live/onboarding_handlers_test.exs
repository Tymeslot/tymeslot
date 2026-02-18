defmodule TymeslotWeb.OnboardingLive.HandlersTest do
  @moduletag :utils
  use TymeslotWeb.ConnCase, async: true
  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.OnboardingLive.TimezoneHandlers

  describe "timezone handlers" do
  @moduletag :utils
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
end
