defmodule Tymeslot.Integrations.Calendar.Google.EventMapper do
  @moduledoc """
  Maps outbound event data from internal representation to the Google Calendar
  API event format. Pure data transformations with no side effects.
  """

  alias Tymeslot.Integrations.Calendar.EventTimeFormatter

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

    if String.match?(base, ~r/^[a-v0-9]{5,1024}$/) do
      base
    else
      # Input is not a valid base32hex ID (e.g. arbitrary string UID) —
      # hash the FULL uid to produce a deterministic, valid Google event ID.
      :crypto.hash(:sha256, uid)
      |> Base.encode32(case: :lower, padding: false)
      |> String.slice(0, 32)
    end
  end

  # --- Private helpers ---

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
          "email" => attendee["email"] || attendee[:email],
          "displayName" => attendee["name"] || attendee[:name]
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
