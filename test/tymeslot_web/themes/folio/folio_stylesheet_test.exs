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
  @masthead "assets/css/scheduling/themes/folio/modules/masthead.css"

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

  # Each cover is cropped per preset (context: no cover file of its own), so
  # a cover Folio offers without a focus rule would be centred blindly.
  test "masthead.css crops every cover Folio offers" do
    css = File.read!(@masthead)
    %{presets: covers} = Enum.find(FolioSpec.option_groups(), &(&1.key == :cover))

    assert covers != []

    assert Enum.reject(covers, fn id ->
             css =~ ~s(.folio-cover[data-cover="#{id}"]) and css =~ "--folio-cover-focus"
           end) == []
  end
end
