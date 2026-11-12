defmodule Tymeslot.ContentTranslations do
  @moduledoc """
  Translations of the texts an organiser writes for invitees: the booking page
  texts and intro on the profile, a booking page's name and texts, a meeting
  type's name, description, questions and locations, and a venue's name and
  description.

  Pure functions over the `translations` map each of those records carries:

      %{locale => %{path => %{"text" => String.t(), "source" => integer()}}}

  A path names one text: a top-level field (`"name"`), or a text inside a
  meeting type's embeds, `"custom_fields/<field id>/label"`,
  `".../help_text"`, `".../body"`,
  `"custom_fields/<field id>/options/<option key>/label"`,
  `"locations/<location id>/label"` and `"locations/<location id>/details"`.
  The embeds carry no translations of their own, so the forms that write them
  never touch this map. `source` is `:erlang.phash2/1` of the original text the
  translation was written against, so a changed original shows as
  `:outdated` (`status/3`).

  A blank translation, or none, falls back to the original, and a blank
  original stays blank: there is nothing to translate.

  Which languages a profile offers is `Tymeslot.ContentTranslations.Languages`;
  listing, counting and saving an organiser's translations is
  `Tymeslot.ContentTranslations.Catalogue`.
  """

  import Ecto.Changeset

  alias Tymeslot.BookingPages.BookingPageSchema
  alias Tymeslot.Locales
  alias Tymeslot.MeetingTypes.LocationSelection
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.MeetingTypes.Slugs
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Validation.Constraints
  alias Tymeslot.Venues.VenueSchema

  @typedoc "A path naming one translatable text of a record."
  @type path :: String.t()

  @typedoc """
  What a text is, so the dashboard can label it. `:option_label` is a
  question's answer option.
  """
  @type kind ::
          :name
          | :description
          | :booking_heading
          | :booking_greeting
          | :booking_instruction
          | :headline
          | :bio
          | :question_label
          | :question_help_text
          | :question_body
          | :option_label
          | :location_label
          | :location_details

  @typedoc """
  One translatable text of a record: its path, its kind, the original text,
  the longest a translation may be, and whether it spans several lines (a
  textarea rather than an input). `context` is the original label of the
  question an option or a question text belongs to, or of the location a
  location text belongs to; nil for a top-level field.
  """
  @type field :: %{
          path: path(),
          kind: kind(),
          original: String.t() | nil,
          max_length: pos_integer(),
          multiline: boolean(),
          context: String.t() | nil
        }

  @type status :: :not_needed | :missing | :translated | :outdated

  # A note question's body has no cap of its own; a translation gets a
  # generous one so the column cannot grow without bound.
  @question_body_max_length 2000

  @booking_text_fields [:booking_heading, :booking_greeting, :booking_instruction]

  @doc """
  The top-level translatable fields of each translated record, as
  `{field, kind, max_length, multiline}`. A meeting type's questions and
  locations are expanded per record by `fields/1`.
  """
  @spec field_table() :: %{module() => [{atom(), kind(), pos_integer(), boolean()}]}
  def field_table do
    booking_texts = [
      {:booking_heading, :booking_heading, Constraints.booking_heading_max_length(), false},
      {:booking_greeting, :booking_greeting, Constraints.booking_welcome_line_max_length(),
       false},
      {:booking_instruction, :booking_instruction, Constraints.booking_welcome_line_max_length(),
       false}
    ]

    %{
      ProfileSchema =>
        booking_texts ++
          [
            {:headline, :headline, Constraints.profile_headline_max_length(), false},
            {:bio, :bio, Constraints.profile_bio_max_length(), true}
          ],
      BookingPageSchema => [
        {:name, :name, BookingPageSchema.name_max_length(), false} | booking_texts
      ],
      MeetingTypeSchema => [
        {:name, :name, Constraints.name_length_range().last, false},
        {:description, :description, Constraints.description_max_length(), true}
      ],
      VenueSchema => [
        {:name, :name, VenueSchema.name_max_length(), false},
        {:description, :description, VenueSchema.description_max_length(), true}
      ]
    }
  end

  @doc "Whether `record` is one whose texts can be translated."
  @spec translatable?(term()) :: boolean()
  def translatable?(%module{}), do: Map.has_key?(field_table(), module)
  def translatable?(_record), do: false

  @doc """
  Every translatable text of `record`, in display order: its top-level
  fields, then (for a meeting type) each question's texts in question order
  and each location's. A record that is not translatable has none.
  """
  @spec fields(struct()) :: [field()]
  def fields(%module{} = record) do
    case Map.fetch(field_table(), module) do
      {:ok, specs} -> top_level_fields(record, specs) ++ nested_fields(record)
      :error -> []
    end
  end

  def fields(_record), do: []

  defp top_level_fields(record, specs) do
    Enum.map(specs, fn {field, kind, max_length, multiline} ->
      field(Atom.to_string(field), kind, Map.get(record, field), max_length, multiline, nil)
    end)
  end

  defp nested_fields(%MeetingTypeSchema{} = meeting_type) do
    question_fields(meeting_type.custom_fields || []) ++
      location_fields(meeting_type.locations || [])
  end

  defp nested_fields(_record), do: []

  defp question_fields(questions) do
    questions
    |> Enum.sort_by(&(&1.position || 0))
    |> Enum.flat_map(fn question ->
      base = "custom_fields/#{question.id}"
      context = question.label

      [field(base <> "/label", :question_label, question.label, 120, false, nil)] ++
        [
          field(
            base <> "/help_text",
            :question_help_text,
            question.help_text,
            300,
            false,
            context
          )
        ] ++
        body_field(question, base, context) ++
        Enum.map(question.options || [], fn option ->
          field(
            "#{base}/options/#{option.key}/label",
            :option_label,
            option.label,
            80,
            false,
            context
          )
        end)
    end)
  end

  defp body_field(%{type: "note", body: body}, base, context),
    do: [field(base <> "/body", :question_body, body, @question_body_max_length, true, context)]

  defp body_field(_question, _base, _context), do: []

  # A video or in-person location is its label alone: a video option's
  # provider and an in-person option's venues say the rest, and a venue is
  # translated on its own. A phone or custom location's details are free text.
  defp location_fields(locations) do
    locations
    |> Enum.sort_by(&(&1.position || 0))
    |> Enum.flat_map(fn location ->
      base = "locations/#{location.id}"
      label = location_label_field(location, base)

      if location.kind in [:phone, :custom] do
        label ++
          [
            field(
              base <> "/details",
              :location_details,
              location.details,
              500,
              true,
              location.label
            )
          ]
      else
        label
      end
    end)
  end

  # A label still reading as its kind's English default ("In person") is
  # already shown in the visitor's language, so there is nothing to translate.
  defp location_label_field(location, base) do
    if LocationSelection.default_label?(location),
      do: [],
      else: [field(base <> "/label", :location_label, location.label, 120, false, nil)]
  end

  defp field(path, kind, original, max_length, multiline, context) do
    %{
      path: path,
      kind: kind,
      original: original,
      max_length: max_length,
      multiline: multiline,
      context: context
    }
  end

  @doc """
  The original text at `path` of `record`, or nil when the record has no
  such text (a deleted question, an option key that changed).
  """
  @spec original(struct(), path()) :: String.t() | nil
  def original(record, path) do
    case Enum.find(fields(record), &(&1.path == path)) do
      %{original: original} -> original
      nil -> nil
    end
  end

  @doc """
  The text at `path` of `record` in `locale`: the translation when there is a
  non-blank one and the original is not blank, otherwise the original.
  """
  @spec text(struct(), path(), String.t() | nil) :: String.t() | nil
  def text(record, path, locale) do
    pick(original(record, path), entries(record, locale), path)
  end

  @doc """
  The stored translation at `path` of `record` in `locale`, or nil.
  """
  @spec translation(struct() | map(), String.t() | nil, path()) :: String.t() | nil
  def translation(record, locale, path) do
    case entries(record, locale) do
      %{^path => %{"text" => text}} when is_binary(text) -> text
      _none -> nil
    end
  end

  @doc """
  How the text at `path` of `record` stands in `locale`:

    * `:not_needed` - the original is blank, so there is nothing to translate;
    * `:missing` - no translation;
    * `:outdated` - translated, but the original has changed since;
    * `:translated` - translated against the current original.
  """
  @spec status(struct(), path(), String.t()) :: status()
  def status(record, path, locale),
    do: status_of(original(record, path), Map.get(entries(record, locale), path))

  @doc """
  `status/3` for a `field/0` of `record`, without looking the field up again.
  """
  @spec field_status(struct(), field(), String.t()) :: status()
  def field_status(record, %{path: path, original: original}, locale),
    do: status_of(original, Map.get(entries(record, locale), path))

  defp status_of(original, entry) do
    cond do
      blank?(original) -> :not_needed
      not match?(%{"text" => text} when is_binary(text) and text != "", entry) -> :missing
      entry["source"] != source(original) -> :outdated
      true -> :translated
    end
  end

  @doc """
  `record`'s translations with the text at `path` in `locale` set to `text`,
  written against the current original. A blank `text` deletes the path (and
  the locale, once it holds nothing). The text is trimmed, its line breaks
  normalised to `\\n` and its null bytes stripped; lengths are checked by
  `changeset/2`, not here.
  """
  @spec put(struct(), String.t(), path(), String.t() | nil) :: map()
  def put(record, locale, path, text) do
    translations = Map.get(record, :translations) || %{}
    entries = Map.get(translations, locale, %{})

    entries =
      case clean(text) do
        nil ->
          Map.delete(entries, path)

        cleaned ->
          Map.put(entries, path, %{"text" => cleaned, "source" => source(original(record, path))})
      end

    if entries == %{},
      do: Map.delete(translations, locale),
      else: Map.put(translations, locale, entries)
  end

  @doc """
  `translations` without the paths `record` no longer has (a deleted
  question, a removed location, an option whose key changed), and without
  the languages no longer supported: texts nobody can be shown any more,
  which `changeset/2` would otherwise refuse on every later save.
  """
  @spec prune(map(), struct()) :: map()
  def prune(translations, record) do
    paths = record |> fields() |> MapSet.new(& &1.path)
    supported = Locales.supported_codes()

    translations
    |> Enum.filter(fn {locale, entries} -> locale in supported and is_map(entries) end)
    |> Enum.map(fn {locale, entries} ->
      {locale, Map.filter(entries, fn {path, _entry} -> path in paths end)}
    end)
    |> Enum.reject(fn {_locale, entries} -> entries == %{} end)
    |> Map.new()
  end

  @doc """
  A changeset writing `translations` to `record`, and only that.

  Each locale must be a supported one, each path one of the record's
  (`fields/1`), and each text a non-blank string no longer than its
  original's cap. An error is added on `:translations`, with the offending
  path in its `:path` option, so a form can show it beside the field.
  """
  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(record, translations) when is_map(translations) do
    caps = record |> fields() |> Map.new(&{&1.path, &1.max_length})

    record
    |> cast(%{translations: translations}, [:translations])
    |> validate_change(:translations, fn :translations, value -> errors(value, caps) end)
  end

  defp errors(translations, caps) do
    supported = Locales.supported_codes()

    Enum.flat_map(translations, fn
      {locale, entries} when is_map(entries) ->
        if locale in supported,
          do: Enum.flat_map(entries, &entry_errors(&1, caps)),
          else: [translations: {"is not a supported language", locale: locale}]

      {locale, _entries} ->
        [translations: {"is invalid", locale: locale}]
    end)
  end

  defp entry_errors({path, %{"text" => text, "source" => source}}, caps)
       when is_binary(text) and is_integer(source) do
    case Map.fetch(caps, path) do
      :error ->
        [translations: {"is invalid", path: path}]

      {:ok, max} ->
        if String.length(text) > max,
          do: [
            translations:
              {"should be at most %{count} character(s)",
               path: path, count: max, validation: :length, kind: :max, type: :string}
          ],
          else: []
    end
  end

  defp entry_errors({path, _entry}, _caps), do: [translations: {"is invalid", path: path}]

  @doc """
  `record` (or each record of a list) with its translatable texts in
  `locale`, the same struct back: a profile's booking texts and intro, the
  booking page it presents (whose texts the profile carries,
  `Tymeslot.BookingPages.apply_to_profile/2`) and its virtual meeting types; a
  booking page's; a meeting type's name, description, questions with their
  options, and locations; a venue's.

  A nil locale, a plain map (a demo persona), or a struct without
  translations comes back unchanged.
  """
  @spec localise(term(), String.t() | nil) :: term()
  def localise(records, locale) when is_list(records),
    do: Enum.map(records, &localise(&1, locale))

  def localise(record, nil), do: record

  def localise(%ProfileSchema{} = profile, locale) do
    entries = entries(profile, locale)

    profile
    |> replace_fields(entries, [:headline, :bio])
    |> localise_presented_page(entries, locale)
    |> Map.update!(:meeting_types, &localise_list(&1, locale))
  end

  def localise(%MeetingTypeSchema{} = meeting_type, locale) do
    entries = entries(meeting_type, locale)

    # A type without a custom slug is addressed by its name's slug: pinned
    # here, so the translated name does not move its address.
    meeting_type
    |> Map.put(:slug, Slugs.effective_slug(meeting_type))
    |> replace_fields(entries, [:name, :description])
    |> Map.put(
      :custom_fields,
      Enum.map(meeting_type.custom_fields || [], &localise_question(&1, entries))
    )
    |> Map.put(
      :locations,
      Enum.map(meeting_type.locations || [], &localise_location(&1, entries))
    )
  end

  def localise(%module{} = record, locale) when module in [BookingPageSchema, VenueSchema] do
    fields = for {field, _kind, _max, _multiline} <- Map.fetch!(field_table(), module), do: field
    replace_fields(record, entries(record, locale), fields)
  end

  def localise(record, _locale), do: record

  defp localise_list(records, locale) when is_list(records), do: localise(records, locale)
  defp localise_list(other, _locale), do: other

  # A profile presenting one of its booking pages carries that page's booking
  # texts in its own fields, so they are translated from the page's map.
  defp localise_presented_page(
         %{booking_page: %BookingPageSchema{} = page} = profile,
         _entries,
         locale
       ) do
    page = localise(page, locale)

    profile
    |> Map.put(:booking_page, page)
    |> struct(Map.take(page, @booking_text_fields))
  end

  defp localise_presented_page(profile, entries, _locale),
    do: replace_fields(profile, entries, @booking_text_fields)

  defp localise_question(question, entries) do
    base = "custom_fields/#{question.id}"

    %{
      question
      | label: pick(question.label, entries, base <> "/label"),
        help_text: pick(question.help_text, entries, base <> "/help_text"),
        body: pick(question.body, entries, base <> "/body"),
        options:
          Enum.map(question.options || [], fn option ->
            %{option | label: pick(option.label, entries, "#{base}/options/#{option.key}/label")}
          end)
    }
  end

  defp localise_location(location, entries) do
    base = "locations/#{location.id}"

    %{
      location
      | label: pick(location.label, entries, base <> "/label"),
        details: pick(location.details, entries, base <> "/details")
    }
  end

  defp replace_fields(record, entries, fields) do
    Enum.reduce(fields, record, fn field, acc ->
      Map.put(acc, field, pick(Map.get(acc, field), entries, Atom.to_string(field)))
    end)
  end

  defp pick(original, entries, path) do
    with false <- blank?(original),
         %{"text" => text} when is_binary(text) and text != "" <- Map.get(entries, path) do
      text
    else
      _untranslated -> original
    end
  end

  defp entries(_record, nil), do: %{}

  defp entries(record, locale) do
    case Map.get(record, :translations) do
      %{^locale => entries} when is_map(entries) -> entries
      _none -> %{}
    end
  end

  @doc "The fingerprint of an original text a translation is written against."
  @spec source(String.t() | nil) :: integer()
  def source(original), do: :erlang.phash2(original)

  defp clean(nil), do: nil

  defp clean(text) when is_binary(text) do
    cleaned =
      text
      |> String.replace("\x00", "")
      |> String.replace(~r/\r\n?/, "\n")
      |> String.trim()

    if cleaned == "", do: nil, else: cleaned
  end

  defp blank?(nil), do: true
  defp blank?(text) when is_binary(text), do: String.trim(text) == ""
  defp blank?(_other), do: false
end
