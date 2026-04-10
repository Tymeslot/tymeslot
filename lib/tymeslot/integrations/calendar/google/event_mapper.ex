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
    |> remove_nil_values()
  end

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
      "status" => get_field_value(event_data, :status) || "confirmed",
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
