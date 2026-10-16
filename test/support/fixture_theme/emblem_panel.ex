defmodule TymeslotWeb.Test.FixtureTheme.EmblemPanel do
  @moduledoc """
  The fixture theme's dashboard panel for its `Emblem` group, registered with
  `option_panels:` in `TymeslotWeb.Test.FixtureTheme.Theme`. It receives the
  assigns every option panel receives, writes a shape through the one
  `theme:set_option` event and uploads an emblem through `upload_asset`, as
  the background's image picker does. It keeps no UI state, so the `Panel`
  defaults for `ui/3`, `handle_ui/5` and `telemetry/3` stand.
  """
  use Phoenix.Component
  use TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Panel

  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Panel

  @impl Panel
  def render(assigns) do
    ~H"""
    <div data-testid="fixture-emblem-panel">
      <p>Emblem</p>
      <button
        :for={choice <- @group.choices}
        type="button"
        phx-click="theme:set_option"
        phx-value-option={@group.key}
        phx-value-field="shape"
        phx-value-choice={choice}
        phx-target={@myself}
        aria-pressed={to_string(@customization.settings["fixture_emblem_shape"] == choice)}
      >
        {choice}
      </button>
      <form
        :if={@uploads[:fixture_emblem_path]}
        id="fixture-emblem-upload"
        phx-change="upload_asset"
        phx-submit="upload_asset"
        phx-target={@myself}
        data-auto-upload="true"
      >
        <input type="hidden" name="asset_field" value="fixture_emblem_path" />
        <.live_file_input upload={@uploads[:fixture_emblem_path]} />
        <button type="submit" class="hidden">Upload</button>
      </form>
    </div>
    """
  end
end
