defmodule TymeslotWeb.Components.UI.LocaleButton do
  @moduledoc """
  One option in a row of language buttons: a flag beside the language code,
  with the active option in turquoise and disabled.

  A row of these replaces a select wherever the choice is the small, closed
  set of supported languages, so the current one reads at a glance. The code
  is the label and the flag only recognition support: several flags are hard
  to tell apart at this size, and a flag is a country rather than a language.

  The caller renders the surrounding `role="group"` and wires the click
  through the global attributes (`phx-click`, `phx-value-*`, `phx-target`).
  Name the value attribute anything but `phx-value-value`: LiveView reads a
  button's native `value` property and would overwrite it with "".
  """

  use Phoenix.Component

  import TymeslotWeb.Components.FlagHelpers

  attr :locale, :map,
    required: true,
    doc: "an entry from `Tymeslot.Locales.supported/0`"

  attr :active, :boolean, required: true
  attr :disabled, :boolean, default: false
  attr :rest, :global, include: ~w(phx-click phx-target)

  slot :inner_block,
    doc: "replaces the flag and code, for an option that is not a language"

  @spec locale_button(map()) :: Phoenix.LiveView.Rendered.t()
  def locale_button(assigns) do
    ~H"""
    <button
      type="button"
      disabled={@active or @disabled}
      aria-pressed={to_string(@active)}
      title={@locale.name}
      aria-label={@locale.name}
      class={[
        "inline-flex items-center gap-1.5 px-2.5 py-1.5 rounded-token-lg text-token-xs font-black uppercase tracking-wider transition-all",
        cond do
          @active -> "bg-turquoise-600 text-white shadow-md shadow-turquoise-200/40 cursor-default"
          @disabled -> "bg-tymeslot-50 text-tymeslot-300 cursor-not-allowed opacity-60"
          true -> "text-tymeslot-500 hover:bg-tymeslot-50 hover:text-tymeslot-900 cursor-pointer"
        end
      ]}
      {@rest}
    >
      <%= if @inner_block != [] do %>
        {render_slot(@inner_block)}
      <% else %>
        <.safe_flag country_code={@locale.country_code} class="w-5 h-auto rounded-xs" />
        <span>{@locale.code}</span>
      <% end %>
    </button>
    """
  end
end
