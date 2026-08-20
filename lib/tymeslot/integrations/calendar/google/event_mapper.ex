defmodule Tymeslot.Integrations.Calendar.Google.EventMapper do
  @moduledoc """
  Maps outbound event data from internal representation to the Google Calendar
  API event format. Pure data transformations with no side effects.
  """

  alias Tymeslot.Integrations.Calendar.EventColour
  alias Tymeslot.Integrations.Calendar.EventTimeFormatter
  alias Tymeslot.Integrations.Calendar.Recurrence.RRule
  alias Tymeslot.Integrations.Calendar.Reminder

  @doc """
  Formats internal event data into a Google Calendar API event body.

  Extracts relevant fields, adds a Google event ID when a `:uid` is present,
  and strips nil values from the result.
  """
  @spec format_event_data(map()) :: map()
  def format_event_data(event_data) do
    event_data
    |> extract_event_fields()
    |> add_google_event_id(event_data)
    |> maybe_add_conference_data(event_data)
    |> maybe_add_reminders(event_data)
    |> maybe_add_recurrence(event_data)
    |> maybe_add_colour(event_data)
    |> remove_nil_values()
  end

  @doc """
  Returns `true` when the event data carries a Google `conferenceData` payload
  that requires the `conferenceDataVersion=1` query parameter on writes.
  """
  @spec requires_conference_data_version?(map()) :: boolean()
  def requires_conference_data_version?(event_data) when is_map(event_data) do
    case get_field_value(event_data, :conference_data) do
      data when is_map(data) and map_size(data) > 0 -> true
      _other -> false
    end
  end

  def requires_conference_data_version?(_other), do: false

  @doc """
  Adds Tymeslot provenance markers to a Google Calendar event body.

  Sets `source` and `extendedProperties` so events created by Tymeslot
  can be identified later during sync.
  """
  @spec add_tymeslot_fingerprint(map()) :: map()
  def add_tymeslot_fingerprint(body) do
    Map.merge(body, %{
      "source" => %{"title" => "Tymeslot", "url" => "https://tymeslot.app"},
      "extendedProperties" => %{"private" => %{"createdBy" => "tymeslot"}}
    })
  end

  @doc """
  Converts a UID to a Google Calendar compatible event ID.

  Google iCalUIDs have the format `{event_id}@google.com` — the domain is
  stripped. UUIDs may contain hyphens — those are stripped too. The result
  must be 5-1024 characters of lowercase a-v and 0-9 (base32hex). When the
  input does not satisfy that constraint a SHA-256 hash is used as fallback.

  An id Google itself minted is returned unchanged; see
  `provider_event_id?/1` for which shapes count and why.
  """
  @spec uuid_to_google_event_id(String.t()) :: String.t()
  def uuid_to_google_event_id(uid) when is_binary(uid) do
    # Strip @domain only for the base32hex fast-path check (Google's own iCalUIDs
    # use the format "{event_id}@google.com"). The full UID is always used for
    # the hash fallback so that different UIDs sharing a local-part never collide.
    base =
      uid
      |> String.split("@")
      |> hd()
      |> String.replace("-", "")
      |> String.downcase()

    cond do
      String.match?(base, ~r/^[a-v0-9]{5,1024}$/) ->
        base

      provider_event_id?(local_part(uid)) ->
        local_part(uid)

      true ->
        # Input is not a valid base32hex ID (e.g. arbitrary string UID) —
        # hash the FULL uid to produce a deterministic, valid Google event ID.
        #
        # `hex_encode32/2`, not `encode32/2`. Standard base32 is a-z and 2-7;
        # base32hex — the alphabet Google's event ids actually require — is a-v
        # and 0-9. The two differ in exactly the characters that make an id
        # invalid, so the fallback that exists to guarantee validity was emitting
        # w, x, y and z and Google answered "Invalid resource id value" with a
        # 400. At 32 characters nearly every hash contains one.
        :sha256
        |> :crypto.hash(uid)
        |> Base.hex_encode32(case: :lower, padding: false)
        |> String.slice(0, 32)
    end
  end

  @doc """
  Whether this is an id Google minted rather than a UID Tymeslot did.

  One occurrence of a recurring series is addressed by an *instance id*:
  `{masterId}_{YYYYMMDD}T{HHMMSS}Z`. That is what `list_events/4` returns for
  the occurrence, so it is the id every caller holds when it wants to write to
  one — and it is not base32hex, because the underscore, the `T` and the `Z`
  all sit outside `a-v0-9`.

  Without this the hash fallback swallowed it. The real instance
  `56km0ibouqobmlmh3g5ptdmp28_20260904T140000Z` became
  `3k00t2b8doud77raa00g0mapusod4t7o`, and the DELETE addressed an id that has
  never existed: Google answered 404 for an occurrence plainly visible in the
  calendar, and on a mirrored series a cancelled occurrence was never withdrawn
  from the target, going on blocking a slot nobody could book.

  The rule is stated here once rather than at each write path, because the two
  kinds of id are told apart by what they *are*, not by which call is about to
  use one. `get_event/3` reached the same conclusion the other way — by opting
  out of conversion entirely — and its exemption is now this rule's special
  case rather than a second, separate one.

  Deliberately a whole-string match on the instance shape, not a test for
  "contains characters outside base32hex". Every UID Tymeslot mints is outside
  that alphabet too — `Engine.target_uid_for/2` yields
  `tymeslot-mirror-<digest>`, whose hyphens fail the fast path — and those
  genuinely need converting. A wider exemption would send our own placeholder
  UIDs to Google verbatim, which is the create path breaking rather than the
  delete path fixed.
  """
  @spec provider_event_id?(String.t()) :: boolean()
  def provider_event_id?(id) when is_binary(id) do
    String.match?(id, ~r/^[a-v0-9]{5,1024}_\d{8}T\d{6}Z$/)
  end

  def provider_event_id?(_other), do: false

  # --- Private helpers ---

  # Google mints an iCalUID as `{id}@google.com`, so the cached form of an
  # instance carries the suffix while the id the write must address does not.
  defp local_part(uid), do: uid |> String.split("@") |> hd()

  defp extract_event_fields(event_data) do
    timezone = get_field_value(event_data, :timezone)

    %{
      "summary" => get_field_value(event_data, :summary),
      "description" => get_field_value(event_data, :description),
      "location" => get_field_value(event_data, :location),
      "start" =>
        EventTimeFormatter.format_with_timezone(
          get_field_value(event_data, :start_time),
          timezone
        ),
      "end" =>
        EventTimeFormatter.format_with_timezone(
          get_field_value(event_data, :end_time),
          timezone
        ),
      "status" => to_string_or_default(get_field_value(event_data, :status), "confirmed"),
      "transparency" => map_transparency(get_field_value(event_data, :transparency)),
      "visibility" => map_visibility(get_field_value(event_data, :visibility)),
      "attendees" => build_attendees(event_data)
    }
  end

  defp build_attendees(event_data) do
    attendees = get_field_value(event_data, :attendees)

    if is_list(attendees) and attendees != [] do
      Enum.map(attendees, fn attendee ->
        remove_nil_values(%{
          "email" => get_field_value(attendee, :email),
          "displayName" => get_field_value(attendee, :name)
        })
      end)
    else
      # Legacy single-attendee path (ad-hoc meetings)
      email = get_field_value(event_data, :attendee_email)
      name = get_field_value(event_data, :attendee_name)

      if email do
        [remove_nil_values(%{"email" => email, "displayName" => name})]
      else
        nil
      end
    end
  end

  defp add_google_event_id(base_data, event_data) do
    case get_field_value(event_data, :uid) do
      nil -> base_data
      uid -> Map.put(base_data, "id", uuid_to_google_event_id(uid))
    end
  end

  defp maybe_add_conference_data(base_data, event_data) do
    case get_field_value(event_data, :conference_data) do
      data when is_map(data) and map_size(data) > 0 ->
        Map.put(base_data, "conferenceData", stringify_keys(data))

      _other ->
        base_data
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Enum.into(map, %{}, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_keys(v)}
      {k, v} -> {k, stringify_keys(v)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  # Reminders sync to Google as explicit overrides (`useDefault: false`). When no
  # reminders are present the key is omitted entirely, so Google applies the
  # calendar's default reminders. The canonical inbound shape is
  # `%{method: :popup | :email, minutes_before: integer}`.
  defp maybe_add_reminders(base_data, event_data) do
    case get_field_value(event_data, :reminders) do
      reminders when is_list(reminders) and reminders != [] ->
        Map.put(base_data, "reminders", %{
          "useDefault" => false,
          "overrides" => Enum.map(reminders, &reminder_override/1)
        })

      _none ->
        base_data
    end
  end

  # Reminder maps reach here either atom-keyed (freshly built in the create/edit
  # flow) or string-keyed (round-tripped through the JSONB cache column). Key
  # reading and provider projection are delegated to Reminder.
  defp reminder_override(reminder) do
    %{
      "method" => Reminder.google_method(Reminder.method(reminder)),
      "minutes" => Reminder.minutes_before(reminder)
    }
  end

  # Google's `recurrence` is a list of whole iCalendar property lines — an
  # RRULE, and then any number of EXDATE, RDATE or EXRULE lines — not a list of
  # rules. The RRULE comes first, and the exception lines follow it.
  #
  # The rule's prefix is normalised because its sources disagree: the Google
  # normaliser keeps `RRULE:` on read, CalDAV and the grid's recurrence editor
  # store the bare body, so any existing prefix is stripped before re-adding
  # exactly one. The exception lines get no such treatment, and that asymmetry
  # is deliberate. There is no bare form of them in this codebase: the only
  # producer is `SyncLink.RecurringSeries`, which filters the master's own
  # `recurrence` list by an `EXDATE` prefix and keeps each line verbatim. A line
  # therefore arrives already prefixed and already carrying whichever `TZID` or
  # `VALUE=DATE` parameter the master wrote — parameters that sit between the
  # name and the colon, so a `strip and re-add "EXDATE:"` would either be a
  # no-op or would corrupt the line by discarding its timezone. Passing them
  # through is what keeps a cancelled occurrence cancelled at the right instant.
  #
  # Additive by construction: the key is written only when a rule is present,
  # and an event carrying no exception lines — every booking event, and every
  # event the calendar grid creates — produces the same one-element list it did
  # before exception lines existed. Lines without a rule describe exclusions
  # from a series that is not there, and are dropped with the rest.
  defp maybe_add_recurrence(base_data, event_data) do
    case get_field_value(event_data, :recurrence_rule) do
      rrule when is_binary(rrule) and rrule != "" ->
        lines = ["RRULE:#{RRule.strip_prefix(rrule)}" | exception_lines(event_data)]
        Map.put(base_data, "recurrence", lines)

      _none ->
        base_data
    end
  end

  defp exception_lines(event_data) do
    case get_field_value(event_data, :recurrence_exception_lines) do
      lines when is_list(lines) -> Enum.filter(lines, &(is_binary(&1) and &1 != ""))
      _none -> []
    end
  end

  # The canonical `:colour` field carries a Tymeslot palette key (e.g.
  # `"tomato"`). Google events use a numeric `colorId` ("1".."11"), so the key
  # is mapped at the boundary. An unrecognised value (e.g. a raw inbound
  # colorId round-tripped from the cache) maps to nil and is omitted, leaving
  # Google's default colour untouched.
  defp maybe_add_colour(base_data, event_data) do
    case EventColour.google_color_id(get_field_value(event_data, :colour)) do
      nil -> base_data
      color_id -> Map.put(base_data, "colorId", color_id)
    end
  end

  defp to_string_or_default(nil, default), do: default
  defp to_string_or_default(value, _default) when is_binary(value), do: value
  defp to_string_or_default(value, _default) when is_atom(value), do: Atom.to_string(value)

  defp map_transparency(nil), do: nil
  defp map_transparency(:transparent), do: "transparent"
  defp map_transparency(:opaque), do: "opaque"
  defp map_transparency(value) when is_binary(value), do: value
  defp map_transparency(_other), do: nil

  defp map_visibility(nil), do: nil
  defp map_visibility(:private), do: "private"
  defp map_visibility(:public), do: "public"
  defp map_visibility(:confidential), do: "confidential"
  defp map_visibility(value) when is_binary(value), do: value
  defp map_visibility(_other), do: nil

  defp get_field_value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key))
    end
  end

  defp remove_nil_values(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
