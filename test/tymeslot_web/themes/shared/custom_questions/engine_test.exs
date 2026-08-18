defmodule TymeslotWeb.Themes.Shared.CustomQuestions.EngineTest do
  use Tymeslot.DataCase, async: true

  @moduletag :custom_fields

  alias Ecto.UUID
  alias TymeslotWeb.Themes.Shared.CustomQuestions.Engine

  defp build_def(type, attrs \\ %{}) do
    Map.merge(
      %{
        "id" => Map.get(attrs, :id, UUID.generate()),
        "type" => type,
        "label" => Map.get(attrs, :label, "Q"),
        "required" => Map.get(attrs, :required, true)
      },
      Map.drop(attrs, [:id, :label, :required])
    )
  end

  test "init/1 starts on question 0 with no answers and no errors" do
    s = Engine.init([build_def("short_text"), build_def("short_text")])
    assert s.current_index == 0
    assert s.answers == %{}
    assert s.errors == %{}
  end

  test "skipped? returns true when there are zero definitions" do
    assert Engine.skipped?(Engine.init([]))
  end

  test "skipped? returns false when there are definitions" do
    refute Engine.skipped?(Engine.init([build_def("short_text")]))
  end

  test "answer/3 stores the raw value for the current question" do
    [d1, d2] = [build_def("short_text"), build_def("short_text")]
    s = Engine.answer(Engine.init([d1, d2]), d1["id"], "Acme")
    assert s.answers[d1["id"]] == "Acme"
  end

  test "next/1 advances when current question is valid" do
    [d1, d2] = [build_def("short_text"), build_def("short_text")]
    s = Engine.answer(Engine.init([d1, d2]), d1["id"], "Acme")
    {:ok, s2} = Engine.next(s)
    assert s2.current_index == 1
  end

  test "next/1 refuses to advance when current required question is empty" do
    [d1, d2] = [build_def("short_text"), build_def("short_text")]
    s = Engine.init([d1, d2])
    assert {:error, s2} = Engine.next(s)
    assert s2.errors[d1["id"]] == "Text is required"
  end

  test "prev/1 goes back without validating" do
    [d1, d2] = [build_def("short_text"), build_def("short_text")]
    s = Engine.answer(Engine.init([d1, d2]), d1["id"], "Acme")
    {:ok, s2} = Engine.next(s)
    s3 = Engine.prev(s2)
    assert s3.current_index == 0
  end

  test "prev/1 on first question is a no-op" do
    [d1] = [build_def("short_text")]
    s = Engine.init([d1])
    assert Engine.prev(s).current_index == 0
  end

  test "complete?/1 true only when on last question and all required answered" do
    [d1, d2] = [build_def("short_text"), build_def("short_text")]
    s = Engine.init([d1, d2])
    refute Engine.complete?(s)

    s = Engine.answer(s, d1["id"], "Acme")
    {:ok, s} = Engine.next(s)
    s = Engine.answer(s, d2["id"], "Beta")
    assert Engine.complete?(s)
  end

  test "validate_all/1 returns ok with normalised answers" do
    [d1, d2] = [build_def("short_text"), build_def("short_text")]

    s =
      Engine.init([d1, d2])
      |> Engine.answer(d1["id"], "Acme")
      |> Engine.answer(d2["id"], "Beta")

    assert {:ok, ans} = Engine.validate_all(s)
    assert ans == %{d1["id"] => "Acme", d2["id"] => "Beta"}
  end

  test "validate_all/1 returns error map for invalid required answers" do
    [d1, d2] = [build_def("short_text"), build_def("short_text")]
    s = Engine.init([d1, d2])
    assert {:error, errs} = Engine.validate_all(s)
    assert Map.has_key?(errs, d1["id"])
    assert Map.has_key?(errs, d2["id"])
  end

  test "init/1 sorts definitions by position" do
    [d_high, d_low] = [
      build_def("short_text", %{position: 5, label: "high"}),
      build_def("short_text", %{position: 1, label: "low"})
    ]

    s = Engine.init([d_high, d_low])
    [first | _rest] = s.definitions
    assert first["label"] == "low"
  end

  test "current_definition/1 returns the definition at current_index" do
    [d1, d2] = [build_def("short_text"), build_def("short_text")]
    s = Engine.init([d1, d2])
    assert Engine.current_definition(s)["id"] == d1["id"]
  end

  test "next/1 at the last question is a no-op on current_index (clamp)" do
    [d1, d2] = [build_def("short_text"), build_def("short_text")]
    s = Engine.init([d1, d2])

    s = Engine.answer(s, d1["id"], "Acme")
    {:ok, s} = Engine.next(s)
    assert s.current_index == 1

    s = Engine.answer(s, d2["id"], "Beta")
    {:ok, s} = Engine.next(s)
    # current_index stayed at 1 (the last index, since total = 2).
    assert s.current_index == 1
  end

  test "next/1 on an empty engine returns {:error, s} without crashing" do
    s = Engine.init([])
    assert {:error, ^s} = Engine.next(s)
  end
end
