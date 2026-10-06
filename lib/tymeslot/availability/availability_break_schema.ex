defmodule Tymeslot.Availability.AvailabilityBreakSchema do
  @moduledoc """
  Schema for breaks within a day's availability.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.Availability.AvailabilityBreakQueries
  alias Tymeslot.Availability.WeeklyAvailabilitySchema
  alias Tymeslot.Availability.Window
  alias Tymeslot.ChangesetValidators.TimeOrder
  alias Tymeslot.Validation.Constraints

  @type t :: %__MODULE__{
          id: integer() | nil,
          weekly_availability_id: integer() | nil,
          start_time: Time.t() | nil,
          end_time: Time.t() | nil,
          label: String.t() | nil,
          sort_order: integer(),
          weekly_availability: WeeklyAvailabilitySchema.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "availability_breaks" do
    field(:start_time, :time)
    field(:end_time, :time)
    field(:label, :string)
    field(:sort_order, :integer, default: 0)

    belongs_to(:weekly_availability, WeeklyAvailabilitySchema)

    timestamps(type: :utc_datetime)
  end

  @doc false
  # `work_hours:` passes the day's hours (as `AvailabilityBreakQueries.get_work_hours/1`
  # returns them) when the caller has already read them; otherwise they are
  # read here.
  @spec changeset(t(), map(), keyword()) :: Ecto.Changeset.t()
  def changeset(break, attrs, opts \\ []) do
    break
    |> cast(attrs, [:weekly_availability_id, :start_time, :end_time, :label, :sort_order])
    |> validate_required([:weekly_availability_id, :start_time, :end_time])
    |> validate_against_window(opts)
    |> validate_label()
    |> foreign_key_constraint(:weekly_availability_id)
  end

  # Inside a same-day window these are the old rules (end after start, start
  # and end within the hours), each reported independently as before. Inside
  # an overnight window the order is read through midnight, so 23:30 to 00:30
  # is a valid break.
  defp validate_against_window(changeset, opts) do
    with id when is_integer(id) <- get_field(changeset, :weekly_availability_id),
         %Time{} = start_time <- get_field(changeset, :start_time),
         %Time{} = end_time <- get_field(changeset, :end_time),
         %{start_time: %Time{}, end_time: %Time{}} = window <-
           Keyword.get_lazy(opts, :work_hours, fn ->
             AvailabilityBreakQueries.get_work_hours(id)
           end) do
      {from, to} = Window.break_offsets(window, start_time, end_time)
      span = Window.span_seconds(window)

      changeset
      |> add_error_if(from >= to, :end_time, "must be after start time")
      |> add_error_if(from < 0, :start_time, "must be within work hours")
      |> add_error_if(to > span, :end_time, "must be within work hours")
    else
      _no_window -> TimeOrder.validate_time_order(changeset, :start_time, :end_time)
    end
  end

  defp add_error_if(changeset, true, field, message), do: add_error(changeset, field, message)
  defp add_error_if(changeset, false, _field, _message), do: changeset

  defp validate_label(changeset) do
    max = Constraints.break_label_max_length()
    validate_length(changeset, :label, max: max, message: "must be #{max} characters or less")
  end
end
