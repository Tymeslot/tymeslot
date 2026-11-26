defmodule TymeslotWeb.Test.FixtureTheme.ClipsPanel do
  @moduledoc """
  The fixture theme's dashboard panel for its `Clips` group: one upload form
  per clip and one for the intro's captions, each saved into its field by the
  upload's progress callback, as the emblem's upload is. It keeps no UI state, so the
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
        novalidate
        id={"fixture-clip-upload-#{field}"}
        phx-change="upload_asset"
        phx-target={@myself}
      >
        <.live_file_input upload={@uploads[field]} />
      </form>
    </div>
    """
  end

  # The fields the dashboard declared an upload for.
  defp declared(uploads), do: Enum.filter(@clip_fields, &Map.has_key?(uploads || %{}, &1))
end
