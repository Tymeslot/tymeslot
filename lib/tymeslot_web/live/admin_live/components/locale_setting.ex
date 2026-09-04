defmodule TymeslotWeb.AdminLive.Components.LocaleSetting do
  @moduledoc """
  The per-surface fallback-language control on the admin settings page.

  A row of flag buttons rather than a select: the choice is a small, closed,
  visually distinctive set, so showing every option at once makes the current
  one readable at a glance instead of hidden behind a click. It mirrors the
  boolean settings' two-tag control, with the active option rendered in
  turquoise and disabled.

  Each button carries its language code beside the flag. Flags alone are a
  poor identifier — several are hard to tell apart at this size, and a flag
  is a country rather than a language — so the code is the label and the flag
  is recognition support.

  The country each flag comes from is read from the `:locales` config entry
  rather than looked up by locale code, so adding a language to that list is
  the only change a new flag needs.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  import TymeslotWeb.Components.FlagHelpers

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
      <.locale_tag
        key={@key}
        locale=""
        label={Formatters.unset_locale_label()}
        active={@effective.value == nil}
        disabled={@disabled}
      >
        <.icon name="hero-globe-alt-mini" class="w-4 h-4" />
        <span>{dgettext("dashboard_admin", "Default")}</span>
      </.locale_tag>

      <.locale_tag
        :for={locale <- @locales}
        key={@key}
        locale={locale.code}
        label={locale.name}
        active={@effective.value == locale.code}
        disabled={@disabled}
      >
        <.safe_flag country_code={locale.country_code} class="w-5 h-auto rounded-xs" />
        <span>{locale.code}</span>
      </.locale_tag>
    </div>
    """
  end

  # NOTE: the param is named `locale`, not `value`, for the same reason the
  # boolean control uses `state`: LiveView's client-side serialisation reads a
  # button's native `value` IDL property and would overwrite `phx-value-value`
  # with the empty string.
  attr :key, :atom, required: true
  attr :locale, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, required: true
  attr :disabled, :boolean, default: false
  slot :inner_block, required: true

  defp locale_tag(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="set_locale"
      phx-value-key={@key}
      phx-value-locale={@locale}
      disabled={@active or @disabled}
      aria-pressed={to_string(@active)}
      title={@label}
      aria-label={@label}
      class={[
        "inline-flex items-center gap-1.5 px-2.5 py-1.5 rounded-token-lg text-token-xs font-black uppercase tracking-wider transition-all",
        cond do
          @active -> "bg-turquoise-600 text-white shadow-md shadow-turquoise-200/40 cursor-default"
          @disabled -> "bg-tymeslot-50 text-tymeslot-300 cursor-not-allowed opacity-60"
          true -> "text-tymeslot-500 hover:bg-tymeslot-50 hover:text-tymeslot-900 cursor-pointer"
        end
      ]}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end
end
