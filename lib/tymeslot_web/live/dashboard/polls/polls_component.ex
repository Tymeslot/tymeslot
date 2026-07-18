defmodule TymeslotWeb.Dashboard.Polls.PollsComponent do
  @moduledoc """
  Dashboard component for meeting polls.

  Meeting polls let a host propose several candidate slots and invite guests to
  vote on the times that suit them, then confirm a booking from the winning slot.
  This module is the parent component for the Polls section: it owns the list of
  the host's polls and the show/hide state of the create form, delegates
  rendering to `PollList` (the cards) and `PollForm` (the create flow), and
  reloads the list when the form reports a new poll.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.MeetingTypes
  alias Tymeslot.Polls
  alias TymeslotWeb.Dashboard.Polls.{PollForm, PollList}

  @impl Phoenix.LiveComponent
  def update(%{poll_created: true}, socket) do
    # The child form persisted a poll: refresh the list and close the form.
    {:ok, socket |> assign(:show_form, false) |> load_polls()}
  end

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:show_form, fn -> false end)
     |> assign_new(:selected_poll_id, fn -> nil end)
     |> assign_new(:meeting_types, fn -> [] end)
     |> load_polls()}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="space-y-10 pb-20">
      <%!-- Header --%>
      <.section_header
        icon="hero-hand-raised"
        title={dgettext("dashboard_common", "Polls")}
        class="mb-4"
      />

      <p class="text-tymeslot-600 mb-6">
        {dgettext(
          "dashboard_common",
          "Find a time that works for everyone. Propose a few slots and let your guests vote."
        )}
      </p>

      <div id="polls-container" class="space-y-6">
        <div :if={!@show_form} class="flex justify-end">
          <button
            type="button"
            phx-click="new_poll"
            phx-target={@myself}
            class="btn btn-primary inline-flex items-center gap-1"
          >
            <.icon name="hero-plus" class="w-4 h-4" />
            {dgettext("dashboard_common", "New poll")}
          </button>
        </div>

        <.live_component
          :if={@show_form}
          module={PollForm}
          id="poll-form"
          current_user={@current_user}
          profile={@profile}
          meeting_types={@meeting_types}
          parent_id={@id}
          parent_myself={@myself}
        />

        <PollList.poll_list
          polls={@polls}
          profile={@profile}
          integration_status={@integration_status}
          selected_poll_id={@selected_poll_id}
          myself={@myself}
        />
      </div>
    </div>
    """
  end

  @impl Phoenix.LiveComponent
  def handle_event("new_poll", _params, socket) do
    meeting_types =
      socket.assigns.current_user.id
      |> MeetingTypes.get_active_meeting_types()
      |> Enum.reject(& &1.payment_required)

    {:noreply, assign(socket, show_form: true, meeting_types: meeting_types)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("cancel_poll_form", _params, socket) do
    {:noreply, assign(socket, :show_form, false)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("select_poll", %{"id" => id}, socket) do
    {:noreply, assign(socket, :selected_poll_id, id)}
  end

  defp load_polls(socket) do
    assign(socket, :polls, Polls.list_polls(socket.assigns.current_user.id))
  end
end
