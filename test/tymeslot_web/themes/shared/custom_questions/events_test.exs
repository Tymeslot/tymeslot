defmodule TymeslotWeb.Themes.Shared.CustomQuestions.EventsTest do
  use ExUnit.Case, async: true

  @moduletag :scheduling
  @moduletag :themes

  alias Phoenix.LiveView.Socket
  alias Tymeslot.Test.LogCapture
  alias TymeslotWeb.Themes.Shared.CustomQuestions.Events

  defp socket, do: %Socket{assigns: %{__changed__: %{}}}

  test "relays a theme's own event untouched on the questions step" do
    assert {:noreply, _socket} = Events.handle_event("theme:hint", %{"q" => "2"}, socket())
    assert_received {:step_event, :questions, "theme:hint", %{"q" => "2"}}
  end

  test "ignores any other event rather than crashing the page" do
    assert {:noreply, _socket} = Events.handle_event("next_slide", %{}, socket())
    refute_received {:step_event, _step, _event, _data}
  end

  test "relays next_step and back_step as the questions step's navigation" do
    assert {:noreply, _socket} = Events.handle_event("next_step", %{}, socket())
    assert_received {:step_event, :questions, :next_step, nil}

    assert {:noreply, _socket} = Events.handle_event("back_step", %{}, socket())
    assert_received {:step_event, :questions, :back_step, nil}
  end

  test "relays under the moment the page gives the questions component" do
    socket = %Socket{assigns: %{__changed__: %{}, moment: :ask}}

    assert {:noreply, _socket} = Events.handle_event("next_step", %{}, socket)
    assert_received {:step_event, :ask, :next_step, nil}
  end

  test "no longer knows the old names next and back" do
    for event <- ["next", "back"] do
      assert {:noreply, _socket} = Events.handle_event(event, %{}, socket())
    end

    refute_received {:step_event, _step, _event, _data}
  end

  test "logs an event it does not know, with the theme and the step" do
    LogCapture.attach()
    socket = %Socket{assigns: %{__changed__: %{}, theme_id: "2"}}

    assert {:noreply, _socket} = Events.handle_event("questions-probe-next", %{}, socket)

    assert_receive {:captured_log,
                    %{level: :warning, meta: %{event: "questions-probe-next"} = meta}}

    assert meta.theme_id == "2"
    assert meta.step == :questions
  end
end
