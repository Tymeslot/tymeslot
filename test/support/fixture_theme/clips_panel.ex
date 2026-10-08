defmodule TymeslotWeb.Test.FixtureTheme.ClipsPanel do
  @moduledoc """
  The fixture theme's dashboard panel for its `Clips` group: one upload form
  per clip and one for the intro's captions, each sending `upload_asset` with
  its field, as the emblem's upload does. It keeps no UI state, so the
  `Panel` defaults stand.
  """
  use Phoenix.Component
  use TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Panel

  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Panel

  @clip_fields [:fixture_intro_clip_path, :fixture_outro_clip_path, :fixture_intro_captions_path]

  @impl Panel
  def render(assigns) do
    ~H"""
    <div data-testid="fixture-clips-panel">
      <p>Clips</p>
      <form
        :for={field <- declared(@uploads)}
        id={"fixture-clip-upload-#{field}"}
        phx-change="upload_asset"
        phx-submit="upload_asset"
        phx-target={@myself}
        data-auto-upload="true"
      >
        <input type="hidden" name="asset_field" value={field} />
        <.live_file_input upload={@uploads[field]} />
        <button type="submit" class="hidden">Upload</button>
      </form>
    </div>
    """
  end

  # The fields the dashboard declared an upload for.
  defp declared(uploads), do: Enum.filter(@clip_fields, &Map.has_key?(uploads || %{}, &1))
end
