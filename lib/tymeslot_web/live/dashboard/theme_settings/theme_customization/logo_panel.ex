defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.LogoPanel do
  @moduledoc """
  The dashboard panel for an `Options.Logo` group: the stored logo, an
  upload form for a new one (`upload_asset` into `logo_path`, which replaces
  the old file) and a button removing it (`theme:set_option` on `logo_path`
  with an empty choice). It keeps no UI state, so the `Panel` defaults for
  `ui/3`, `handle_ui/5` and `telemetry/3` stand.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext
  use TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Panel

  alias Tymeslot.ThemeCustomizations.Options.Logo
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Panel

  import TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Pickers.ImageUpload,
    only: [image_upload: 1]

  @impl Panel
  def render(assigns) do
    assigns =
      assign(assigns, :logo, Logo.media(assigns.customization.settings, assigns.group).logo)

    ~H"""
    <.card
      title={dgettext("dashboard_appearance", "Logo")}
      description={
        dgettext(
          "dashboard_appearance",
          "Your logo, for the themes that show one on your booking page."
        )
      }
      data-testid="logo-panel"
    >
      <div class="flex flex-col sm:flex-row sm:items-start gap-8">
        <div class="w-40 h-40 shrink-0 p-4 rounded-token-2xl bg-tymeslot-50 border-2 border-tymeslot-100 flex items-center justify-center overflow-hidden">
          <%= if @logo do %>
            <img
              src={@logo.src}
              alt={dgettext("dashboard_appearance", "Your logo")}
              class="max-w-full max-h-full object-contain"
              data-testid="logo-preview"
            />
          <% else %>
            <.icon name="hero-photo" class="w-10 h-10 text-tymeslot-300" />
          <% end %>
        </div>

        <div class="flex-1 space-y-6">
          <div class="bg-tymeslot-50 p-8 rounded-token-4xl border-2 border-tymeslot-100 border-dashed">
            <.image_upload
              id="theme-logo-form"
              field={:logo_path}
              uploads={@uploads}
              myself={@myself}
            />
          </div>

          <%= if @logo do %>
            <.action_button
              variant={:secondary}
              phx-click="theme:set_option"
              phx-value-option={@group.key}
              phx-value-field="logo_path"
              phx-value-choice=""
              phx-target={@myself}
              data-testid="remove-logo"
            >
              <.icon name="hero-trash-mini" class="w-4 h-4" />
              {dgettext("dashboard_appearance", "Remove logo")}
            </.action_button>
          <% else %>
            <p class="text-token-sm text-tymeslot-500 font-bold">
              {dgettext("dashboard_appearance", "No logo uploaded yet.")}
            </p>
          <% end %>
        </div>
      </div>
    </.card>
    """
  end
end
