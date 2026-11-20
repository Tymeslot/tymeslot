defmodule TymeslotWeb.Dashboard.Calendar.PanelFields do
  @moduledoc """
  The side panel's plain fields: what a title, place or notes edit writes,
  the Busy/Free switch, and the reminder list.

  Text goes through `CreateParams.clean_text/2`, the rule a create uses (title
  500, place 1,000, notes 5,000 characters, a title never blank). The reminder
  field lists every alarm the event carries, each removable, and adds a
  notification or an email at a lead time `ReminderForm` allows. An add or a
  remove writes the whole list back with every other alarm untouched, so an
  alarm another app set at a lead time the panel does not offer survives
  every edit but its own removal.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.CalendarGrid.CreateParams
  alias Tymeslot.Integrations.Calendar.Reminder
  alias TymeslotWeb.Components.Calendar.ReminderForm
  alias TymeslotWeb.Dashboard.Calendar.Creation
  alias TymeslotWeb.Dashboard.Calendar.PanelReminderList

  @text_fields %{
    "title" => {:summary, :title},
    "location" => {:location, :location},
    "notes" => {:description, :description}
  }

  @doc """
  The change a text field's `value` makes (`field` is the event the panel
  sends: `"title"`, `"location"` or `"notes"`), or why it cannot be saved.
  """
  @spec text_change(String.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def text_change(field, value) when is_binary(value) do
    {key, create_field} = Map.fetch!(@text_fields, field)

    case CreateParams.clean_text(create_field, value) do
      {:ok, clean} -> {:ok, %{key => clean}}
      {:error, _field, reason} -> {:error, Creation.refusal_message(create_field, reason)}
    end
  end

  @doc "The `transparency` a Busy/Free choice writes."
  @spec transparency(String.t()) :: String.t()
  def transparency("free"), do: "transparent"
  def transparency("busy"), do: "opaque"

  @doc """
  The reminders an event carrying `reminders`, on a calendar of `provider`,
  gets with the reminder the add row's `params` choose (`"minutes"`,
  `"method"`), appended so the alarms already there are written back as
  they are. `:error`, writing nothing, for a choice the row does not offer,
  one the event already has, or a list already as long as the calendar
  keeps (`CreateParams.reminder_capacity/1`); a calendar keeping one method
  takes that one, whatever the row sent.
  """
  @spec add_reminder([map()], map(), String.t() | nil) :: {:ok, [map()]} | :error
  def add_reminder(reminders, params, provider) do
    {max, methods} = CreateParams.reminder_capacity(provider)
    method = if match?([_only], methods), do: Atom.to_string(hd(methods)), else: params["method"]

    with true <- length(reminders) < max,
         {:ok, reminder} <-
           ReminderForm.parse_reminder(%{"method" => method, "minutes" => params["minutes"]}),
         false <- Enum.any?(reminders, &(key(&1) == key(reminder))) do
      {:ok, reminders ++ [reminder]}
    else
      _not_added -> :error
    end
  end

  @doc """
  `reminders` without the one at `index`, every other alarm kept as it is.
  `key` is the removed reminder's `key/1` as the panel drew it: when the
  list has changed under the panel since (a sync), the reminder at `index`
  is another one and `:error` removes nothing.
  """
  @spec drop_reminder([map()], term(), term()) :: {:ok, [map()]} | :error
  def drop_reminder(reminders, index, key) do
    with {at, ""} <- Integer.parse(to_string(index)),
         %{} = reminder <- Enum.at(reminders, at),
         true <- at >= 0 and key(reminder) == key do
      {:ok, List.delete_at(reminders, at)}
    else
      _stale_or_invalid -> :error
    end
  end

  @doc """
  The provider of the integration `integration_id` among `integrations`,
  which decides how many reminders, and of which methods, a calendar keeps.
  `nil` for none (a booking, which no calendar holds).
  """
  @spec provider([map()], term()) :: String.t() | nil
  def provider(integrations, integration_id) do
    case Enum.find(integrations, &(&1.id == integration_id)) do
      nil -> nil
      integration -> integration.provider
    end
  end

  @doc """
  What tells a reminder apart in the list, its method and lead time, read
  through `Reminder` so a cached string-keyed alarm matches a canonical one.
  """
  @spec key(map()) :: String.t()
  def key(reminder), do: "#{Reminder.method(reminder)}:#{Reminder.minutes_before(reminder)}"

  attr :free, :boolean, required: true
  attr :target, :any, required: true

  @doc "Busy or Free, with what the choice means for bookings."
  @spec busy_free(map()) :: Phoenix.LiveView.Rendered.t()
  def busy_free(assigns) do
    ~H"""
    <div>
      <p class="label" aria-hidden="true">
        {dgettext("dashboard_calendar_editing", "Show me as")}
      </p>
      <.segmented_control
        id="calendar-panel-free"
        value={if @free, do: "free", else: "busy"}
        on_change="panel:free"
        target={@target}
        aria_label={dgettext("dashboard_calendar_editing", "Show me as")}
        size={:sm}
      >
        <:option value="busy" label={dgettext("dashboard_calendar_editing", "Busy")} />
        <:option value="free" label={dgettext("dashboard_calendar_editing", "Free")} />
      </.segmented_control>
      <p class="mt-1 text-token-xs text-tymeslot-500">
        {if @free,
          do: dgettext("dashboard_calendar_editing", "Guests can book this time"),
          else: dgettext("dashboard_calendar_editing", "Guests can't book this time")}
      </p>
    </div>
    """
  end

  attr :reminders, :list, required: true
  attr :provider, :string, default: nil, doc: "the provider of the event's calendar"
  attr :disabled, :boolean, default: false
  attr :target, :any, required: true

  @doc """
  The event's reminders, each removable, and the row that adds one; read
  only, without either, when the event cannot be changed.
  """
  @spec reminder_field(map()) :: Phoenix.LiveView.Rendered.t()
  def reminder_field(assigns) do
    {max, methods} = CreateParams.reminder_capacity(assigns.provider)

    assigns =
      assign(assigns,
        full: length(assigns.reminders) >= max,
        single: match?([_only], methods)
      )

    ~H"""
    <section id="calendar-panel-reminders" class="space-y-2">
      <h3 class="label mb-0">{dgettext("dashboard_calendar_editing", "Reminders")}</h3>
      <PanelReminderList.chips
        id="calendar-panel-reminder-list"
        reminders={@reminders}
        remove={
          !@disabled &&
            fn {reminder, index} ->
              JS.push("panel:drop_reminder",
                value: %{index: index, key: key(reminder)},
                target: @target
              )
            end
        }
      />
      <p :if={@reminders == [] and @disabled} class="text-token-sm text-tymeslot-500">
        {dgettext("dashboard_calendar_editing", "None")}
      </p>
      <form
        :if={!@disabled and !@full}
        id="calendar-panel-reminder-add"
        class="flex flex-wrap items-end gap-2"
        phx-submit="panel:add_reminder"
        phx-target={@target}
        novalidate
      >
        <.select
          id="calendar-panel-reminder-minutes"
          name="minutes"
          compact
          aria-label={dgettext("dashboard_calendar_editing", "Reminder time")}
          options={PanelReminderList.minutes_options()}
        />
        <.select
          :if={!@single}
          id="calendar-panel-reminder-method"
          name="method"
          compact
          aria-label={dgettext("dashboard_calendar_editing", "Reminder method")}
          options={PanelReminderList.method_options()}
        />
        <.action_button
          id="calendar-panel-reminder-add-button"
          type="submit"
          variant={:secondary}
          size={:sm}
        >
          {dgettext("dashboard_calendar_editing", "Add reminder")}
        </.action_button>
      </form>
    </section>
    """
  end
end
