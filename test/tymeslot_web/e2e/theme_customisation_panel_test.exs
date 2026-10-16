defmodule TymeslotWeb.E2E.ThemeCustomisationPanelTest do
  @moduledoc """
  Regression test for the theme customisation panel losing every selection.

  LiveView's client reads a `<button>`'s native `value` IDL property and
  overwrites `phx-value-value` with it before the click payload is sent (the
  same gotcha documented above `schedule_chip/1` in `availability_section.ex`
  and `locale_tag/1` in `locale_setting.ex`). The customisation panel's choice
  buttons used to carry `phx-value-value`, so every palette scheme, gradient,
  solid colour, image and video preset click sent `"value":""` and nothing
  the user picked was ever saved. `LiveViewTest`'s `render_click/1` reads
  `phx-value-*` directly from the element and never reproduces the bug, so
  this drives a real Chrome session instead.
  """
  use TymeslotWeb.BrowserCase, async: false

  import Tymeslot.TestHelpers.Eventually

  alias Tymeslot.Profiles
  alias Tymeslot.ThemeCustomizations

  @moduletag :e2e
  @moduletag :themes

  feature "picking a palette scheme and a background preset persists both",
          %{session: session} do
    {session, user} = log_in_via_browser(session)
    profile = Profiles.get_profile(user.id)

    session
    |> visit("/dashboard/theme/customize/1")
    |> wait_for_live()
    |> click(
      css(
        "button[phx-click='theme:set_option'][phx-value-option='palette'][phx-value-field='scheme']",
        # The scheme name is CSS `uppercase`, and WebDriver's rendered-text
        # match respects that transform, so match the upper-cased text.
        text: "SUNSET GLOW"
      )
    )

    eventually(
      fn ->
        assert match?(
                 %{settings: %{"color_scheme" => "sunset"}},
                 ThemeCustomizations.get_by_profile_and_theme(profile.id, "1")
               )
      end,
      timeout: 3000
    )

    session
    |> click(css("button[phx-click='theme:set_browsing_type'][phx-value-type='gradient']"))
    |> click(
      css(
        "button[phx-click='theme:set_option'][phx-value-option='background'][phx-value-field='gradient']",
        text: "FOREST"
      )
    )

    eventually(
      fn ->
        assert match?(
                 %{
                   settings: %{
                     "background_type" => "gradient",
                     "background_value" => "gradient_4"
                   }
                 },
                 ThemeCustomizations.get_by_profile_and_theme(profile.id, "1")
               )
      end,
      timeout: 3000
    )
  end
end
