defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.FontPanel do
  @moduledoc """
  The dashboard panel for an `Options.Font` group: the group's fonts, in its
  order. Each label asks for the font's heading stack with the dashboard's
  own font as the fallback; the dashboard loads no booking-page font CSS,
  so the panel works whether or not the font files exist. It keeps no UI
  state.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext
  use TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Panel

  alias Tymeslot.ThemeCustomizations.Options.Font
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Panel

  @impl Panel
  def render(assigns) do
    assigns =
      assign(assigns,
        choice: Font.choice(assigns.customization.settings, assigns.group),
        fonts: Font.presets(assigns.group)
      )

    ~H"""
    <.card
      title={dgettext("dashboard_appearance", "Font")}
      description={
        dgettext(
          "dashboard_appearance",
          "The typeface of the text and headings on your booking page."
        )
      }
      data-testid="font-panel"
    >
      <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
        <button
          :for={{id, font} <- @fonts}
          type="button"
          class={[
            "flex items-center justify-center p-5 rounded-token-2xl border-2 transition-all duration-300",
            if(@choice == id,
              do: "bg-turquoise-50 border-turquoise-400 shadow-xl shadow-turquoise-500/10",
              else: "bg-white border-tymeslot-50 hover:border-turquoise-200 hover:shadow-lg"
            )
          ]}
          phx-click="theme:set_option"
          phx-value-option={@group.key}
          phx-value-field="font"
          phx-value-choice={id}
          phx-target={@myself}
          aria-pressed={to_string(@choice == id)}
        >
          <span
            class={[
              "text-token-lg font-bold",
              if(@choice == id, do: "text-turquoise-700", else: "text-tymeslot-700")
            ]}
            style={"font-family: var(--font-heading-#{id}, inherit)"}
          >
            {font_name(font)}
          </span>
        </button>
      </div>
    </.card>
    """
  end

  # Names that are words are registered for extraction in `Presets.Fonts`;
  # a typeface name has no entry and comes back as it is.
  defp font_name(%{name: name}),
    do: Gettext.dgettext(TymeslotWeb.Gettext, "dashboard_appearance", name)
end
