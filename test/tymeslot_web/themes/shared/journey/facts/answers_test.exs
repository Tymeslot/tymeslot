defmodule TymeslotWeb.Themes.Shared.Journey.Facts.AnswersTest do
  use ExUnit.Case, async: true

  @moduletag :scheduling
  @moduletag :themes
  @moduletag :custom_fields

  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Themes.Shared.CustomQuestions.Engine
  alias TymeslotWeb.Themes.Shared.Journey.Facts.Answers

  defp socket(assigns), do: %Socket{assigns: Map.merge(%{__changed__: %{}, flash: %{}}, assigns)}

  defp question(id), do: %{"id" => id, "type" => "short_text", "label" => id, "required" => true}

  test "are the answers, needing only the meeting type" do
    assert Answers.key() == :answers
    assert Answers.requires(%{}) == [:meeting_type]
    assert Answers.events() == [:answer]
  end

  test "are needed only when the meeting type has questions" do
    assert Answers.required?(%{meeting_type: %{custom_fields: [question("company")]}})
    refute Answers.required?(%{meeting_type: %{custom_fields: []}})
    refute Answers.required?(%{meeting_type: %{}})
    refute Answers.required?(%{meeting_type: nil})
    refute Answers.required?(%{})
  end

  test "an answer is stored on the engine" do
    socket = socket(%{engine: Engine.init([question("company")])})

    assert {:noreply, socket} = Answers.handle(socket, :answer, {"company", "Acme"})
    assert socket.assigns.engine.answers["company"] == "Acme"
  end

  describe "known?/1" do
    test "answers that validate are known" do
      engine = [question("company")] |> Engine.init() |> Engine.answer("company", "Acme")

      assert Answers.known?(%{engine: engine})
    end

    test "a required question left blank is not" do
      refute Answers.known?(%{engine: Engine.init([question("company")])})
    end

    test "carried-over answers are not known until the booker has seen them" do
      engine = [question("company")] |> Engine.init() |> Engine.prefill(%{"company" => "Acme"})

      refute Answers.known?(%{engine: engine})
      assert Answers.known?(%{engine: Engine.mark_reviewed(engine)})
    end

    test "no questions, or no engine yet, asks nothing" do
      assert Answers.known?(%{engine: Engine.init([])})
      assert Answers.known?(%{})
    end
  end

  describe "continue/1" do
    test "moves to the following question once the current one is answered" do
      engine =
        [question("company"), question("role")]
        |> Engine.init()
        |> Engine.answer("company", "Acme")

      assert {:stay, socket} = Answers.continue(socket(%{engine: engine}))
      assert socket.assigns.engine.current_index == 1
    end

    test "stays on a question that does not validate" do
      engine = Engine.init([question("company"), question("role")])

      assert {:stay, socket} = Answers.continue(socket(%{engine: engine}))
      assert socket.assigns.engine.current_index == 0
      assert socket.assigns.engine.errors["company"]
    end

    test "is done past the last question once every answer validates, and marks them seen" do
      engine =
        [question("company")]
        |> Engine.init()
        |> Engine.prefill(%{"company" => "Acme"})

      assert {:done, socket} = Answers.continue(socket(%{engine: engine}))
      refute Engine.pending_review?(socket.assigns.engine)
    end

    test "is done at once when there are no questions" do
      socket = socket(%{engine: Engine.init([])})

      assert Answers.continue(socket) == {:done, socket}
    end
  end

  describe "back/1" do
    test "leaves from the first question" do
      socket = socket(%{engine: Engine.init([question("company")])})

      assert Answers.back(socket) == {:leave, socket}
    end

    test "returns to the previous question from a later one" do
      engine =
        [question("company"), question("role")]
        |> Engine.init()
        |> Engine.answer("company", "Acme")

      {:ok, engine} = Engine.next(engine)

      assert {:stay, socket} = Answers.back(socket(%{engine: engine}))
      assert socket.assigns.engine.current_index == 0
    end
  end
end
