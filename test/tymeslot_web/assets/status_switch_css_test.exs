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
  test "the status switch rules sit in the components layer" do
    css = File.read!(@dashboard_css)

    assert [_match, layer_body] =
             Regex.run(~r/@layer components \{\n(.*?)\n\}/s, css, capture: :all),
           "dashboard.css has no components layer"

    assert layer_body =~ ~r/^\s*\.status-toggle \{/m
    assert layer_body =~ ~r/^\s*\.status-toggle-slider \{/m

    outside = String.replace(css, layer_body, "")
    refute outside =~ ~r/\.status-toggle/
  end

  # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
  test "the status switch shows a focus ring for keyboard focus only" do
    css = File.read!(@dashboard_css)

    assert css =~ ~r/\.status-toggle:focus-visible \{[^}]*outline: 2px solid/
    refute css =~ ~r/\.status-toggle:focus \{/
    refute css =~ ~r/^\s*ring(-offset)?:/m
  end
end
