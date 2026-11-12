defmodule TymeslotWeb.Dashboard.Languages.LanguageBar do
  @moduledoc """
  The row of languages at the top of a translatable form, a segmented
  control (`CoreComponents.Navigation.segmented_control/1`): the original
  language, then each translation language, the one being edited pressed.
  A translation language with texts of the record still missing or outdated
  in it carries their count, in amber.

  Each option pushes `choose_editing_locale` with `phx-value-locale` to
  `target`; the original sends its own code, which is not a translation
  language, so it reads as the original. Each option's id is
  `<id>-<locale>`.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Components.CoreComponents.Navigation
  alias TymeslotWeb.Dashboard.Languages.Labels

  attr :id, :string, required: true
  attr :original, :string, required: true
  attr :locales, :list, required: true, doc: "the translation languages, in order"

  attr :current, :string,
    default: nil,
    doc: "the translation language edited, nil for the original"

  attr :open, :map,
    default: %{},
    doc: "for each translation language, how many texts are missing or outdated in it"

  attr :target, :any, required: true

  @spec language_bar(map()) :: Phoenix.LiveView.Rendered.t()
  def language_bar(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-x-3 gap-y-2" data-testid="language-bar">
      <span class="text-token-sm font-bold text-tymeslot-600" aria-hidden="true">
        {dgettext("dashboard_languages", "Editing in:")}
      </span>
      <Navigation.segmented_control
        id={@id}
        value={@current || @original}
        on_change="choose_editing_locale"
        param="locale"
        target={@target}
        aria_label={dgettext("dashboard_languages", "Editing language")}
        overflow={:wrap}
      >
        <:option
          value={@original}
          label={
            dgettext("dashboard_languages", "%{language} (original)",
              language: Labels.language_name(@original)
            )
          }
        />
        <:option
          :for={code <- @locales}
          value={code}
          label={Labels.language_name(code)}
          count={if open_count(@open, code) > 0, do: open_count(@open, code)}
          attention
        >
          <span :if={open_count(@open, code) > 0} class="sr-only">
            {dngettext(
              "dashboard_languages",
              "(%{count} text missing or outdated)",
              "(%{count} texts missing or outdated)",
              open_count(@open, code)
            )}
          </span>
        </:option>
      </Navigation.segmented_control>
    </div>
    """
  end

  defp open_count(open, code), do: Map.get(open, code, 0)
end
