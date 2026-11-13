defmodule TymeslotWeb.Dashboard.Languages.RemoveLanguageModal do
  @moduledoc """
  Confirmation before a translation language is removed from the Languages
  page. What removing it means for invitees depends on which languages the
  organiser offers: offering only their own, the booking page stops offering
  it; offering every language, the page stays available in it, with the
  original texts (`Tymeslot.ContentTranslations.Languages.content_locale/2`).
  Either way its translations are kept, so adding the language again brings
  them back (`Tymeslot.Profiles.ProfileSchema.booking_languages_changeset/2`).
  Its events go to the owning `LanguagesComponent` (`@myself`).
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Dashboard.Languages.Labels

  attr :locale, :string, required: true
  attr :original, :string, required: true, doc: "the original language"
  attr :offer_all, :boolean, required: true, doc: "whether every language is offered"
  attr :myself, :any, required: true

  @spec remove_language_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def remove_language_modal(assigns) do
    assigns =
      assign(assigns,
        language: Labels.language_name(assigns.locale),
        original_language: Labels.language_name(assigns.original)
      )

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
      <p :if={not @offer_all} data-testid="remove-language-effect">
        {dgettext(
          "dashboard_languages",
          "Your booking page will no longer be offered in %{language}: invitees can choose only the languages you keep.",
          language: @language
        )}
      </p>
      <p :if={@offer_all} data-testid="remove-language-effect">
        {dgettext(
          "dashboard_languages",
          "You offer your booking page in every language, so invitees can still choose %{language}, but they will see your texts in %{original}.",
          language: @language,
          original: @original_language
        )}
      </p>
      <p>
        {dgettext(
          "dashboard_languages",
          "Your %{language} translations are kept: add the language again and they come back.",
          language: @language
        )}
      </p>
    </.confirm_modal>
    """
  end
end
