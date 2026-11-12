defmodule Tymeslot.ContentTranslations.AttendeeTexts do
  @moduledoc """
  The attendee's copies of a booking's snapshot strings, in the attendee's
  language, stored on the meeting as `attendee_texts`:

      %{
        "locale" => "de",
        "meeting_type" => ...,
        "description" => ...,
        "location" => ...,
        "custom_fields_snapshot" => [...]
      }

  A booking's plain columns (`meeting_type`, `description`, `location`,
  `custom_fields_snapshot`) keep the organiser's original, for the
  organiser's emails, calendar event and dashboard. The attendee's emails and
  their reschedule and cancel pages read the copy when they are in its
  locale (`text/3`).

  The copy is stored only when the attendee's language is one of the
  organiser's translation languages and something was actually translated.
  """

  alias Tymeslot.ContentTranslations
  alias Tymeslot.ContentTranslations.Languages
  alias Tymeslot.CustomFields.Snapshot
  alias Tymeslot.MeetingTypes

  @keys [:meeting_type, :description, :location, :custom_fields_snapshot]

  @typedoc "The stored copy, string-keyed (a jsonb column)."
  @type t :: %{String.t() => term()}

  @doc "The snapshot fields an attendee copy may replace."
  @spec keys() :: [atom()]
  def keys, do: @keys

  @doc """
  The attendee copy for a booking about to be written with `attrs` (its
  `:meeting_type`, `:description`, `:location`, `:custom_fields_snapshot`
  and `:attendee_locale`, all in the original), on `meeting_type`, owned by
  `profile`. `location_choice` is what the booker chose
  (`MeetingTypes.resolve_location/2`), resolved again against the
  translated meeting type and venues. Nil when there is nothing to store.
  """
  @spec build(map() | nil, map() | nil, map(), map()) :: t() | nil
  def build(nil, _profile, _attrs, _location_choice), do: nil

  def build(meeting_type, profile, attrs, location_choice) do
    case Languages.content_locale(profile, attrs[:attendee_locale]) do
      nil -> nil
      locale -> translated(meeting_type, locale, attrs, location_choice)
    end
  end

  defp translated(meeting_type, locale, attrs, location_choice) do
    localised = ContentTranslations.localise(meeting_type, locale)

    location =
      localised
      |> MeetingTypes.resolve_location(Map.put(location_choice, :content_locale, locale))
      |> Map.get(:location)

    texts = %{
      "meeting_type" => localised.name,
      "description" => localised.description || "",
      "location" => if(is_nil(attrs[:location]), do: nil, else: location),
      "custom_fields_snapshot" =>
        Snapshot.overlay_texts(attrs[:custom_fields_snapshot] || [], localised)
    }

    originals = Map.new(@keys, &{Atom.to_string(&1), Map.get(attrs, &1)})

    if texts == originals, do: nil, else: Map.put(texts, "locale", locale)
  end

  @doc """
  `key` of `meeting` (one of `keys/0`) as a reader in `locale` sees it: the
  attendee copy when the meeting carries one in that locale, otherwise the
  meeting's own value.
  """
  @spec text(map(), atom(), String.t() | nil) :: term()
  def text(meeting, key, locale) when key in @keys do
    case Map.get(meeting, :attendee_texts) do
      %{"locale" => ^locale} = texts when is_binary(locale) ->
        Map.get(texts, Atom.to_string(key), Map.get(meeting, key))

      _no_copy ->
        Map.get(meeting, key)
    end
  end
end
