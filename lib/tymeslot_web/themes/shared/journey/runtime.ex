defmodule TymeslotWeb.Themes.Shared.Journey.Runtime do
  @moduledoc """
  The engine every theme's booking runs on: the parts of the flow that are
  no one fact's. The journey is `socket.assigns.journey`, which
  `SchedulingLive` assigns on mount.

  `handle_step_event/4` routes a step component's `{:step_event, moment,
  event, data}`, in this order:

    1. `next_step` and `back_step` from the current moment go to the
       navigator's `continue/2` and `back/2`;
    2. `schedule_another` from the confirmation starts the booking again
       (`restart/1`);
    3. an ambient event (`Journey.Ambient`: the timezone picker's) is
       accepted from every visible moment, never from an outcome;
    4. an event a fact owns goes to that fact's `handle/3` when the moment
       it came from is visible (`Navigator.visible/2`) and collects the
       fact, this booking needs the owner (`required?/1`), and every fact
       the owner `requires/1` is known;
    5. anything else is `:unhandled`, which `SchedulingLive` logs and drops.

  A theme's own `theme:<name>` events never reach this module. With
  `Navigators.Paged` only the current moment is visible, so a canonical
  event sent from another step is dropped, as it always was. A page without
  a journey (the meeting and poll pages the same LiveView serves) handles
  none of them, and its step indicator moves nothing.

  `transition_to/3` shows a moment or an outcome: it sets `:current_state`
  and, for a moment, runs each collected fact's `enter/2` with `params` (the
  URL's, or `%{}` for a move inside the page). The navigators and
  `BookingFlow` move through it. `navigate_to_step/2` is the step
  indicator's click, handed to the navigator's `go_to/3`.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]

  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Themes.Shared.GuestBooking
  alias TymeslotWeb.Themes.Shared.Journey
  alias TymeslotWeb.Themes.Shared.Journey.Ambient
  alias TymeslotWeb.Themes.Shared.ReschedulePin

  @type reply :: {:noreply, Socket.t()}

  @doc """
  Handles an event a step component bubbled up from `moment_key`.

  Returns `:unhandled` for an event the booking does not take from there, so
  the LiveView can log and drop it.
  """
  @spec handle_step_event(Socket.t(), atom(), atom(), term()) :: reply() | :unhandled
  def handle_step_event(%Socket{assigns: %{journey: journey}} = socket, moment_key, event, data) do
    cond do
      navigation?(journey, socket.assigns, moment_key, event) ->
        navigate(journey, socket, event)

      restart?(socket.assigns, moment_key, event) ->
        {:noreply, restart(socket)}

      event in Ambient.events() ->
        ambient_event(journey, socket, moment_key, event, data)

      true ->
        fact_event(journey, socket, moment_key, event, data)
    end
  end

  def handle_step_event(_socket, _moment_key, _event, _data), do: :unhandled

  @doc "Shows the moment or outcome `key`, running what its facts set up."
  @spec transition_to(Socket.t(), atom(), map()) :: Socket.t()
  def transition_to(socket, key, params) do
    socket = assign(socket, :current_state, key)

    case Journey.moment(socket.assigns.journey, key) do
      nil -> socket
      moment -> Enum.reduce(moment.collects, socket, &Journey.fact!(&1).enter(&2, params))
    end
  end

  @doc """
  Starts the booking again, in place: the confirmation's "Schedule another
  meeting". A booker who came through the overview returns to the journey's
  opening moment; any other (a private or direct link, a reschedule) to the
  moment a meeting type's own link opens on, for the same meeting type, so
  the organiser's other types stay hidden.
  """
  # The flow restarts here without navigating, so the reschedule context has
  # to be dropped explicitly or the next submit moves the meeting that was
  # just moved (see `ReschedulePin.abandon/1`). The day and time belong to
  # the booking just made: kept, the schedule step would reopen the calendar
  # on them, with a time that is no longer free.
  @spec restart(Socket.t()) :: Socket.t()
  def restart(socket) do
    journey = socket.assigns.journey
    opening = journey.navigator.entry(journey, restart_route(socket.assigns), socket.assigns)

    socket
    |> GuestBooking.assign_defaults()
    |> ReschedulePin.abandon()
    |> assign(selected_date: nil, selected_time: nil)
    |> transition_to(opening, %{})
  end

  @doc """
  Handles a click on the step indicator: the navigator decides where it may
  go (`Navigator.go_to/3`).
  """
  # `step` is guarded to a binary: a crafted socket push can deliver a
  # non-binary payload, which `Integer.parse/1` has no clause for.
  @spec navigate_to_step(Socket.t(), map()) :: reply()
  def navigate_to_step(%Socket{assigns: %{journey: journey}} = socket, %{"step" => step})
      when is_binary(step),
      do: journey.navigator.go_to(journey, socket, step)

  def navigate_to_step(socket, _params), do: {:noreply, socket}

  defp navigation?(journey, assigns, moment_key, event) do
    event in [:next_step, :back_step] and moment_key == assigns[:current_state] and
      Journey.moment(journey, moment_key) != nil
  end

  defp navigate(journey, socket, :next_step), do: journey.navigator.continue(journey, socket)
  defp navigate(journey, socket, :back_step), do: journey.navigator.back(journey, socket)

  # The route whose entry the booking starts again on: the overview, or the
  # meeting type's own link (`/:username/:slug`, live action `:schedule`),
  # so a restart opens where a fresh visit by the same way in would.
  defp restart_route(%{entered_via_overview: true}), do: :overview
  defp restart_route(_assigns), do: :schedule

  defp restart?(assigns, moment_key, event) do
    event == :schedule_another and moment_key == :confirmation and
      assigns[:current_state] == :confirmation
  end

  defp ambient_event(journey, socket, moment_key, event, data) do
    case visible_moment(journey, socket.assigns, moment_key) do
      {:ok, _moment} -> Ambient.handle(socket, event, data)
      :none -> :unhandled
    end
  end

  defp fact_event(journey, socket, moment_key, event, data) do
    case owner(journey, socket.assigns, moment_key, event) do
      {:ok, fact} -> fact.handle(socket, event, data)
      :none -> :unhandled
    end
  end

  # The fact owning `event` among those `moment_key` collects, when that
  # moment is on screen, this booking needs the owner, and every fact the
  # owner needs is known.
  defp owner(journey, assigns, moment_key, event) do
    with {:ok, moment} <- visible_moment(journey, assigns, moment_key),
         {:ok, fact} <- owning_fact(moment, event),
         true <- fact.required?(assigns),
         true <- Enum.all?(fact.requires(assigns), &Journey.fact!(&1).known?(assigns)) do
      {:ok, fact}
    else
      _refused -> :none
    end
  end

  defp visible_moment(journey, assigns, moment_key) do
    visible = journey.navigator.visible(journey, assigns)

    case Enum.find(visible, fn {moment, _state} -> moment.key == moment_key end) do
      {moment, _state} -> {:ok, moment}
      nil -> :none
    end
  end

  defp owning_fact(moment, event) do
    case Enum.find(Enum.map(moment.collects, &Journey.fact!/1), &(event in &1.events())) do
      nil -> :none
      fact -> {:ok, fact}
    end
  end
end
