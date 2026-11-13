defmodule TymeslotWeb.Dashboard.Polls.PollDuration do
  @moduledoc """
  The poll create form's duration. A poll without a meeting type takes the
  number the host types in. With a type, it takes the type's length, and for
  a type that offers several (`Tymeslot.MeetingTypes.Lengths`) the host picks
  one of them: a poll asks a group to agree on one slot, so the length is
  settled before the candidate times go out, by the host rather than by each
  invitee.

  Every value travels as `poll[duration]`, which `Tymeslot.Polls.create_poll/2`
  keeps over the type's primary duration.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.MeetingTypes.Lengths
  alias Tymeslot.Validation.Constraints
  alias TymeslotWeb.Components.CoreComponents.Forms
  alias TymeslotWeb.Components.CoreComponents.Select
  alias TymeslotWeb.Dashboard.DashboardFormat

  @doc """
  The duration the form holds once `params` arrive: the host's own for a poll
  without a type, otherwise the length of `meeting_type` they chose, which
  falls back to its primary duration when it is not one the type offers (as
  after switching to another type).
  """
  @spec resolve(map() | nil, map(), String.t()) :: String.t()
  def resolve(nil, params, current), do: Map.get(params, "duration", current)

  def resolve(meeting_type, params, _current) do
    meeting_type
    |> Lengths.resolve(Lengths.parse(Map.get(params, "duration")))
    |> Integer.to_string()
  end

  @doc """
  The length the host typed, in minutes, or nil when it is not a whole
  number: the changeset then says what is wrong, where a default would
  quietly replace it.
  """
  @spec parse(String.t() | integer() | nil) :: integer() | nil
  def parse(value) when is_integer(value), do: value

  def parse(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _other -> nil
    end
  end

  def parse(_other), do: nil

  attr :meeting_type, :map, default: nil, doc: "the selected meeting type, if any"
  attr :duration, :string, required: true
  attr :errors, :list, default: []

  @doc "The duration field for the selected meeting type, or none."
  @spec duration_field(map()) :: Phoenix.LiveView.Rendered.t()
  def duration_field(%{meeting_type: nil} = assigns) do
    ~H"""
    <Forms.input
      type="number"
      name="poll[duration]"
      label={dgettext("dashboard_polls", "Duration (minutes)")}
      value={@duration}
      min={Constraints.poll_duration_minutes_opts()[:greater_than_or_equal_to]}
      max={Constraints.poll_duration_minutes_opts()[:less_than_or_equal_to]}
      required
      errors={@errors}
      icon="hero-clock"
    />
    """
  end

  def duration_field(assigns) do
    assigns = assign(assigns, :lengths, Lengths.offered(assigns.meeting_type))

    ~H"""
    <Select.select
      :if={length(@lengths) > 1}
      id="poll-duration-select"
      name="poll[duration]"
      label={dgettext("dashboard_polls", "Duration")}
      value={@duration}
      options={Enum.map(@lengths, &{DashboardFormat.duration(&1), Integer.to_string(&1)})}
      errors={@errors}
      data-testid="poll-duration-select"
    />
    <div :if={length(@lengths) <= 1}>
      <input type="hidden" name="poll[duration]" value={@duration} />
      <p class="text-token-sm text-tymeslot-600 mt-8">
        {dgettext("dashboard_polls", "Duration: %{minutes} min (from meeting type)",
          minutes: @duration
        )}
      </p>
    </div>
    """
  end
end
