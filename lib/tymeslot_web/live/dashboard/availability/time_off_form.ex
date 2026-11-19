defmodule TymeslotWeb.Dashboard.Availability.TimeOffForm do
  @moduledoc """
  The data behind the time-off form modal of
  `TymeslotWeb.Dashboard.Availability.TimeOffCard`, as plain functions: the
  form as it opens for a new or a stored period, the attributes read from a
  submitted form, the form as it reads after a change, and the changeset's
  messages the form shows under its fields.
  """

  alias Ecto.Changeset
  alias Tymeslot.Availability.TimeOff
  alias Tymeslot.Validation.Constraints

  # Fields the form renders an inline error under. Anything else the changeset
  # can complain about has no home in the form and becomes a flash instead.
  # `attrs_from/1` and `errors/1` both read it, so every field an error is
  # reported for is also one the attributes carry, which `validate/4` relies on.
  @form_fields [:starts_on, :ends_on, :start_time, :end_time, :label]

  # The fields that decide which bookings the period swallows. The note does
  # not, so typing one must not send the overlap query off again.
  @schedule_fields [:starts_on, :ends_on, :start_time, :end_time]

  @doc """
  The form's attributes from submitted `params`, trimmed. Anything but a
  string, which only a hand-built event can send, reads as blank rather than
  crashing the component.
  """
  @spec attrs_from(map()) :: %{atom() => String.t()}
  def attrs_from(params) do
    Map.new(@form_fields, fn field ->
      case Map.get(params, to_string(field)) do
        value when is_binary(value) -> {field, String.trim(value)}
        _missing_or_malformed -> {field, ""}
      end
    end)
  end

  @doc """
  The form as it opens for a new period on `today`.

  The `min_*` dates keep the date pickers from offering days already gone,
  and the `max_*` ones the years a mistyped date lands in. On an edit
  (`edit/2`) both reach out to the stored date when it falls outside them, or
  the browser would refuse to submit a period already under way, or one
  already reaching further ahead than the bound allows, at all.
  """
  @spec blank(Date.t()) :: map()
  def blank(today) do
    last_day = today |> Constraints.time_off_last_end_date() |> Date.to_iso8601()

    @form_fields
    |> Map.new(&{&1, ""})
    |> Map.merge(%{
      mode: :create,
      id: nil,
      errors: %{},
      conflicts: [],
      today: Date.to_iso8601(today),
      min_starts_on: Date.to_iso8601(today),
      min_ends_on: Date.to_iso8601(today),
      max_starts_on: last_day,
      max_ends_on: last_day
    })
  end

  @doc """
  The form as it opens for the stored `period` on `today`.

  A stored period is read for overlaps as the form opens: an edit is the
  likelier way to swallow a booking, because the row is one the host already
  trusts, and the panel has to be there before anything is changed.
  """
  @spec edit(TimeOff.period(), Date.t()) :: map()
  def edit(period, today) do
    last_end_date = Constraints.time_off_last_end_date(today)

    %{
      mode: :edit,
      id: period.id,
      period: period,
      errors: %{},
      conflicts: TimeOff.conflicting_meetings(period),
      today: Date.to_iso8601(today),
      min_starts_on: earliest_iso8601(period.starts_on, today),
      min_ends_on: earliest_iso8601(period.ends_on, today),
      max_starts_on: latest_iso8601(period.starts_on, last_end_date),
      max_ends_on: latest_iso8601(period.ends_on, last_end_date),
      starts_on: Date.to_iso8601(period.starts_on),
      ends_on: Date.to_iso8601(period.ends_on),
      start_time: wire_time(period.start_time),
      end_time: wire_time(period.end_time),
      label: period.label || ""
    }
  end

  @doc """
  The form `data` after a change to `attrs`, run through the same rules as
  saving a period for `profile_id` on `today`, so a date in the past or a
  backwards range is flagged beside its field before the form is submitted.

  Only fields that hold a value report while the form is being filled in: a
  last day not chosen yet is not an error until the form is submitted.

  The rules themselves read nothing from the database: the period being
  edited was loaded when the form opened. Saving re-reads it. Only the overlap
  panel costs a query, and only when a date or a time has moved.
  """
  @spec validate(map(), map(), integer(), Date.t()) :: map()
  def validate(data, attrs, profile_id, today) do
    changeset =
      data
      |> validation_target(profile_id)
      |> TimeOff.validate(attrs, today: today)

    errors =
      changeset
      |> errors()
      |> Map.reject(fn {field, _message} -> Map.fetch!(attrs, field) == "" end)

    data
    |> Map.merge(attrs)
    |> Map.put(:errors, errors)
    |> Map.put(:conflicts, conflicts(data, attrs, changeset))
  end

  @doc """
  The changeset's first message for each field the form renders an error
  under.

  Kept as `{message, opts}` rather than flattened to a string: the form input
  translates that shape through the `errors` domain, interpolating counts, in
  whatever language the dashboard is in.
  """
  @spec errors(Changeset.t()) :: %{atom() => {String.t(), keyword()}}
  def errors(changeset) do
    changeset
    |> Changeset.traverse_errors(& &1)
    |> Map.take(@form_fields)
    |> Map.new(fn {field, messages} -> {field, List.first(messages)} end)
  end

  # The bookings already inside the period, so the modal can name them while
  # the dates are still being chosen rather than only once the row is written.
  # Reading them is a query, so it runs only when a date or a time actually
  # moved: every other change leaves the answer as it was.
  defp conflicts(data, attrs, changeset) do
    if Map.take(data, @schedule_fields) == Map.take(attrs, @schedule_fields) do
      Map.get(data, :conflicts, [])
    else
      TimeOff.conflicting_meetings(changeset)
    end
  end

  defp validation_target(%{mode: :edit, period: period}, _profile_id), do: period
  defp validation_target(_create, profile_id), do: profile_id

  defp earliest_iso8601(date, today), do: [date, today] |> Enum.min(Date) |> Date.to_iso8601()

  defp latest_iso8601(date, bound), do: [date, bound] |> Enum.max(Date) |> Date.to_iso8601()

  # The wire format the time dropdown submits, which is 24h whatever clock the
  # organiser reads; `TimeFormat.format/2` is for showing a time to someone.
  defp wire_time(nil), do: ""
  defp wire_time(%Time{} = time), do: Calendar.strftime(time, "%H:%M")
end
