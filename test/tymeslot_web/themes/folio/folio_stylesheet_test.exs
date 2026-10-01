defmodule TymeslotWeb.Themes.Folio.FolioStylesheetTest do
  @moduledoc """
  Folio's stylesheet against its spec: the defaults `variables.css` declares
  are exactly the custom properties the spec's defaults produce, so a page
  that renders before its style block (or without one) looks like Ivory.
  """

  # The test reads a shipped stylesheet, not application code.
  # credo:disable-for-this-file Jump.CredoChecks.VacuousTest

  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Tymeslot.ThemeCustomizations.FolioSpec

  @variables "assets/css/scheduling/themes/folio/modules/variables.css"

  defp declared(css, name) do
    case Regex.run(~r/^\s*#{Regex.escape(name)}:\s*([^;]+);/m, css) do
      [_match, value] -> String.trim(value)
      nil -> nil
    end
  end

  test "variables.css declares every default the spec emits, with the spec's value" do
    css = File.read!(@variables)
    defaults = Map.new(FolioSpec.defaults(), fn {key, value} -> {Atom.to_string(key), value} end)
    %{vars: vars} = FolioSpec.tokens(defaults, %{})

    assert map_size(vars) > 10
    assert Enum.reject(vars, fn {name, value} -> declared(css, name) == value end) == []
  end
end
