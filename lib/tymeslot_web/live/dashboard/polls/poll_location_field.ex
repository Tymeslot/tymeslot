defmodule TymeslotWeb.Dashboard.Polls.PollLocationField do
  @moduledoc """
  Where a poll's meeting will be held, as the create form and the poll
  editor ask it (`Tymeslot.Polls.PollLocation`): a video call on one of the
  host's video integrations, which gets its room when the host confirms a
  time, one of their saved locations, or a place they type in.

  Without a choice, a poll on a meeting type takes the type's location, and
  the empty option says which. Without a type, it means no location.

  The choice posts inside the caller's form as `poll[location]` (see
  `Tymeslot.Polls.PollLocation.parse_choice/2`), and the place typed in as
  `poll[location_details]`.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Bookings.CreateAdHoc
  alias Tymeslot.Polls.PollLocation
  alias TymeslotWeb.Components.CoreComponents.Forms
  alias TymeslotWeb.Dashboard.Polls.PollFormErrors

  @doc """
  The form state for `params` as they arrive: the choice and the place
  typed in, each kept as it was when the change did not carry it.
  """
  @spec form_state(map(), map()) :: %{location_choice: String.t(), location_details: String.t()}
  def form_state(params, assigns) do
    %{
      location_choice: Map.get(params, "location", assigns.location_choice),
      location_details: Map.get(params, "location_details", assigns.location_details)
    }
  end

  @doc """
  The poll attributes for the location `params` carry, keyed by atoms, or
  with `:string_keys` by strings, as the editor's other attributes are.
  """
  @spec attrs(map(), :atom_keys | :string_keys) :: map()
  def attrs(params, keys \\ :atom_keys) do
    attrs =
      PollLocation.parse_choice(Map.get(params, "location"), Map.get(params, "location_details"))

    case keys do
      :atom_keys -> attrs
      :string_keys -> Map.new(attrs, fn {key, value} -> {Atom.to_string(key), value} end)
    end
  end

  @doc "The message for a location that is no longer the host's to choose."
  @spec not_found_message() :: String.t()
  def not_found_message,
    do:
      dgettext(
        "dashboard_polls",
        "This location or video provider is no longer available. Please choose another."
      )

  attr :id, :string, required: true
  attr :choice, :string, required: true, doc: "the value chosen, as `poll[location]` posts it"
  attr :details, :string, required: true, doc: "the place typed in for a custom location"
  attr :options, :map, required: true, doc: "`Tymeslot.Polls.location_options/1`"

  attr :type_location, :map,
    default: nil,
    doc: "the meeting type's location (`PollLocation.of_meeting_type/1`), if it has one"

  attr :errors, :map, default: %{}, doc: "the form's errors, by field"

  @doc "The location select, and the field for a place typed in."
  @spec field(map()) :: Phoenix.LiveView.Rendered.t()
  def field(assigns) do
    ~H"""
    <div class="space-y-2" data-testid="poll-location">
      <Forms.input
        type="select"
        id={"#{@id}-choice"}
        name="poll[location]"
        label={dgettext("dashboard_polls", "Location (optional)")}
        value={@choice}
        prompt={prompt(@type_location)}
        options={options(@options)}
        errors={errors(@errors, [:location_kind, :venue_id, :video_integration_id])}
      >
        <:description>
          {dgettext(
            "dashboard_polls",
            "Shown on the voting page and in the invitations. A video call gets its room when you confirm a time."
          )}
        </:description>
      </Forms.input>
      <Forms.input
        :if={@choice == "custom"}
        type="text"
        id={"#{@id}-details"}
        name="poll[location_details]"
        value={@details}
        maxlength={CreateAdHoc.custom_location_max_length()}
        placeholder={dgettext("dashboard_polls", "An address, a room or a meeting point")}
        aria-label={dgettext("dashboard_polls", "Custom location")}
        phx-debounce="300"
        errors={errors(@errors, [:location_details])}
      />
    </div>
    """
  end

  defp errors(errors, fields), do: Enum.flat_map(fields, &PollFormErrors.error_list(errors, &1))

  defp prompt(nil), do: dgettext("dashboard_polls", "No location")

  defp prompt(%{kind: :video}),
    do: dgettext("dashboard_polls", "From the meeting type: video call")

  defp prompt(%{place: place}) when is_binary(place),
    do: dgettext("dashboard_polls", "From the meeting type: %{place}", place: place)

  defp prompt(_type_location), do: dgettext("dashboard_polls", "No location")

  # Grouped as `options_for_select/2` takes them, each group left out when
  # the host has nothing in it.
  defp options(%{videos: videos, venues: venues}) do
    group(dgettext("dashboard_polls", "Video call"), videos, "video") ++
      group(dgettext("dashboard_polls", "Saved locations"), venues, "venue") ++
      [{dgettext("dashboard_polls", "Custom location…"), "custom"}]
  end

  defp group(_label, [], _prefix), do: []

  defp group(label, entries, prefix),
    do: [{label, Enum.map(entries, &{&1.name, "#{prefix}:#{&1.id}"})}]
end
