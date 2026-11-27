defmodule Tymeslot.Bookings.RedirectParams do
  @moduledoc """
  Where a new booking sends its booker, and what the embedding page is told
  about it: the meeting type's redirect address (`redirect_url`), with the
  booking's details appended as query parameters when the host opted in
  (`redirect_pass_details`), and the same details as a map for an embed's
  `onSuccess` callback.

  Pure: it reads only what it is given, so the booking page can call it on
  the synchronous confirmation, on an embedded paid booking's `:paid`
  broadcast, and on Stripe Checkout's return page alike. Deciding whether a
  booking redirects at all (a reschedule, a simulated booking) is the
  caller's (`TymeslotWeb.Themes.Shared.BookingSuccess`).

  ## Query parameters

  Named as Calendly names them, so a thank-you page written for Calendly
  reads them unchanged: `event_type_name`, `event_type_uuid` (the meeting
  type's id), `event_start_time` and `event_end_time` (ISO 8601 with the
  offset of the invitee's time zone), `assigned_to` (the organiser's name),
  `invitee_email`, `invitee_full_name`, `invitee_first_name`,
  `invitee_last_name`, `invitee_uuid`, `utm_source`, `utm_medium`,
  `utm_campaign`, `utm_content`, `utm_term`, and `answer_1` to `answer_10`,
  the custom questions' answers by the question's place in the booking's
  snapshot. A value that is nil or empty is left out, and a query the
  address already carries is kept, bar a key this module sets.

  ## Identifiers

  The meeting's `uid` is the booking's bearer secret: the cancel and
  reschedule links are built from it (`Tymeslot.Meetings.MeetingSchema`),
  so it never appears here. `invitee_uuid` and `appointmentId` are the
  booking's `calendar_uid`, the name it goes by in calendars, which grants
  nothing. A seat on a group meeting is handed over as its seat view
  (`Tymeslot.Meetings.SeatView`), whose `calendar_uid` is already the
  seat's own (its participant id, the id webhooks call `seat.id`), never
  the shared slot's and never the seat's management token; so the two are
  the same value for a seat as for a solo booking.

  ## The `data` map

  Camel-cased for the embedding page's script, with nil and empty values
  left out. The event's facts are always there (`eventTypeName`,
  `eventTypeUuid`, `eventStartTime`, `eventEndTime`, `assignedTo`); the
  invitee's personal details, the UTM tags and the answers only when the
  host opted in, exactly as the address gets them.
  """

  alias Tymeslot.Meetings.SeatView

  @utm_keys [
    utm_source: :utmSource,
    utm_medium: :utmMedium,
    utm_campaign: :utmCampaign,
    utm_content: :utmContent,
    utm_term: :utmTerm
  ]

  # Calendly passes ten answers; a longer questionnaire keeps its first ten.
  @max_url_answers 10

  # Question types whose answer reads as text. A note is not a question (it
  # shows the booker a text to acknowledge) and takes no number; a question
  # of any other type, such as a file upload should one be added, takes its
  # number but passes no value.
  @textual_types ~w(short_text number single_select multi_select yes_no phone url date time)
  @not_a_question ~w(note)

  @typedoc """
  What the booking page knows about the booker: the name and email they
  booked with (on a group session, their own, not another seat's), the time
  zone they booked in, the UTM tags they arrived with (atom keys, as
  `Tymeslot.Analytics.UtmExtractor` gives them), and the questions they were
  asked with their answers (`custom_fields_snapshot`, string-keyed maps;
  `custom_field_answers`, keyed by question id).
  """
  @type booker :: %{
          optional(:name) => String.t() | nil,
          optional(:email) => String.t() | nil,
          optional(:timezone) => String.t() | nil,
          optional(:utm) => map() | nil,
          optional(:custom_fields_snapshot) => [map()] | nil,
          optional(:custom_field_answers) => map() | nil
        }

  @type result :: %{redirect_url: String.t() | nil, data: map()}

  @doc """
  The redirect address and the `data` map for `meeting`, booked on
  `meeting_type` by `booker`.

  `redirect_url` is nil when the meeting type has none. With
  `redirect_pass_details` off it is the address as the host saved it.
  """
  @spec build(map() | nil, map(), booker()) :: result()
  def build(meeting_type, meeting, booker) do
    pass_details? = map_value(meeting_type, :redirect_pass_details) == true
    event = event_values(meeting_type, meeting, booker)
    invitee = if pass_details?, do: invitee_values(meeting, booker), else: []
    answers = if pass_details?, do: answers(booker), else: []

    %{
      redirect_url: redirect_url(meeting_type, pass_details?, event ++ invitee, answers),
      data: data(event, invitee, answers)
    }
  end

  # The event's facts, as `{query key, data key, value}`.
  defp event_values(meeting_type, meeting, booker) do
    timezone = Map.get(booker, :timezone)

    [
      {"event_type_name", :eventTypeName, map_value(meeting_type, :name)},
      {"event_type_uuid", :eventTypeUuid, id_string(map_value(meeting_type, :id))},
      {"event_start_time", :eventStartTime, local_iso8601(meeting.start_time, timezone)},
      {"event_end_time", :eventEndTime, local_iso8601(meeting.end_time, timezone)},
      {"assigned_to", :assignedTo, Map.get(meeting, :organizer_name)}
    ]
  end

  # The invitee's details and the tags they arrived with, passed only on
  # the host's opt-in. `appointmentId` and `inviteeUuid` both name the
  # booking: its `calendar_uid`, which a seat view already sets to the
  # seat's own id. The participant id is read as a fallback for a seat
  # handed over without that overlay.
  defp invitee_values(meeting, booker) do
    name = booker |> Map.get(:name) |> trim()
    {first, last} = split_name(name)
    utm = Map.get(booker, :utm) || %{}

    [
      {nil, :appointmentId, Map.get(meeting, :calendar_uid)},
      {"invitee_uuid", :inviteeUuid, invitee_uuid(meeting)},
      {"invitee_email", :inviteeEmail, booker |> Map.get(:email) |> trim()},
      {"invitee_full_name", :inviteeFullName, name},
      {"invitee_first_name", :inviteeFirstName, first},
      {"invitee_last_name", :inviteeLastName, last}
    ] ++
      Enum.map(@utm_keys, fn {key, data_key} ->
        {Atom.to_string(key), data_key, utm_value(utm, key)}
      end)
  end

  defp invitee_uuid(meeting) do
    case SeatView.participant_id(meeting) do
      nil -> Map.get(meeting, :calendar_uid)
      participant_id -> participant_id
    end
  end

  # "Ada Lovelace King" is first name "Ada", last name "Lovelace King": the
  # booking form asks for one name, and the first word is the safest guess
  # at a given name. A single word is a first name only.
  defp split_name(nil), do: {nil, nil}

  defp split_name(name) do
    case String.split(name, ~r/\s+/u, parts: 2) do
      [first, last] -> {first, last}
      [first] -> {first, nil}
    end
  end

  defp redirect_url(meeting_type, pass_details?, values, answers) do
    case meeting_type |> map_value(:redirect_url) |> trim() do
      nil -> nil
      url when pass_details? -> append_query(url, query_pairs(values, answers))
      url -> url
    end
  end

  defp query_pairs(values, answers) do
    answer_pairs =
      answers
      |> Enum.take(@max_url_answers)
      |> Enum.with_index(1)
      |> Enum.map(fn {answer, number} -> {"answer_#{number}", answer} end)

    values
    |> Enum.flat_map(fn
      {nil, _data_key, _value} -> []
      {query_key, _data_key, value} -> [{query_key, value}]
    end)
    |> Kernel.++(answer_pairs)
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
  end

  # Keeps the address's own query, as written, ahead of the booking's, and
  # drops from it only a key the booking sets, so a parameter the host's
  # page reads is never sent twice with two values.
  defp append_query(url, []), do: url

  defp append_query(url, pairs) do
    uri = URI.parse(url)
    ours = MapSet.new(pairs, &elem(&1, 0))

    kept =
      (uri.query || "")
      |> String.split("&", trim: true)
      |> Enum.reject(&MapSet.member?(ours, query_key(&1)))

    query = Enum.join(kept ++ [URI.encode_query(pairs)], "&")
    URI.to_string(%{uri | query: query})
  end

  # The booking's keys are plain ASCII, so a segment's key is compared as
  # written.
  defp query_key(segment), do: segment |> String.split("=", parts: 2) |> hd()

  defp data(event, invitee, answers) do
    values =
      (event ++ invitee)
      |> Enum.reject(fn {_query_key, _data_key, value} -> blank?(value) end)
      |> Map.new(fn {_query_key, data_key, value} -> {data_key, value} end)

    if Enum.all?(answers, &blank?/1),
      do: values,
      else: Map.put(values, :answers, answers)
  end

  # Every question's answer as text, in the snapshot's order, "" for one
  # left blank or not textual, so an answer's place is its question's.
  defp answers(booker) do
    answers = Map.get(booker, :custom_field_answers) || %{}

    (Map.get(booker, :custom_fields_snapshot) || [])
    |> Enum.reject(&(field(&1, "type") in @not_a_question))
    |> Enum.map(&answer_text(&1, Map.get(answers, field(&1, "id"))))
  end

  defp answer_text(question, value) do
    if field(question, "type") in @textual_types,
      do: render(question, value),
      else: ""
  end

  defp render(_question, true), do: "Yes"
  defp render(_question, false), do: "No"

  defp render(question, values) when is_list(values),
    do:
      values |> Enum.map(&option_label(question, &1)) |> Enum.reject(&blank?/1) |> Enum.join(", ")

  defp render(question, value) when is_binary(value) do
    if field(question, "type") == "single_select",
      do: option_label(question, value),
      else: String.trim(value)
  end

  defp render(_question, value) when is_number(value), do: to_string(value)
  defp render(_question, _blank_or_unreadable), do: ""

  # A select's answer is the option's key; the booker saw its label.
  defp option_label(question, key) when is_binary(key) do
    case Enum.find(field(question, "options") || [], &(field(&1, "key") == key)) do
      nil -> key
      option -> field(option, "label") || key
    end
  end

  defp option_label(_question, value) when is_number(value), do: to_string(value)
  defp option_label(_question, _value), do: ""

  # The snapshot is string-keyed, but a caller may hand in the definitions
  # as the meeting type holds them (atom-keyed structs).
  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, String.to_existing_atom(key))

  defp local_iso8601(%DateTime{} = datetime, timezone) do
    datetime
    |> in_zone(timezone)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp local_iso8601(_missing, _timezone), do: nil

  # A zone that no longer resolves leaves the time in UTC, still correct.
  defp in_zone(datetime, timezone) when is_binary(timezone) and timezone != "" do
    case DateTime.shift_zone(datetime, timezone) do
      {:ok, shifted} -> shifted
      {:error, _reason} -> datetime
    end
  end

  defp in_zone(datetime, _timezone), do: datetime

  defp utm_value(utm, key), do: Map.get(utm, key) || Map.get(utm, Atom.to_string(key))

  defp map_value(nil, _key), do: nil
  defp map_value(map, key) when is_map(map), do: Map.get(map, key)

  defp id_string(id) when is_integer(id), do: Integer.to_string(id)
  defp id_string(id) when is_binary(id), do: id
  defp id_string(_id), do: nil

  defp trim(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim(_value), do: nil

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
end
