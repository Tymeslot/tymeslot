defmodule Tymeslot.ContentTranslations.Catalogue do
  @moduledoc """
  Everything an organiser can translate, how far each translation language
  has got, and saving translations, all scoped to the organiser's own user id.

  An **entity** is one translated record as the dashboard shows it:

      %{
        kind: :profile | :booking_page | :meeting_type | :venue,
        id: integer(),
        name: String.t() | nil,   # the record's own name; nil for the profile
        record: struct(),         # for ContentTranslations.field_status/3 and translation/3
        fields: [ContentTranslations.field()]
      }

  `{kind, id}` addresses an entity in `save/4`. The profile appears twice in
  `items/1`, once with its booking page texts and once with its intro, under
  the same `{:profile, id}`.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.Changeset
  alias Tymeslot.BookingPages
  alias Tymeslot.ContentTranslations
  alias Tymeslot.ContentTranslations.Languages
  alias Tymeslot.ContentTranslations.TranslationQueries
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Repo
  alias Tymeslot.Venues

  @type kind :: :profile | :booking_page | :meeting_type | :venue
  @type entity :: %{
          kind: kind(),
          id: integer(),
          name: String.t() | nil,
          record: struct(),
          fields: [ContentTranslations.field()]
        }
  @type items :: %{
          booking_texts: [entity()],
          intro: [entity()],
          meeting_types: [entity()],
          venues: [entity()]
        }
  @type progress :: %{
          total: non_neg_integer(),
          translated: non_neg_integer(),
          outdated: non_neg_integer(),
          missing: non_neg_integer()
        }

  @booking_text_paths ~w(booking_heading booking_greeting booking_instruction)
  @intro_paths ~w(headline bio)

  @doc """
  Every translatable entity of the user, grouped:

    * `:booking_texts` - the profile's booking page texts, then each booking
      page's name and texts;
    * `:intro` - the profile's headline and bio;
    * `:meeting_types` - each meeting type not archived, with its questions
      and locations;
    * `:venues` - each saved venue.

  A user without a profile has nothing to translate.
  """
  @spec items(integer()) :: items()
  def items(user_id) when is_integer(user_id) do
    case Profiles.get_profile_by_user_id(user_id) do
      {:ok, profile} ->
        %{
          booking_texts: [
            entity(:profile, profile, nil, @booking_text_paths)
            | Enum.map(BookingPages.list(profile.id), &entity(:booking_page, &1))
          ],
          intro: [entity(:profile, profile, nil, @intro_paths)],
          meeting_types:
            user_id
            |> MeetingTypes.get_all_meeting_types()
            |> Enum.reject(& &1.is_archived)
            |> Enum.map(&entity(:meeting_type, &1)),
          venues: user_id |> Venues.list_venues() |> Enum.map(&entity(:venue, &1))
        }

      {:error, :not_found} ->
        %{booking_texts: [], intro: [], meeting_types: [], venues: []}
    end
  end

  @doc """
  How far each of `locales` has got across `items` (`items/1`, read once by
  the caller), counting only texts whose original is not blank: `translated`
  against the current original, `outdated` (translated, but the original
  changed since) and `missing`.
  """
  @spec progress(items(), [String.t()]) :: %{String.t() => progress()}
  def progress(items, locales) when is_map(items) and is_list(locales) do
    fields =
      for {_group, entities} <- items,
          entity <- entities,
          field <- entity.fields,
          do: {entity.record, field}

    Map.new(locales, &{&1, locale_progress(fields, &1)})
  end

  defp locale_progress(fields, locale) do
    statuses =
      for {record, field} <- fields,
          status = ContentTranslations.field_status(record, field, locale),
          status != :not_needed,
          do: status

    counts = Enum.frequencies(statuses)

    %{
      total: length(statuses),
      translated: Map.get(counts, :translated, 0),
      outdated: Map.get(counts, :outdated, 0),
      missing: Map.get(counts, :missing, 0)
    }
  end

  @doc """
  The user's entity `{kind, id}` as stored now, with all of its fields, or
  `{:error, :not_found}` for one the user does not own. A form that edits the
  record reads it here so its translations are never a stale copy.
  """
  @spec get(integer(), {kind(), integer() | String.t()}) ::
          {:ok, entity()} | {:error, :not_found}
  def get(user_id, {kind, id}) when is_integer(user_id) do
    with {:ok, profile} <- fetch_profile(user_id),
         {:ok, record} <- fetch(kind, id, user_id, profile) do
      {:ok, entity(kind, record)}
    end
  end

  @doc """
  Saves `texts` (`%{path => text}`) as the `locale` translations of the
  user's entity `{kind, id}`, and returns it with all of its fields.

  A blank text deletes that translation; a path the entity does not have is
  ignored, and translations of paths it no longer has (a deleted question)
  are dropped. `locale` must be one of the user's translation languages.

  Returns `{:error, :not_found}` for an entity the user does not own, and
  `{:error, changeset}` for a language that is not a translation language or
  a text over its cap (the error on `:translations` names the `:path`).
  """
  @spec save(integer(), {kind(), integer() | String.t()}, String.t(), %{String.t() => String.t()}) ::
          {:ok, entity()} | {:error, Ecto.Changeset.t() | :not_found}
  def save(user_id, {kind, id}, locale, texts)
      when is_integer(user_id) and is_binary(locale) and is_map(texts) do
    with {:ok, profile} <- fetch_profile(user_id),
         {:ok, record} <- fetch(kind, id, user_id, profile) do
      Repo.transaction(fn -> save_locked(record, kind, locale, texts, profile) end)
    end
  end

  # The whole map is written back, so it is read under the row's lock: two
  # saves at once (two languages, or two tabs) would otherwise each write
  # back the map as they found it, and the later would drop the earlier's
  # texts.
  defp save_locked(record, kind, locale, texts, profile) do
    with {:ok, record} <- TranslationQueries.lock(record),
         {:ok, saved} <-
           TranslationQueries.update(build_changeset(record, locale, texts, profile)) do
      entity(kind, saved)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp build_changeset(record, locale, texts, profile) do
    paths = record |> ContentTranslations.fields() |> MapSet.new(& &1.path)

    translations =
      texts
      |> Enum.filter(fn {path, _text} -> path in paths end)
      |> Enum.reduce(record, fn {path, text}, acc ->
        %{acc | translations: ContentTranslations.put(acc, locale, path, text)}
      end)
      |> Map.fetch!(:translations)
      |> ContentTranslations.prune(record)

    changeset = ContentTranslations.changeset(record, translations)

    if locale in Languages.translation_locales(profile),
      do: changeset,
      else:
        Changeset.add_error(
          changeset,
          :translations,
          dgettext_noop("errors", "is not a translation language"),
          locale: locale
        )
  end

  defp fetch_profile(user_id) do
    case Profiles.get_profile_by_user_id(user_id) do
      {:ok, profile} -> {:ok, profile}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp fetch(:profile, id, _user_id, %ProfileSchema{id: profile_id} = profile) do
    if parse_id(id) == profile_id, do: {:ok, profile}, else: {:error, :not_found}
  end

  defp fetch(:booking_page, id, _user_id, profile) do
    case parse_id(id) do
      nil -> {:error, :not_found}
      page_id -> BookingPages.fetch(profile.id, page_id)
    end
  end

  defp fetch(:meeting_type, id, user_id, _profile) do
    with meeting_type_id when is_integer(meeting_type_id) <- parse_id(id),
         %{} = meeting_type <- MeetingTypes.get_meeting_type(meeting_type_id, user_id) do
      {:ok, meeting_type}
    else
      _missing -> {:error, :not_found}
    end
  end

  defp fetch(:venue, id, user_id, _profile), do: Venues.get_venue(user_id, id)
  defp fetch(_kind, _id, _user_id, _profile), do: {:error, :not_found}

  defp parse_id(id) when is_integer(id), do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _not_an_id -> nil
    end
  end

  defp parse_id(_id), do: nil

  defp entity(kind, record, name \\ :own, paths \\ nil) do
    fields = ContentTranslations.fields(record)
    fields = if paths, do: Enum.filter(fields, &(&1.path in paths)), else: fields

    %{
      kind: kind,
      id: record.id,
      name: if(name == :own, do: Map.get(record, :name), else: name),
      record: record,
      fields: fields
    }
  end
end
