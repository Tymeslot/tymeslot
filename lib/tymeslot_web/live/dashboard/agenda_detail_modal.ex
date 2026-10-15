defmodule TymeslotWeb.Dashboard.AgendaDetailModal do
  @moduledoc """
  Detail modal for a single agenda appointment.

  Stateless function component rendered by `DashboardOverviewComponent` when a
  row in the agenda is clicked. The details and the Join and Manage actions are
  `AppointmentDetails`, shared with the calendar's booking modal; this modal
  adds the colour picker. Dismissal dispatches `close_entry` back to the owning
  component (`@myself`), which holds the open/closed state.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias Tymeslot.Agenda.Entry
  alias Tymeslot.Integrations.Calendar.EventColour
  alias TymeslotWeb.Components.Dashboard.Appointments.AppointmentDetails
  alias TymeslotWeb.Dashboard.DashboardFormat

  attr :entry, Entry, required: true
  attr :timezone, :string, required: true
  attr :time_format, :string, required: true
  attr :now, DateTime, required: true
  attr :myself, :any, required: true

  @spec agenda_detail_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def agenda_detail_modal(assigns) do
    ~H"""
    <.modal
      id="agenda-detail-modal"
      show={true}
      on_cancel={JS.push("close_entry", target: @myself)}
      size={:medium}
    >
      <:header>{DashboardFormat.title(@entry.title)}</:header>

      <div class="space-y-6">
        <AppointmentDetails.appointment_details
          entry={@entry}
          timezone={@timezone}
          time_format={@time_format}
          now={@now}
        />

        <div :if={@entry.target}>
          <p
            id="agenda-colour-picker-label"
            class="text-token-xs font-black uppercase tracking-widest text-tymeslot-400 mb-2"
          >
            {dgettext("dashboard_home", "Colour")}
          </p>
          <div
            role="radiogroup"
            aria-labelledby="agenda-colour-picker-label"
            class="flex flex-wrap items-center gap-2"
          >
            <button
              :for={{key, label, swatch_class} <- EventColour.palette()}
              type="button"
              role="radio"
              aria-checked={to_string(@entry.colour == key)}
              phx-click="set_entry_colour"
              phx-value-colour={key}
              phx-value-target={encode_target(@entry.target)}
              phx-target={@myself}
              aria-label={label}
              class={[
                "w-7 h-7 rounded-token-full border-2 transition",
                swatch_class,
                @entry.colour == key && "ring-2 ring-turquoise-500 ring-offset-2 border-white",
                @entry.colour != key && "border-transparent hover:scale-110"
              ]}
            ></button>
            <button
              type="button"
              role="radio"
              aria-checked={to_string(@entry.colour == nil)}
              phx-click="clear_entry_colour"
              phx-value-target={encode_target(@entry.target)}
              phx-target={@myself}
              class={[
                "inline-flex items-center h-7 px-3 rounded-token-full border text-token-xs font-bold transition",
                @entry.colour == nil && "border-turquoise-400 text-turquoise-700 bg-turquoise-50",
                @entry.colour != nil && "border-tymeslot-200 text-tymeslot-500 hover:bg-tymeslot-50"
              ]}
            >
              {dgettext("dashboard_home", "Default")}
            </button>
          </div>
        </div>
      </div>

      <:footer :if={AppointmentDetails.actions?(@entry)}>
        <AppointmentDetails.appointment_actions entry={@entry} />
      </:footer>
    </.modal>
    """
  end

  # Encodes an entry's colour target into a DOM-safe string for `phx-value-*`.
  # `DashboardOverviewComponent.decode_target/1` is the inverse. `parts: 2` keeps
  # any colons inside a provider uid intact on the way back.
  defp encode_target({:meeting, id}), do: "meeting:#{id}"
  defp encode_target({:external, integration_id, uid}), do: "external:#{integration_id}:#{uid}"
end
