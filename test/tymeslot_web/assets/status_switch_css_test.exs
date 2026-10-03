defmodule TymeslotWeb.Assets.StatusSwitchCssTest do
  use ExUnit.Case, async: true

  @moduletag :ui
  @moduletag :dashboard

  @dashboard_css Path.expand("../../../assets/css/components/dashboard.css", __DIR__)

  # The StatusSwitch component sizes its track, border and slider travel with
  # Tailwind utilities. An unlayered `.status-toggle` rule beats every utility,
  # which once drew every size at the medium size; inside the components layer
  # the utilities win. These guard a stylesheet, not application code, so there
  # is no Tymeslot function for them to call.

  # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
  test "every status switch rule sits in the components layer" do
    rules =
      @dashboard_css
      |> File.read!()
      |> rules_with_ancestors()
      |> Enum.filter(fn {selector, _ancestors} -> selector =~ ".status-toggle" end)

    assert Enum.any?(rules, fn {selector, _} -> selector == ".status-toggle" end)
    assert Enum.any?(rules, fn {selector, _} -> selector == ".status-toggle-slider" end)

    assert Enum.reject(rules, fn {_selector, ancestors} ->
             "@layer components" in ancestors
           end) == []
  end

  # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
  test "the status switch shows a focus ring for keyboard focus only" do
    css = File.read!(@dashboard_css)

    assert css =~ ~r/\.status-toggle:focus-visible \{[^}]*outline: 2px solid/
    refute css =~ ~r/\.status-toggle:focus \{/
  end

  # Every rule's selector with the at-rules enclosing it, outermost first:
  # a brace-depth walk over the stylesheet with comments removed, so a rule
  # in a second layer block or nested in a media query inside the layer is
  # still seen in its layer.
  defp rules_with_ancestors(css) do
    css
    |> String.replace(~r{/\*.*?\*/}s, "")
    |> String.graphemes()
    |> Enum.reduce({"", [], []}, fn
      "{", {prelude, stack, rules} ->
        prelude = String.trim(prelude)
        ancestors = Enum.reverse(stack)

        rules =
          if String.starts_with?(prelude, "@"), do: rules, else: [{prelude, ancestors} | rules]

        {"", [prelude | stack], rules}

      "}", {_prelude, stack, rules} ->
        {"", tl(stack), rules}

      ";", {_prelude, stack, rules} ->
        {"", stack, rules}

      char, {prelude, stack, rules} ->
        {prelude <> char, stack, rules}
    end)
    |> elem(2)
  end
end
