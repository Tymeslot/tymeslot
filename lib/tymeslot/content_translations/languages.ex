defmodule Tymeslot.ContentTranslations.Languages do
  @moduledoc """
  The booking languages of an organiser, one account-wide setting on the
  profile shared by every booking page:

    * the **original** language, the one their texts are written in
      (`content_locale`, else the booking pages' fallback), always offered;
    * the **translation** languages (`translation_locales`), the only ones
      their texts are translated into;
    * whether the booking page is offered in **every** interface language
      (`offer_all_locales`, today's behaviour and the default) or only in the
      original and the translation languages.

  Accepts a profile struct or a plain map (a demo persona, which carries none
  of these fields and so offers everything in the fallback language).
  """

  alias Tymeslot.Locales

  @doc "The language the organiser's texts are written in."
  @spec original(map() | nil) :: String.t()
  def original(profile) do
    case profile && Map.get(profile, :content_locale) do
      code when is_binary(code) -> if Locales.acceptable?(code), do: code, else: fallback()
      _unset -> fallback()
    end
  end

  @doc """
  The supported languages the organiser translates into, in their order. A
  code no longer supported is left out.
  """
  @spec translation_locales(map() | nil) :: [String.t()]
  def translation_locales(profile) do
    supported = Locales.supported_codes()

    codes = (profile && Map.get(profile, :translation_locales)) || []
    Enum.filter(codes, &(&1 in supported))
  end

  @doc "Whether the booking page is offered only in the organiser's own languages."
  @spec restricted?(map() | nil) :: boolean()
  def restricted?(profile), do: (profile && Map.get(profile, :offer_all_locales)) == false

  @doc """
  The languages the booking page is offered in: every supported language, or,
  when `restricted?/1`, the original followed by the translation languages.
  """
  @spec offered(map() | nil) :: [String.t()]
  def offered(profile) do
    if restricted?(profile) do
      Enum.uniq([original(profile) | translation_locales(profile)])
    else
      Locales.supported_codes()
    end
  end

  @doc "Whether the booking page may be shown in `locale`."
  @spec offers?(map() | nil, term()) :: boolean()
  def offers?(profile, locale) do
    Locales.acceptable?(locale) and (not restricted?(profile) or locale in offered(profile))
  end

  @doc """
  The page language for a visitor: the first of `candidates` (highest
  priority first) that is acceptable and offered, else the original.
  """
  @spec resolve(map() | nil, [term()]) :: String.t()
  def resolve(profile, candidates) when is_list(candidates),
    do: Enum.find(candidates, original(profile), &offers?(profile, &1))

  @doc """
  The language the organiser's texts are shown in on a page in `locale`:
  `locale` when it is one of their translation languages, else nil (the
  original). A language removed from the translations keeps its stored
  texts, but they are no longer shown.
  """
  @spec content_locale(map() | nil, String.t() | nil) :: String.t() | nil
  def content_locale(profile, locale) do
    if is_binary(locale) and locale != original(profile) and
         locale in translation_locales(profile),
       do: locale
  end

  defp fallback, do: Locales.booking_default_locale()
end
