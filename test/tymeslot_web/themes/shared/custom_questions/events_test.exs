defmodule TymeslotWeb.Themes.Shared.CustomQuestions.EventsTest do
  use ExUnit.Case, async: true

  @moduletag :scheduling
  @moduletag :themes

  alias Phoenix.LiveView.Socket
  alias Tymeslot.Test.LogCapture
  alias TymeslotWeb.Themes.Shared.CustomQuestions.Engine
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

  defp definitions do
    [
      %{"id" => "a", "type" => "short_text", "label" => "A", "required" => true, "position" => 0},
      %{
        "id" => "b",
        "type" => "short_text",
        "label" => "B",
        "required" => false,
        "position" => 1
      },
      %{
        "id" => "m",
        "type" => "multi_select",
        "label" => "M",
        "required" => false,
        "position" => 2,
        "options" => [%{"key" => "x", "label" => "X"}, %{"key" => "y", "label" => "Y"}]
      }
    ]
  end

  defp asking,
    do: %Socket{assigns: %{__changed__: %{}, moment: :pick, engine: Engine.init(definitions())}}

  describe "the question an answer is for" do
    test "is the one the event names, on a screen that shows them all" do
      assert {:noreply, _socket} =
               Events.handle_event("answer", %{"question" => "b", "value" => "Acme"}, asking())

      assert_received {:step_event, :pick, :answer, {"b", "Acme"}}
    end

    test "is the one on show when the event names none, or one the engine does not have" do
      Events.handle_event("answer", %{"value" => "Acme"}, asking())
      assert_received {:step_event, :pick, :answer, {"a", "Acme"}}

      Events.handle_event("answer", %{"question" => "zz", "value" => "Acme"}, asking())
      assert_received {:step_event, :pick, :answer, {"a", "Acme"}}
    end

    test "is the one a choice toggled names" do
      Events.handle_event("multi_toggle", %{"question" => "m", "value" => "y"}, asking())
      assert_received {:step_event, :pick, :answer, {"m", ["y"]}}
    end
  end

  describe "all_questions/1" do
    test "gives every question with its answer, and no error before the booker has seen one" do
      engine = Engine.answer(Engine.init(definitions()), "b", "Design")

      assert [
               %{definition: %{"id" => "a"}, value: nil, error: nil},
               %{definition: %{"id" => "b"}, value: "Design", error: nil},
               %{definition: %{"id" => "m"}, value: nil, error: nil}
             ] = Events.all_questions(%{engine: engine})
    end

    test "names a question the submit refused while its answer still fails" do
      refused = %{refused_questions: MapSet.new(["a"])}

      assert [%{error: error} | _rest] =
               Events.all_questions(Map.put(refused, :engine, Engine.init(definitions())))

      assert byte_size(error) > 0

      answered = Engine.answer(Engine.init(definitions()), "a", "Acme")
      assert [%{error: nil} | _rest] = Events.all_questions(Map.put(refused, :engine, answered))
    end

    test "names a touched answer that fails" do
      engine = Engine.answer(Engine.init(definitions()), "a", "")

      assert [%{error: error} | _rest] = Events.all_questions(%{engine: engine})
      assert byte_size(error) > 0
    end

    test "is empty without questions" do
      assert Events.all_questions(%{engine: Engine.init([])}) == []
      assert Events.all_questions(%{}) == []
    end
  end
end
