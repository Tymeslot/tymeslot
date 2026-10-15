defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Pickers.ColorPicker do
  @moduledoc """
  Function component for selecting solid color backgrounds in theme customization.

  Renders the curated 12-swatch grid plus a collapsible "Custom" disclosure panel
  containing the reusable `ColourPickerWidget`. Both swatch clicks and committed
  picker values reach the parent LiveComponent as `theme:set_option` with the
  field `"color"`.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.ThemeCustomizations

  import TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.CurrentIndicator,
    only: [current_indicator: 1]

  import TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Pickers.ColourPickerWidget,
    only: [colour_picker_widget: 1]

  @swatches ~w(#ffffff #020617 #94a3b8 #dc2626 #ea580c #d97706 #059669 #0e7490 #2563eb #4f46e5 #9333ea #db2777)

  @doc """
  Renders the color picker.

  Expects assigns:
    * `:option`        : the background option group's key
    * `:customization` — current customization map (reads its `"background_value"` setting)
    * `:myself`        — CID of the parent LiveComponent
    * `:custom_picker_open` — boolean controlling the disclosure panel
  """
  @spec color_picker(map()) :: Phoenix.LiveView.Rendered.t()
  def color_picker(assigns) do
    assigns =
      assigns
      |> assign(:swatches, @swatches)
      |> assign(:custom_hex, current_custom_hex(assigns.customization))

    ~H"""
    <div class="space-y-6">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <p class="text-token-sm font-black text-tymeslot-400 uppercase tracking-widest">
          {dgettext("dashboard_appearance", "Select a solid colour")}
        </p>
        <div class="flex flex-wrap items-center gap-3">
          <%= if @customization.settings["background_type"] == "color" and @customization.settings["background_value"] do %>
            <.current_indicator
              swatches={[@customization.settings["background_value"]]}
              label={dgettext("dashboard_appearance", "Solid Colour")}
              code={String.upcase(@customization.settings["background_value"])}
              highlighted={not preset_swatch?(@customization.settings["background_value"])}
            />
          <% end %>
          <button
            type="button"
            phx-click="theme:toggle_custom_picker"
            phx-value-option={@option}
            phx-target={@myself}
            aria-expanded={to_string(@custom_picker_open)}
            aria-controls="custom-background-picker"
            class={[
              "flex items-center gap-2 px-3.5 py-2 rounded-token-xl border-2 text-token-2xs font-black uppercase tracking-widest transition-all duration-300",
              if(@custom_picker_open,
                do:
                  "bg-turquoise-50 border-turquoise-300 text-turquoise-700 shadow-sm shadow-turquoise-500/10",
                else:
                  "bg-tymeslot-50 border-transparent text-tymeslot-600 hover:bg-tymeslot-100 hover:border-tymeslot-200"
              )
            ]}
          >
            <.icon name="hero-swatch-mini" class="w-4 h-4" />
            <span>{dgettext("dashboard_appearance", "Custom")}</span>
            <.icon
              name="hero-chevron-down-mini"
              class={"w-4 h-4 transition-transform duration-300 #{if @custom_picker_open, do: "rotate-180"}"}
            />
          </button>
        </div>
      </div>

      <div class="flex flex-wrap gap-4">
        <%= for color <- @swatches do %>
          <button
            type="button"
            class={[
              "w-14 h-14 rounded-token-2xl border-4 transition-all duration-300 shadow-sm transform hover:scale-110",
              if(@customization.settings["background_value"] == color,
                do: "border-turquoise-400 shadow-xl shadow-turquoise-500/20 scale-110",
                else: "border-tymeslot-50 hover:border-turquoise-200"
              )
            ]}
            style={"background-color: #{color}"}
            phx-click="theme:set_option"
            phx-value-option={@option}
            phx-value-field="color"
            phx-value-choice={color}
            phx-target={@myself}
          >
            <%= if @customization.settings["background_value"] == color do %>
              <div class="bg-white rounded-token-full p-1 w-6 h-6 mx-auto flex items-center justify-center shadow-lg ring-1 ring-tymeslot-100">
                <.icon name="hero-check-mini" class="w-4 h-4 text-turquoise-600" />
              </div>
            <% end %>
          </button>
        <% end %>
      </div>

      <%= if @custom_picker_open do %>
        <div class="animate-fade-in-up rounded-token-2xl border-2 border-tymeslot-50 bg-tymeslot-50/50 p-4">
          <.colour_picker_widget
            id="custom-background-picker"
            target={@myself}
            initial_hex={@custom_hex}
            commit_event="theme:set_option"
            commit_params={%{option: @option, field: "color"}}
          />
        </div>
      <% end %>
    </div>
    """
  end

  defp current_custom_hex(%{settings: %{"background_value" => "#" <> _rest = hex}})
       when byte_size(hex) in [4, 7],
       do: hex

  defp current_custom_hex(_customization), do: ThemeCustomizations.default_custom_palette_seed()

  defp preset_swatch?(value) when is_binary(value), do: String.downcase(value) in @swatches
end
