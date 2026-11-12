defmodule TymeslotWeb.Dashboard.Languages.LanguageBar do
  @moduledoc """
  The row of languages at the top of a translatable form: the original
  language, then each translation language, the one being edited pressed. A
  dot on a translation language means some text of the record is missing or
  outdated in it.

  Each button pushes `choose_editing_locale` with `phx-value-locale` (empty
  for the original) to `target`.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  import TymeslotWeb.Components.FlagHelpers, only: [locale_flag: 1]

  alias TymeslotWeb.Dashboard.Languages.Labels

  attr :id, :string, required: true
  attr :original, :string, required: true
  attr :locales, :list, required: true, doc: "the translation languages, in order"

  attr :current, :string,
    default: nil,
    doc: "the translation language edited, nil for the original"

  attr :open, :list, default: [], doc: "the translation languages with texts still to do"
  attr :target, :any, required: true

  @spec language_bar(map()) :: Phoenix.LiveView.Rendered.t()
  def language_bar(assigns) do
    ~H"""
    <div
      id={@id}
      class="flex flex-wrap items-center gap-2"
      role="group"
      aria-label={dgettext("dashboard_languages", "Editing language")}
      data-testid="language-bar"
    >
      <span class="text-token-sm font-bold text-tymeslot-600">
        {dgettext("dashboard_languages", "Editing in:")}
      </span>
      <button
        type="button"
        phx-click="choose_editing_locale"
        phx-value-locale=""
        phx-target={@target}
        aria-pressed={to_string(is_nil(@current))}
        data-locale={@original}
        class={[
          "btn-tag-selector btn-tag-selector-primary inline-flex items-center gap-2",
          is_nil(@current) && "btn-tag-selector-primary--active"
        ]}
      >
        <.locale_flag locale={@original} class="w-5 h-4" />
        {Labels.language_name(@original)}
        <span class="text-token-xs font-medium text-tymeslot-500">
          {dgettext("dashboard_languages", "original")}
        </span>
      </button>
      <button
        :for={code <- @locales}
        type="button"
        phx-click="choose_editing_locale"
        phx-value-locale={code}
        phx-target={@target}
        aria-pressed={to_string(@current == code)}
        data-locale={code}
        class={[
          "btn-tag-selector btn-tag-selector-primary inline-flex items-center gap-2",
          @current == code && "btn-tag-selector-primary--active"
        ]}
      >
        <.locale_flag locale={code} class="w-5 h-4" />
        {Labels.language_name(code)}
        <span :if={code in @open} class="w-2 h-2 rounded-token-full bg-amber-500" aria-hidden="true"></span>
        <span :if={code in @open} class="sr-only">
          {dgettext("dashboard_languages", "(some texts are missing or outdated)")}
        </span>
      </button>
    </div>
    """
  end
end
