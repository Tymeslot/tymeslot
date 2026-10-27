defmodule TymeslotWeb.AdminLive.FormattersTest do
  use ExUnit.Case, async: true

  @moduletag :infrastructure

  alias Tymeslot.AppSettings
  alias TymeslotWeb.AdminLive.Formatters

  describe "toggled/2" do
    # The settings page renders an on/off tag for exactly these keys
    # (`Components.Settings` dispatches on `Formatters.kind/1`), so a new
    # boolean setting without its own message pair fails here rather than
    # crashing the admin's LiveView when they first switch it.
    test "every boolean setting the admin page can toggle has its own on and off message" do
      keys = Enum.filter(AppSettings.keys(), &(Formatters.kind(&1) == :boolean))
      assert :registration_enabled in keys

      messages = for key <- keys, on? <- [true, false], do: Formatters.toggled(key, on?)

      assert Enum.all?(messages, &is_binary/1)
      assert length(Enum.uniq(messages)) == length(messages)
    end

    test "says whether registration was turned on or off without repeating its label" do
      assert Formatters.toggled(:registration_enabled, true) == "Registration turned on."
      assert Formatters.toggled(:registration_enabled, false) == "Registration turned off."
    end
  end
end
