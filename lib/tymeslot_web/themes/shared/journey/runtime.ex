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
       fact, this booking needs the owner (`required?/1`), every fact the
       owner `requires/1` is known, and, when the moment is not the current
       one, the owner may be revisited (`revisitable?/1`); when such an
       event changes the owner's value, the facts depending on it are
       forgotten (`clear/2`), so the page moves back to them;
    5. anything else is `:unhandled`, which `SchedulingLive` logs and drops.

  A theme's own `theme:<name>` events never reach this module. With
  `Navigators.Paged` only the current moment is visible, so a canonical
  event sent from another step is dropped, as it always was. A page without
  a journey (the meeting and poll pages the same LiveView serves) handles
  none of them, and its step indicator moves nothing.

  `transition_to/3` shows a moment or an outcome: it sets `:current_state`
  and, for a moment, opens it (`open_moment/3`: its `defaults:`, then
  `enter/2` of each collected fact the booking requires, with `params`, the
  URL's or `%{}` for a move inside the page) and lets the navigator settle
  (`settle/1`). The navigators and `BookingFlow` move through it. A fact's
  or an ambient event settles too, and when that moves `:current_state` the
  new current moment becomes `:journey_focus`. `clear/2` forgets facts and
  those depending on them. `navigate_to_step/2` is the step indicator's
  click, handed to the navigator's `go_to/3`.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]

  alias Phoenix.LiveView.Socket
  alias Tymeslot.MeetingPayments
  alias TymeslotWeb.Themes.Shared.GuestBooking
  alias TymeslotWeb.Themes.Shared.Journey
  alias TymeslotWeb.Themes.Shared.Journey.Ambient
  alias TymeslotWeb.Themes.Shared.Journey.Moment
  alias TymeslotWeb.Themes.Shared.Journey.Progress
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

  @doc """
  Shows the moment or outcome `key`. A moment is opened (`open_moment/3`),
  then the navigator settles what the booking now reaches (`settle/1`).
  """
  @spec transition_to(Socket.t(), atom(), map()) :: Socket.t()
  def transition_to(socket, key, params) do
    socket = assign(socket, :current_state, key)

    case Journey.moment(socket.assigns.journey, key) do
      %Moment{} = moment -> socket |> open_moment(moment, params) |> settle()
      nil -> socket
    end
  end

  @doc """
  Shows `moment`: applies its `defaults:` to each defaulted fact not yet
  known (the fact's `default/2`), runs `enter/2` of each fact it collects
  that the booking requires, with `params` (the URL parameters on arrival,
  `%{}` inside the page), and records the moment in `:journey_opened`, so a
  navigator showing several moments enters each once while it stays shown.
  """
  @spec open_moment(Socket.t(), Moment.t(), map()) :: Socket.t()
  def open_moment(socket, %Moment{} = moment, params) do
    facts = Journey.facts()

    socket
    |> apply_defaults(moment, facts)
    |> enter_facts(moment, params, facts)
    |> then(&assign(&1, :journey_opened, MapSet.put(opened(&1), moment.key)))
  end

  @doc """
  Forgets `keys` and every fact depending on them for this booking
  (`Progress.dependents/3`), through each fact's `clear/1`.
  """
  @spec clear(Socket.t(), [atom()]) :: Socket.t()
  def clear(socket, keys) do
    facts = Journey.facts()

    keys
    |> Enum.flat_map(&Progress.dependents(&1, socket.assigns, facts))
    |> Enum.uniq()
    |> Enum.reduce(socket, fn key, acc ->
      fact = Map.fetch!(facts, key)

      if Code.ensure_loaded?(fact) and function_exported?(fact, :clear, 1),
        do: fact.clear(acc),
        else: acc
    end)
  end

  @doc """
  Lets the journey's navigator reveal what the booking reaches now
  (`Navigator.settle/2`); the socket unchanged for a navigator without one.
  """
  @spec settle(Socket.t()) :: Socket.t()
  def settle(%Socket{assigns: %{journey: %Journey{navigator: navigator} = journey}} = socket) do
    if Code.ensure_loaded?(navigator) and function_exported?(navigator, :settle, 2),
      do: navigator.settle(journey, socket),
      else: socket
  end

  def settle(socket), do: socket

  @doc """
  Starts the booking again, in place: the confirmation's "Schedule another
  meeting". It keeps the meeting type and forgets every fact depending on
  it (the time, the answers, the booking just made). A booker who came
  through the overview returns to the journey's opening moment; any other
  (a private or direct link, a reschedule) to the moment a meeting type's
  own link opens on, for the same meeting type, so the organiser's other
  types stay hidden.
  """
  # The flow restarts here without navigating, so the reschedule context has
  # to be dropped explicitly or the next submit moves the meeting that was
  # just moved (see `ReschedulePin.abandon/1`). The day and time belong to
  # the booking just made: kept, the schedule step would reopen the calendar
  # on them, with a time that is no longer free. The answers are the last
  # booker's, and the booking's `meeting_uid` would leave the attendee
  # known, so the next booking's details moment would open as done. A
  # reschedule still named in the URL is patched out of it, to the route the
  # booking starts again on, so a reload does not start the move over.
  @spec restart(Socket.t()) :: Socket.t()
  def restart(socket) do
    journey = socket.assigns.journey
    route = restart_route(socket.assigns)
    opening = journey.navigator.entry(journey, route, socket.assigns)

    socket
    |> clear(Progress.dependents(:meeting_type, socket.assigns) -- [:meeting_type])
    |> forget_payment_wait()
    |> GuestBooking.assign_defaults()
    |> ReschedulePin.abandon()
    |> assign(selected_date: nil, selected_time: nil)
    |> assign(:journey_opened, MapSet.new())
    |> transition_to(opening, %{})
    |> ReschedulePin.drop_from_url(route)
  end

  @doc """
  Forgets a paid booking's payment wait: the meeting it waited on and its
  checkout link, and the page's subscription to that meeting's payment
  broadcasts, so a repeated broadcast for it cannot move a later booking.
  """
  @spec forget_payment_wait(Socket.t()) :: Socket.t()
  def forget_payment_wait(socket) do
    case socket.assigns[:awaiting_payment_meeting] do
      %{id: id} -> Phoenix.PubSub.unsubscribe(Tymeslot.PubSub, MeetingPayments.payment_topic(id))
      _none -> :ok
    end

    assign(socket, awaiting_payment_meeting: nil, awaiting_payment_checkout_url: nil)
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

  @doc """
  The step numbers the step indicator may offer as clickable: those its
  `navigate_to_step` would move to (`Navigator.can_go_to?/3`). None on a
  page without a journey, or whose navigator has no numbered steps.
  """
  @spec navigable_steps(map()) :: [pos_integer()]
  def navigable_steps(%{journey: %Journey{navigator: navigator} = journey} = assigns) do
    if Code.ensure_loaded?(navigator) and function_exported?(navigator, :can_go_to?, 3),
      do: Enum.filter(1..length(journey.moments)//1, &navigator.can_go_to?(journey, assigns, &1)),
      else: []
  end

  def navigable_steps(_assigns), do: []

  defp navigation?(journey, assigns, moment_key, event) do
    event in [:next_step, :back_step] and moment_key == assigns[:current_state] and
      Journey.moment(journey, moment_key) != nil
  end

  defp navigate(journey, socket, :next_step), do: journey.navigator.continue(journey, socket)
  defp navigate(journey, socket, :back_step), do: journey.navigator.back(journey, socket)

  # The route whose entry the booking starts again on: the overview, or the
  # meeting type's own link (`/:username/:slug`, live action `:schedule`),
  # so a restart opens where a fresh visit by the same way in would. A page
  # holding no meeting type (a direct visit to `/:username/thank-you`) has no
  # schedule to return to, so it starts again on the overview.
  defp restart_route(%{entered_via_overview: true}), do: :overview
  defp restart_route(%{meeting_type: %{}}), do: :schedule
  defp restart_route(_assigns), do: :overview

  defp restart?(assigns, moment_key, event) do
    event == :schedule_another and moment_key == :confirmation and
      assigns[:current_state] == :confirmation
  end

  defp ambient_event(journey, socket, moment_key, event, data) do
    case visible_moment(journey, socket.assigns, moment_key) do
      {:ok, _moment, _state} -> socket |> Ambient.handle(event, data) |> after_event()
      :none -> :unhandled
    end
  end

  defp fact_event(journey, socket, moment_key, event, data) do
    case owner(journey, socket.assigns, moment_key, event) do
      {:ok, fact, :current} ->
        socket |> fact.handle(event, data) |> after_event()

      {:ok, fact, _answered} ->
        socket |> fact.handle(event, data) |> forget_dependents(fact, socket) |> after_event()

      :none ->
        :unhandled
    end
  end

  # A fact answered earlier changed: what the booking built on its old value
  # (a time picked for another meeting type's length, the details form opened
  # for it) is forgotten, so settling moves the page back to the first moment
  # still to complete. The fact itself keeps its new value.
  defp forget_dependents({:noreply, socket}, fact, before) do
    if changed?(fact, before, socket) do
      key = fact.key()
      {:noreply, clear(socket, Progress.dependents(key, socket.assigns) -- [key])}
    else
      {:noreply, socket}
    end
  end

  defp forget_dependents(other, _fact, _before), do: other

  # What a fact holds is what its `clear/1` resets, so it changed when one of
  # those assigns did. Comparing them, rather than taking every event as a
  # change, keeps a click on the meeting type already chosen from forgetting
  # the time. A fact without `clear/1` cannot be forgotten, nor read as
  # changed.
  defp changed?(fact, before, socket) do
    if Code.ensure_loaded?(fact) and function_exported?(fact, :clear, 1) do
      (held(fact, before) ++ held(fact, socket))
      |> Enum.uniq()
      |> Enum.any?(&(Map.get(before.assigns, &1) != Map.get(socket.assigns, &1)))
    else
      false
    end
  end

  defp held(fact, socket) do
    assigns = socket.assigns
    cleared = fact.clear(socket).assigns

    for key <- Enum.uniq(Map.keys(assigns) ++ Map.keys(cleared)),
        key != :__changed__,
        Map.get(assigns, key) != Map.get(cleared, key),
        do: key
  end

  defp apply_defaults(socket, %Moment{defaults: defaults}, facts) do
    Enum.reduce(defaults || [], socket, fn {key, strategy}, acc ->
      fact = Map.fetch!(facts, key)
      if fact.known?(acc.assigns), do: acc, else: fact.default(acc, strategy)
    end)
  end

  defp enter_facts(socket, %Moment{collects: collects}, params, facts) do
    Enum.reduce(collects, socket, fn key, acc ->
      fact = Map.fetch!(facts, key)
      if fact.required?(acc.assigns), do: fact.enter(acc, params), else: acc
    end)
  end

  defp opened(socket), do: socket.assigns[:journey_opened] || MapSet.new()

  # A navigator that reveals moments by itself moves the focus to the moment
  # an event made current; one that does not leaves `:current_state` alone,
  # and so the assigns.
  defp after_event({:noreply, socket}) do
    before = socket.assigns[:current_state]
    settled = settle(socket)

    if settled.assigns[:current_state] == before,
      do: {:noreply, settled},
      else: {:noreply, assign(settled, :journey_focus, settled.assigns[:current_state])}
  end

  defp after_event(other), do: other

  # The fact owning `event` among those `moment_key` collects, when that
  # moment is on screen, this booking needs the owner, and every fact the
  # owner needs is known. From a moment already answered (a page showing
  # several) the owner must also be one the booker may revisit, so a crafted
  # event cannot change what Back and Edit refuse to reopen: the meeting type
  # of a direct or private link.
  defp owner(journey, assigns, moment_key, event) do
    with {:ok, moment, state} <- visible_moment(journey, assigns, moment_key),
         {:ok, fact} <- owning_fact(moment, event),
         true <- fact.required?(assigns),
         true <- Enum.all?(fact.requires(assigns), &Journey.fact!(&1).known?(assigns)),
         true <- state == :current or fact.revisitable?(assigns) do
      {:ok, fact, state}
    else
      _refused -> :none
    end
  end

  defp visible_moment(journey, assigns, moment_key) do
    visible = journey.navigator.visible(journey, assigns)

    case Enum.find(visible, fn {moment, _state} -> moment.key == moment_key end) do
      {moment, state} -> {:ok, moment, state}
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
