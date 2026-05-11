defmodule TymeslotWeb.Dashboard.Automation.HelpersTest do
  use Tymeslot.DataCase, async: true

  @moduletag :utils

  alias TymeslotWeb.Dashboard.Automation.Helpers

  describe "toggle_event/2" do
    test "adds event if not present" do
      form_values = %{"events" => ["event1"]}
      updated = Helpers.toggle_event(form_values, "event2")
      assert "event2" in updated["events"]
      assert "event1" in updated["events"]
    end

    test "removes event if present" do
      form_values = %{"events" => ["event1", "event2"]}
      updated = Helpers.toggle_event(form_values, "event1")
      assert "event2" in updated["events"]
      refute "event1" in updated["events"]
    end

    test "initializes events list if missing" do
      form_values = %{}
      updated = Helpers.toggle_event(form_values, "event1")
      assert updated["events"] == ["event1"]
    end
  end

  describe "parse_id/1" do
    test "returns integer as is" do
      assert Helpers.parse_id(123) == 123
    end

    test "parses string to integer" do
      assert Helpers.parse_id("456") == 456
    end

    test "returns 0 for invalid string" do
      assert Helpers.parse_id("abc") == 0
    end
  end

  describe "handle_feature_access_error/2" do
    setup do
      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
      {:ok, socket: socket}
    end

    test "returns socket unchanged for :insufficient_plan and sends error flash", %{socket: socket} do
      result = Helpers.handle_feature_access_error(socket, :insufficient_plan)
      assert result == socket
      assert_received {:flash, {:error, "Automation is available on Pro plans."}}
    end

    test "returns socket unchanged for :pro_required and sends error flash", %{socket: socket} do
      result = Helpers.handle_feature_access_error(socket, :pro_required)
      assert result == socket
      assert_received {:flash, {:error, "This automation feature is available on the Pro plan."}}
    end

    test "returns socket unchanged for :feature_disabled and sends error flash", %{socket: socket} do
      result = Helpers.handle_feature_access_error(socket, :feature_disabled)
      assert result == socket
      assert_received {:flash, {:error, "This automation feature is available on the Pro plan."}}
    end

    test "returns socket unchanged for :stripe_required and sends error flash", %{socket: socket} do
      result = Helpers.handle_feature_access_error(socket, :stripe_required)
      assert result == socket
      assert_received {:flash, {:error, "Connect a Stripe account to use this automation."}}
    end

    test "returns socket unchanged for :feature_access_checker_failed and sends error flash", %{
      socket: socket
    } do
      result = Helpers.handle_feature_access_error(socket, :feature_access_checker_failed)
      assert result == socket

      assert_received {:flash,
                       {:error, "Unable to verify subscription status. Please try again."}}
    end

    test "catch-all clause handles unknown atom and sends generic error flash", %{socket: socket} do
      result = Helpers.handle_feature_access_error(socket, :some_future_reason)
      assert result == socket
      assert_received {:flash, {:error, "Unable to perform this action. Please try again."}}
    end
  end

  describe "format_changeset_errors/1" do
    test "formats changeset errors into a flat map" do
      import Ecto.Changeset
      data = %{}
      types = %{name: :string, url: :string}

      changeset =
        {data, types}
        |> cast(%{name: "", url: "invalid"}, [:name, :url])
        |> validate_required([:name])
        |> add_error(:url, "is invalid")

      errors = Helpers.format_changeset_errors(changeset)
      assert errors.name == "can't be blank"
      assert errors.url == "is invalid"
    end
  end
end
