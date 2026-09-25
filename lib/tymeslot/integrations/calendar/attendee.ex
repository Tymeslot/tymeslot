defmodule Tymeslot.Integrations.Calendar.Attendee do
  @moduledoc """
  The single source of truth for the shape of an attendee on a cached calendar
  event (`ProviderCalendarEventSchema.attendees`).

  The canonical shape is an atom-keyed map:

      %{
        email: String.t() | nil,
        display_name: String.t() | nil,
        response_status: :accepted | :declined | :tentative | :needs_action | nil,
        optional: boolean()
      }

  Everything that writes an attendee builds it with `new/1`: the sync
  normalisers for each provider, and the calendar grid when the organiser adds
  someone. Anything that reads one goes through `normalise/1`, because the
  column is JSONB and every stored row comes back string-keyed whatever wrote
  it. Rows written before this module existed are read as well: the grid used
  to spell the label `name`, which ad-hoc booking payloads still do.

  ## A missing reply is not a pending one

  `response_status` is `nil` unless a provider actually reported a reply, and
  neither function ever fills it in. The Google write path depends on the
  difference: `events.update` is a full replace, so a cached reply has to be
  sent back or Google resets it, while an attendee with no reply is sent
  without one so that Google applies its own default to a new invitee.
  """

  @typedoc "A reply to the invitation, as reported by the provider."
  @type response_status :: :accepted | :declined | :tentative | :needs_action

  @typedoc "A canonical attendee map."
  @type t :: %{
          email: String.t() | nil,
          display_name: String.t() | nil,
          response_status: response_status() | nil,
          optional: boolean()
        }

  @defaults [email: nil, display_name: nil, response_status: nil, optional: false]

  @response_statuses %{
    "accepted" => :accepted,
    "declined" => :declined,
    "tentative" => :tentative,
    "needs_action" => :needs_action
  }

  @doc """
  Builds a canonical attendee from atom-keyed fields.

  Accepts a keyword list or a map. Omitted fields take their defaults, which
  leave `response_status` at `nil`. An unknown field raises, so a misspelt key
  fails where it is written rather than going missing on the provider.

      iex> Tymeslot.Integrations.Calendar.Attendee.new(email: "ada@example.com")
      %{email: "ada@example.com", display_name: nil, response_status: nil, optional: false}
  """
  @spec new(keyword() | map()) :: t()
  def new(fields) do
    fields
    |> Enum.to_list()
    |> Keyword.validate!(@defaults)
    |> Map.new()
  end

  @doc """
  Reads an attendee map of any vintage into the canonical shape.

  Accepts atom or string keys, the legacy `name` spelling of `display_name`,
  and a reply as an atom or as the string a JSONB round trip leaves behind. A
  reply this module does not recognise reads as `:needs_action`, since it is a
  reply that cannot be carried; an absent one stays `nil`. The `status` key the
  grid once wrote was never a reply from anyone, and is ignored.
  """
  @spec normalise(map()) :: t()
  def normalise(%{} = attendee) do
    %{
      email: field(attendee, :email),
      display_name: field(attendee, :display_name) || field(attendee, :name),
      response_status: response_status(field(attendee, :response_status)),
      optional: field(attendee, :optional) in [true, "true"]
    }
  end

  defp field(attendee, key) do
    case Map.fetch(attendee, key) do
      {:ok, value} -> value
      :error -> Map.get(attendee, Atom.to_string(key))
    end
  end

  defp response_status(nil), do: nil

  defp response_status(status) when is_atom(status),
    do: response_status(Atom.to_string(status))

  defp response_status(status) when is_binary(status),
    do: Map.get(@response_statuses, status, :needs_action)

  defp response_status(_other), do: :needs_action
end
