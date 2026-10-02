defmodule TymeslotWeb.Components.Dashboard.Appointments.OpenAttrsTest do
  @moduledoc """
  Covers the click and keyboard bindings every agenda surface opens an
  appointment with.
  """

  use ExUnit.Case, async: true

  @moduletag :dashboard
  @moduletag :unit

  alias TymeslotWeb.Components.Dashboard.Appointments.OpenAttrs

  test "pushes the event with its values, focusable, with Enter and Space handed to the listener" do
    assert OpenAttrs.build("open_entry", %{"id" => "e1"}, target: 3) == %{
             "phx-click" => "open_entry",
             "phx-value-id" => "e1",
             "phx-target" => 3,
             "data-keyboard-click" => true,
             "role" => "button",
             "tabindex" => "0"
           }
  end

  test "leaves the keys to a hook that already turns them into a click" do
    attrs = OpenAttrs.build("show_event", %{"event-id" => 7}, keys: :hook)

    assert attrs["role"] == "button"
    assert attrs["tabindex"] == "0"
    refute Map.has_key?(attrs, "data-keyboard-click")
  end

  test "binds the click alone for an element with its own keyboard route" do
    assert OpenAttrs.build("show_event", %{"event-id" => 7}, keys: :none) == %{
             "phx-click" => "show_event",
             "phx-value-event-id" => 7
           }
  end
end
