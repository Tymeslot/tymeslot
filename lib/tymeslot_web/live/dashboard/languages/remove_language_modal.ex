defmodule TymeslotWeb.Dashboard.Languages.RemoveLanguageModal do
  @moduledoc """
  Confirmation before a language is unticked on the Languages page, which
  only happens while the organiser chooses the languages themselves: the
  booking page stops offering it. Its translations are kept, so ticking the
  language again brings them back
  (`Tymeslot.Profiles.ProfileSchema.booking_languages_changeset/2`).
  Its events go to the owning `LanguagesComponent` (`@myself`).
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Dashboard.Languages.Labels

  attr :locale, :string, required: true
  attr :myself, :any, required: true

  @spec remove_language_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def remove_language_modal(assigns) do
    assigns = assign(assigns, :language, Labels.language_name(assigns.locale))

    ~H"""
    <.confirm_modal
      id="remove-language-modal"
      show
      title={dgettext("dashboard_languages", "Remove %{language}?", language: @language)}
      confirm_label={dgettext("dashboard_languages", "Remove language")}
      on_cancel={JS.push("cancel_remove", target: @myself)}
      on_confirm={JS.push("confirm_remove", target: @myself)}
      data-testid="confirm-remove-language"
    >
      <p data-testid="remove-language-effect">
        {dgettext(
          "dashboard_languages",
          "Your booking page will no longer be offered in %{language}: invitees can choose only the languages you keep.",
          language: @language
        )}
      </p>
      <p>
        {dgettext(
          "dashboard_languages",
          "Your %{language} translations are kept: tick the language again and they come back.",
          language: @language
        )}
      </p>
    </.confirm_modal>
    """
  end
end
