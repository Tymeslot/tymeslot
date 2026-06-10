defmodule TymeslotWeb.Components.LanguageSwitcher do
  @moduledoc """
  Language switcher dropdown component for booking pages.
  Provides a dropdown interface for selecting between available languages,
  with flags and language names displayed for each option.
  """
  use Phoenix.Component

  import TymeslotWeb.Components.CoreComponents
  import TymeslotWeb.Components.FlagHelpers

  attr :locale, :string, required: true
  attr :locales, :list, required: true
  attr :dropdown_open, :boolean, default: false
  attr :theme, :string, default: "quill"

  @spec language_switcher(map()) :: Phoenix.LiveView.Rendered.t()
  def language_switcher(assigns) do
    ~H"""
    <div class="language-switcher">
      <.dropdown
        id="language-switcher-dropdown"
        open={@dropdown_open}
        on_toggle="toggle_language_dropdown"
        on_close="close_language_dropdown"
        trigger_class={switcher_button_class(@theme)}
        class={dropdown_panel_class(@theme)}
        aria-label="Change language"
      >
        <:trigger>
          <.locale_flag locale={@locale} class="w-5 h-4" />
          <span class="ml-2 hidden sm:inline">{current_locale_name(@locale, @locales)}</span>
          <svg class="w-4 h-4 ml-1" fill="currentColor" viewBox="0 0 20 20">
            <path
              fill-rule="evenodd"
              d="M5.293 7.293a1 1 0 011.414 0L10 10.586l3.293-3.293a1 1 0 111.414 1.414l-4 4a1 1 0 01-1.414 0l-4-4a1 1 0 010-1.414z"
              clip-rule="evenodd"
            />
          </svg>
        </:trigger>
        <:panel>
          <%= for locale_data <- @locales do %>
            <button
              type="button"
              phx-click="change_locale"
              phx-value-locale={locale_data.code}
              class={dropdown_item_class(@theme, @locale == locale_data.code)}
              role="menuitem"
            >
              <.locale_flag locale={locale_data.code} class="w-5 h-4" />
              <span class="ml-3">{locale_data.name}</span>
              <%= if @locale == locale_data.code do %>
                <svg class="w-4 h-4 ml-auto text-blue-600" fill="currentColor" viewBox="0 0 20 20">
                  <path
                    fill-rule="evenodd"
                    d="M16.707 5.293a1 1 0 010 1.414l-8 8a1 1 0 01-1.414 0l-4-4a1 1 0 011.414-1.414L8 12.586l7.293-7.293a1 1 0 011.414 0z"
                    clip-rule="evenodd"
                  />
                </svg>
              <% end %>
            </button>
          <% end %>
        </:panel>
      </.dropdown>
    </div>
    """
  end

  defp current_locale_name(locale, locales) do
    case Enum.find(locales, fn l -> l.code == locale end) do
      %{name: name} -> name
      _other -> String.upcase(locale)
    end
  end

  defp switcher_button_class("quill") do
    "flex items-center px-4 py-2 rounded-lg text-white text-sm font-medium transition-all duration-200 language-switcher-button-quill"
  end

  defp switcher_button_class("rhythm") do
    "flex items-center px-4 py-2 rounded-lg text-white text-sm font-medium transition-all duration-200 language-switcher-button-rhythm"
  end

  defp switcher_button_class(_arg), do: switcher_button_class("quill")

  defp dropdown_panel_class("quill") do
    "w-48 rounded-lg shadow-xl language-dropdown-quill"
  end

  defp dropdown_panel_class("rhythm") do
    "w-48 rounded-lg shadow-xl language-dropdown-rhythm"
  end

  defp dropdown_panel_class(_arg), do: dropdown_panel_class("quill")

  defp dropdown_item_class("rhythm", active) do
    base = "flex items-center w-full px-4 py-3 text-left text-sm transition-colors"
    active_class = if active, do: "active", else: ""
    "#{base} language-dropdown-item-rhythm #{active_class}"
  end

  defp dropdown_item_class(theme, active) do
    base =
      "flex items-center w-full px-4 py-3 text-left text-tymeslot-700 text-sm transition-colors"

    theme_class = "language-dropdown-item-#{theme}"
    active_class = if active, do: "active", else: ""
    "#{base} #{theme_class} #{active_class}"
  end
end
