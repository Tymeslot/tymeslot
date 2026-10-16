defmodule TymeslotWeb.Themes.Core.ContextOverridesTest do
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias TymeslotWeb.Themes.Core.Context

  test "a valid ?primary-color= becomes a normalised override" do
    assert %Context{overrides: %{primary_color: "#e11d48"}} =
             Context.from_params(%{"primary-color" => "#E11D48"})
  end

  test "the three-digit shorthand embed.js allows is expanded" do
    assert %Context{overrides: %{primary_color: "#aabbcc"}} =
             Context.from_params(%{"primary-color" => "#abc"})
  end

  test "anything else is ignored" do
    for value <- ["red", "#e11d48;}body{", "e11d48", "#12345", ""] do
      assert %Context{overrides: overrides} = Context.from_params(%{"primary-color" => value})
      assert overrides == %{}, "accepted #{inspect(value)}"
    end
  end

  test "the override reaches the assigns" do
    assigns = Context.to_assigns(Context.from_params(%{"primary-color" => "#e11d48"}))

    assert assigns.theme_overrides == %{primary_color: "#e11d48"}
  end
end
