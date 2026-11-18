defmodule TymeslotWeb.Dashboard.Calendar.PanelNewRepeat do
  @moduledoc """
  Repeat in the side panel's New event state: the draft can be made a
  series before it is created, so the whole series is written at once and
  its guests are invited to the series, as the old Quick Add allowed.

  It offers what the edit panel's Repeat field does (`PanelRepeat`): the
  common patterns named for the draft's own start, and Custom…, which
  opens the repeat editor (`RecurrenceEditor`) inside the New event form.
  The form keeps the choice (`"repeat"`, a `PanelRepeat` preset or
  `"custom"`) and the editor's fields (`"repeat_custom"`); the rule is
  composed from the draft as cast, so it follows a start that moves, and
  what the calendar would refuse is refused before anything is written. A
  Tymeslot meeting and a group event do not repeat, so the field gives way
  to them.
  """

  alias Tymeslot.CalendarGrid.CreateParams
  alias TymeslotWeb.Components.Calendar.RecurrenceEditor
  alias TymeslotWeb.Components.Calendar.RepeatForm
  alias TymeslotWeb.Dashboard.Calendar.PanelGroupEvent
  alias TymeslotWeb.Dashboard.Calendar.PanelMeeting
  alias TymeslotWeb.Dashboard.Calendar.PanelRepeat

  @custom_fields ~w(freq interval by_day on end_type count until)

  @doc "The repeat fields among a form change's `params`."
  @spec fields(map()) :: map()
  def fields(params) do
    choice =
      case params["repeat"] do
        choice when is_binary(choice) -> %{"repeat" => choice}
        _absent -> %{}
      end

    custom =
      if Map.has_key?(params, "freq"),
        do: %{"repeat_custom" => Map.take(params, @custom_fields)},
        else: %{}

    Map.merge(choice, custom)
  end

  @doc """
  Whether the form is one that can repeat: a plain calendar event, neither
  a meeting nor a group event as the form counts them (`PanelMeeting.on?/1`,
  `PanelGroupEvent.on?/2`, `group_allowed` being the organiser's plan).
  """
  @spec offered?(map(), boolean()) :: boolean()
  def offered?(form, group_allowed),
    do: not PanelMeeting.on?(form) and not PanelGroupEvent.on?(group_allowed, form)

  @doc """
  The rule the form's repeat choice makes for `create`, the draft as cast,
  on a calendar of `provider`, in the organiser's `timezone`, for an
  organiser whose plan allows group events or not: `{:ok, nil}`
  for none, or `{:error, :repeat, message}` when the calendar would refuse
  it.
  """
  @spec rule(map(), CreateParams.t(), String.t() | nil, String.t(), boolean()) ::
          {:ok, String.t() | nil} | {:error, :repeat, String.t()}
  def rule(form, create, provider, timezone, group_allowed) do
    with true <- offered?(form, group_allowed),
         {:ok, spec} <- spec(form) do
      case PanelRepeat.rule_for(spec, event(create, provider), nil, timezone) do
        {:ok, rule, _opts} -> {:ok, rule}
        :unchanged -> {:ok, nil}
        {:error, message} -> {:error, :repeat, message}
      end
    else
      _none -> {:ok, nil}
    end
  end

  @doc """
  What the field shows for `create`, the draft as cast (see
  `PanelRepeat.field/2`): the form's choice, the rule the editor draws, and
  a summary of the rule the choice makes, left out while the calendar
  refuses it. Nothing for a draft the
  domain has not accepted yet.
  """
  @spec field(map(), CreateParams.t() | nil, String.t() | nil, String.t(), boolean()) ::
          map() | nil
  def field(_form, nil, _provider, _timezone, _group_allowed), do: nil

  def field(form, create, provider, timezone, group_allowed) do
    field = PanelRepeat.field(event(create, provider), timezone)
    choice = choice(form)

    %{
      field
      | current: choice,
        rule:
          if(choice == "custom",
            do: typed_rule(form, create, field),
            else: create.recurrence_rule
          ),
        summary: summary(form, create, provider, timezone, group_allowed, field.start)
    }
  end

  # What the form's choice repeats by now; none while the calendar refuses
  # it, rather than the last rule it accepted, which the header's refusal
  # would then seem to contradict.
  defp summary(form, create, provider, timezone, group_allowed, start) do
    case rule(form, create, provider, timezone, group_allowed) do
      {:ok, rule} when is_binary(rule) -> RecurrenceEditor.summary(rule, start)
      _none_or_refused -> nil
    end
  end

  # The editor draws the pattern its fields hold, refused or not, so a
  # pattern the calendar refuses stays on screen to be changed rather than
  # falling back to "Does not repeat" and going out as a one-off.
  defp typed_rule(form, create, field) do
    composed =
      RepeatForm.compose_recurrence_rule(form["repeat_custom"] || %{}, %{
        all_day: create.all_day,
        start_date: date_of(field.start),
        timezone: field.timezone,
        rule: nil,
        check_until: false
      })

    if is_binary(composed), do: composed
  end

  defp date_of(%DateTime{} = at), do: DateTime.to_date(at)
  defp date_of(%Date{} = date), do: date

  defp choice(form) do
    case form["repeat"] do
      "custom" -> "custom"
      choice when is_binary(choice) -> if(PanelRepeat.preset?(choice), do: choice, else: "none")
      _none -> "none"
    end
  end

  defp spec(form) do
    case choice(form) do
      "none" -> :none
      "custom" -> {:ok, {:custom, form["repeat_custom"] || %{}}}
      preset -> {:ok, {:preset, preset}}
    end
  end

  # The draft as the repeat field reads an event: a one-off with no rule yet,
  # starting where the draft does, on the calendar it is going to.
  defp event(%CreateParams{all_day: true} = create, provider),
    do: %{all_day: true, start_date: create.start_at, recurrence_rule: nil, provider: provider}

  defp event(create, provider),
    do: %{all_day: false, start_at: create.start_at, recurrence_rule: nil, provider: provider}
end
