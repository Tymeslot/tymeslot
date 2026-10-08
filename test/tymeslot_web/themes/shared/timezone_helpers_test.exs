defmodule TymeslotWeb.Themes.Shared.TimezoneHelpersTest do
  use ExUnit.Case, async: true

  @moduletag :scheduling

  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Themes.Shared.TimezoneHelpers

  # A socket mid-mount: `connect_params` only exists while mounting, and a
  # socket counts as connected once it has a transport pid.
  defp mounting_socket(connect_params, connected?) do
    %Socket{
      assigns: %{__changed__: %{}},
      private: %{connect_params: connect_params},
      transport_pid: if(connected?, do: self())
    }
  end

  describe "assign_user_timezone/2" do
    test "prefers the timezone the booker's browser reported over the URL" do
      socket = mounting_socket(%{"timezone" => "Asia/Tokyo"}, true)

      socket = TimezoneHelpers.assign_user_timezone(socket, %{"timezone" => "Europe/Berlin"})

      assert socket.assigns.user_timezone == "Asia/Tokyo"
    end

    test "keeps the timezone the visitor chose before a language switch over the browser's" do
      socket = mounting_socket(%{"timezone" => "Asia/Tokyo"}, true)

      socket =
        TimezoneHelpers.assign_user_timezone(socket, %{"visitor_timezone" => "America/New_York"})

      assert socket.assigns.user_timezone == "America/New_York"
    end

    test "ignores a carried timezone that does not exist" do
      socket = mounting_socket(%{"timezone" => "Asia/Tokyo"}, true)

      socket = TimezoneHelpers.assign_user_timezone(socket, %{"visitor_timezone" => "Mars/Base"})

      assert socket.assigns.user_timezone == "Asia/Tokyo"
    end

    test "uses the URL's timezone on the static render, before the browser has reported one" do
      socket = mounting_socket(%{}, false)

      socket = TimezoneHelpers.assign_user_timezone(socket, %{"timezone" => "Europe/Berlin"})

      assert socket.assigns.user_timezone == "Europe/Berlin"
    end

    test "stores a renamed zone under its current name" do
      socket = mounting_socket(%{"timezone" => "Europe/Kiev"}, true)

      assert TimezoneHelpers.assign_user_timezone(socket, %{}).assigns.user_timezone ==
               "Europe/Kyiv"
    end

    test "falls back to the default for a zone that does not exist" do
      socket = mounting_socket(%{"timezone" => "Mars/Olympus_Mons"}, true)

      assert TimezoneHelpers.assign_user_timezone(socket, %{}).assigns.user_timezone ==
               "Europe/Tallinn"
    end

    test "falls back to the default when nothing names a timezone" do
      socket = mounting_socket(%{}, false)

      assert TimezoneHelpers.assign_user_timezone(socket, %{}).assigns.user_timezone ==
               "Europe/Tallinn"
    end
  end
end
