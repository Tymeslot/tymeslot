defmodule Tymeslot.ContentTranslations.AttendeeTexts do
  @moduledoc """
  The attendees' copies of a booking's snapshot strings, one per language
  they booked in, stored on the meeting as `attendee_texts`:

      %{
        "de" => %{
          "meeting_type" => ...,
          "description" => ...,
          "location" => ...,
          "custom_fields_snapshot" => [...]
        },
        "fr" => %{...}
      }

  A booking's plain columns (`meeting_type`, `description`, `location`,
  `custom_fields_snapshot`) keep the organiser's original, for the
  organiser's emails, calendar event and dashboard. An attendee's emails and
  their reschedule and cancel pages read the copy in their own locale
  (`text/3`), falling back to the original when there is none.

  The copies are keyed by locale alone because every snapshot string is the
  slot's, not the booker's: on a group meeting or a planned session all
  participants share one slot, so two participants in the same language read
  the same copy, and each participant in another language reads their own
  (`Tymeslot.Meetings.Recipient.as_seen_by/2` carries their locale).

  A copy is stored only for a locale someone booked in, that is one of the
  organiser's translation languages, and in which something was actually
  translated. A meeting with no copies stores nil.
  """

  alias Tymeslot.ContentTranslations
  alias Tymeslot.ContentTranslations.Languages
  alias Tymeslot.CustomFields.Snapshot
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles

  @keys [:meeting_type, :description, :location, :custom_fields_snapshot]

  @typedoc "One locale's copy, string-keyed (a jsonb column)."
  @type entry :: %{String.t() => term()}

  @typedoc "The stored copies, by locale."
  @type t :: %{String.t() => entry()}

  @doc "The snapshot fields an attendee copy may replace."
  @spec keys() :: [atom()]
  def keys, do: @keys

  @doc """
  The copies for a booking about to be written with `attrs` (its
  `:meeting_type`, `:description`, `:location`, `:custom_fields_snapshot`
  and `:attendee_locale`, all in the original), on `meeting_type`, owned by
  `profile`: at most the booker's own locale. `location_choice` is what the
  booker chose (`MeetingTypes.resolve_location/2`), resolved again against
  the translated meeting type and venues. Nil when there is nothing to store.
  """
  @spec build(map() | nil, map() | nil, map(), map()) :: t() | nil
  def build(nil, _profile, _attrs, _location_choice), do: nil

  def build(meeting_type, profile, attrs, location_choice) do
    with locale when is_binary(locale) <-
           Languages.content_locale(profile, attrs[:attendee_locale]),
         %{} = entry <- entry(meeting_type, locale, attrs, location_choice) do
      %{locale => entry}
    else
      _nothing_translated -> nil
    end
  end

  @doc """
  The copies of `slot`, a shared group slot, once a booker carrying
  `texts` (`build/4`) takes a seat on it: their locale's copy added when
  the slot has none in that locale yet. A copy the slot already holds is
  kept, since every booker in that locale reads the same slot, and one equal
  to the slot's own originals is not added. Nil when there are none.
  """
  @spec merge(map(), t() | nil) :: t() | nil
  def merge(slot, texts) do
    originals = originals(slot)

    (texts || %{})
    |> Map.reject(fn {_locale, entry} -> entry == originals end)
    |> Map.merge(slot.attendee_texts || %{})
    |> nil_if_empty()
  end

  @doc """
  The copies for `meeting` once a reschedule moves it: `location_attrs`
  (`Tymeslot.Bookings.RescheduleLocation`) written over its stored
  originals, and `location_choice` the booker's new choice, resolved
  against the translated meeting type and venues as `build/4` does for a
  new booking. Every locale the meeting holds a copy in is rebuilt (and
  dropped once it reads as the originals), and a one-to-one meeting's own
  attendee locale is built too, since the new location may be translated
  where the old one was not. Nil when there is nothing to store.
  """
  @spec relocated(map(), map() | nil, map(), map()) :: t() | nil
  def relocated(meeting, meeting_type, location_attrs, location_choice) do
    profile = Profiles.get_profile(meeting.organizer_user_id)

    attrs =
      meeting
      |> Map.take(@keys)
      |> Map.merge(Map.take(location_attrs, [:location]))

    meeting
    |> locales()
    |> Enum.map(
      &build(meeting_type, profile, Map.put(attrs, :attendee_locale, &1), location_choice)
    )
    |> Enum.reduce(%{}, &Map.merge(&2, &1 || %{}))
    |> nil_if_empty()
  end

  # A shared slot's `attendee_locale` is only its first booker's (or, on a
  # planned session, the default), so only a one-to-one meeting adds it.
  defp locales(%{capacity: capacity} = meeting) when is_integer(capacity) and capacity > 1,
    do: Map.keys(meeting.attendee_texts || %{})

  defp locales(meeting),
    do: Enum.uniq(Map.keys(meeting.attendee_texts || %{}) ++ [meeting.attendee_locale])

  defp entry(meeting_type, locale, attrs, location_choice) do
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

    if texts != originals(attrs), do: texts
  end

  defp originals(fields), do: Map.new(@keys, &{Atom.to_string(&1), Map.get(fields, &1)})

  defp nil_if_empty(texts) when map_size(texts) == 0, do: nil
  defp nil_if_empty(texts), do: texts

  @doc """
  `key` of `meeting` (one of `keys/0`) as a reader in `locale` sees it: the
  copy the meeting carries in that locale, otherwise the meeting's own value.
  """
  @spec text(map(), atom(), String.t() | nil) :: term()
  def text(meeting, key, locale) when key in @keys do
    case Map.get(meeting, :attendee_texts) do
      %{^locale => %{} = entry} when is_binary(locale) ->
        Map.get(entry, Atom.to_string(key), Map.get(meeting, key))

      _no_copy ->
        Map.get(meeting, key)
    end
  end

  @doc """
  `meeting` with each of `keys/0` as a reader in `locale` sees it
  (`text/3`), for a template that reads them off the meeting.
  """
  @spec as_read_in(map(), String.t() | nil) :: map()
  def as_read_in(meeting, locale) do
    Enum.reduce(@keys, meeting, fn key, acc -> Map.put(acc, key, text(meeting, key, locale)) end)
  end
end
