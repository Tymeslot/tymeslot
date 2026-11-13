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
  translated. A text a copy leaves out, or holds as nil, reads as the
  original. A meeting with no copies stores nil.
  """

  alias Tymeslot.Bookings.BookingTitle
  alias Tymeslot.ContentTranslations
  alias Tymeslot.ContentTranslations.Languages
  alias Tymeslot.CustomFields.Snapshot
  alias Tymeslot.Locales
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
  The copies of `slot`, a shared group slot, once a booker takes a seat on
  it with `attrs`, the attributes their booking was built with (`build/4`'s,
  carrying `:attendee_texts`): their locale's copy added when the slot has
  none in that locale yet. A copy the slot already holds is kept, since every
  booker in that locale reads the same slot.

  The booker's copy was built from the texts as they read when they booked,
  which need not be the slot's: the organiser may have renamed the type
  since the slot was made, or the booker carried their own questions over
  from another slot (a seat move). A text whose original differs from the
  slot's is left out of the copy, so it reads as the slot's original, and a
  copy left reading as the slot's originals is not added. Nil when there are
  none.
  """
  @spec merge(map(), map()) :: t() | nil
  def merge(slot, attrs) do
    slot_originals = originals(slot)
    booker_originals = originals(attrs)

    (attrs[:attendee_texts] || %{})
    |> Map.new(fn {locale, entry} ->
      {locale,
       Map.filter(entry, fn {key, _text} -> booker_originals[key] == slot_originals[key] end)}
    end)
    |> Map.reject(fn {_locale, entry} -> redundant?(entry, slot_originals) end)
    |> Map.merge(slot.attendee_texts || %{})
    |> nil_if_empty()
  end

  @doc """
  The copies for `meeting` once a reschedule moves it: `location_attrs`
  (`Tymeslot.Bookings.RescheduleLocation`) written over its stored
  originals, and `location_choice` the booker's new choice, resolved
  against the translated meeting type and venues as `build/4` does for a
  new booking.

  Only the location moves: every other text of a stored copy is the one the
  attendee booked with, and stays, whatever the meeting type reads now. A
  copy left reading as the originals is dropped, and a one-to-one meeting's
  own attendee locale gains a copy of the location alone when it had none
  and the new location is translated. Nil when there is nothing to store.
  """
  @spec relocated(map(), map() | nil, map(), map()) :: t() | nil
  def relocated(meeting, meeting_type, location_attrs, location_choice) do
    profile = Profiles.get_profile(meeting.organizer_user_id)
    moved = Map.merge(meeting, Map.take(location_attrs, [:location]))
    originals = originals(moved)

    meeting
    |> locales()
    |> Map.new(fn locale ->
      location = location(meeting_type, profile, locale, moved.location, location_choice)
      entry = (meeting.attendee_texts || %{})[locale] || %{}
      {locale, Map.put(entry, "location", location)}
    end)
    |> Map.reject(fn {_locale, entry} -> redundant?(entry, originals) end)
    |> nil_if_empty()
  end

  # A shared slot's `attendee_locale` is only its first booker's (or, on a
  # planned session, the default), so only a one-to-one meeting adds it.
  defp locales(%{capacity: capacity} = meeting) when is_integer(capacity) and capacity > 1,
    do: Map.keys(meeting.attendee_texts || %{})

  defp locales(meeting),
    do: Enum.uniq(Map.keys(meeting.attendee_texts || %{}) ++ [meeting.attendee_locale])

  # The new location in `locale`, the original where the language is no
  # longer translated into, or the meeting has no location.
  defp location(_meeting_type, _profile, _locale, nil, _choice), do: nil

  defp location(meeting_type, profile, locale, original, choice) do
    case Languages.content_locale(profile, locale) do
      nil -> original
      content_locale -> resolve_location(meeting_type, content_locale, choice)
    end
  end

  defp resolve_location(meeting_type, locale, location_choice) do
    meeting_type
    |> ContentTranslations.localise(locale)
    |> MeetingTypes.resolve_location(Map.put(location_choice, :content_locale, locale))
    |> Map.get(:location)
  end

  defp entry(meeting_type, locale, attrs, location_choice) do
    localised = ContentTranslations.localise(meeting_type, locale)
    originals = originals(attrs)

    texts = %{
      "meeting_type" => localised.name,
      "description" => localised.description,
      "location" =>
        if(is_nil(attrs[:location]),
          do: nil,
          else: resolve_location(meeting_type, locale, location_choice)
        ),
      "custom_fields_snapshot" =>
        Snapshot.overlay_texts(attrs[:custom_fields_snapshot] || [], localised)
    }

    if redundant?(texts, originals), do: nil, else: texts
  end

  defp originals(fields), do: Map.new(@keys, &{Atom.to_string(&1), Map.get(fields, &1)})

  # A copy that says nothing the originals do not: each of its texts nil
  # (which reads as the original, `text/3`) or the original's own, a blank
  # description (nil on the type, "" on the booking) matching a blank one.
  defp redundant?(entry, originals),
    do: Enum.all?(entry, fn {key, text} -> is_nil(text) or same?(text, originals[key]) end)

  defp same?(text, original), do: text == original or (blank?(text) and blank?(original))

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_text), do: false

  defp nil_if_empty(texts) when map_size(texts) == 0, do: nil
  defp nil_if_empty(texts), do: texts

  @doc """
  `key` of `meeting` (one of `keys/0`) as a reader in `locale` sees it: the
  copy the meeting carries in that locale, otherwise (no copy, or one that
  leaves this text out or nil) the meeting's own value.
  """
  @spec text(map(), atom(), String.t() | nil) :: term()
  def text(meeting, key, locale) when key in @keys do
    case Map.get(meeting, :attendee_texts) do
      %{^locale => %{} = entry} when is_binary(locale) ->
        Map.get(entry, Atom.to_string(key)) || Map.get(meeting, key)

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

  @doc """
  `meeting` as its attendee reads it in `locale`, for a page or a template
  that renders the meeting itself: their copies of its texts (`as_read_in/2`)
  and its title in their language, the type named as they read it. `locale`
  is a stored one, normalised as their emails normalise it
  (`Tymeslot.Meetings.Recipient`): one no longer supported, or none, is the
  booking pages' fallback.
  """
  @spec attendee_view(map(), String.t() | nil) :: map()
  def attendee_view(meeting, locale) do
    attendee_meeting =
      as_read_in(meeting, Locales.acceptable(locale) || Locales.booking_default_locale())

    %{
      attendee_meeting
      | title: BookingTitle.localise_with_type(meeting, attendee_meeting.meeting_type)
    }
  end
end
