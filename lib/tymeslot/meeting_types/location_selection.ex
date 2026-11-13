defmodule Tymeslot.MeetingTypes.LocationSelection do
  @moduledoc """
  What a meeting type offers as its locations, and what the booker's choice
  among them means for the meeting that gets written.

  Two responsibilities, deliberately in one place because they are the same
  question asked at two moments:

    * `options/1` — the list the booking page renders. It is also the list
      the host's editor renders, so the two can never disagree about what
      this meeting type offers.

    * `resolve/4` — turns the option id the booker submitted into the
      meeting fields that follow from it: the location string the calendar
      event and confirmation emails show, the kind, and the video
      integration the room will be created on.

  ## The booker submits an id, never a location

  Everything else is derived here from the host's own stored option. A
  forged or stale id resolves to the first option rather than being
  honoured, so the worst a tampered submission achieves is booking a
  location the host already offers.

  The same holds for the video provider a booker picks within a video
  option: it is honoured only when the option lists it, and otherwise the
  option's first provider is used.

  A venue within an in-person option is honoured the same way, by
  `place_at_venue/3` once the option is resolved: the booker's pick if the
  option still offers it, otherwise the option's first venue. An in-person
  option offering no venue resolves to its label alone, which is the
  "address arranged after booking" location.

  ## Meeting types with no stored list

  `locations` was added after meeting types existed, and rows can still
  reach this module without one: bulk-inserted defaults, seeds, an import.
  Those fall back to the single option their `allow_video` /
  `video_integration_id` pair already describes, which is exactly what such
  a type offered before the list existed.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Locales
  alias Tymeslot.MeetingTypes.LocationOption
  alias Tymeslot.Venues

  # Each kind's default label in English, as it is stored: on the location,
  # and in the meeting a booking on it writes. It is read in each reader's
  # language (`default_label/1`, `display_location/2`).
  @default_labels %{
    video: "Video call",
    in_person: "In person",
    phone: "Phone call",
    custom: "Somewhere else"
  }

  @typedoc "The meeting fields that follow from the booker's chosen location."
  @type resolution :: %{
          location: String.t() | nil,
          location_kind: LocationOption.kind() | nil,
          location_option_id: String.t() | nil,
          video_integration_id: integer() | nil,
          venue_id: integer() | nil,
          address_to_arrange: boolean(),
          attendee_phone: String.t() | nil
        }

  @doc """
  The meeting type's locations, in the host's order.

  Returns `[]` only when there is no meeting type at all (an ad-hoc booking
  against a bare duration), which callers read as "this booking has no
  configured location".

  A label still reading as its kind's English default ("In person") is
  shown in the current locale: the default meeting types store it that way,
  so it is the name nobody chose rather than one the host wrote.
  """
  @spec options(map() | nil) :: [LocationOption.t()]
  def options(meeting_type),
    do: meeting_type |> stored_options() |> Enum.map(&localise_default_label/1)

  # The locations as stored, a default label in English: what a booking
  # resolves against, so the meeting records the default rather than one
  # reader's wording of it.
  defp stored_options(nil), do: []

  defp stored_options(%{locations: locations}) when is_list(locations) and locations != [],
    do: Enum.sort_by(locations, &(&1.position || 0))

  defp stored_options(meeting_type), do: derived_options(meeting_type)

  @doc """
  Whether the booker has anything to choose: between locations, between the
  providers of a video location, or between the venues of an in-person one.

  `video_choices` and `venue_choices` map an option id to what that option
  offers (`Tymeslot.MeetingTypes.location_video_choices/1` and
  `location_venue_choices/1` on the booking page, which leave out providers
  and venues that no longer exist). The booking page renders its location
  picker exactly when this is true, and `Tymeslot.MeetingTypes.GroupLocationRule`
  admits only locations for which it can never be.
  """
  @spec choice_required?([LocationOption.t()], map() | nil, map() | nil) :: boolean()
  def choice_required?(options, video_choices, venue_choices) do
    length(options) > 1 or several?(video_choices) or several?(venue_choices)
  end

  defp several?(choices), do: Enum.any?(Map.values(choices || %{}), &(length(&1) > 1))

  @doc """
  The option with `id`, or the first one when `id` matches nothing, as
  stored: a default label stays the English default (`display_location/2`
  reads it in the reader's language).
  """
  @spec fetch(map() | nil, String.t() | nil) :: LocationOption.t() | nil
  def fetch(meeting_type, id) do
    opts = stored_options(meeting_type)

    Enum.find(opts, &(&1.id == id)) || List.first(opts)
  end

  @doc """
  Resolves the booker's choice into meeting attributes.

  `guest_phone` is only consulted for a phone option that asks the booker
  for their number; it is ignored everywhere else, so a submission carrying
  one against a video option cannot smuggle it onto the meeting. Likewise
  `video_integration_id`, the provider picked within a video option, is
  only consulted for a video option.
  """
  @spec resolve(map() | nil, String.t() | nil, String.t() | nil, integer() | String.t() | nil) ::
          resolution()
  def resolve(meeting_type, chosen_id, guest_phone \\ nil, video_integration_id \\ nil) do
    case fetch(meeting_type, chosen_id) do
      nil -> empty_resolution()
      option -> resolution_for(option, guest_phone, video_integration_id)
    end
  end

  @doc """
  The video integration a choice lands on: the one the booker picked when
  the option lists it, otherwise the option's first. Nil for an option that
  is not a video call.
  """
  @spec video_integration_for(LocationOption.t(), integer() | String.t() | nil) ::
          integer() | nil
  def video_integration_for(%LocationOption{kind: :video, video_integration_ids: ids}, chosen) do
    chosen_id = to_integer(chosen)
    if chosen_id in ids, do: chosen_id, else: List.first(ids)
  end

  def video_integration_for(%LocationOption{}, _chosen), do: nil

  defp to_integer(id) when is_integer(id), do: id

  defp to_integer(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _other -> nil
    end
  end

  defp to_integer(_id), do: nil

  @doc """
  Places a resolved in-person booking at one of the venues its option
  offers.

  `venues` are the option's venues that still exist, in the host's order
  (`Tymeslot.MeetingTypes.location_venue_choices/1`). The first id in
  `preferred` that they include wins: the booker's pick, then, on a
  reschedule, the meeting's current venue. Otherwise the option's first
  venue. With no venues the resolution is returned unchanged: the option's
  label, no venue, and the address to be arranged.
  """
  @spec place_at_venue(resolution(), [Venues.choice()], [integer() | String.t() | nil]) ::
          resolution()
  def place_at_venue(resolution, [], _preferred), do: resolution

  def place_at_venue(resolution, [first | _rest] = venues, preferred) do
    venue =
      Enum.find_value(preferred, fn id ->
        chosen = to_integer(id)
        Enum.find(venues, &(&1.id == chosen))
      end) || first

    %{resolution | venue_id: venue.id, location: Venues.display(venue), address_to_arrange: false}
  end

  @doc """
  The location string for an option, with the booker's own number folded in
  when the option asked for one.
  """
  @spec display(LocationOption.t(), String.t() | nil) :: String.t()
  # An in-person option's address lives in its venues (see
  # `place_at_venue/3`), never in the option, so the option alone is its label.
  def display(%LocationOption{kind: :in_person, label: label}, _guest_phone), do: label

  def display(%LocationOption{collect_from_guest: true, label: label} = option, guest_phone) do
    case normalize_phone(guest_phone) do
      nil -> LocationOption.display(%{option | details: nil})
      phone -> "#{label} (#{phone})"
    end
  end

  def display(%LocationOption{} = option, _guest_phone), do: LocationOption.display(option)

  defp resolution_for(%LocationOption{} = option, guest_phone, video_integration_id) do
    %{
      location: display(option, guest_phone),
      location_kind: option.kind,
      location_option_id: option.id,
      video_integration_id: video_integration_for(option, video_integration_id),
      venue_id: nil,
      # Until `place_at_venue/3` places it, an in-person booking has no
      # address yet.
      address_to_arrange: option.kind == :in_person,
      attendee_phone: collected_phone(option, guest_phone)
    }
  end

  defp empty_resolution do
    %{
      location: nil,
      location_kind: nil,
      location_option_id: nil,
      video_integration_id: nil,
      venue_id: nil,
      address_to_arrange: false,
      attendee_phone: nil
    }
  end

  defp collected_phone(%LocationOption{kind: :phone, collect_from_guest: true}, guest_phone),
    do: normalize_phone(guest_phone)

  defp collected_phone(_option, _guest_phone), do: nil

  defp normalize_phone(phone) when is_binary(phone) do
    case String.trim(phone) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_phone(_phone), do: nil

  # The single option a meeting type offered before the list existed. The
  # ids are stable strings rather than generated UUIDs: the booking form
  # posts the id back, and a value that changed between render and submit
  # would resolve to "not found" on every submission.
  defp derived_options(%{allow_video: true, video_integration_id: id}) when is_integer(id) do
    [
      %LocationOption{
        id: "legacy-video",
        kind: :video,
        label: @default_labels.video,
        video_integration_ids: [id],
        position: 0
      }
    ]
  end

  defp derived_options(_meeting_type) do
    [
      %LocationOption{
        id: "legacy-in-person",
        kind: :in_person,
        label: @default_labels.in_person,
        position: 0
      }
    ]
  end

  @doc """
  Whether a location's label still reads as its kind's English default. Such
  a label is shown in the visitor's language already, so it is not the host's
  own text to translate.
  """
  @spec default_label?(map()) :: boolean()
  def default_label?(%{kind: kind, label: label}), do: Map.get(@default_labels, kind) == label
  def default_label?(_location), do: false

  @doc """
  `label` as a location of `kind` stores it: its kind's English default when
  it reads as that default in any supported language, otherwise unchanged.

  The editor shows a stored default in the host's own language
  (`options/1`), so a form saved untouched posts it back localised; stored
  as such it would read as text the host wrote, shown untranslated to every
  visitor and offered for translation. Stored as the English default, it
  stays the name nobody chose, shown in each reader's language.
  """
  @spec stored_label(LocationOption.kind() | nil, String.t() | nil) :: String.t() | nil
  def stored_label(kind, label) when is_binary(label) do
    case Map.fetch(@default_labels, kind) do
      {:ok, english} -> if label in localised_defaults(kind), do: english, else: label
      :error -> label
    end
  end

  def stored_label(_kind, label), do: label

  defp localised_defaults(kind) do
    for locale <- Locales.supported_codes() do
      Gettext.with_locale(TymeslotWeb.Gettext, locale, fn -> default_label(kind) end)
    end
  end

  defp localise_default_label(%LocationOption{} = option) do
    if default_label?(option),
      do: %{option | label: default_label(option.kind)},
      else: option
  end

  @doc """
  A meeting's `location` as a reader sees it, in the current locale: a
  location of `kind` still carrying its kind's English default ("In person",
  or "Phone call (+44 20 7946 0000)" with the number it adds) reads in that
  language; anything else (a venue, a label the host wrote) as written.

  A default label is product wording rather than the host's text, so every
  reader sees it in their own language, translated or not.
  """
  @spec display_location(String.t() | nil, LocationOption.kind() | nil) :: String.t() | nil
  def display_location(location, kind) when is_binary(location) do
    with {:ok, english} <- Map.fetch(@default_labels, kind),
         {:ok, rest} <- after_default(location, english) do
      default_label(kind) <> rest
    else
      _written -> location
    end
  end

  def display_location(location, _kind), do: location

  defp after_default(english, english), do: {:ok, ""}

  defp after_default(location, english) do
    if String.starts_with?(location, english <> " ("),
      do: {:ok, String.replace_prefix(location, english, "")},
      else: :error
  end

  @doc """
  The default label of `kind` in the current locale: what a location still
  carrying its English default reads as (`options/1`), and the name an
  editor gives a location the host has not named.
  """
  @spec default_label(LocationOption.kind()) :: String.t()
  def default_label(:video), do: dgettext("booking", "Video call")
  def default_label(:in_person), do: dgettext("booking", "In person")
  def default_label(:phone), do: dgettext("booking", "Phone call")
  def default_label(:custom), do: dgettext("booking", "Somewhere else")
end
