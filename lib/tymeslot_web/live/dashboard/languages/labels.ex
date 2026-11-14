defmodule TymeslotWeb.Dashboard.Languages.Labels do
  @moduledoc """
  The wording the Languages page and the translation editor share: a
  language's own name, and the label of each kind of translatable text
  (`Tymeslot.ContentTranslations.kind/0`).
  """
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Locales

  @doc """
  A supported language's name, as the language switcher shows it (in that
  language). An unknown code comes back upper-cased.
  """
  @spec language_name(String.t()) :: String.t()
  def language_name(code) do
    case Enum.find(Locales.supported(), &(&1.code == code)) do
      %{name: name} -> name
      nil -> String.upcase(to_string(code))
    end
  end

  @doc "The supported languages as `<.select>` options, `{name, code}`, less `except`."
  @spec language_options([String.t()]) :: [{String.t(), String.t()}]
  def language_options(except \\ []) do
    for %{code: code, name: name} <- Locales.supported(), code not in except, do: {name, code}
  end

  @doc "The label of a translatable text of `kind`."
  @spec field_label(Tymeslot.ContentTranslations.kind()) :: String.t()
  def field_label(:name), do: dgettext("dashboard_languages", "Name")
  def field_label(:description), do: dgettext("dashboard_languages", "Description")
  def field_label(:booking_heading), do: dgettext("dashboard_languages", "Heading")
  def field_label(:booking_greeting), do: dgettext("dashboard_languages", "Greeting")
  def field_label(:booking_instruction), do: dgettext("dashboard_languages", "Instruction")
  def field_label(:headline), do: dgettext("dashboard_languages", "Headline")
  def field_label(:bio), do: dgettext("dashboard_languages", "Bio")
  def field_label(:question_label), do: dgettext("dashboard_languages", "Question")
  def field_label(:question_help_text), do: dgettext("dashboard_languages", "Help text")
  def field_label(:question_body), do: dgettext("dashboard_languages", "Note text")
  def field_label(:option_label), do: dgettext("dashboard_languages", "Answer option")
  def field_label(:location_label), do: dgettext("dashboard_languages", "Location name")
  def field_label(:location_details), do: dgettext("dashboard_languages", "Location details")
end
