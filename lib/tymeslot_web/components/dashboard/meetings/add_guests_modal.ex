defmodule TymeslotWeb.Components.Dashboard.Meetings.AddGuestsModal do
  @moduledoc """
  Lets the host invite colleagues to a booking that already exists.

  Deliberately not gated on the meeting type's `allow_guests`: that setting
  decides whether the person booking may bring anyone, and says nothing about
  whom the host may invite to their own meeting afterwards.

  Addresses are collected one at a time, the way they are collected everywhere
  else in the app, so what is about to be sent is visible as a list rather than
  as text that still has to be parsed. Nothing is sent until the host says so.

  The guests already on the booking are listed rather than merely counted, so
  the host can see who has answered before adding to the list.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Components.CoreComponents

  attr :id, :string, required: true
  attr :show, :boolean, required: true
  attr :meeting, :map, default: nil
  attr :staged, :list, default: []
  attr :existing, :list, default: []
  attr :remaining, :integer, default: 0
  attr :on_cancel, Phoenix.LiveView.JS, required: true
  attr :confirm_event, :string, required: true
  attr :target, :any, required: true

  @spec add_guests_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def add_guests_modal(assigns) do
    ~H"""
    <CoreComponents.modal id={@id} show={@show} on_cancel={@on_cancel} size={:medium}>
      <:header>
        <div class="flex items-center gap-2">
          <CoreComponents.icon name="hero-user-plus" class="w-5 h-5 text-green-600" />
          {dgettext("dashboard_bookings", "Add guest")}
        </div>
      </:header>

      <div :if={@meeting} class="space-y-5">
        <p class="text-tymeslot-600 font-medium text-lg leading-relaxed">
          {dgettext(
            "dashboard_bookings",
            "Everyone you add receives the invitation with the calendar file, and can accept or decline. The guests already invited hear nothing."
          )}
        </p>

        <div>
          <p class="text-token-sm font-black uppercase tracking-wide text-tymeslot-400 mb-2">
            {dgettext("dashboard_bookings", "Email addresses")}
          </p>

          <div :if={@staged != []} class="flex flex-wrap gap-2 mb-3">
            <span
              :for={email <- @staged}
              class="inline-flex items-center gap-1.5 pl-3 pr-1.5 py-1 rounded-full bg-turquoise-50 border border-turquoise-200 text-turquoise-800 font-medium"
            >
              {email}
              <button
                type="button"
                phx-click="unstage_guest"
                phx-value-email={email}
                phx-target={@target}
                class="w-5 h-5 rounded-full hover:bg-turquoise-200 flex items-center justify-center transition-colors"
                aria-label={dgettext("dashboard_bookings", "Remove %{email}", email: email)}
              >
                <CoreComponents.icon name="hero-x-mark" class="w-3 h-3" />
              </button>
            </span>
          </div>

          <form
            :if={length(@staged) < @remaining}
            id="stage-guest-form"
            phx-submit="stage_guest"
            phx-target={@target}
            class="flex gap-3"
          >
            <input
              type="email"
              id="stage-guest-email"
              name="email"
              value=""
              placeholder="colleague@example.com"
              class="input flex-1"
            />
            <CoreComponents.action_button type="submit" variant={:secondary}>
              {dgettext("dashboard_bookings", "Add")}
            </CoreComponents.action_button>
          </form>

          <p class="text-tymeslot-500 font-medium mt-2">
            {dngettext(
              "dashboard_bookings",
              "Room for one more guest.",
              "Room for %{count} more guests.",
              @remaining - length(@staged)
            )}
          </p>
        </div>

        <div :if={@existing != []} class="space-y-2">
          <p class="text-token-sm font-black uppercase tracking-wide text-tymeslot-400">
            {dgettext("dashboard_bookings", "Already invited")}
          </p>
          <ul class="space-y-1">
            <li
              :for={guest <- @existing}
              class="flex items-center justify-between gap-3 text-tymeslot-600 font-medium"
            >
              <span class="truncate">{guest.email}</span>
              <span class="shrink-0 text-token-sm text-tymeslot-400">
                {status_label(guest.status)}
              </span>
            </li>
          </ul>
        </div>
      </div>

      <:footer>
        <div class="flex justify-end gap-3">
          <CoreComponents.action_button variant={:secondary} phx-click={@on_cancel}>
            {dgettext("common", "Cancel")}
          </CoreComponents.action_button>
          <CoreComponents.action_button
            variant={:primary}
            disabled={@staged == []}
            phx-click={@confirm_event}
            phx-target={@target}
          >
            {dgettext("dashboard_bookings", "Send invitation")}
          </CoreComponents.action_button>
        </div>
      </:footer>
    </CoreComponents.modal>
    """
  end

  defp status_label("accepted"), do: dgettext("dashboard_bookings", "Going")
  defp status_label("declined"), do: dgettext("dashboard_bookings", "Declined")
  defp status_label(_pending), do: dgettext("dashboard_bookings", "Awaiting reply")
end
