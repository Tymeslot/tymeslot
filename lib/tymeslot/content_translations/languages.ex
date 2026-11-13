defmodule Tymeslot.ContentTranslations.Languages do
  @moduledoc """
  The booking languages of an organiser, one account-wide setting on the
  profile shared by every booking page:

    * the **original** language, the one their texts are written in
      (`content_locale`, `original/1`), always offered;
    * the **translation** languages (`translation_locales`), the only ones
      their texts are translated into;
    * whether the booking page is offered in **every** interface language
      (`offer_all_locales`, today's behaviour and the default) or only in the
      original and the translation languages.

  Accepts a profile struct or a plain map (a demo persona, which carries none
  of these fields and so offers everything in the fallback language).
  """

  alias Tymeslot.Locales

  @doc """
  The language the organiser's texts are written in: `content_locale`, which
  saving the booking languages always sets
  (`Tymeslot.Profiles.update_booking_languages/2`).

  Unset, it is the booking pages' fallback, which an admin can change. A
  fallback since moved onto one of the organiser's translation languages
  cannot be their original (those texts are translations, and stay shown),
  so the first supported language they do not translate into stands in.
  """
  @spec original(map() | nil) :: String.t()
  def original(profile) do
    case profile && Map.get(profile, :content_locale) do
      code when is_binary(code) ->
        if Locales.acceptable?(code), do: code, else: fallback(profile)

      _unset ->
        fallback(profile)
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

  @typedoc """
  What a visitor's language may come from, highest priority first:

    * `:picked` - the language the visitor chose themselves: a `?locale=`
      on the URL, else the language switcher's choice remembered in the
      session;
    * `:booked` - the language a meeting was booked in
      (`attendee_locale`), on that meeting's own pages;
    * `:browser` - the browser's `Accept-Language` tags, highest weight
      first.
  """
  @type preferences :: [picked: term(), booked: term(), browser: [term()]]

  @doc """
  The page language for a visitor, among the languages the organiser offers
  (`offered/1`): the visitor's own pick, else the language their meeting was
  booked in, else the first browser language offered, else the original.

  A pick the organiser does not offer (one remembered from before they
  restricted their languages, or from another organiser's page) is not
  passed over for the next candidate: the visitor gets the original, the
  page's default language. `stale_pick?/2` tells the caller so, to replace
  the remembered choice.
  """
  @spec visitor_locale(map() | nil, preferences()) :: String.t()
  def visitor_locale(profile, preferences) do
    picked = Keyword.get(preferences, :picked)

    cond do
      offers?(profile, picked) ->
        picked

      Locales.acceptable?(picked) ->
        original(profile)

      true ->
        resolve(profile, [
          Keyword.get(preferences, :booked) | Keyword.get(preferences, :browser, [])
        ])
    end
  end

  @doc """
  Whether `picked`, the visitor's own choice of language, is one the
  booking page cannot be shown in, so `visitor_locale/2` set it aside for the
  original.
  """
  @spec stale_pick?(map() | nil, term()) :: boolean()
  def stale_pick?(profile, picked),
    do: Locales.acceptable?(picked) and not offers?(profile, picked)

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

  defp fallback(profile) do
    translations = translation_locales(profile)

    Enum.find(
      [Locales.booking_default_locale(), Locales.default_locale() | Locales.supported_codes()],
      Locales.booking_default_locale(),
      &(&1 not in translations)
    )
  end
end
