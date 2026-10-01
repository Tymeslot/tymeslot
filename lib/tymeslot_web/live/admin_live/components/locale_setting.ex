defmodule TymeslotWeb.AdminLive.Components.LocaleSetting do
  @moduledoc """
  The per-surface fallback-language control on the admin settings page.

  A row of `LocaleButton`s rather than a select, mirroring the boolean
  settings' two-tag control, with a leading "Default" option for no value.

  The country each flag comes from is read from the `:locales` config entry
  rather than looked up by locale code, so adding a language to that list is
  the only change a new flag needs.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  import TymeslotWeb.Components.UI.LocaleButton

  alias Tymeslot.Locales
  alias TymeslotWeb.AdminLive.Formatters

  attr :key, :atom, required: true
  attr :effective, :map, required: true
  attr :disabled, :boolean, default: false

  @spec locale_control(map()) :: Phoenix.LiveView.Rendered.t()
  def locale_control(assigns) do
    assigns = assign(assigns, :locales, Locales.supported())

    ~H"""
    <div
      role="group"
      aria-label={dgettext("dashboard_admin", "Set %{name}", name: Formatters.humanise(@key))}
      class="inline-flex flex-wrap items-center justify-end p-1 bg-white border-2 border-tymeslot-100 rounded-token-xl shadow-sm gap-1 shrink-0 max-w-full"
    >
      <.locale_button
        locale={%{code: "", name: Formatters.unset_locale_label()}}
        active={@effective.value == nil}
        disabled={@disabled}
        phx-click="set_locale"
        phx-value-key={@key}
        phx-value-locale=""
      >
        <.icon name="hero-globe-alt-mini" class="w-4 h-4" />
        <span>{dgettext("dashboard_admin", "Default")}</span>
      </.locale_button>

      <.locale_button
        :for={locale <- @locales}
        locale={locale}
        active={@effective.value == locale.code}
        disabled={@disabled}
        phx-click="set_locale"
        phx-value-key={@key}
        phx-value-locale={locale.code}
      />
    </div>
    """
  end
end
