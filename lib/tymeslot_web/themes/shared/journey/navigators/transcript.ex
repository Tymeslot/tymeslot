defmodule TymeslotWeb.Themes.Shared.Journey.Navigators.Transcript do
  @moduledoc """
  A conversation: the moments the booking has reached form a list, the
  answered ones above as its history and the current one last, and the next
  appears below by itself once its turn comes (`Navigators.Reveal`), as a
  reply does in a chat.

  An answered moment is changed by editing it. `go_to/3` with the moment's
  key (a control sending `navigate_to_step` with `phx-value-step` the key and
  carrying `data-intent="edit"`) forgets the facts the moment collected and
  every fact depending on them (`Runtime.clear/2`): the moment is current
  again, the moments after it leave the list, and it takes the focus. A step
  naming no answered moment changes nothing, and so does one naming a moment
  whose facts may not be revisited (`Fact.revisitable?/1`: the meeting type
  only for a booker who came through the overview, so a direct or private
  link never reopens the organiser's other meeting types), as `Paged`'s Back
  and step indicator refuse it. `back/2` steps back inside the current
  moment (the questions wizard) and, from its start, edits the last answered
  moment. While an outcome is current nothing is answered, so nothing is
  edited.

  The list is `<ol class="journey journey--transcript">`, a polite live region
  announcing each moment added to it; the moment that just opened, or the one
  edited, takes the focus through its `Journey.Components.moment_heading/1`.
  A theme's moment components render an `<li>` as their root.
  """

  @behaviour TymeslotWeb.Themes.Shared.Journey.Navigator

  import Phoenix.Component, only: [assign: 3]

  alias TymeslotWeb.Themes.Shared.Journey
  alias TymeslotWeb.Themes.Shared.Journey.Navigator
  alias TymeslotWeb.Themes.Shared.Journey.Navigators.Reveal
  alias TymeslotWeb.Themes.Shared.Journey.Progress
  alias TymeslotWeb.Themes.Shared.Journey.Runtime

  @impl Navigator
  def entry(journey, live_action, _assigns), do: Reveal.entry(journey, live_action)

  @impl Navigator
  def visible(journey, assigns), do: Reveal.visible(journey, assigns)

  @impl Navigator
  def continue(journey, socket), do: Reveal.continue(journey, socket)

  @impl Navigator
  def back(journey, socket), do: Reveal.back(journey, socket, &edit_last_answer(journey, &1))

  @impl Navigator
  def go_to(journey, socket, step) when is_binary(step) do
    case Enum.find(answered(journey, socket), &(Atom.to_string(&1.key) == step)) do
      nil -> {:noreply, socket}
      moment -> {:noreply, edit(journey, socket, moment)}
    end
  end

  def go_to(_journey, socket, _step), do: {:noreply, socket}

  @impl Navigator
  def settle(journey, socket), do: Reveal.settle(journey, socket)

  @impl Navigator
  def frame,
    do:
      {"ol",
       [
         class: "journey journey--transcript",
         "aria-live": "polite",
         "aria-relevant": "additions"
       ]}

  defp edit_last_answer(journey, socket) do
    case List.last(answered(journey, socket)) do
      nil -> {:noreply, socket}
      moment -> {:noreply, edit(journey, socket, moment)}
    end
  end

  defp edit(journey, socket, moment) do
    socket
    |> Runtime.clear(Progress.required(moment, socket.assigns))
    |> then(&Reveal.settle(journey, &1))
    |> assign(:journey_focus, moment.key)
  end

  # The moments that may be edited: answered (`:done`) and each of whose
  # facts may be revisited.
  defp answered(journey, socket) do
    for {moment, :done} <- Reveal.visible(journey, socket.assigns),
        Journey.revisitable?(moment, socket.assigns),
        do: moment
  end
end
